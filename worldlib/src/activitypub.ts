import { NotFoundError } from '@concrnt/client'

const DEFAULT_RETRY_DELAYS_MS = [0, 300, 1000, 2500]
const FIVE_MINUTES_MS = 5 * 60 * 1000
const THIRTY_MINUTES_MS = 30 * 60 * 1000
const DEFAULT_CACHE_TTL_MS = FIVE_MINUTES_MS
const MAX_CACHE_ENTRIES = 1000
const MAX_CONCURRENT_RESOLVES = 8

const ACTOR_TYPES = new Set(['Application', 'Group', 'Organization', 'Person', 'Service'])

export interface ActivitypubResolveApi {
    callConcrntApi<T>(host: string, api: string, args: Record<string, string>, init?: RequestInit): Promise<T>
}

export interface ActivitypubResolveOptions {
    cacheTtlMs?: number
    revalidateAfterMs?: number
    force?: boolean
    retryDelaysMs?: number[]
}

interface CachePolicy {
    revalidateAfterMs: number
    cacheTtlMs: number
}

interface CacheEntry {
    promise: Promise<unknown>
    resolvedAt?: number
    policy?: CachePolicy
    refreshPromise?: Promise<unknown>
}

const cache = new Map<string, CacheEntry>()
const resolveQueue: Array<() => void> = []
let activeResolves = 0

const normalizeUri = (uri: string): string => uri.trim().replace(/^activity:\/\//, 'https://')

const cacheKey = (domain: string, uri: string): string => `${domain}\n${normalizeUri(uri)}`

const wait = (delayMs: number): Promise<void> =>
    delayMs > 0 ? new Promise((resolve) => setTimeout(resolve, delayMs)) : Promise.resolve()

const isNotFound = (error: unknown): boolean => error instanceof NotFoundError

const getObjectType = (value: unknown): string | undefined => {
    if (!value || typeof value !== 'object' || !('type' in value)) return undefined
    const type = (value as { type?: unknown }).type
    return typeof type === 'string' ? type : undefined
}

const getCachePolicy = (value: unknown): CachePolicy => {
    const type = getObjectType(value)

    if (type === 'Note') {
        return {
            revalidateAfterMs: FIVE_MINUTES_MS,
            cacheTtlMs: THIRTY_MINUTES_MS
        }
    }

    if (ACTOR_TYPES.has(type ?? '')) {
        return {
            revalidateAfterMs: FIVE_MINUTES_MS,
            cacheTtlMs: FIVE_MINUTES_MS
        }
    }

    return {
        revalidateAfterMs: DEFAULT_CACHE_TTL_MS,
        cacheTtlMs: DEFAULT_CACHE_TTL_MS
    }
}

const applyCachePolicyOverrides = (policy: CachePolicy, options: ActivitypubResolveOptions): CachePolicy => {
    const cacheTtlMs = Math.max(0, options.cacheTtlMs ?? policy.cacheTtlMs)
    const revalidateAfterMs = Math.min(
        cacheTtlMs,
        Math.max(
            0,
            options.revalidateAfterMs ?? (options.cacheTtlMs === undefined ? policy.revalidateAfterMs : cacheTtlMs)
        )
    )

    return { revalidateAfterMs, cacheTtlMs }
}

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

const startBackgroundRefresh = <T>(
    entry: CacheEntry,
    key: string,
    api: ActivitypubResolveApi,
    domain: string,
    uri: string,
    retryDelaysMs: number[]
): void => {
    if (entry.refreshPromise) return

    const refreshPromise = resolveWithRetry<T>(api, domain, uri, retryDelaysMs)
    entry.refreshPromise = refreshPromise

    refreshPromise.then(
        (value) => {
            if (cache.get(key) !== entry) return
            entry.promise = Promise.resolve(value)
            entry.resolvedAt = Date.now()
            entry.policy = getCachePolicy(value)
            entry.refreshPromise = undefined
            pruneCache()
        },
        (error) => {
            if (cache.get(key) !== entry) return
            entry.refreshPromise = undefined

            // A retried 404 can represent a remote Delete/Tombstone. Do not
            // keep serving the stale Note after the bridge confirms it absent.
            if (isNotFound(error)) cache.delete(key)
        }
    )
}

/**
 * Resolves an ActivityPub object while sharing in-flight requests and recent
 * successful results. The bridge can transiently return 404 for an existing
 * remote object, so only NotFoundError is retried. Notes are served stale while
 * they are revalidated between 5 and 30 minutes; actor objects use a 5-minute
 * cache so profile changes propagate sooner.
 */
export const resolveActivitypubObject = <T>(
    api: ActivitypubResolveApi,
    domain: string,
    uri: string,
    options: ActivitypubResolveOptions = {}
): Promise<T> => {
    const key = cacheKey(domain, uri)
    const cached = cache.get(key)
    const retryDelaysMs = options.retryDelaysMs?.length ? options.retryDelaysMs : DEFAULT_RETRY_DELAYS_MS

    if (!options.force && cached) {
        const resolvedAt = cached.resolvedAt
        if (resolvedAt === undefined) return cached.promise as Promise<T>

        const storedPolicy = cached.policy ?? {
            revalidateAfterMs: options.cacheTtlMs ?? DEFAULT_CACHE_TTL_MS,
            cacheTtlMs: options.cacheTtlMs ?? DEFAULT_CACHE_TTL_MS
        }
        const policy = applyCachePolicyOverrides(storedPolicy, options)
        const ageMs = Date.now() - resolvedAt

        if (ageMs < policy.revalidateAfterMs) return cached.promise as Promise<T>

        if (ageMs < policy.cacheTtlMs) {
            startBackgroundRefresh<T>(cached, key, api, domain, uri, retryDelaysMs)
            return cached.promise as Promise<T>
        }

        cache.delete(key)
    }

    const promise = resolveWithRetry<T>(api, domain, uri, retryDelaysMs)
    const entry: CacheEntry = { promise }
    cache.set(key, entry)

    promise.then(
        (value) => {
            if (cache.get(key) !== entry) return
            entry.resolvedAt = Date.now()
            entry.policy = getCachePolicy(value)
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
