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
    maxWidth?: number
    maxHeight?: number
}

interface CenteredOptions {
    popoverSize: PopoverSize
    viewport: PopoverViewport
    gap: number
}

interface FallbackRequirementOptions {
    anchorPositioningSupported: boolean
    anchorSizeSupported: boolean
    hasAnchorRef: boolean
    matchAnchorWidth: boolean
}

// WebKit はレイアウト値を 1/64 CSS px 単位で丸めることがある。制約直後の
// ResizeObserver 再計測を同じ寸法として扱い、中央寄せ位置の微小な往復を防ぐ。
const CSS_LAYOUT_UNIT = 1 / 64

const clampMeasuredSize = (measured: number, maximum: number): number => {
    const constrained = Math.min(measured, maximum)
    return maximum - constrained <= CSS_LAYOUT_UNIT ? maximum : constrained
}

export interface PopoverFallbackRequirements {
    needsPositionFallback: boolean
    needsWidthFallback: boolean
}

type CssLength = string | number | undefined
type SupportsConstraint = (value: string) => boolean

export const combinePopoverMaxConstraint = (
    viewportMaximum: number | undefined,
    callerMaximum: CssLength,
    supportsConstraint: SupportsConstraint = () => true
): CssLength => {
    if (viewportMaximum === undefined) return callerMaximum
    if (callerMaximum === undefined || callerMaximum === 'none') return viewportMaximum

    const callerCss = typeof callerMaximum === 'number' ? `${callerMaximum}px` : callerMaximum.trim()
    if (!callerCss) return viewportMaximum
    const combined = `min(${viewportMaximum}px, ${callerCss})`

    // intrinsic-size / CSS-wide keyword など、min() の引数にできない値では
    // 宣言全体を無効にせず、少なくとも viewport 境界を維持する。
    return supportsConstraint(combined) ? combined : viewportMaximum
}

export const needsPopoverFallbackScrolling = (overflow: string | undefined, overflowY: string | undefined): boolean =>
    overflow === undefined && overflowY === undefined

export const getPopoverFallbackRequirements = (options: FallbackRequirementOptions): PopoverFallbackRequirements => ({
    needsPositionFallback: !options.anchorPositioningSupported,
    needsWidthFallback:
        options.hasAnchorRef &&
        options.matchAnchorWidth &&
        (!options.anchorPositioningSupported || !options.anchorSizeSupported)
})

type ComparablePlacement = Partial<PopoverPlacement>

export const isSamePopoverFallbackPlacement = (
    current: ComparablePlacement | undefined,
    next: ComparablePlacement
): boolean => {
    if (!current) return false
    return (
        current.top === next.top &&
        current.left === next.left &&
        current.width === next.width &&
        current.maxWidth === next.maxWidth &&
        current.maxHeight === next.maxHeight
    )
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
    const maximumContentHeight = Math.max(0, viewport.height - gap * 2)
    const width = matchAnchorWidth ? Math.min(anchorRect.width, maximumContentWidth) : popoverSize.width
    const visibleWidth = clampMeasuredSize(width, maximumContentWidth)
    const visibleHeight = clampMeasuredSize(popoverSize.height, maximumContentHeight)
    const maximumLeft = viewportRight - visibleWidth - gap
    const left = maximumLeft < minimumLeft ? minimumLeft : Math.min(Math.max(anchorRect.left, minimumLeft), maximumLeft)

    const belowTop = anchorRect.bottom + gap
    const availableBelow = viewportBottom - belowTop
    const availableAbove = anchorRect.top - gap - viewport.top
    const placeAbove = availableBelow < visibleHeight && availableAbove > availableBelow
    const desiredTop = placeAbove ? anchorRect.top - gap - visibleHeight : belowTop
    const maximumTop = viewportBottom - visibleHeight - gap
    const top = maximumTop < minimumTop ? minimumTop : Math.min(Math.max(desiredTop, minimumTop), maximumTop)

    return {
        top,
        left,
        ...(matchAnchorWidth ? { width } : {}),
        // JS fallback 中は制約を常に保持する。visualViewport の小数pxと
        // WebKit layout-unit の丸め差で制約が外れ、ResizeObserver が往復するのを防ぐ。
        maxWidth: maximumContentWidth,
        maxHeight: maximumContentHeight
    }
}

// anchorRef をまだ提供していない既存 caller も、旧 WebKit で画面外へ消えないよう
// viewport 中央へ収める。横幅を縮める場合は Popover 側の border-box と組み合わせる。
export const getCenteredPopoverFallbackPlacement = (options: CenteredOptions): PopoverPlacement => {
    const { popoverSize, viewport, gap } = options
    const maximumContentWidth = Math.max(0, viewport.width - gap * 2)
    const maximumContentHeight = Math.max(0, viewport.height - gap * 2)
    const visibleWidth = clampMeasuredSize(popoverSize.width, maximumContentWidth)
    const visibleHeight = clampMeasuredSize(popoverSize.height, maximumContentHeight)

    return {
        top: viewport.top + Math.max(gap, (viewport.height - visibleHeight) / 2),
        left: viewport.left + Math.max(gap, (viewport.width - visibleWidth) / 2),
        // max 制約は内容が小さければ表示サイズを変えず、制約後の再計測でも残る。
        maxWidth: maximumContentWidth,
        maxHeight: maximumContentHeight
    }
}
