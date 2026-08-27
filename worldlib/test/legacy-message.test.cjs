const test = require('node:test')
const assert = require('node:assert/strict')

const { Client } = require('../dist/cjs/client.js')

const AUTHOR = `con1${'a'.repeat(38)}`
const VIEWER = `con1${'b'.repeat(38)}`
const LEGACY_ID = 'm0123456789abcdefghijklmnop'
const URI = `cckv://${AUTHOR}/concrnt.world/profiles/main/posts/${LEGACY_ID}`
const SCHEMA = 'https://schema.concrnt.world/m/plaintext.json'

test('a legacy message remains usable when association APIs fail, with a short hint-specific cache', async () => {
    const messageRequests = []
    let associationAttempts = 0
    let countAttempts = 0
    let commitAttempts = 0
    const receiver = {
        ccid: VIEWER,
        messageCache: {},
        rerouteTargets: {},
        api: {
            getDocument: async (requestedURI, hint) => {
                if (requestedURI !== URI) throw new Error('profile unavailable')
                messageRequests.push(hint)
                if (hint === 'broken.example') throw new Error('v1 backend unavailable')
                return {
                    kind: 'record',
                    key: URI,
                    schema: SCHEMA,
                    value: { body: 'legacy body' },
                    author: AUTHOR,
                    createdAt: new Date('2025-01-02T03:04:05.000Z')
                }
            },
            getEntity: async () => {
                throw new Error('entity unavailable')
            },
            getAssociationsAll: async () => {
                associationAttempts += 1
                throw new Error('legacy server has no association API')
            },
            getAssociationCounts: async () => {
                countAttempts += 1
                throw new Error('legacy server has no association count API')
            },
            commit: async () => {
                commitAttempts += 1
            }
        }
    }

    const originalDateNow = Date.now
    Date.now = () => 1_800_000_000_000
    try {
        const firstPromise = Client.prototype.getMessage.call(receiver, URI, 'legacy.example')
        const message = await firstPromise
        await Promise.resolve()

        assert.equal(message.value.body, 'legacy body')
        assert.equal(message.ownAssociationsLoaded, false)
        assert.deepEqual(message.ownAssociations, [])
        assert.deepEqual(message.associationCounts, {})
        assert.deepEqual(message.reactionCounts, {})
        assert.equal(associationAttempts, 1)
        assert.equal(countAttempts, 2)

        const legacyKey = `${URI}\0legacy.example`
        assert.equal(receiver.messageCache[legacyKey].expire, Date.now() + 5_000)
        assert.strictEqual(Client.prototype.getMessage.call(receiver, URI, 'legacy.example'), firstPromise)

        const mirrorPromise = Client.prototype.getMessage.call(receiver, URI, 'mirror.example')
        assert.notStrictEqual(mirrorPromise, firstPromise)
        await mirrorPromise
        await Promise.resolve()
        assert.equal(receiver.messageCache[`${URI}\0mirror.example`].expire, Date.now() + 5_000)
        assert.deepEqual(messageRequests, ['legacy.example', 'mirror.example'])

        await assert.rejects(message.favorite(receiver), /own association state is unavailable/)
        await assert.rejects(
            message.reaction(receiver, ':wave:', 'https://example.com/wave.png'),
            /own association state is unavailable/
        )
        assert.equal(commitAttempts, 0)

        const brokenKey = `${URI}\0broken.example`
        await assert.rejects(
            Client.prototype.getMessage.call(receiver, URI, 'broken.example'),
            /v1 backend unavailable/
        )
        await Promise.resolve()
        assert.equal(receiver.messageCache[brokenKey], undefined)

        await assert.rejects(
            Client.prototype.getMessage.call(receiver, URI, 'broken.example'),
            /v1 backend unavailable/
        )
        assert.equal(messageRequests.filter((hint) => hint === 'broken.example').length, 2)
    } finally {
        Date.now = originalDateNow
    }
})
