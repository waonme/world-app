import { Suspense, use, useMemo } from 'react'
import { Text } from '@concrnt/ui'
import type { CSSProperties } from 'react'
import { useClient } from '../contexts/Client'

interface Props {
    uri: string
    style?: CSSProperties
}

export const ListName = (props: Props) => {
    const { client } = useClient()

    const textPromise = useMemo(
        () => client!.getList(props.uri).then((list) => list?.title ?? 'No Name'),
        [client, props.uri]
    )

    return (
        <Suspense key={props.uri} fallback={<Text style={props.style}>Loading...</Text>}>
            <Inner textPromise={textPromise} style={props.style} />
        </Suspense>
    )
}

const Inner = ({ textPromise, style }: { textPromise: Promise<string>; style?: CSSProperties }) => {
    const text = use(textPromise)

    return <Text style={style}>{text}</Text>
}
