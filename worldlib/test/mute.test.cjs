const test = require('node:test')
const assert = require('node:assert/strict')

const { Client } = require('../dist/cjs/client.js')
const {
    combineMuteMatches,
    findMute,
    isMuteEntryExpired,
    muteEntryId,
    normalizeMuteText,
    normalizeMuteWord
} = require('../dist/cjs/mute.js')

test('combined message boundaries keep block and hard-hide matches unrevealable', () => {
    const outerWord = { reason: 'word', value: 'outer', entry: { type: 'word', target: 'outer' } }
    const targetBlock = { reason: 'block', value: 'cc1blocked' }
    const combinedBlock = combineMuteMatches([outerWord, targetBlock])

    assert.equal(combinedBlock.match, targetBlock)
    assert.equal(combinedBlock.fullyHidden, true)

    const targetUser = { reason: 'user', value: 'cc1target', entry: { type: 'user', target: 'cc1target' } }
    const outerHardHide = {
        reason: 'timeline',
        value: 'ccat://example.com/timeline/main',
        entry: { type: 'timeline', target: 'ccat://example.com/timeline/main', hidePlaceholder: true }
    }
    const combinedHardHide = combineMuteMatches([outerHardHide, targetUser])

    assert.equal(combinedHardHide.match, targetUser)
    assert.equal(combinedHardHide.fullyHidden, true)
})

test('mute text and words use lowercase NFKC normalization', () => {
    assert.equal(normalizeMuteText('ＡＢＣ・ｶﾀｶﾅ'), 'abc・カタカナ')
    assert.equal(normalizeMuteWord('  ＴＥＳＴ\u3000'), 'test')

    const match = findMute({ author: 'cc1author', body: 'prefix ＴＥＳＴ suffix' }, [
        { type: 'word', target: 'ｔｅｓｔ' }
    ])
    assert.equal(match?.reason, 'word')
})

test('mute entry IDs are deterministic and word IDs use normalized targets', () => {
    const canonicalWordId = 'xqzg0q6re2u859em81cma2kzq'

    assert.equal(muteEntryId('word', 'test'), canonicalWordId)
    assert.equal(muteEntryId('word', ' ＴＥＳＴ '), canonicalWordId)
    assert.equal(muteEntryId('word', 'test'), muteEntryId('word', 'test'))
    assert.notEqual(muteEntryId('user', 'test'), canonicalWordId)
    assert.notEqual(muteEntryId('timeline', 'test'), canonicalWordId)
})

test('expiry is inclusive and invalid dates remain active', () => {
    const now = new Date('2026-08-27T12:00:00.000Z')

    assert.equal(isMuteEntryExpired({ type: 'user', target: 'cc1user' }, now), false)
    assert.equal(
        isMuteEntryExpired({ type: 'user', target: 'cc1user', expiresAt: '2026-08-27T12:00:00.001Z' }, now),
        false
    )
    assert.equal(
        isMuteEntryExpired({ type: 'user', target: 'cc1user', expiresAt: '2026-08-27T12:00:00.000Z' }, now),
        true
    )
    assert.equal(
        isMuteEntryExpired({ type: 'user', target: 'cc1user', expiresAt: '2026-08-27T11:59:59.999Z' }, now),
        true
    )
    assert.equal(isMuteEntryExpired({ type: 'user', target: 'cc1user', expiresAt: 'not-a-date' }, now), false)
})

test('match priority is block, user, word, then timeline regardless of entry order', () => {
    const target = {
        author: 'cc1author',
        body: 'contains forbidden text',
        timelines: ['ccat://example.com/timeline/main']
    }
    const timeline = { type: 'timeline', target: 'ccat://example.com/timeline/main' }
    const word = { type: 'word', target: 'forbidden' }
    const user = { type: 'user', target: 'cc1author' }

    assert.equal(findMute(target, [timeline, word, user], { blocks: ['cc1author'] })?.reason, 'block')
    assert.equal(findMute(target, [timeline, word, user])?.reason, 'user')
    assert.equal(findMute(target, [timeline, word])?.reason, 'word')
    assert.equal(findMute(target, [timeline])?.reason, 'timeline')
})

test('home-scoped entries only apply at home and expired entries are skipped', () => {
    const entries = [
        { type: 'word', target: 'home-only', scope: 'home' },
        { type: 'word', target: 'expired', expiresAt: '2026-08-27T11:59:59.999Z' }
    ]
    const now = new Date('2026-08-27T12:00:00.000Z')

    assert.equal(
        findMute({ author: 'cc1author', body: 'home-only' }, entries, { viewContext: 'other', now }),
        undefined
    )
    assert.equal(
        findMute({ author: 'cc1author', body: 'home-only' }, entries, { viewContext: 'home', now })?.reason,
        'word'
    )
    assert.equal(findMute({ author: 'cc1author', body: 'expired' }, entries, { viewContext: 'home', now }), undefined)
})

test('reroutes-only user entries do not hide the author original posts', () => {
    const entries = [{ type: 'user', target: 'cc1author', reroutesOnly: true }]

    assert.equal(findMute({ author: 'cc1author', isReroute: false }, entries), undefined)
    assert.equal(findMute({ author: 'cc1author', isReroute: true }, entries)?.reason, 'user')
})

test('Client.mute persists a normalized private record and reloads the cache', async () => {
    const committed = []
    let reloads = 0
    const receiver = {
        ccid: 'cc1owner',
        api: {
            commit: async (document) => committed.push(document)
        },
        mutes: {
            reload: () => {
                reloads += 1
            }
        }
    }

    await Client.prototype.mute.call(receiver, {
        type: 'word',
        target: ' ＴＥＳＴ ',
        scope: 'home',
        hidePlaceholder: true
    })

    assert.equal(committed.length, 1)
    assert.deepEqual(
        {
            kind: committed[0].kind,
            key: committed[0].key,
            schema: committed[0].schema,
            value: committed[0].value,
            author: committed[0].author,
            policy: committed[0].policy
        },
        {
            kind: 'record',
            key: 'cckv://cc1owner/concrnt.world/mutes/xqzg0q6re2u859em81cma2kzq',
            schema: 'https://schema.concrnt.world/s/mute.json',
            value: { type: 'word', target: 'test', scope: 'home', hidePlaceholder: true },
            author: 'cc1owner',
            policy: {
                entries: [{ url: 'https://policy.concrnt.world/private.json' }]
            }
        }
    )
    assert.ok(committed[0].createdAt instanceof Date)
    assert.equal(reloads, 1)
})

test('Client.unmute deletes the same deterministic URI and reloads the cache', async () => {
    const deleted = []
    let reloads = 0
    const receiver = {
        ccid: 'cc1owner',
        api: {
            delete: async (uri) => deleted.push(uri)
        },
        mutes: {
            reload: () => {
                reloads += 1
            }
        }
    }

    await Client.prototype.unmute.call(receiver, 'word', ' ＴＥＳＴ ')

    assert.deepEqual(deleted, ['cckv://cc1owner/concrnt.world/mutes/xqzg0q6re2u859em81cma2kzq'])
    assert.equal(reloads, 1)
})

test('mute refresh bypasses query cache and preserves the last list on refresh failure', async () => {
    const calls = []
    let response = [{ type: 'user', target: 'cc1old' }]
    let fail = false
    const api = {
        defaultHost: 'home.example',
        queryAll: async (_query, _domain, options) => {
            calls.push(options)
            if (fail) throw new Error('offline')
            return response.map((entry, index) => ({
                cckv: `cckv://cc1owner/concrnt.world/mutes/${index}`,
                document: JSON.stringify({ value: entry })
            }))
        },
        delete: async () => {}
    }
    const client = new Client(api, 'cc1owner', {}, { domain: 'home.example' })

    assert.deepEqual(await client.mutes.value(), [{ type: 'user', target: 'cc1old' }])
    assert.equal(calls[0].cache, true)

    response = [{ type: 'word', target: 'new' }]
    await client.mutes.refresh()
    assert.deepEqual(client.mutes.current, [{ type: 'word', target: 'new' }])
    assert.equal(calls[1].cache, false)

    const originalSetTimeout = global.setTimeout
    const originalConsoleError = console.error
    global.setTimeout = () => ({})
    console.error = () => {}
    try {
        fail = true
        await client.mutes.refresh()
    } finally {
        global.setTimeout = originalSetTimeout
        console.error = originalConsoleError
    }
    assert.deepEqual(client.mutes.current, [{ type: 'word', target: 'new' }])
})
