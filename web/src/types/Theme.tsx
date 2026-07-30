export interface Theme {
    content: {
        text: string
        link: string
        background: string
    }
    ui: {
        text: string
        background: string
    }
    backdrop: {
        text: string
        background: string
    }
    divider: string
    variant: 'classic' | 'world'
    meta?: any
    space: string
    round: string
    // 「注目」を担うアクセント色(選択インジケータ・新着・強調)。省略時は content.link から導出。
    // 既存テーマJSONを壊さないため optional
    accent?: string
    // 破壊的操作・エラーの色。省略時は既定値
    danger?: string
}

export const CssVar = {
    contentText: 'var(--content-text)',
    contentLink: 'var(--content-link)',
    contentBackground: 'var(--content-background)',
    uiText: 'var(--ui-text)',
    uiBackground: 'var(--ui-background)',
    backdropText: 'var(--backdrop-text)',
    backdropBackground: 'var(--backdrop-background)',
    divider: 'var(--divider)',
    accent: 'var(--accent)',
    danger: 'var(--danger)',
    // 本文色の透過で作る派生テキスト階層。独立グレースケールは持たない(v1からの原則)
    textSecondary: 'var(--text-secondary)',
    textDisabled: 'var(--text-disabled)',
    scrim: 'var(--scrim)',
    shadow1: 'var(--shadow-1)',
    shadow2: 'var(--shadow-2)',
    roundFull: '9999px',
    space: (mul: number) => `calc(var(--space) * ${mul})`,
    round: (mul: number) => `calc(var(--round) * ${mul})`,
    // 操作状態は色相を変えず透過率で表す。hover 8% / pressed 12% / selected 15%
    stateHover: (color: string) => `rgb(from ${color} r g b / 0.08)`,
    statePressed: (color: string) => `rgb(from ${color} r g b / 0.12)`,
    stateSelected: (color: string) => `rgb(from ${color} r g b / 0.15)`
}
