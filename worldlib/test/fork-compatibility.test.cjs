const test = require('node:test')
const assert = require('node:assert/strict')

const {
    V1_SUBKEY_PROVISION_MARKER,
    WEB_LOGOUT_STORAGE_KEYS,
    atprotoFollowKey,
    bridgeEnabledAfterSaveFailure,
    bridgeSettingsStatusAfterLoad,
    canWriteBridgeSettings,
    decideStoredSessionAction,
    legacyAtprotoFollowKey
} = require('../dist/cjs/forkCompatibility.js')

test('stored session policy never auto-provisions an ordinary logged-out session', () => {
    const base = { domain: 'home.example', masterKey: 'master', subKey: undefined }

    assert.equal(decideStoredSessionAction({ ...base, v1SubkeyProvisionPending: false }), 'explicit-reenrollment')
    assert.equal(decideStoredSessionAction({ ...base, v1SubkeyProvisionPending: true }), 'provision-v1-subkey')
    assert.equal(
        decideStoredSessionAction({
            domain: 'home.example',
            masterKey: undefined,
            subKey: 'sub',
            v1SubkeyProvisionPending: false
        }),
        'ready'
    )
    assert.equal(
        decideStoredSessionAction({
            domain: undefined,
            masterKey: 'master',
            subKey: undefined,
            v1SubkeyProvisionPending: true
        }),
        'no-session'
    )
})

test('logout clears transient session state but retains recovery material', () => {
    assert.ok(WEB_LOGOUT_STORAGE_KEYS.includes('SubKey'))
    assert.ok(WEB_LOGOUT_STORAGE_KEYS.includes(V1_SUBKEY_PROVISION_MARKER))
    assert.ok(WEB_LOGOUT_STORAGE_KEYS.includes('composerDraft'))
    assert.equal(WEB_LOGOUT_STORAGE_KEYS.includes('Domain'), false)
    assert.equal(WEB_LOGOUT_STORAGE_KEYS.includes('PrivateKey'), false)
    assert.equal(WEB_LOGOUT_STORAGE_KEYS.includes('Mnemonic'), false)
})

test('bridge settings stay read-only until a successful or missing-record load', () => {
    assert.equal(bridgeSettingsStatusAfterLoad('found'), 'ready')
    assert.equal(bridgeSettingsStatusAfterLoad('missing'), 'ready')
    assert.equal(bridgeSettingsStatusAfterLoad('error'), 'load-failed')
    assert.equal(canWriteBridgeSettings('loading', false), false)
    assert.equal(canWriteBridgeSettings('load-failed', false), false)
    assert.equal(canWriteBridgeSettings('ready', true), false)
    assert.equal(canWriteBridgeSettings('ready', false), true)
    assert.equal(bridgeEnabledAfterSaveFailure(true, false), false)
    assert.equal(bridgeEnabledAfterSaveFailure(false, true), true)
    assert.equal(bridgeEnabledAfterSaveFailure(true), true)
})

test('current and legacy Bluesky follow keys remain distinct and addressable', () => {
    const ccid = 'cc1owner'
    const did = 'did:plc:example'

    assert.equal(legacyAtprotoFollowKey(ccid, did), 'cckv://cc1owner/atproto.concrnt.world/follows/did:plc:example')
    assert.equal(atprotoFollowKey(ccid, did), 'cckv://cc1owner/atproto.concrnt.world/follows/x2qst2zft9sabpzd3mztshm4n')
    assert.notEqual(atprotoFollowKey(ccid, did), legacyAtprotoFollowKey(ccid, did))
})
