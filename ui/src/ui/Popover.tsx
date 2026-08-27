import { useId, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode, type RefObject } from 'react'
import { CssVar } from '../types/Theme'
import {
    getCenteredPopoverFallbackPlacement,
    getPopoverFallbackPlacement,
    type PopoverPlacement
} from './popoverPlacement'

export { getCenteredPopoverFallbackPlacement, getPopoverFallbackPlacement } from './popoverPlacement'

// トリガー側が style={{ anchorName: useAnchor()の返り値 }} で宣言し、Popoverのanchorに渡すアンカー名を生成する
export const useAnchor = (): string => {
    const id = useId().replace(/[^a-zA-Z0-9-]/g, '')
    return `--anchor-${id}`
}

interface Props {
    open: boolean
    onClose: () => void
    anchor: string // トリガー側が style={{ anchorName: '--xxx' }} で宣言したアンカー名
    children: ReactNode
    style?: CSSProperties
    mode?: 'auto' | 'manual' // manualはlight dismiss・auto同士の排他制御の対象外。openを外部stateだけで制御したいとき用
    anchorRef?: RefObject<HTMLElement | null> // CSS Anchor Positioning 非対応時だけ使う実要素
    matchAnchorWidth?: boolean
}

const supportsAnchorPositioning = () =>
    typeof CSS !== 'undefined' &&
    CSS.supports('anchor-name: --popover-anchor') &&
    CSS.supports('position-anchor: --popover-anchor') &&
    CSS.supports('top: anchor(bottom)')

const supportsAnchorSize = () => typeof CSS !== 'undefined' && CSS.supports('width: anchor-size(width)')

const resolveGap = (anchor: HTMLElement): number => {
    const value = window.getComputedStyle(anchor).getPropertyValue('--space').trim()
    if (/^\d+(\.\d+)?px$/.test(value)) return Number.parseFloat(value)
    return 4
}

type FallbackPlacement = Partial<PopoverPlacement>

const isSamePlacement = (current: FallbackPlacement | undefined, next: FallbackPlacement): boolean =>
    current?.top === next.top && current.left === next.left && current.width === next.width

export const Popover = (props: Props) => {
    const ref = useRef<HTMLDivElement>(null)
    const [fallbackPlacement, setFallbackPlacement] = useState<FallbackPlacement>()
    const anchorPositioningSupported = supportsAnchorPositioning()
    const anchorSizeSupported = supportsAnchorSize()
    const needsPositionFallback = !anchorPositioningSupported
    const needsWidthFallback =
        Boolean(props.anchorRef) &&
        Boolean(props.matchAnchorWidth) &&
        (!anchorPositioningSupported || !anchorSizeSupported)

    useLayoutEffect(() => {
        const el = ref.current
        if (!el) return

        if (!props.open) {
            if (el.matches(':popover-open')) el.hidePopover()
            return
        }

        if (!el.matches(':popover-open')) el.showPopover()

        if (!needsPositionFallback && !needsWidthFallback) {
            return
        }

        const updatePlacement = () => {
            const anchor = props.anchorRef?.current

            const visualViewport = window.visualViewport
            const viewport = visualViewport
                ? {
                      top: visualViewport.offsetTop,
                      left: visualViewport.offsetLeft,
                      width: visualViewport.width,
                      height: visualViewport.height
                  }
                : {
                      top: 0,
                      left: 0,
                      width: document.documentElement.clientWidth,
                      height: document.documentElement.clientHeight
                  }
            const gap = anchor ? resolveGap(anchor) : 4
            const anchorRect = anchor?.getBoundingClientRect()

            // 幅を先に合わせ、折り返し後の正しい高さで上下反転を判定する。
            if (needsWidthFallback && anchorRect) {
                const fallbackWidth = Math.min(anchorRect.width, Math.max(0, viewport.width - gap * 2))
                el.style.width = `${fallbackWidth}px`
            }

            const popoverRect = el.getBoundingClientRect()
            const placement = anchorRect
                ? getPopoverFallbackPlacement({
                      anchorRect,
                      popoverSize: popoverRect,
                      viewport,
                      gap,
                      matchAnchorWidth: needsWidthFallback
                  })
                : getCenteredPopoverFallbackPlacement({ popoverSize: popoverRect, viewport, gap })
            const next: FallbackPlacement = {
                ...(needsPositionFallback ? { top: placement.top, left: placement.left } : {}),
                ...(placement.width !== undefined ? { width: placement.width } : {})
            }
            setFallbackPlacement((current) => (isSamePlacement(current, next) ? current : next))
        }

        const animationFrame = window.requestAnimationFrame(updatePlacement)
        const resizeObserver = typeof ResizeObserver === 'undefined' ? undefined : new ResizeObserver(updatePlacement)
        const anchor = props.anchorRef?.current
        if (anchor) resizeObserver?.observe(anchor)
        resizeObserver?.observe(el)
        window.addEventListener('resize', updatePlacement)
        window.addEventListener('scroll', updatePlacement, true)
        window.visualViewport?.addEventListener('resize', updatePlacement)
        window.visualViewport?.addEventListener('scroll', updatePlacement)

        return () => {
            window.cancelAnimationFrame(animationFrame)
            resizeObserver?.disconnect()
            window.removeEventListener('resize', updatePlacement)
            window.removeEventListener('scroll', updatePlacement, true)
            window.visualViewport?.removeEventListener('resize', updatePlacement)
            window.visualViewport?.removeEventListener('scroll', updatePlacement)
        }
    }, [
        anchorPositioningSupported,
        anchorSizeSupported,
        needsPositionFallback,
        needsWidthFallback,
        props.anchorRef,
        props.open
    ])

    return (
        <div
            ref={ref}
            popover={props.mode ?? 'auto'}
            onToggle={(e) => {
                // light dismiss(外側クリック/Esc)で閉じたときに親のstateへ反映する
                if (e.newState === 'closed') {
                    setFallbackPlacement(undefined)
                    if (props.open) props.onClose()
                }
            }}
            style={
                {
                    position: 'fixed',
                    positionAnchor: props.anchor,
                    inset: 'auto',
                    top: `calc(anchor(bottom) + ${CssVar.space(1)})`,
                    left: 'anchor(left)',
                    positionTryFallbacks: 'flip-block, flip-inline',
                    margin: 0,
                    border: 'none',
                    boxSizing: 'border-box',
                    padding: CssVar.space(1),
                    borderRadius: CssVar.round(1),
                    backgroundColor: CssVar.contentBackground,
                    color: CssVar.contentText,
                    boxShadow: '0 2px 8px rgba(0, 0, 0, 0.2)',
                    ...props.style,
                    ...(props.matchAnchorWidth && anchorSizeSupported ? { width: 'anchor-size(width)' } : {}),
                    ...(props.open && (needsPositionFallback || needsWidthFallback) && !fallbackPlacement
                        ? { visibility: 'hidden' }
                        : {}),
                    ...(props.open && (needsPositionFallback || needsWidthFallback) ? fallbackPlacement : {})
                } as CSSProperties
            }
        >
            {props.children}
        </div>
    )
}
