# waonme/world-app fork contract

このファイルは、arakoshi.com のために upstream (`concrnt/world-app`) と異なる挙動を保つための台帳です。実装の形ではなく、ユーザーから見える契約を正本にします。古い `dev` ブランチやコミット履歴だけを仕様書として扱わないでください。

## ブランチと配備

| 対象 | 役割 |
|---|---|
| `upstream/main` | 取り込み元。履歴を書き換えず merge する |
| `origin/main` | 唯一の本番ブランチ。VPS が定期取得して arakoshi.com に配備する |
| `integrate/upstream-*` | upstream 取り込み、競合解決、検証、PR 用 |
| `origin/dev` | 旧独自仕様の履歴参照。新規開発・配備には使わない |

本統合の固定点は upstream `2339365ce35516b8cd6869d5eff30f0b0186d9e1`、旧仕様の参照点は `origin/dev` の `52dd8f82671a1eb0a083e642f71e71087ef108e1` です。

`.github/workflows/build-check.yaml` はPR実行時点の `concrnt/world-app` main がHEADに含まれることを必須検査します。`.github/workflows/upstream-status.yaml` は毎週 `origin/main` との差を再確認し、未取り込みcommitがあれば失敗として通知します。どちらも自動mergeは行いません。

## 維持する独自仕様

| ID | 状態 / owner | ユーザー向け契約 | 主なコードアンカー | 出典 / ゲート |
|---|---|---|---|---|
| F-001 | Retained / waonme fork | UI からユーザー・ワード・タイムラインを期限付きでミュートし、ユーザーのリルートだけを対象にもできる。保存済み entry の `scope: home` と `hidePlaceholder` も表示判定時に尊重する（この2項目を編集する UI は未提供）。ブロック投稿は設定有効時に、外側の association が別のミュートに一致していても本文・noticeを出さない。 | `worldlib/src/mute.ts`, `worldlib/src/client.ts`, `app/src/contexts/Mute.tsx`, `web/src/contexts/Mute.tsx`, 両方の `MuteSettings.tsx` / `NotificationTimeline.tsx` / `RealtimeTimeline.tsx` | [PR #2](https://github.com/waonme/world-app/pull/2), `016aa18`; `pnpm --filter @concrnt/worldlib test:fork` と app/web build |
| F-002 | Retained / waonme fork | v2 で見つからない正当な v1 投稿を読み出せるが、所有者・署名者不一致と 403 は受理しない。関連取得が部分失敗したときは投稿表示を維持し、不確かな自分のリアクションを重複更新しない。 | `client/src/api.ts`, `worldlib/src/message.ts`, `worldlib/src/client.ts` | [PR #13](https://github.com/waonme/world-app/pull/13), [PR #14](https://github.com/waonme/world-app/pull/14); `pnpm --filter @concrnt/client test` と `pnpm --filter @concrnt/worldlib test:fork` |
| F-003 | Retained / waonme fork | 旧形式の Bluesky follow key を引き続き認識する。Bridge 設定はロード成功または未作成を確認するまで編集できず、ロード失敗時は上書きせず、保存失敗時は toggle を元へ戻してエラーを示す。アカウント resolver は選択アカウントと一致させる。 | `worldlib/src/forkCompatibility.ts`, 両方の `utils/bluesky.ts`, `views/Bluesky.tsx`, `views/BskyPerson.tsx`, `app/src/views/Welcome.tsx` | [PR #15](https://github.com/waonme/world-app/pull/15) (`2cb2cc7`, `e81618e`, `d178bdb`, `c7a133f`); fork policy tests と app/web build |
| F-004 | Retained / waonme fork | logout は新しい subkey を勝手に発行せず、Domain と master key / mnemonic を保持する。logged-out session は明示的な再登録でのみ復旧し、完全削除は壊れた値を含む recovery material の backup 成功後にだけ許可する。native は保存 API の正常完了を成功とし、保存キャンセル・失敗では解禁しない。Web は recovery data の生成とブラウザ管理 download の開始を成功境界とする。開始後の保存完了・キャンセルはページから観測できないため保証外。 | `worldlib/src/forkCompatibility.ts`, `web/src/contexts/Client.tsx`, `web/src/lib/subkey.ts`, `web/src/lib/v1storage.ts`, `web/src/components/EmergencyKit.tsx`, 両方の `ResetSessionButton.tsx`, `app/src/components/BackupKeyButton.tsx`, `app/src/views/Welcome.tsx` | [PR #15](https://github.com/waonme/world-app/pull/15) (`b22e45a`, `53334a0`, `2066592`, `492acb8`); fork policy tests、recovery anchors、app/web build |
| F-005 | Retained / VPS operator | 本番は毎回canonical HTTPSから一時mirrorを新規作成し、config allowlistとstrict fsckを通す。replace、graft、shallow/alternate、worktree config、filterを拒否・無効化し、fresh worktreeのraw byte/modeをcommitのblob IDと直接照合してから正確なSHAをビルド・配備する。非fast-forward、build / rollout / smoke test 失敗時に成功 SHA を進めない。変更前DeploymentとSHAをtransaction journalへ保存し、resourceVersion付きpatchとtransaction固有のpostpatch状態が一致する場合だけ、失敗・TERM・次回起動時にmetadata、strategy、template、image、probe、sidecarをまとめて復元する。外部更新、state欠落、取得元不一致、retry backoffはfail-closedに扱う。 | `ops/vps-deployer/deploy.sh`, `deploy-lib.sh`, `test-deploy.sh`, `world-app-vps-deploy.service`, `web/Dockerfile`, `/cc-info` | `8f14d09..85e58db`; deployer safety tests、static review、本番 smoke |
| F-006 | Retained / waonme fork | web のインライン返信先を編集した後、like / reaction による同値メッセージ再取得で選択を既定値へ戻さない。CSS Anchor Positioning 非対応の旧 WebKit でも投稿先 picker と既存 popover を画面内で操作でき、対応ブラウザでは upstream の native 配置を使う。 | `web/src/views/Post.tsx`, `web/src/views/postReplyDestinations.ts`, `ui/src/ui/Popover.tsx`, `ui/src/ui/popoverPlacement.ts`, 両方の `TimelinePicker.tsx` | upstream `75cc475` / `35a8f90` 取り込み時の独立反証; web state tests、UI placement tests、app/web build |

詳細な不変条件と反証条件は `.quality/contracts/upstream-friendly-fork.md` にあります。

F-001 の表示境界は Concrnt message envelope の `author` / `body` / `distributes` と、読み込み済みの association target です。通常通知は同じ表示境界、集約通知は muted/blocked actor、新着表示は envelope と association target を判定します。外部から後解決する ActivityPub / Bluesky 本文、push 配送、サーバー未読カウンターは対象外です。期限は次の表示判定・resource refresh 時に反映され、期限時刻ちょうどに再描画する timer は持ちません。

## upstream に吸収済みで、独自パッチとしては持たないもの

- ActivityPub の actor identity、resolve retry / dedupe、object 別 cache、private media、blurhash なし media（旧 PR #5〜#9）。現在の upstream 実装を正本にします。
- セマンティックデザイントークンと timeline/list tab の基礎スタイル（旧 PR #3〜#4）。現在の upstream が同等以上なので、古い差分を再適用しません。

## 意図的に戻さないもの

- 旧 `dev` 用 GHCR build workflow。現在は VPS が `main` を配備します。
- 全アカウントを削除する旧 `clear_all` 動作。個別の復旧 UI と明示的 logout を使います。
- list / domain / thread / push 配送レベルのミュート。F-001 の対象外です。

## upstream 取り込み手順

1. clean なローカル `main` で `scripts/prepare-upstream-sync.sh` を実行します。スクリプトは root 解決前の `core.worktree`、`origin/main` と一致しない状態、lookalike remote、local/include経由のURL rewrite、local HTTP/TLS transport、replace ref、graft、shallow/alternate object store、hidden index flags、local diff / merge driver / rerere / merge options を拒否します。proxy・CA環境を除去し、merge時のattributesを取得済み`main`のtreeへ固定してsystem/user-global attributesを無効化したうえで、正規GitHub URLから取得した固定 upstream SHA と正確な2親を持つ統合ブランチを作ります。
2. 競合をこの台帳の ID 単位で解消します。新しい upstream が同等の挙動を持つ場合は、古い実装ではなく新しい実装を採用し、台帳を更新します。
3. 次を実行します。

   ```sh
   pnpm install --frozen-lockfile
   ops/vps-deployer/test-deploy.sh
   scripts/test-prepare-upstream-sync.sh
   scripts/check-fork-contract.sh
   pnpm --filter @concrnt/client test
   pnpm --filter @concrnt/worldlib test:fork
   pnpm --filter @concrnt/ui test:popover
   pnpm --filter web test:fork
   pnpm --workspace-concurrency=1 --filter web... build
   pnpm --workspace-concurrency=1 --filter world-app... build
   git diff --check origin/main...HEAD
   ```

4. 統合ブランチを push して PR を作り、必須 check と台帳のレビュー後にだけ `main` へ merge します。`main` を upstream へ reset / force-push しません。

`ops/vps-deployer/deploy.sh` を変更した PR は、先にレビュー済みブランチの deployer を VPS へ導入・照合してから merge します。導入できない場合は timer を停止してから merge します。詳細は `ops/vps-deployer/README.md` を参照してください。

## 既知の hosting 境界

upstream の `functions/embed/youtube.ts` は Cloudflare Pages Functions 用です。現在の VPS deployer は `web/dist` だけを配備するため、アプリは upstream の `https://concrnt.world/embed/youtube` に依存します。arakoshi.com 単独で完結させる場合は、この endpoint を別途配備して host を設定可能にする必要があります。
