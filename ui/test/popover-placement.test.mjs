import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

import {
    combinePopoverMaxConstraint,
    getCenteredPopoverFallbackPlacement,
    getPopoverFallbackPlacement,
    getPopoverFallbackRequirements,
    isSamePopoverFallbackPlacement,
    needsPopoverFallbackScrolling
} from '../src/ui/popoverPlacement.ts'

test('places a matching-width popover below its anchor when space is available', () => {
    assert.deepEqual(
        getPopoverFallbackPlacement({
            anchorRect: { top: 100, bottom: 120, left: 50, width: 200 },
            popoverSize: { width: 200, height: 80 },
            viewport: { top: 0, left: 0, width: 400, height: 400 },
            gap: 4,
            matchAnchorWidth: true
        }),
        { top: 124, left: 50, width: 200, maxWidth: 392, maxHeight: 392 }
    )
})

test('flips above the anchor when the lower side is too short', () => {
    assert.deepEqual(
        getPopoverFallbackPlacement({
            anchorRect: { top: 350, bottom: 370, left: 50, width: 200 },
            popoverSize: { width: 200, height: 100 },
            viewport: { top: 0, left: 0, width: 400, height: 400 },
            gap: 4,
            matchAnchorWidth: true
        }),
        { top: 246, left: 50, width: 200, maxWidth: 392, maxHeight: 392 }
    )
})

test('keeps the popover within an offset visual viewport', () => {
    assert.deepEqual(
        getPopoverFallbackPlacement({
            anchorRect: { top: 250, bottom: 270, left: 10, width: 350 },
            popoverSize: { width: 350, height: 80 },
            viewport: { top: 200, left: 20, width: 300, height: 300 },
            gap: 4,
            matchAnchorWidth: true
        }),
        { top: 274, left: 24, width: 292, maxWidth: 292, maxHeight: 292 }
    )
})

test('centers an unregistered legacy caller inside an offset visual viewport', () => {
    assert.deepEqual(
        getCenteredPopoverFallbackPlacement({
            popoverSize: { width: 180, height: 100 },
            viewport: { top: 200, left: 20, width: 300, height: 300 },
            gap: 4
        }),
        { top: 300, left: 80, maxWidth: 292, maxHeight: 292 }
    )
})

test('constrains an oversized anchored popover in both axes inside an offset visual viewport', () => {
    assert.deepEqual(
        getPopoverFallbackPlacement({
            anchorRect: { top: 250, bottom: 270, left: 10, width: 350 },
            popoverSize: { width: 600, height: 900 },
            viewport: { top: 200, left: 20, width: 300, height: 300 },
            gap: 4,
            matchAnchorWidth: true
        }),
        { top: 204, left: 24, width: 292, maxWidth: 292, maxHeight: 292 }
    )
})

test('constrains an oversized unanchored popover without forcing a fixed width', () => {
    assert.deepEqual(
        getCenteredPopoverFallbackPlacement({
            popoverSize: { width: 380, height: 900 },
            viewport: { top: 200, left: 20, width: 300, height: 300 },
            gap: 4
        }),
        { top: 204, left: 24, maxWidth: 292, maxHeight: 292 }
    )
})

test('unanchored narrow-width fallback converges after ResizeObserver remeasurement', () => {
    const viewport = { top: 200, left: 20, width: 300, height: 300 }
    const first = getCenteredPopoverFallbackPlacement({
        popoverSize: { width: 380, height: 100 },
        viewport,
        gap: 4
    })
    const repeated = getCenteredPopoverFallbackPlacement({
        popoverSize: { width: first.maxWidth, height: 100 },
        viewport,
        gap: 4
    })

    assert.deepEqual(first, { top: 300, left: 24, maxWidth: 292, maxHeight: 292 })
    assert.deepEqual(repeated, first)
    assert.equal('width' in first, false)
    assert.equal(isSamePopoverFallbackPlacement(first, repeated), true)
})

test('anchored oversized fallback remains stable after both constraints take effect', () => {
    const options = {
        anchorRect: { top: 250, bottom: 270, left: 10, width: 350 },
        viewport: { top: 200, left: 20, width: 300, height: 300 },
        gap: 4,
        matchAnchorWidth: true
    }
    const first = getPopoverFallbackPlacement({ ...options, popoverSize: { width: 600, height: 900 } })
    const repeated = getPopoverFallbackPlacement({
        ...options,
        popoverSize: { width: first.width, height: first.maxHeight }
    })

    assert.deepEqual(repeated, first)
    assert.equal(isSamePopoverFallbackPlacement(first, repeated), true)
    assert.equal(isSamePopoverFallbackPlacement(first, { ...first, maxHeight: 280 }), false)
})

test('fractional visual viewport constraints remain stable after WebKit layout rounding', () => {
    const viewport = { top: 0, left: 0, width: 299.333, height: 499.333 }
    const first = getCenteredPopoverFallbackPlacement({
        popoverSize: { width: 380, height: 700 },
        viewport,
        gap: 4
    })
    const rounded = getCenteredPopoverFallbackPlacement({
        popoverSize: { width: 291.328125, height: 491.328125 },
        viewport,
        gap: 4
    })

    assert.deepEqual(first, { top: 4, left: 4, maxWidth: 291.333, maxHeight: 491.333 })
    assert.deepEqual(rounded, first)
    assert.equal(isSamePopoverFallbackPlacement(first, rounded), true)
})

test('viewport constraints preserve stricter caller sizing and scrolling choices', () => {
    assert.equal(combinePopoverMaxConstraint(792, 'min(40vh, 300px)'), 'min(792px, min(40vh, 300px))')
    assert.equal(combinePopoverMaxConstraint(792, 240), 'min(792px, 240px)')
    assert.equal(combinePopoverMaxConstraint(292, '90vw'), 'min(292px, 90vw)')
    assert.equal(combinePopoverMaxConstraint(292, undefined), 292)
    assert.equal(combinePopoverMaxConstraint(undefined, '300px'), '300px')
    assert.equal(
        combinePopoverMaxConstraint(792, 'max-content', () => false),
        792
    )
    assert.equal(
        combinePopoverMaxConstraint(792, 'min(40vh, 300px)', () => true),
        'min(792px, min(40vh, 300px))'
    )

    assert.equal(needsPopoverFallbackScrolling(undefined, undefined), true)
    assert.equal(needsPopoverFallbackScrolling('hidden', undefined), false)
    assert.equal(needsPopoverFallbackScrolling(undefined, 'scroll'), false)
})

test('feature fallback leaves fully native CSS anchor positioning untouched', () => {
    assert.deepEqual(
        getPopoverFallbackRequirements({
            anchorPositioningSupported: true,
            anchorSizeSupported: true,
            hasAnchorRef: true,
            matchAnchorWidth: true
        }),
        { needsPositionFallback: false, needsWidthFallback: false }
    )
    assert.deepEqual(
        getPopoverFallbackRequirements({
            anchorPositioningSupported: true,
            anchorSizeSupported: false,
            hasAnchorRef: true,
            matchAnchorWidth: true
        }),
        { needsPositionFallback: false, needsWidthFallback: true }
    )
    assert.deepEqual(
        getPopoverFallbackRequirements({
            anchorPositioningSupported: false,
            anchorSizeSupported: false,
            hasAnchorRef: false,
            matchAnchorWidth: false
        }),
        { needsPositionFallback: true, needsWidthFallback: false }
    )

    // CSS anchor positioning は使えるが anchor-size() だけが無い環境では、
    // 初回 state は top/left を持たない width-only fallback になる。
    assert.equal(isSamePopoverFallbackPlacement(undefined, { width: 180 }), false)
})

test('component wires scroll safety and cleans up fallback viewport observers', async () => {
    const source = await readFile(new URL('../src/ui/Popover.tsx', import.meta.url), 'utf8')

    assert.match(source, /maxHeight: placement\.maxHeight/)
    assert.match(source, /overflowY: 'auto'/)
    assert.match(source, /resizeObserver\?\.disconnect\(\)/)
    assert.match(source, /visualViewport\?\.removeEventListener\('resize', updatePlacement\)/)
    assert.match(source, /visualViewport\?\.removeEventListener\('scroll', updatePlacement\)/)
    assert.match(source, /setFallbackPlacement\(undefined\)/)
})
