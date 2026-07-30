import { useTranslation } from 'react-i18next'
import { ListItem, Text } from '@concrnt/ui'
import { Select } from './Select'

interface Props {
    open: boolean
    onClose: () => void
    // 無期限のときはundefined
    onSelect: (expiresAt: string | undefined) => void
}

const DURATIONS: Array<{ key: string; ms?: number }> = [
    { key: 'for1hour', ms: 60 * 60 * 1000 },
    { key: 'for1day', ms: 24 * 60 * 60 * 1000 },
    { key: 'for1week', ms: 7 * 24 * 60 * 60 * 1000 },
    { key: 'for1month', ms: 30 * 24 * 60 * 60 * 1000 },
    { key: 'indefinite' }
]

// ミュート期間の選択シート。選択時にexpiresAt(ISO 8601)を返す
export const MuteDurationSelect = (props: Props) => {
    const { t } = useTranslation('', { keyPrefix: 'components.muteDurationSelect' })

    return (
        <Select
            open={props.open}
            onClose={props.onClose}
            title={t('title')}
            options={DURATIONS.map((duration) => (
                <ListItem
                    key={duration.key}
                    onClick={() => {
                        props.onSelect(
                            duration.ms !== undefined ? new Date(Date.now() + duration.ms).toISOString() : undefined
                        )
                        props.onClose()
                    }}
                >
                    <Text>{t(duration.key)}</Text>
                </ListItem>
            ))}
        />
    )
}
