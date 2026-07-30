import { useTranslation } from 'react-i18next'
import { useClient } from '../../contexts/Client'
import { MessageProps } from './types'
import { RerouteMessageSchema } from '@concrnt/worldlib'

import { Avatar, Text, IconButton, ListItem, useAnchor } from '@concrnt/ui'

import { useState } from 'react'
import { MdMoreHoriz } from 'react-icons/md'
import { MdRepeat } from 'react-icons/md'
import { Select } from '../Select'
import { hapticSuccess } from '../../utils/haptics'
import { OnelineMessageLayout } from './OnelineLayout'
import { MessageContainer } from './main'
import { TimeDiff } from '../TimeDiff'
import { RenderError } from './RenderError'
import { ErrorBoundary } from 'react-error-boundary'
import { CssVar } from '../../types/Theme'

export const RerouteMessage = (props: MessageProps<RerouteMessageSchema>) => {
    const { t } = useTranslation('', { keyPrefix: 'components.rerouteMessage' })
    const { client } = useClient()
    const menuAnchor = useAnchor()

    const [menuOpen, setMenuOpen] = useState(false)

    return (
        <div>
            <OnelineMessageLayout
                left={
                    <div
                        style={{
                            display: 'flex',
                            justifyContent: 'space-between',
                            alignItems: 'center',
                            gap: CssVar.space(1),
                            fontSize: '0.75rem',
                            color: CssVar.textSecondary
                        }}
                    >
                        <MdRepeat size={14} />
                        <Avatar
                            ccid={props.message.author}
                            src={props.message.authorProfile?.avatar}
                            style={{ width: '16px', height: '16px' }}
                        />
                    </div>
                }
            >
                <Text variant="caption">
                    {t('userRerouted', { name: props.message.authorProfile?.username || 'Anonymous' })}
                </Text>
                <div style={{ flex: 1 }} />
                <IconButton
                    onClick={(e) => {
                        e.stopPropagation()
                        setMenuOpen(true)
                    }}
                    style={
                        {
                            padding: 0,
                            margin: 0,
                            anchorName: menuAnchor
                        } as React.CSSProperties
                    }
                >
                    <MdMoreHoriz size={16} />
                </IconButton>
                <Select
                    open={menuOpen}
                    onClose={() => setMenuOpen(false)}
                    options={[
                        <ListItem
                            key="delete"
                            onClick={() => {
                                client.api.delete(props.message.uri).then(() => hapticSuccess())
                                setMenuOpen(false)
                            }}
                        >
                            <Text>{t('deleteReroute')}</Text>
                        </ListItem>
                    ]}
                    anchor={menuAnchor}
                />
                <div style={{ flexShrink: 0 }}>
                    <TimeDiff date={props.message.createdAt} />
                </div>
            </OnelineMessageLayout>
            <ErrorBoundary FallbackComponent={RenderError}>
                <MessageContainer uri={props.message.value.targetURI} />
            </ErrorBoundary>
        </div>
    )
}
