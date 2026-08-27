import assert from 'node:assert/strict'
import test from 'node:test'

import { getCenteredPopoverFallbackPlacement, getPopoverFallbackPlacement } from '../src/ui/popoverPlacement.ts'

test('places a matching-width popover below its anchor when space is available', () => {
    assert.deepEqual(
        getPopoverFallbackPlacement({
            anchorRect: { top: 100, bottom: 120, left: 50, width: 200 },
            popoverSize: { width: 200, height: 80 },
            viewport: { top: 0, left: 0, width: 400, height: 400 },
            gap: 4,
            matchAnchorWidth: true
        }),
        { top: 124, left: 50, width: 200 }
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
        { top: 246, left: 50, width: 200 }
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
        { top: 274, left: 24, width: 292 }
    )
})

test('centers an unregistered legacy caller inside an offset visual viewport', () => {
    assert.deepEqual(
        getCenteredPopoverFallbackPlacement({
            popoverSize: { width: 180, height: 100 },
            viewport: { top: 200, left: 20, width: 300, height: 300 },
            gap: 4
        }),
        { top: 300, left: 80 }
    )
})
