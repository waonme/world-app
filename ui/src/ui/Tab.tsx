import type { CSSProperties, MouseEvent, ReactNode } from 'react'
import { motion } from 'motion/react'
import { CssVar } from '../types/Theme'
import { ButtonBase } from './ButtonBase'

interface Props {
    selected?: boolean
    children: ReactNode
    onClick?: (e: MouseEvent<HTMLButtonElement>) => void
    groupId?: string
    style?: CSSProperties
}

const pressedStyle: CSSProperties = {
    // 置かれる面の文字色に追従する押下ハイライト
    backgroundColor: 'color-mix(in srgb, currentcolor 12%, transparent)'
}

const indicatorInlineInset = `calc(${CssVar.space(1)} / 2)`
const indicatorHeight = '4px'
const indicatorGap = CssVar.space(1)

export const Tab = (props: Props) => {
    return (
        <ButtonBase
            style={{
                flex: 1,
                width: '100%',
                padding: CssVar.space(2),
                display: 'flex',
                justifyContent: 'center',
                alignItems: 'center',
                borderRadius: CssVar.round(1),
                ...props.style,
                // 選択状態は accent で示す(style.color は非選択時の文字色)
                color: props.selected ? CssVar.accent : props.style?.color
            }}
            onClick={props.onClick}
            pressedStyle={pressedStyle}
        >
            <div
                style={{
                    position: 'relative',
                    display: 'inline-flex',
                    justifyContent: 'center',
                    alignItems: 'center',
                    paddingInline: indicatorInlineInset,
                    paddingBottom: `calc(${indicatorGap} + ${indicatorHeight})`
                }}
            >
                {props.children}
                {props.selected && (
                    <motion.div
                        layoutId={'tab-underline-' + props.groupId}
                        style={{
                            position: 'absolute',
                            height: indicatorHeight,
                            backgroundColor: CssVar.accent,
                            borderRadius: CssVar.roundFull,
                            bottom: 0,
                            left: 0,
                            right: 0
                        }}
                        transition={{ type: 'spring', stiffness: 500, damping: 40 }}
                    />
                )}
            </div>
        </ButtonBase>
    )
}
