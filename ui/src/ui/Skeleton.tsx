import type { CSSProperties } from 'react'
import { CssVar } from '../types/Theme'

interface Props {
    width?: string | number
    height?: string | number
    style?: CSSProperties
}

export const Skeleton = (props: Props) => {
    return (
        <>
            <div
                style={{
                    position: 'relative',
                    width: props.width ?? '100%',
                    height: props.height ?? '100%',
                    overflow: 'hidden',
                    background: `color-mix(in srgb, ${CssVar.contentText} 8%, transparent)`,
                    borderRadius: CssVar.round(1),
                    ...props.style
                }}
            >
                {/* classNameはreduced-motion分岐(メディアクエリ)のために必要 */}
                <div
                    className="cc-skeleton-shimmer"
                    style={{
                        position: 'absolute',
                        inset: 0,
                        transform: 'translateX(-100%)',
                        background: `linear-gradient(90deg, transparent 0%, color-mix(in srgb, ${CssVar.contentText} 8%, transparent) 50%, transparent 100%)`
                    }}
                />
            </div>

            <style>{`
                .cc-skeleton-shimmer {
                    animation: shimmer 1.6s linear infinite;
                }
                @media (prefers-reduced-motion: reduce) {
                    .cc-skeleton-shimmer {
                        animation: none;
                    }
                }
                @keyframes shimmer {
                    0% {
                        transform: translateX(-100%);
                    }
                    100% {
                        transform: translateX(100%);
                    }
                }
            `}</style>
        </>
    )
}
