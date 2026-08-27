import { invoke } from '@tauri-apps/api/core'
import { Button, Text } from '@concrnt/ui'
import { runAfterSuccessfulBackup } from '@concrnt/worldlib'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useClient } from '../contexts/Client'

export const BackupKeyButton = (props: { onBackupComplete?: () => void; ccid?: string }) => {
    const { t } = useTranslation('', { keyPrefix: 'app.backupKeyButton' })
    const clientContext = useClient()
    const client = clientContext?.client

    const [backingUp, setBackingUp] = useState(false)
    const [error, setError] = useState<string | null>(null)

    const username = client?.profile?.username
    let filename = 'concrnt_backup'
    if (username) {
        filename += `_${username}`
    }
    const timestamp = new Date().toLocaleDateString().replace(/\//g, '-')
    filename += `_${timestamp}.txt`

    return (
        <>
            <Button
                disabled={backingUp}
                onClick={async () => {
                    setError(null)
                    setBackingUp(true)
                    try {
                        await runAfterSuccessfulBackup(
                            () =>
                                invoke('backup_masterkey', {
                                    ccid: props.ccid,
                                    filename: filename,
                                    template: t('fileTemplate', { domain: client?.server?.domain ?? 'N/A' })
                                }),
                            props.onBackupComplete
                        )
                    } catch (err) {
                        console.error('Failed to backup masterkey', err)
                        setError(err instanceof Error ? err.message : String(err))
                    } finally {
                        setBackingUp(false)
                    }
                }}
            >
                {backingUp ? t('backingUp') : t('backupMasterkey')}
            </Button>
            {error && (
                <Text style={{ color: '#ff5b5b', wordBreak: 'break-all', whiteSpace: 'pre-line' }}>
                    {t('backupFailed')}
                    {'\n'}
                    {error}
                </Text>
            )}
        </>
    )
}
