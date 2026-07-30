import { useTranslation } from 'react-i18next'
import { MdVisibilityOff } from 'react-icons/md'
import { Message, type MuteMatch } from '@concrnt/worldlib'
import { useClient } from '../../contexts/Client'
import { TimelineTag } from '../TimelineTag'

interface Props {
    // マッチした側のメッセージ(外側 or associationTarget)
    message: Message<any>
    mute: MuteMatch
    onReveal: () => void
}

export const MuteNotice = (props: Props) => {
    const { t } = useTranslation('', { keyPrefix: 'components.muteNotice' })
    const { client } = useClient()

    // reason 'block' はMessageContainerが完全非表示にするため、ここには来ない
    const reasonLabel =
        props.mute.reason === 'user'
            ? t('mutedByUser')
            : props.mute.reason === 'word'
              ? t('mutedByWord')
              : t('mutedByTimeline')

    return (
        <div
            style={{
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                fontSize: '0.875em',
                opacity: 0.7,
                overflow: 'hidden',
                padding: '4px 0'
            }}
        >
            <MdVisibilityOff size={16} style={{ flexShrink: 0 }} />
            <span
                style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: '4px',
                    minWidth: 0,
                    overflow: 'hidden',
                    whiteSpace: 'nowrap',
                    textOverflow: 'ellipsis'
                }}
            >
                {reasonLabel}:{' '}
                {props.mute.reason === 'timeline' ? (
                    <TimelineTag uri={props.mute.value} style={{ fontSize: '0.875em' }} />
                ) : props.mute.reason === 'word' ? (
                    props.mute.value
                ) : (
                    (props.message.authorProfile?.username ?? 'anonymous')
                )}
            </span>
            <span
                onClick={(e) => {
                    e.stopPropagation()
                    props.onReveal()
                }}
                style={{
                    cursor: 'pointer',
                    textDecoration: 'underline',
                    flexShrink: 0
                }}
            >
                {t('show')}
            </span>
            {props.mute.entry && (
                <span
                    onClick={(e) => {
                        e.stopPropagation()
                        if (!props.mute.entry) return
                        client.unmute(props.mute.entry.type, props.mute.entry.target).catch(console.error)
                    }}
                    style={{
                        cursor: 'pointer',
                        textDecoration: 'underline',
                        flexShrink: 0
                    }}
                >
                    {t('unmute')}
                </span>
            )}
        </div>
    )
}
