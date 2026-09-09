import { CDID } from '@concrnt/client'

export type MuteType = 'user' | 'word' | 'timeline'

// エントリの適用範囲。global(省略時)は全画面、homeはホームタイムラインのみ
export type MuteScope = 'global' | 'home'

// いま表示している文脈。ホームタイムラインか、それ以外か
export type MuteViewContext = 'home' | 'other'

export interface MuteEntry {
    type: MuteType
    target: string
    // ISO 8601。省略時は無期限
    expiresAt?: string
    scope?: MuteScope
    // user型のみ: 本人の投稿は表示し、リルートだけを隠す
    reroutesOnly?: boolean
    // noticeすら出さず完全に非表示にする
    hidePlaceholder?: boolean
}

export type MuteReason = MuteType | 'block'

export interface MuteMatch {
    reason: MuteReason
    value: string
    entry?: MuteEntry
}

export interface MuteTarget {
    author: string
    body?: string
    timelines?: string[]
    isReroute?: boolean
}

export interface CombinedMuteMatches {
    match?: MuteMatch
    fullyHidden: boolean
}

export type MessageAuthorMenuAction = 'delete' | 'mute'

// 投稿者本人には削除、それ以外にはフォーク固有のauthor muteを出す。
// app/webの競合解消を同じ判定に固定する。
export const messageAuthorMenuAction = (author: string, viewer?: string): MessageAuthorMenuAction =>
    author === viewer ? 'delete' : 'mute'

// NFKC正規化で全角半角・半角カナの揺れを吸収してから比較する
export const normalizeMuteText = (text: string): string => text.normalize('NFKC').toLowerCase()

export const normalizeMuteWord = (word: string): string => normalizeMuteText(word.trim())

export const muteEntryId = (type: MuteType, target: string): string =>
    CDID.newFromStringX(`${type}:${type === 'word' ? normalizeMuteWord(target) : target}`).toString()

export const isMuteEntryExpired = (entry: MuteEntry, now: Date = new Date()): boolean => {
    if (!entry.expiresAt) return false
    const expires = new Date(entry.expiresAt).getTime()
    return !Number.isNaN(expires) && expires <= now.getTime()
}

// 開示状態のキー。マッチしたルール自体が変わったときだけ再度隠す
export const muteMatchKey = (match: MuteMatch): string =>
    [
        match.reason,
        match.value,
        match.entry?.expiresAt ?? '',
        match.entry?.scope ?? '',
        match.entry?.reroutesOnly ? 'reroutesOnly' : ''
    ].join('\u0000')

// 外側のassociationと参照先など、複数の判定境界を一つの表示にまとめる。
// block / hidePlaceholder は別境界のrevealableなmuteで上書きされてはならない。
export const combineMuteMatches = (matches: Array<MuteMatch | undefined>): CombinedMuteMatches => {
    const present = matches.filter((match): match is MuteMatch => match !== undefined)
    const priority: Record<MuteReason, number> = { block: 3, user: 2, word: 1, timeline: 0 }
    const match = present.reduce<MuteMatch | undefined>(
        (selected, candidate) =>
            !selected || priority[candidate.reason] > priority[selected.reason] ? candidate : selected,
        undefined
    )
    return {
        match,
        fullyHidden: present.some((candidate) => candidate.reason === 'block' || candidate.entry?.hidePlaceholder)
    }
}

export const findMute = (
    target: MuteTarget,
    entries: MuteEntry[],
    options?: { blocks?: string[]; viewContext?: MuteViewContext; now?: Date }
): MuteMatch | undefined => {
    const now = options?.now ?? new Date()
    const viewContext = options?.viewContext ?? 'other'

    if (options?.blocks?.includes(target.author)) {
        return { reason: 'block', value: target.author }
    }

    const applicable = entries.filter((entry) => {
        if (isMuteEntryExpired(entry, now)) return false
        if (entry.scope === 'home' && viewContext !== 'home') return false
        return true
    })

    const userMatch = applicable.find(
        (entry) => entry.type === 'user' && entry.target === target.author && (!entry.reroutesOnly || target.isReroute)
    )
    if (userMatch) return { reason: 'user', value: userMatch.target, entry: userMatch }

    if (target.body) {
        const normalizedBody = normalizeMuteText(target.body)
        const wordMatch = applicable.find((entry) => {
            if (entry.type !== 'word') return false
            const word = normalizeMuteWord(entry.target)
            return word.length > 0 && normalizedBody.includes(word)
        })
        if (wordMatch) return { reason: 'word', value: wordMatch.target, entry: wordMatch }
    }

    if (target.timelines && target.timelines.length > 0) {
        const timelineMatch = applicable.find(
            (entry) => entry.type === 'timeline' && target.timelines!.includes(entry.target)
        )
        if (timelineMatch) return { reason: 'timeline', value: timelineMatch.target, entry: timelineMatch }
    }

    return undefined
}
