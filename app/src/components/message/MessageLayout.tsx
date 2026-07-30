import { ReactNode } from 'react'
import { CssVar } from '../../types/Theme'

interface Props {
    onClick?: () => void
    left: ReactNode
    headerLeft: ReactNode
    headerRight?: ReactNode
    children?: ReactNode
}

export const MessageLayout = (props: Props) => {
    return (
        <div
            style={{
                display: 'flex',
                flexDirection: 'row',
                gap: CssVar.space(2),
                overflow: 'hidden'
            }}
            onClick={(e) => {
                e.stopPropagation()
                props.onClick?.()
            }}
        >
            {props.left}
            <div
                style={{
                    display: 'flex',
                    flexDirection: 'column',
                    gap: CssVar.space(1),
                    flex: 1,
                    overflow: 'hidden'
                }}
            >
                <div
                    style={{
                        display: 'flex',
                        flexDirection: 'row',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        gap: CssVar.space(2)
                    }}
                >
                    {/* 名前行は本文よりわずかに小さく(v1: 0.95rem)。時刻等のメタは各自の指定に任せる。
                        flex:1+minWidth:0 が無いと shrink-to-fit になり、width:100% の子(スケルトン)が幅0に潰れる */}
                    <div style={{ fontSize: '0.95rem', overflow: 'hidden', flex: 1, minWidth: 0 }}>
                        {props.headerLeft}
                    </div>
                    {props.headerRight}
                </div>
                {props.children}
            </div>
        </div>
    )
}
