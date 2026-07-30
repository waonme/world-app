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
    // color-mixは元色のアルファを乗算的に保つ(半透明テーマでも破綻しない)
    stateHover: (color: string) => `color-mix(in srgb, ${color} 8%, transparent)`,
    statePressed: (color: string) => `color-mix(in srgb, ${color} 12%, transparent)`,
    stateSelected: (color: string) => `color-mix(in srgb, ${color} 15%, transparent)`
}

// Loose shape of a v1 (MUI-based) Concrnt theme, as shared/stored by the v1 client.
export interface ThemeV1 {
    meta?: { name?: string; author?: string; comment?: string }
    palette?: {
        primary?: { main?: string; contrastText?: string }
        secondary?: { main?: string }
        background?: { default?: string; paper?: string; contrastText?: string }
        text?: { primary?: string; secondary?: string; disabled?: string }
        divider?: string
    }
    shape?: { borderRadius?: number }
}

// Converts a v1 (palette-based) theme into the v2 (content/ui/backdrop) structure.
// Idempotent: a value that already has `content` (v2 shape) is returned untouched.
export const migrateTheme = (input: any): Theme => {
    if (input && typeof input === 'object' && input.content) {
        return input as Theme
    }

    const v1 = (input ?? {}) as ThemeV1
    const palette = v1.palette ?? {}

    const uiBackground = palette.primary?.main ?? '#0476d9'
    const contentText = palette.text?.primary ?? '#000000'

    return {
        content: {
            // v1では secondary.main がリンク・タブ選択・通知dotを担うアクセント。
            // text.secondary は組み込みテーマだと本文色と同値のことがある(例: blue)ため、
            // secondary.main を優先して拾う
            link: palette.secondary?.main ?? palette.text?.secondary ?? contentText,
            text: contentText,
            background: palette.background?.paper ?? '#ffffff'
        },
        ui: {
            text: palette.primary?.contrastText ?? '#ffffff',
            background: uiBackground
        },
        backdrop: {
            text: palette.background?.contrastText ?? '#ffffff',
            background: palette.background?.default ?? uiBackground
        },
        divider: palette.divider ?? '#e6e2df',
        variant: 'world',
        space: '4px',
        round: v1.shape?.borderRadius != null ? `${v1.shape.borderRadius}px` : '4px',
        meta: {
            name: v1.meta?.name ?? 'imported'
        }
    }
}
