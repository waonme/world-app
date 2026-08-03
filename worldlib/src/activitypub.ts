import { NotFoundError } from '@concrnt/client'

const DEFAULT_RETRY_DELAYS_MS = [0, 300, 1000, 2500]
const DEFAULT_CACHE_TTL_MS = 5 * 60 * 1000
const MAX_CACHE_ENTRIES = 1000
const MAX_CONCURRENT_RESOLVES = 8

export interface ActivitypubResolveApi {
    callConcrntApi<T>(host: string, api: string, args: Record<string, string>, init?: RequestInit): Promise<T>
}

export interface ActivitypubResolveOptions {
    cacheTtlMs?: number
    force?: boolean
    retryDelaysMs?: number[]
}

interface CacheEntry {
    promise: Promise<unknown>
    resolvedAt?: number
}

const cache = new Map<string, CacheEntry>()
const resolveQueue: Array<() => void> = []
let activeResolves = 0

const normalizeUri = (uri: string): string => uri.trim().replace(/^activity:\/\//, 'https://')

const cacheKey = (domain: string, uri: string): string => `${domain}\n${normalizeUri(uri)}`

const wait = (delayMs: number): Promise<void> =>
    delayMs > 0 ? new Promise((resolve) => setTimeout(resolve, delayMs)) : Promise.resolve()

const isNotFound = (error: unknown): boolean => error instanceof NotFoundError

const acquireResolveSlot = (): Promise<void> => {
    if (activeResolves < MAX_CONCURRENT_RESOLVES) {
        activeResolves += 1
        return Promise.resolve()
    }

    return new Promise((resolve) => {
        resolveQueue.push(() => {
            activeResolves += 1
            resolve()
        })
    })
}

const releaseResolveSlot = (): void => {
    activeResolves -= 1
    resolveQueue.shift()?.()
}

const withResolveSlot = async <T>(resolver: () => Promise<T>): Promise<T> => {
    await acquireResolveSlot()
    try {
        return await resolver()
    } finally {
        releaseResolveSlot()
    }
}

const resolveWithRetry = async <T>(
    api: ActivitypubResolveApi,
    domain: string,
    uri: string,
    retryDelaysMs: number[]
): Promise<T> => {
    let lastError: unknown

    for (let attempt = 0; attempt < retryDelaysMs.length; attempt += 1) {
        await wait(retryDelaysMs[attempt])

        try {
            return await withResolveSlot(() =>
                api.callConcrntApi<T>(domain, 'net.concrnt.activitypub.resolve', {
                    uri: normalizeUri(uri)
                })
            )
        } catch (error) {
            lastError = error
            if (!isNotFound(error) || attempt === retryDelaysMs.length - 1) {
                throw error
            }
        }
    }

    throw lastError
}

const pruneCache = (): void => {
    if (cache.size <= MAX_CACHE_ENTRIES) return

    const resolvedEntries = [...cache.entries()]
        .filter((entry): entry is [string, CacheEntry & { resolvedAt: number }] => entry[1].resolvedAt !== undefined)
        .sort((a, b) => a[1].resolvedAt - b[1].resolvedAt)

    for (const [key] of resolvedEntries.slice(0, cache.size - MAX_CACHE_ENTRIES)) {
        cache.delete(key)
    }
}

/**
 * Resolves an ActivityPub object while sharing in-flight requests and recent
 * successful results. The bridge can transiently return 404 for an existing
 * remote object, so only NotFoundError is retried.
 */
export const resolveActivitypubObject = <T>(
    api: ActivitypubResolveApi,
    domain: string,
    uri: string,
    options: ActivitypubResolveOptions = {}
): Promise<T> => {
    const key = cacheKey(domain, uri)
    const cacheTtlMs = options.cacheTtlMs ?? DEFAULT_CACHE_TTL_MS
    const cached = cache.get(key)

    if (!options.force && cached) {
        const isPending = cached.resolvedAt === undefined
        const isFresh = cached.resolvedAt !== undefined && Date.now() - cached.resolvedAt < cacheTtlMs
        if (isPending || isFresh) return cached.promise as Promise<T>
        cache.delete(key)
    }

    const retryDelaysMs = options.retryDelaysMs?.length ? options.retryDelaysMs : DEFAULT_RETRY_DELAYS_MS
    const promise = resolveWithRetry<T>(api, domain, uri, retryDelaysMs)
    const entry: CacheEntry = { promise }
    cache.set(key, entry)

    promise.then(
        () => {
            if (cache.get(key) !== entry) return
            entry.resolvedAt = Date.now()
            pruneCache()
        },
        () => {
            // A later render or manual retry must be able to try again.
            if (cache.get(key) === entry) cache.delete(key)
        }
    )

    return promise
}

export const invalidateActivitypubObject = (domain: string, uri: string): void => {
    cache.delete(cacheKey(domain, uri))
}

export const clearActivitypubObjectCache = (): void => {
    cache.clear()
}
