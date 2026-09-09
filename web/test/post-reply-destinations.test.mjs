import assert from 'node:assert/strict'
import test from 'node:test'

import { reconcileReplyDestinations } from '../src/views/postReplyDestinations.ts'

const POST_A = 'cckv://owner.example/posts/a'
const POST_B = 'cckv://owner.example/posts/b'
const COMMUNITY_A = 'ccat://community.example/timelines/a'
const COMMUNITY_B = 'ccat://community.example/timelines/b'
const COMMUNITY_C = 'ccat://community.example/timelines/c'

test('an asynchronously loaded post initializes a pristine inline composer', () => {
    const initial = { postUri: POST_A, defaults: [], selected: [] }

    assert.deepEqual(reconcileReplyDestinations(initial, POST_A, [COMMUNITY_A, COMMUNITY_B]), {
        postUri: POST_A,
        defaults: [COMMUNITY_A, COMMUNITY_B],
        selected: [COMMUNITY_A, COMMUNITY_B]
    })
})

test('an equal action-triggered refresh preserves an edited destination selection', () => {
    const edited = {
        postUri: POST_A,
        defaults: [COMMUNITY_A, COMMUNITY_B],
        selected: [COMMUNITY_A]
    }

    const refreshed = reconcileReplyDestinations(edited, POST_A, [COMMUNITY_A, COMMUNITY_B])

    assert.strictEqual(refreshed, edited)
    assert.deepEqual(refreshed.selected, [COMMUNITY_A])
})

test('a real default change follows only while the selection is pristine', () => {
    const pristine = {
        postUri: POST_A,
        defaults: [COMMUNITY_A, COMMUNITY_B],
        selected: [COMMUNITY_A, COMMUNITY_B]
    }
    const edited = { ...pristine, selected: [COMMUNITY_A] }
    const nextDefaults = [COMMUNITY_A, COMMUNITY_C]

    assert.deepEqual(reconcileReplyDestinations(pristine, POST_A, nextDefaults).selected, nextDefaults)
    assert.deepEqual(reconcileReplyDestinations(edited, POST_A, nextDefaults), {
        postUri: POST_A,
        defaults: nextDefaults,
        selected: [COMMUNITY_A]
    })
})

test('switching posts resets even an edited selection to the new post defaults', () => {
    const edited = {
        postUri: POST_A,
        defaults: [COMMUNITY_A, COMMUNITY_B],
        selected: [COMMUNITY_A]
    }

    assert.deepEqual(reconcileReplyDestinations(edited, POST_B, [COMMUNITY_C]), {
        postUri: POST_B,
        defaults: [COMMUNITY_C],
        selected: [COMMUNITY_C]
    })
})
