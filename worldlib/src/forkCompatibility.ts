import { CDID } from '@concrnt/client'

export const V1_SUBKEY_PROVISION_MARKER = 'V1SubkeyProvisionPending'

export type StoredSessionAction = 'no-session' | 'ready' | 'provision-v1-subkey' | 'explicit-reenrollment'

export const decideStoredSessionAction = (input: {
    domain?: string | null
    masterKey?: string | null
    subKey?: string | null
    v1SubkeyProvisionPending: boolean
}): StoredSessionAction => {
    if (!input.domain || (!input.masterKey && !input.subKey)) return 'no-session'
    if (input.masterKey && !input.subKey) {
        return input.v1SubkeyProvisionPending ? 'provision-v1-subkey' : 'explicit-reenrollment'
    }
    return 'ready'
}

// logoutは再登録に必要な接続先・master key・mnemonicを保持する。
// それらを消すのはbackupを要求するResetSessionButtonだけ。
export const WEB_LOGOUT_STORAGE_KEYS = [
    'SubKey',
    'SelectedProfile',
    'V1EntityProofPending',
    V1_SUBKEY_PROVISION_MARKER,
    'composerDraft'
] as const

export type BridgeSettingsStatus = 'loading' | 'ready' | 'load-failed'
export type BridgeSettingsLoadOutcome = 'found' | 'missing' | 'error'

export const bridgeSettingsStatusAfterLoad = (outcome: BridgeSettingsLoadOutcome): BridgeSettingsStatus =>
    outcome === 'error' ? 'load-failed' : 'ready'

export const canWriteBridgeSettings = (status: BridgeSettingsStatus, saving: boolean): boolean =>
    status === 'ready' && !saving

export const bridgeEnabledAfterSaveFailure = (current: boolean, rollback?: boolean): boolean => rollback ?? current

export const runAfterSuccessfulBackup = async <T>(
    save: () => Promise<T>,
    onBackupComplete?: () => void
): Promise<T> => {
    const result = await save()
    onBackupComplete?.()
    return result
}

export const atprotoFollowKey = (ccid: string, did: string): string =>
    `cckv://${ccid}/atproto.concrnt.world/follows/${CDID.newFromStringX(did).toString()}`

// 2026-08以前のクライアントが使っていたDID直書きキー。
export const legacyAtprotoFollowKey = (ccid: string, did: string): string =>
    `cckv://${ccid}/atproto.concrnt.world/follows/${did}`
