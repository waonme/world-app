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
