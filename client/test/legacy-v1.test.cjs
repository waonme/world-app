const test = require('node:test')
const assert = require('node:assert/strict')

const { Api, NotFoundError, PermissionError } = require('../dist/cjs/index.js')

const OWNER = `con1${'a'.repeat(38)}`
const OTHER_OWNER = `con1${'b'.repeat(38)}`
const LEGACY_ID = 'm0123456789abcdefghijklmnop'
const REPLY_ID = 'mponmlkjihgfedcba9876543210'
const URI = `cckv://${OWNER}/concrnt.world/profiles/main/posts/${LEGACY_ID}`
const REPLY_SCHEMA = 'https://schema.concrnt.world/m/reply.json'

const makeLegacyResponse = ({ id = LEGACY_ID, author = OWNER, signer = OWNER } = {}) => ({
    status: 'ok',
    error: '',
    content: {
        id,
        author,
        schema: REPLY_SCHEMA,
        document: JSON.stringify({
            signer,
            type: 'message',
            schema: REPLY_SCHEMA,
            body: {
                body: 'legacy reply',
                replyToMessageAuthor: OTHER_OWNER,
                replyToMessageId: REPLY_ID
            },
            signedAt: '2025-01-02T03:04:05.000Z'
        }),
        cdate: '2025-01-02T03:04:06.000Z'
    }
})

const makeApi = (response = makeLegacyResponse()) => {
    const calls = {
        resource: [],
        resolve: [],
        online: [],
        legacy: []
    }
    const api = new Api('current.example', {}, {})

    api.getResource = async (...args) => {
        calls.resource.push(args)
        throw new NotFoundError('missing from v2', URI)
    }
    api.resolveDomain = async (...args) => {
        calls.resolve.push(args)
        return 'legacy.example'
    }
    api.getServerOnlineStatus = async (...args) => {
        calls.online.push(args)
        return true
    }
    api.fetchWithCredential = async (...args) => {
        calls.legacy.push(args)
        return response
    }

    return { api, calls }
}

test('getDocument falls back to a matching v1 message and maps its legacy reply target', async () => {
    const { api, calls } = makeApi()

    const document = await api.getDocument(URI, 'hint.example')

    assert.deepEqual(
        {
            kind: document.kind,
            key: document.key,
            schema: document.schema,
            author: document.author,
            value: document.value,
            createdAt: document.createdAt.toISOString()
        },
        {
            kind: 'record',
            key: URI,
            schema: REPLY_SCHEMA,
            author: OWNER,
            value: {
                body: 'legacy reply',
                replyToMessageAuthor: OTHER_OWNER,
                replyToMessageId: REPLY_ID,
                targetURI: `cckv://${OTHER_OWNER}/concrnt.world/profiles/main/posts/${REPLY_ID}`
            },
            createdAt: '2025-01-02T03:04:05.000Z'
        }
    )
    assert.deepEqual(calls.resolve, [[OWNER, 'hint.example']])
    assert.deepEqual(calls.online, [['legacy.example']])
    assert.deepEqual(calls.legacy, [['legacy.example', `/api/v1/message/${LEGACY_ID}`, {}, undefined]])
})

for (const [name, response] of [
    ['envelope owner', makeLegacyResponse({ author: OTHER_OWNER })],
    ['document signer', makeLegacyResponse({ signer: OTHER_OWNER })]
]) {
    test(`getDocument rejects a v1 response with a mismatched ${name}`, async () => {
        const { api } = makeApi(response)

        await assert.rejects(
            api.getDocument(URI),
            (error) => error instanceof NotFoundError && /identity does not match/.test(error.message)
        )
    })
}

test('getDocument does not try v1 for a non-legacy or non-standard post URI', async () => {
    const forbiddenURI = `cckv://${OWNER}/concrnt.world/profiles/main/posts/not-a-v1-id`
    const originalError = new NotFoundError('missing from v2', forbiddenURI)
    const { api, calls } = makeApi()
    api.getResource = async () => {
        throw originalError
    }

    await assert.rejects(api.getDocument(forbiddenURI), (error) => error === originalError)
    assert.equal(calls.resolve.length, 0)
    assert.equal(calls.online.length, 0)
    assert.equal(calls.legacy.length, 0)
})

test('getDocument never turns a v2 permission failure into a v1 fallback', async () => {
    const permissionError = new PermissionError('forbidden')
    const { api, calls } = makeApi()
    api.getResource = async () => {
        throw permissionError
    }

    await assert.rejects(api.getDocument(URI), (error) => error === permissionError)
    assert.equal(calls.resolve.length, 0)
    assert.equal(calls.online.length, 0)
    assert.equal(calls.legacy.length, 0)
})
