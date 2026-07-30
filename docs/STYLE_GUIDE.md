# world-app スタイルガイド

UIの見た目に関する判断はすべてこの文書を基準にする。迷ったときは v1 (concrnt-world) の設計思想に立ち返る。

> 適用範囲: **新規・変更するコード**に適用する。既存コードの逸脱(生色・独自サイズ等)は Stage 1 以降で画面単位に解消していく(§6)。

## 1. 世界観の原則(v1から継承)

1. **3面ロール** — 画面は「backdrop(世界)→ ui(道具)→ content(紙)」の3枚の面で構成する。階層は影やボーダーではなく**面の色替え**で示す。各面は必ず対になる文字色を持つ。
2. **アクセントは1本** — `accent`(既定では `content.link` から導出)は「注目」専用: リンク・選択インジケータ・通知ドット。操作面の地色(`ui.background`)とは役割が違う。選択可能要素すべてをアクセントで塗らない。新着ピルのような「面を持つCTA」は accent でなく **ui面色**(v1の contained primary 踏襲)。また accent は content面(紙)前提の色のため、**backdrop面に置くUI(下部ナビ等)の選択状態は面に合う色を明示する**(`Tab` の `selectedColor`)。
3. **派生色は本文色の透過で作る** — secondary text は 70%、disabled は 45%、面の反応(hover/pressed/selected)は 8/12/15%。独立したグレースケールは持たない。これによりどのユーザーテーマでも破綻しない。
4. **形状は静か** — 角丸は `round` トークン基数(既定4px)の乗数。ピル(`roundFull`)は「行動を促すもの」(FAB・新着ピル・チップ)専用。
5. **テーマはユーザーの文化** — テーマJSONは投稿で共有される。新しいテーマスロットは必ず optional+導出フォールバックにし、既存テーマを壊さない。

## 2. トークン台帳

実装は常に `CssVar`(`ui/src/types/Theme.tsx`)を参照する。**生のhex/rgb/色名をアプリ層に書かない。**

### 色(テーマ由来)
| トークン | 役割 |
|---|---|
| `CssVar.contentText / contentBackground` | 紙面の文字/背景 |
| `CssVar.contentLink` | 本文中のリンク |
| `CssVar.uiText / uiBackground` | 操作面(ヘッダ・containedボタン)の文字/背景 |
| `CssVar.backdropText / backdropBackground` | 最背面の文字/背景 |
| `CssVar.divider` | 区切り線 |

### 色(導出。テーマ側スロットは optional)
| トークン | 導出 | 用途 |
|---|---|---|
| `CssVar.accent` | `theme.accent ?? content.link` | 選択インジケータ・新着・強調 |
| `CssVar.danger` | `theme.danger ?? #d32f2f` | エラー文言・破壊的操作(白地で4.5:1以上) |
| `CssVar.textSecondary` | text 70% | 補足テキスト(`opacity:0.7`の代替) |
| `CssVar.textDisabled` | text 45% | 無効状態・プレースホルダ |
| `CssVar.scrim` | 黒50% | モーダル/シートの背面 |

### 状態(色相を変えず透過率で表す)
| 関数 | α | 用途 |
|---|---|---|
| `CssVar.stateHover(color)` | 0.08 | hover・静的な淡い地(チップ地・スケルトン基調も同値) |
| `CssVar.statePressed(color)` | 0.12 | 押下 |
| `CssVar.stateSelected(color)` | 0.15 | 選択面 |

透過の実装は `color-mix(in srgb, <色> N%, transparent)` を使う。**元色のアルファを乗算的に保つ**(半透明の本文色を持つテーマでも派生が本文より濃くならない)ため、`rgb(from ...)` によるアルファ置換より優先する。

### ブラウザサポート下限
`color-mix` 基準で **Chrome/WebView 111+ / Safari 16.2+**(iOS版TauriのターゲットはiOS 15だが、`color-mix` は導入前から既に使用されており、この下限はStage 0以前からのもの)。非対応エンジンでは淡い地の宣言が無効になり透明にフォールバックする(機能は失われない)。相対色構文 `rgb(from ...)` は既存の押下スタイルに残存しており、そちらは Chrome 119+/Safari 16.4+ を要する。

### 影・角丸・間隔
- 影: `CssVar.shadow1`(浮遊パネル: Popover等)/ `CssVar.shadow2`(FAB等)。この2段以外を作らない。
- 角丸: `CssVar.round(0.5 | 1 | 2 | 4)` = 2/4/8/16px、正円は `50%`、ピルは `CssVar.roundFull`。生pxを書かない。
- 間隔: `CssVar.space(n)`。乗数は `0.5 / 1 / 2 / 3 / 4` を基本とする(4pxグリッド)。生px(4px, 8px…)は space() に置換する。

## 3. タイポグラフィ

閉じたスケールのみ使用。**独自サイズの追加禁止。**ベースは `html` の 16px(将来 baseFontSize 設定で可変にするため、原則 rem/em で組む)。

| サイズ | 役割 |
|---|---|
| `2rem` | 特大見出し(オンボーディング等) |
| `1.5rem` | ページタイトル級 |
| `1.2rem` | セクション見出し・大きめボタン |
| `1rem` | **本文・入力・主要操作(基準)** |
| `0.95rem` | メッセージの名前行(ユーザー名)専用。v1の階層(0.9〜0.95rem)を継承 |
| `0.875rem` | キャプション・補助操作(`Text variant="caption"`) |
| `0.75rem` | メタ情報(時刻・投稿先タグ)。**非操作要素のみ** |

- 見出しは `Text` の variant(h1〜h6、em基準)を使う。
- 密度が欲しいときに文字を縮めない。余白と構造で調整する。
- 太さは 400 / 700 の2種を基本とする(現状の実態に合わせる。500/600 の導入は変更提案として扱う)。

## 4. 寸法ラダー

- **操作要素の高さ**: 24(チップ)/ 32(IconButton)/ 40(ヘッダスロット・dense行)/ 48(ListItem・主要ボタン)。44/42/36/30/28 等の中間値は最寄りに吸収する。
- **アイコン**: 14 / 16 / 20 / 24。奇数(15等)を使わない。
- **アバター**: 40(標準)/ 20(チップ内)/ 16(インライン)。形は**角丸4pxの正方形**で統一(丸アバターは新着ピル等の特殊文脈のみ)。

## 5. 禁止事項

- アプリ層での生色指定(hex / rgb / 色名)。必要な色がなければトークンを追加する議論をする
- `opacity` によるテキスト階層の代用(→ `textSecondary` / `textDisabled`)
- 独自フォントサイズ・独自の影・独自の角丸の場当たり追加
- MUI残骸の文字列(`'text.secondary'` 等)— これらは**無効なCSS**になる
- app/web で同名コンポーネントのスタイル値を無断で乖離させること(プラットフォーム差はコメントで理由を残す)

## 6. 段階計画(進行状況)

- **Stage 0(この文書と同時に導入)**: トークン基盤・バグ級修正(Skeletonシマー・Spoiler・PullToRefresh・Divider/Chip/Avatar/レンダラーのトークン化)・blueテーマのアクセント復活(#1e6476)・darkgrayのdivider修正・Storybookのテーマ定義一本化
- **Stage 1**: タイムライン+リスト切り替えタブ(選択状態の明確化、名前/時刻の階層、生値のトークン置換、app/webドリフト解消)
- **Stage 2**: NotificationTimeline・EmojiPicker・Composer・Settings系
- **Stage 3**: オンボーディング(EmergencyKit/Register)の統一、MediaViewerのscrim整理、ダークテーマの本設計(ライト基準確定後に別階調系として設計)

調査の全記録(4方面監査レポート)は PR の記述とセッションログを参照。
