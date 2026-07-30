import BoringAvatar from 'boring-avatars'
import { Suspense, use, useDeferredValue } from 'react'
import { CCImage } from '../contexts/CCImage'
import { CssVar } from '../types/Theme'

interface Props {
    ccid: string
    src?: string | Promise<string | undefined>
    style?: React.CSSProperties
    onClick?: () => void
}

export const Avatar = (props: Props) => {
    return (
        <Suspense
            fallback={
                <div
                    style={{
                        width: '40px',
                        height: '40px',
                        borderRadius: '4px',
                        backgroundColor: `rgb(from ${CssVar.contentText} r g b / 0.08)`,
                        ...props.style
                    }}
                />
            }
        >
            {useDeferredValue(<Inner {...props} />)}
        </Suspense>
    )
}

const Inner = (props: Props) => {
    const src = props.src instanceof Promise ? use(props.src) : props.src

    if (src) {
        return (
            <CCImage
                src={src}
                maxWidth={256}
                alt="avatar"
                style={{
                    width: '40px',
                    height: '40px',
                    borderRadius: '4px',
                    objectFit: 'cover',
                    ...props.style
                }}
                onClick={props.onClick}
            />
        )
    } else {
        return (
            <BoringAvatar
                square
                size={40}
                variant="beam"
                style={{
                    borderRadius: '4px',
                    ...props.style
                }}
                name={props.ccid}
                onClick={props.onClick}
            />
        )
    }
}
