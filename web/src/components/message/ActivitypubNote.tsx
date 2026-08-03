import { Suspense, use, useMemo, useState } from 'react'
import { ApObject } from '../../utils/activitypub'
import { MessageLayout } from './MessageLayout'
import { Avatar, Button, CfmRenderer, CssVar, Text } from '@concrnt/ui'
import { TimeDiff } from '../TimeDiff'
import { useNavigate } from 'react-router-dom'
import { useClient } from '../../contexts/Client'
import { MessageSkeleton } from './MessageSkeleton'
import { ApNoteSchema, invalidateActivitypubObject, Message, resolveActivitypubObject } from '@concrnt/worldlib'
import { MessageFooter } from './Footer'
import { CollapsibleBody } from './CollapsibleBody'
import { MediaGallery } from '../MediaGallery/main'

interface Props {
    actorURL: string
    noteURL: string
    message?: Message<ApNoteSchema>
    forceExpanded?: boolean
}

export const ActivitypubNote = (props: Props) => {
    const { client } = useClient()
    const [retryKey, setRetryKey] = useState(0)

    const notePromise = useMemo(() => {
        return resolveActivitypubObject<ApObject>(client.api, client.server.domain, props.noteURL, {
            force: retryKey > 0
        })
            .then(async (res) => new ApObject(res))
            .catch((error) => {
                console.warn(`Failed to resolve ActivityPub note: ${props.noteURL}`, error)
                return null
            })
    }, [client, props.noteURL, retryKey])

    const authorPromise = useMemo(() => {
        return resolveActivitypubObject<ApObject>(client.api, client.server.domain, props.actorURL)
            .then(async (res) => new ApObject(res))
            .catch((error) => {
                console.warn(`Failed to resolve ActivityPub actor: ${props.actorURL}`, error)
                return null
            })
    }, [client, props.actorURL])

    const retry = () => {
        invalidateActivitypubObject(client.server.domain, props.noteURL)
        setRetryKey((key) => key + 1)
    }

    return (
        <Suspense fallback={<MessageSkeleton />}>
            <Note
                notePromise={notePromise}
                authorPromise={authorPromise}
                message={props.message}
                forceExpanded={props.forceExpanded}
                onRetry={retry}
            />
        </Suspense>
    )
}

const Note = (props: {
    notePromise: Promise<ApObject | null>
    authorPromise: Promise<ApObject | null>
    message?: Message<ApNoteSchema>
    forceExpanded?: boolean
    onRetry: () => void
}) => {
    const navigate = useNavigate()

    const note = use(props.notePromise)
    const author = use(props.authorPromise)

    if (!note) {
        return (
            <div
                style={{
                    padding: CssVar.space(2),
                    display: 'flex',
                    alignItems: 'center',
                    gap: CssVar.space(2)
                }}
            >
                <Text>Note could not be loaded.</Text>
                <Button onClick={props.onRetry}>Retry</Button>
            </div>
        )
    }

    const medias = note.getAttachmentMedias()

    return (
        <MessageLayout
            onClick={() => {
                navigate('/activitypub/view/' + encodeURIComponent(note.id))
            }}
            left={
                <div
                    onClick={(e) => {
                        e.stopPropagation()
                        if (note.attributedTo) navigate('/activitypub/view/' + encodeURIComponent(note.attributedTo))
                    }}
                >
                    <Avatar ccid={note.attributedTo ?? ''} src={author?.getIcons()[0]?.url} />
                </div>
            }
            headerLeft={
                <Text
                    style={{
                        fontWeight: 'bold'
                    }}
                >
                    {author?.name ?? author?.preferredUsername ?? 'Unknown'}
                </Text>
            }
            headerRight={note.published && <TimeDiff date={new Date(note.published)} />}
        >
            <CollapsibleBody forceExpanded={props.forceExpanded}>
                <CfmRenderer messagebody={note.content ?? ''} emojiDict={{}} />
                {medias.length > 0 && <MediaGallery medias={medias} />}
            </CollapsibleBody>
            {props.message && <MessageFooter message={props.message} />}
        </MessageLayout>
    )
}
