import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button, Divider, Switch, Text, TextField, View } from '@concrnt/ui'
import { type MuteEntry } from '@concrnt/worldlib'
import { MdDelete } from 'react-icons/md'
import { useClient } from '../contexts/Client'
import { usePreference } from '../contexts/Preference'
import { useSubscribe } from '../hooks/useSubscribe'
import { Header } from '../ui/Header'
import { CssVar } from '../types/Theme'
import { CCUserChip } from '../components/CCUserChip'
import { TimelineTag } from '../components/TimelineTag'
import { MuteDurationSelect } from '../components/MuteDurationSelect'

export const MuteSettingsView = () => {
    const { t } = useTranslation('', { keyPrefix: 'views.muteSettings' })
    const { client } = useClient()
    const [mutes] = useSubscribe(client.mutes)
    const [muteBlockedUsers, setMuteBlockedUsers] = usePreference('muteBlockedUsers')

    const [wordDraft, setWordDraft] = useState('')
    // 期間選択シートの対象。既存エントリなら期限の変更、新規ならワード追加
    const [durationTarget, setDurationTarget] = useState<MuteEntry | null>(null)

    const userEntries = mutes.filter((entry) => entry.type === 'user')
    const wordEntries = mutes.filter((entry) => entry.type === 'word')
    const timelineEntries = mutes.filter((entry) => entry.type === 'timeline')

    const expiryLabel = (entry: MuteEntry): string => {
        if (!entry.expiresAt) return t('indefinite')
        const expires = new Date(entry.expiresAt)
        // 不正な日付は無期限として扱う(判定側 isMuteEntryExpired と同じ扱い)
        if (Number.isNaN(expires.getTime())) return t('indefinite')
        return t('until', { date: expires.toLocaleString() })
    }

    const entryRow = (entry: MuteEntry, label: React.ReactNode): React.ReactNode => (
        <div
            key={`${entry.type}:${entry.target}`}
            style={{
                display: 'flex',
                alignItems: 'center',
                gap: CssVar.space(2),
                width: '100%'
            }}
        >
            <div style={{ flex: 1, minWidth: 0, display: 'flex', alignItems: 'center', gap: CssVar.space(1) }}>
                {label}
                {entry.type === 'user' && entry.reroutesOnly && <Text variant="caption">{t('reroutesOnly')}</Text>}
            </div>
            <span
                onClick={() => setDurationTarget(entry)}
                style={{
                    cursor: 'pointer',
                    textDecoration: 'underline',
                    fontSize: '0.875em',
                    opacity: 0.7,
                    flexShrink: 0
                }}
            >
                {expiryLabel(entry)}
            </span>
            <MdDelete
                size={20}
                style={{ cursor: 'pointer', flexShrink: 0 }}
                onClick={() => {
                    client.unmute(entry.type, entry.target).catch(console.error)
                }}
            />
        </div>
    )

    return (
        <View>
            <Header>{t('title')}</Header>
            <div
                style={{
                    flex: 1,
                    overflowY: 'auto',
                    touchAction: 'pan-y',
                    display: 'flex',
                    flexDirection: 'column',
                    gap: CssVar.space(3),
                    padding: CssVar.space(4)
                }}
            >
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                    <Text variant="h3">{t('muteBlockedUsers')}</Text>
                    <Switch
                        checked={muteBlockedUsers ?? true}
                        onChange={(next: boolean) => setMuteBlockedUsers(next)}
                    />
                </div>
                <Text variant="caption">{t('muteBlockedUsersDesc')}</Text>

                <Divider />

                <Text variant="h3">{t('users')}</Text>
                {userEntries.length === 0 && <Text variant="caption">{t('noEntries')}</Text>}
                {userEntries.map((entry) => entryRow(entry, <CCUserChip ccid={entry.target} avatar />))}

                <Divider />

                <Text variant="h3">{t('words')}</Text>
                <div style={{ display: 'flex', alignItems: 'center', gap: CssVar.space(2) }}>
                    <TextField
                        value={wordDraft}
                        placeholder={t('wordPlaceholder')}
                        onChange={(e) => setWordDraft(e.target.value)}
                    />
                    <Button
                        onClick={() => {
                            if (wordDraft.trim().length === 0) return
                            setDurationTarget({ type: 'word', target: wordDraft })
                        }}
                    >
                        {t('add')}
                    </Button>
                </div>
                {wordEntries.length === 0 && <Text variant="caption">{t('noEntries')}</Text>}
                {wordEntries.map((entry) => entryRow(entry, <Text>{entry.target}</Text>))}

                <Divider />

                <Text variant="h3">{t('timelines')}</Text>
                {timelineEntries.length === 0 && <Text variant="caption">{t('noEntries')}</Text>}
                {timelineEntries.map((entry) => entryRow(entry, <TimelineTag uri={entry.target} />))}
            </div>
            <MuteDurationSelect
                open={durationTarget !== null}
                onClose={() => setDurationTarget(null)}
                onSelect={(expiresAt) => {
                    if (!durationTarget) return
                    client
                        .mute({ ...durationTarget, expiresAt })
                        .then(() => setWordDraft(''))
                        .catch(console.error)
                }}
            />
        </View>
    )
}
