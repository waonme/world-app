export interface ReplyDestinationState {
    postUri: string
    defaults: string[]
    selected: string[]
}

/**
 * Reconcile destinations loaded from the replied-to post with the user's
 * current inline-composer selection.
 *
 * A cache refresh may return a new Message (and array) with identical
 * destinations. A real default change is followed only while the selection is
 * still pristine; switching to another post always starts from that post's
 * defaults.
 */
export const reconcileReplyDestinations = (
    current: ReplyDestinationState,
    postUri: string,
    nextDefaults: string[]
): ReplyDestinationState => {
    const samePost = current.postUri === postUri
    const sameDefaults =
        current.defaults.length === nextDefaults.length &&
        current.defaults.every((destination, index) => destination === nextDefaults[index])

    if (samePost && sameDefaults) return current

    const selectionIsPristine =
        current.selected.length === current.defaults.length &&
        current.selected.every((destination, index) => destination === current.defaults[index])

    return {
        postUri,
        defaults: nextDefaults,
        selected: !samePost || selectionIsPristine ? nextDefaults : current.selected
    }
}
