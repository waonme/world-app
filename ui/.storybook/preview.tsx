import type { Preview } from '@storybook/react-vite'
import type { Theme } from '../src/types/Theme'
// 本番と同じテーマ定義を使う(独自コピーは round 等が乖離していた)
import { Themes } from '../src/data/Themes'

const preview: Preview = {
    parameters: {
        controls: {
            matchers: {
                color: /(background|color)$/i,
                date: /Date$/i
            }
        },

        a11y: {
            // 'todo' - show a11y violations in the test UI only
            // 'error' - fail CI on a11y violations
            // 'off' - skip a11y checks entirely
            test: 'todo'
        }
    },
    globalTypes: {
        theme: {
            description: 'Global theme for components',
            defaultValue: 'All',
            toolbar: {
                title: 'Theme',
                icon: 'circlehollow',
                dynamicTitle: true,
                items: ['All', ...Object.keys(Themes)]
            }
        }
    },
    decorators: [
        (Story, context) => {
            const themeName = context.globals.theme || 'All'
            let previewTargets: Theme[] = []
            if (themeName === 'All') {
                previewTargets = Object.values(Themes)
            } else {
                previewTargets.push(Themes[themeName])
            }

            return (
                <div
                    style={{
                        display: 'flex',
                        flexDirection: 'column'
                    }}
                >
                    {previewTargets.map((themeData) => (
                        <div
                            key={themeData.meta.name}
                            style={{
                                display: 'flex',
                                flex: 1,
                                alignItems: 'center',
                                justifyContent: 'center',
                                background: 'var(--content-background)',
                                '--content-text': themeData.content.text,
                                '--content-link': themeData.content.link,
                                '--content-background': themeData.content.background,
                                '--ui-text': themeData.ui.text,
                                '--ui-background': themeData.ui.background,
                                '--backdrop-text': themeData.backdrop.text,
                                '--backdrop-background': themeData.backdrop.background,
                                '--divider': themeData.divider,
                                '--space': themeData.space,
                                '--round': themeData.round,
                                '--accent': themeData.accent ?? themeData.content.link,
                                '--danger': themeData.danger ?? '#d32f2f',
                                '--text-secondary': 'color-mix(in srgb, var(--content-text) 70%, transparent)',
                                '--text-disabled': 'color-mix(in srgb, var(--content-text) 45%, transparent)',
                                '--scrim': 'rgba(0, 0, 0, 0.5)',
                                '--shadow-1': '0 2px 8px rgba(0, 0, 0, 0.2)',
                                '--shadow-2': '0 4px 8px rgba(0, 0, 0, 0.2)'
                            }}
                        >
                            <Story />
                        </div>
                    ))}
                </div>
            )
        }
    ]
}

export default preview
