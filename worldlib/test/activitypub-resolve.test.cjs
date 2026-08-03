const assert = require('node:assert/strict')
const test = require('node:test')

const { NotFoundError } = require('@concrnt/client')
const {
    clearActivitypubObjectCache,
    invalidateActivitypubObject,
    resolveActivitypubObject
} = require('../dist/cjs/activitypub.js')

test.beforeEach(() => {
    clearActivitypubObjectCache()
})

test('deduplicates concurrent resolves and caches successful objects', async () => {
    let calls = 0
    const api = {
        callConcrntApi: async () => {
            calls += 1
            await new Promise((resolve) => setTimeout(resolve, 5))
            return { id: 'https://example.com/notes/1', type: 'Note' }
        }
    }

    const first = resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/1')
    const second = resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/1')
    assert.equal(first, second)

    const [firstValue, secondValue] = await Promise.all([first, second])
    assert.deepEqual(firstValue, secondValue)
    assert.equal(calls, 1)

    await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/1')
    assert.equal(calls, 1)
})

test('retries a transient not-found response', async () => {
    let calls = 0
    const api = {
        callConcrntApi: async () => {
            calls += 1
            if (calls < 3) throw new NotFoundError('temporary 404', 'https://example.com/notes/2')
            return { id: 'https://example.com/notes/2', type: 'Note' }
        }
    }

    const value = await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/2', {
        retryDelaysMs: [0, 0, 0]
    })

    assert.equal(value.id, 'https://example.com/notes/2')
    assert.equal(calls, 3)
})

test('does not retain a failed resolve and supports explicit invalidation', async () => {
    let calls = 0
    const api = {
        callConcrntApi: async () => {
            calls += 1
            if (calls === 1) throw new NotFoundError('temporary 404', 'https://example.com/notes/3')
            return { id: 'https://example.com/notes/3', type: 'Note' }
        }
    }

    await assert.rejects(
        resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/3', { retryDelaysMs: [0] })
    )
    await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/3', { retryDelaysMs: [0] })
    assert.equal(calls, 2)

    invalidateActivitypubObject('example.net', 'https://example.com/notes/3')
    await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/3', { retryDelaysMs: [0] })
    assert.equal(calls, 3)
})

test('limits concurrent bridge requests', async () => {
    let active = 0
    let maxActive = 0
    const api = {
        callConcrntApi: async (_domain, _api, args) => {
            active += 1
            maxActive = Math.max(maxActive, active)
            await new Promise((resolve) => setTimeout(resolve, 5))
            active -= 1
            return { id: args.uri, type: 'Note' }
        }
    }

    await Promise.all(
        Array.from({ length: 24 }, (_, index) =>
            resolveActivitypubObject(api, 'example.net', `https://example.com/notes/${index}`, {
                retryDelaysMs: [0]
            })
        )
    )

    assert.equal(maxActive, 8)
})

test('serves a Note stale while revalidating between 5 and 30 minutes', async () => {
    const originalNow = Date.now
    let now = 1_000_000
    Date.now = () => now

    try {
        let calls = 0
        let finishRefresh
        const api = {
            callConcrntApi: async () => {
                calls += 1
                if (calls === 1) {
                    return { id: 'https://example.com/notes/4', type: 'Note', content: 'before' }
                }
                return new Promise((resolve) => {
                    finishRefresh = resolve
                })
            }
        }

        const first = await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/4')
        now += 6 * 60 * 1000

        const stale = await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/4')
        await new Promise((resolve) => setImmediate(resolve))

        assert.equal(stale, first)
        assert.equal(stale.content, 'before')
        assert.equal(calls, 2)

        finishRefresh({ id: 'https://example.com/notes/4', type: 'Note', content: 'after' })
        await new Promise((resolve) => setImmediate(resolve))

        const refreshed = await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/4')
        assert.equal(refreshed.content, 'after')
        assert.equal(calls, 2)
    } finally {
        Date.now = originalNow
    }
})

test('blocks on refresh after a Note reaches 30 minutes', async () => {
    const originalNow = Date.now
    let now = 2_000_000
    Date.now = () => now

    try {
        let calls = 0
        let finishRefresh
        const api = {
            callConcrntApi: async () => {
                calls += 1
                if (calls === 1) return { id: 'https://example.com/notes/5', type: 'Note', content: 'before' }
                return new Promise((resolve) => {
                    finishRefresh = resolve
                })
            }
        }

        await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/5')
        now += 31 * 60 * 1000

        const refresh = resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/5')
        await new Promise((resolve) => setImmediate(resolve))
        assert.equal(calls, 2)

        finishRefresh({ id: 'https://example.com/notes/5', type: 'Note', content: 'after' })
        assert.equal((await refresh).content, 'after')
    } finally {
        Date.now = originalNow
    }
})

test('refreshes an actor after 5 minutes instead of serving it stale', async () => {
    const originalNow = Date.now
    let now = 3_000_000
    Date.now = () => now

    try {
        let calls = 0
        let finishRefresh
        const api = {
            callConcrntApi: async () => {
                calls += 1
                if (calls === 1) return { id: 'https://example.com/users/alice', type: 'Person', name: 'Before' }
                return new Promise((resolve) => {
                    finishRefresh = resolve
                })
            }
        }

        await resolveActivitypubObject(api, 'example.net', 'https://example.com/users/alice')
        now += 6 * 60 * 1000

        const refresh = resolveActivitypubObject(api, 'example.net', 'https://example.com/users/alice')
        await new Promise((resolve) => setImmediate(resolve))
        assert.equal(calls, 2)

        finishRefresh({ id: 'https://example.com/users/alice', type: 'Person', name: 'After' })
        assert.equal((await refresh).name, 'After')
    } finally {
        Date.now = originalNow
    }
})

test('drops a stale Note when background revalidation confirms not found', async () => {
    const originalNow = Date.now
    let now = 4_000_000
    Date.now = () => now

    try {
        let calls = 0
        const api = {
            callConcrntApi: async () => {
                calls += 1
                if (calls === 1) return { id: 'https://example.com/notes/6', type: 'Note', content: 'before' }
                if (calls === 2) throw new NotFoundError('deleted', 'https://example.com/notes/6')
                return { id: 'https://example.com/notes/6', type: 'Note', content: 'restored' }
            }
        }

        await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/6')
        now += 6 * 60 * 1000

        const stale = await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/6', {
            retryDelaysMs: [0]
        })
        assert.equal(stale.content, 'before')
        await new Promise((resolve) => setImmediate(resolve))

        const restored = await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/6', {
            retryDelaysMs: [0]
        })
        assert.equal(restored.content, 'restored')
        assert.equal(calls, 3)
    } finally {
        Date.now = originalNow
    }
})

test('keeps cacheTtlMs as a per-call override', async () => {
    const originalNow = Date.now
    let now = 5_000_000
    Date.now = () => now

    try {
        let calls = 0
        const api = {
            callConcrntApi: async () => {
                calls += 1
                return { id: 'https://example.com/notes/7', type: 'Note', content: `version ${calls}` }
            }
        }

        await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/7')
        now += 1

        const forcedByTtl = await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/7', {
            cacheTtlMs: 0,
            retryDelaysMs: [0]
        })
        assert.equal(forcedByTtl.content, 'version 2')

        const defaultPolicy = await resolveActivitypubObject(api, 'example.net', 'https://example.com/notes/7')
        assert.equal(defaultPolicy.content, 'version 2')
        assert.equal(calls, 2)
    } finally {
        Date.now = originalNow
    }
})
