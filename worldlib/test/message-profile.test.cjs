const assert = require('node:assert/strict')
const test = require('node:test')

const { Message } = require('../dist/cjs/message.js')

const bridgeID = 'con1activitypubbridge'
const messageURI = 'ccfs://association'

const createClient = (profileOverride) => ({
    ccid: undefined,
    api: {
        getDocument: async (uri) => {
            if (uri === messageURI) {
                return {
                    kind: 'association',
                    schema: 'https://schema.concrnt.world/a/like.json',
                    author: bridgeID,
                    value: profileOverride ? { profileOverride } : {},
                    createdAt: new Date('2026-08-03T00:00:00Z')
                }
            }

            return {
                kind: 'record',
                schema: 'https://schema.concrnt.world/p/main.json',
                author: bridgeID,
                value: {
                    username: 'ActivityPub Bridge',
                    avatar: 'https://example.com/bridge.png'
                },
                createdAt: new Date('2026-08-03T00:00:00Z')
            }
        },
        getEntity: async () => ({
            kind: 'record',
            schema: 'https://schema.concrnt.world/entity.json',
            author: bridgeID,
            value: { domain: 'example.com' },
            createdAt: new Date('2026-08-03T00:00:00Z')
        }),
        getAssociationCounts: async () => ({})
    }
})

test('Message.load uses profileOverride for an ActivityPub actor', async () => {
    const message = await Message.load(
        createClient({
            username: 'Remote User',
            avatar: 'https://remote.example/avatar.png'
        }),
        messageURI
    )

    assert.equal(message.authorUser.profile.username, 'ActivityPub Bridge')
    assert.equal(message.authorProfile.username, 'Remote User')
    assert.equal(message.authorProfile.avatar, 'https://remote.example/avatar.png')
})

test('Message.load falls back to the record author profile without an override', async () => {
    const message = await Message.load(createClient(), messageURI)

    assert.equal(message.authorProfile.username, 'ActivityPub Bridge')
    assert.equal(message.authorProfile.avatar, 'https://example.com/bridge.png')
})

test('Message.load preserves base profile fields missing from a partial override', async () => {
    const message = await Message.load(createClient({ username: 'Remote User' }), messageURI)

    assert.equal(message.authorProfile.username, 'Remote User')
    assert.equal(message.authorProfile.avatar, 'https://example.com/bridge.png')
})
