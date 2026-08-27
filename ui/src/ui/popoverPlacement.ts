export interface PopoverRect {
    top: number
    bottom: number
    left: number
    width: number
}

export interface PopoverSize {
    width: number
    height: number
}

export interface PopoverViewport {
    top: number
    left: number
    width: number
    height: number
}

interface Options {
    anchorRect: PopoverRect
    popoverSize: PopoverSize
    viewport: PopoverViewport
    gap: number
    matchAnchorWidth: boolean
}

export interface PopoverPlacement {
    top: number
    left: number
    width?: number
}

interface CenteredOptions {
    popoverSize: PopoverSize
    viewport: PopoverViewport
    gap: number
}

// CSS Anchor Positioning が使えない WebView 用の配置計算。
// native の flip-block / flip-inline と同様に、下に収まらなければ上へ、右にはみ出せば左へ寄せる。
export const getPopoverFallbackPlacement = (options: Options): PopoverPlacement => {
    const { anchorRect, popoverSize, viewport, gap, matchAnchorWidth } = options
    const viewportRight = viewport.left + viewport.width
    const viewportBottom = viewport.top + viewport.height
    const minimumLeft = viewport.left + gap
    const minimumTop = viewport.top + gap

    const maximumContentWidth = Math.max(0, viewport.width - gap * 2)
    const width = matchAnchorWidth ? Math.min(anchorRect.width, maximumContentWidth) : popoverSize.width
    const maximumLeft = viewportRight - width - gap
    const left = maximumLeft < minimumLeft ? minimumLeft : Math.min(Math.max(anchorRect.left, minimumLeft), maximumLeft)

    const belowTop = anchorRect.bottom + gap
    const availableBelow = viewportBottom - belowTop
    const availableAbove = anchorRect.top - gap - viewport.top
    const placeAbove = availableBelow < popoverSize.height && availableAbove > availableBelow
    const desiredTop = placeAbove ? anchorRect.top - gap - popoverSize.height : belowTop
    const maximumTop = viewportBottom - popoverSize.height - gap
    const top = maximumTop < minimumTop ? minimumTop : Math.min(Math.max(desiredTop, minimumTop), maximumTop)

    return {
        top,
        left,
        ...(matchAnchorWidth ? { width } : {})
    }
}

// anchorRef をまだ提供していない既存 caller も、旧 WebKit で画面外へ消えないよう
// viewport 中央へ収める。横幅を縮める場合は Popover 側の border-box と組み合わせる。
export const getCenteredPopoverFallbackPlacement = (options: CenteredOptions): PopoverPlacement => {
    const { popoverSize, viewport, gap } = options
    const maximumContentWidth = Math.max(0, viewport.width - gap * 2)
    const visibleWidth = Math.min(popoverSize.width, maximumContentWidth)
    const visibleHeight = Math.min(popoverSize.height, Math.max(0, viewport.height - gap * 2))

    return {
        top: viewport.top + Math.max(gap, (viewport.height - visibleHeight) / 2),
        left: viewport.left + Math.max(gap, (viewport.width - visibleWidth) / 2),
        ...(popoverSize.width > maximumContentWidth ? { width: maximumContentWidth } : {})
    }
}
