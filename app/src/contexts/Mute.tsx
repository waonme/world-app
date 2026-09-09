import { createContext, ReactNode, useCallback, useContext } from 'react'
import { findMute, type MuteMatch, type MuteTarget, type MuteViewContext } from '@concrnt/worldlib'
import { useClient } from './Client'
import { useSubscribe } from '../hooks/useSubscribe'
import { usePreference } from './Preference'

const MuteScopeContext = createContext<MuteViewContext>('other')

interface MuteScopeProviderProps {
    context: MuteViewContext
    children: ReactNode
}

// scope: 'home' のミュートエントリを効かせたいビュー(ホームタイムライン)で使う
export const MuteScopeProvider = (props: MuteScopeProviderProps): ReactNode => {
    return <MuteScopeContext.Provider value={props.context}>{props.children}</MuteScopeContext.Provider>
}

export const useMuteScope = (): MuteViewContext => {
    return useContext(MuteScopeContext)
}

export function useMuteCheck(): (target: MuteTarget) => MuteMatch | undefined {
    const { client } = useClient()
    const [mutes] = useSubscribe(client.mutes)
    const [blocks] = useSubscribe(client.blocks)
    const [muteBlockedUsers] = usePreference('muteBlockedUsers')
    const viewContext = useMuteScope()

    return useCallback(
        (target: MuteTarget) =>
            findMute(target, mutes, {
                blocks: muteBlockedUsers ? blocks : undefined,
                viewContext: viewContext
            }),
        [mutes, blocks, muteBlockedUsers, viewContext]
    )
}
