import { Association, Message, ReactionAssociationSchema, Schemas } from '@concrnt/worldlib'
import { Document } from '@concrnt/client'
import { useClient } from '../../contexts/Client'
import { CssVar } from '../../types/Theme'
import { hapticLight } from '../../utils/haptics'
import { startTransition } from 'react'
import { ReactionState } from './Footer'
import { ButtonBase, CCImage } from '@concrnt/ui'

interface Props {
    message: Message<any>
    reactionState: ReactionState
    updateReactionState: React.Dispatch<React.SetStateAction<ReactionState>>
}

export const MessageReactions = (props: Props) => {
    const { client } = useClient()

    const { reactionCounts, ownReactions } = props.reactionState

    const handleReactionClick = async (imageUrl: string) => {
        if (!client) return
        if (client.ccid === '') return // ゲストはリアクション不可(表示のみ)
        hapticLight()

        if (ownReactions[imageUrl]) {
            startTransition(async () => {
                props.updateReactionState((prev: ReactionState) => {
                    const newOwnReactions = { ...prev.ownReactions }
                    delete newOwnReactions[imageUrl]
                    return {
                        reactionCounts: {
                            ...prev.reactionCounts,
                            [imageUrl]: Math.max((prev.reactionCounts[imageUrl] || 1) - 1, 0)
                        },
                        ownReactions: newOwnReactions
                    }
                })
                await ownReactions[imageUrl].delete(client).catch((e) => {
                    console.error('Failed to delete reaction:', e)
                })
            })
        } else {
            startTransition(async () => {
                props.updateReactionState((prev: ReactionState) => {
                    return {
                        reactionCounts: {
                            ...prev.reactionCounts,
                            [imageUrl]: (prev.reactionCounts[imageUrl] || 0) + 1
                        },
                        ownReactions: {
                            ...prev.ownReactions,
                            [imageUrl]: new Association('dummy', {
                                kind: 'association',
                                author: client.ccid,
                                schema: Schemas.reactionAssociation,
                                value: {
                                    imageUrl,
                                    shortcode: ''
                                },
                                createdAt: new Date()
                            })
                        }
                    }
                })

                const sds = await client.api
                    .getAssociations(props.message.uri, {
                        schema: Schemas.reactionAssociation,
                        variant: imageUrl,
                        limit: 1
                    })
                    .then((res) => res.items)
                    .catch((e) => {
                        console.error('Failed to fetch existing reactions:', e)
                        return []
                    })

                if (sds.length == 0) return
                const doc = JSON.parse(sds[0].document) as Document<ReactionAssociationSchema>
                const shortcode = doc.value.shortcode

                await props.message.reaction(client, shortcode, imageUrl).catch((e) => {
                    console.error('Failed to add reaction:', e)
                })
            })
        }
    }

    return (
        <div
            style={{
                display: 'flex',
                flexWrap: 'wrap',
                gap: CssVar.space(1)
            }}
        >
            {Object.entries(reactionCounts).map(([imageUrl, count]) => {
                const isOwn = !!ownReactions[imageUrl]
                return (
                    <ButtonBase
                        key={imageUrl}
                        onClick={(e) => {
                            e.stopPropagation()
                            handleReactionClick(imageUrl)
                        }}
                        pressedStyle={{ backgroundColor: CssVar.statePressed(CssVar.contentText) }}
                        style={{
                            display: 'flex',
                            alignItems: 'center',
                            gap: CssVar.space(1),
                            padding: `${CssVar.space(0.5)} ${CssVar.space(2)}`,
                            borderRadius: CssVar.round(1),
                            border: isOwn ? `1.5px solid ${CssVar.accent}` : `1px solid ${CssVar.divider}`,
                            backgroundColor: isOwn ? CssVar.stateSelected(CssVar.accent) : 'transparent',
                            cursor: 'pointer',
                            color: CssVar.contentText,
                            fontSize: '0.75rem'
                        }}
                    >
                        <CCImage
                            src={imageUrl}
                            maxHeight={128}
                            alt=""
                            style={{
                                height: '18px',
                                width: '18px',
                                objectFit: 'contain'
                            }}
                        />
                        <span>{count}</span>
                    </ButtonBase>
                )
            })}
        </div>
    )
}
