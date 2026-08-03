import { useEffect, useState } from 'react'
import { useClient } from '../contexts/Client'
import { View } from '../components/View'
import { Button } from '@concrnt/ui'
import { ApNote } from './ApNote'
import { ApPerson } from './ApPerson'
import { ApObject } from '../utils/activitypub'
import { invalidateActivitypubObject, resolveActivitypubObject } from '@concrnt/worldlib'

interface Props {
    uri: string
}

interface ResolveState {
    key: string
    object?: ApObject
    failed: boolean
}

export const ApView = (props: Props) => {
    const { client } = useClient()
    const [retryKey, setRetryKey] = useState(0)
    const [resolveState, setResolveState] = useState<ResolveState>({ key: '', failed: false })
    const requestKey = `${props.uri}\n${retryKey}`

    useEffect(() => {
        let cancelled = false

        resolveActivitypubObject<ApObject>(client.api, client.server.domain, props.uri, { force: retryKey > 0 })
            .then(async (res) => {
                if (!cancelled) setResolveState({ key: requestKey, object: new ApObject(res), failed: false })
            })
            .catch((err) => {
                console.warn(`Failed to resolve ActivityPub object: ${props.uri}`, err)
                if (!cancelled) setResolveState({ key: requestKey, failed: true })
            })

        return () => {
            cancelled = true
        }
    }, [props.uri, client, retryKey, requestKey])

    const currentState = resolveState.key === requestKey ? resolveState : undefined
    const ld = currentState?.object

    if (!ld) {
        if (currentState?.failed) {
            return (
                <View>
                    <p>ActivityPub object could not be loaded.</p>
                    <Button
                        onClick={() => {
                            invalidateActivitypubObject(client.server.domain, props.uri)
                            setRetryKey((key) => key + 1)
                        }}
                    >
                        Retry
                    </Button>
                </View>
            )
        }
        return <View></View>
    }

    switch (ld.type) {
        case 'Note':
            return <ApNote note={ld} />
        case 'Person':
            return <ApPerson person={ld} />
        default:
            return (
                <View>
                    <p>Unsupported type: {ld.type}</p>
                    <pre>{JSON.stringify(ld, null, 2)}</pre>
                </View>
            )
    }
}
