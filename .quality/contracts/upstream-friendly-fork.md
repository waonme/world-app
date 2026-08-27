# Quality Contract: upstream-friendly production fork

- Contract ID: `world-app-upstream-friendly-fork-20260827`
- Status: IMPLEMENTED / PRE-MERGE GATE
- Risk tier: High
- Source specification: user direction on 2026-08-27; [mute PR #2](https://github.com/waonme/world-app/pull/2); fork PRs #3-#15; production incident where the VPS moved from `dev` behavior to a `main` build without fork features
- Approved revision: integration branch based on production `85e58db`, frozen upstream cut `35a8f90`; final PR head is recorded by the review PR
- Approved by: repository owner direction; final diff approval pending
- Change boundary: branch policy, upstream integration workflow, production deployment contract, fork-specific web/app/client/worldlib behavior, regression tests and documentation

## Intent

### Intended change

Make `main` the documented production fork branch, forward-port the still-required `dev` customizations onto the latest upstream, and make future upstream updates repeatable and reviewable without silently dropping fork behavior.

### User-visible outcome

arakoshi.com keeps its documented mute, ActivityPub, legacy-content, session-recovery, and presentation behavior while receiving current upstream improvements.

### Non-goals

- Automatically deploy an upstream update that has not passed the fork gates.
- Preserve historical commit topology or obsolete implementation details when a smaller current-upstream implementation gives the same observable behavior.
- Add the Phase 2 mute features explicitly excluded by PR #2: list-scoped, domain, thread, and push-notification mute.
- Change Concrnt server or ActivityPub bridge behavior outside this repository.

### Protected surfaces

- Existing accounts, subkeys, backups, legacy follows, and bridge settings must remain readable and recoverable.
- Mute records remain private and compatible with existing `cckv://<owner>/concrnt.world/mutes/<id>` data.
- ActivityPub access control and v1 fallback ownership validation must not be weakened.
- Production deployment must retain exact-commit verification and rollback-on-failure.
- App and web must retain equivalent user-visible behavior while preserving platform-specific navigation and UI code.

## Facts, assumptions, and open decisions

### Confirmed facts

- `main` is polled and deployed by `ops/vps-deployer`; `/cc-info` reports the deployed main commit.
- The previous fork feature line is `origin/dev`; mute was merged there by PR #2 and never existed on the pre-sync `main`.
- The integration branch contains the frozen upstream cut `35a8f90`; production `main` remains at `85e58db` until the reviewed PR is merged.
- `origin/dev` contains additional mute, ActivityPub, legacy-v1, theme/style, and session/bridge changes, but its historical tests were not all retained through earlier upstream integrations.
- The current production deployment at `85e58db` lacks the mute implementation.

### Assumptions

- `origin/dev` at `52dd8f8` is the behavioral baseline that arakoshi.com intended to preserve before the move to the VPS `main` deployment.
- Fork style changes are retained unless current upstream already provides an equivalent or better observable result.
- Existing implementation may be replaced when direct reuse creates higher conflict or maintenance risk.

### Human decisions

- [ ] After behavior is restored and verified, decide whether the old `dev` and merged feature branches should be archived or kept as historical references.
- [x] Use current upstream styling instead of reapplying obsolete PR #3/#4 implementation details.
- [ ] Enable a GitHub `main` ruleset requiring PRs and the `build-check` job after this workflow exists on the default branch.
- [ ] Before merging this PR, install and verify its deployer script on the VPS (or pause the old timer) so the release that introduces the gate is protected by it.

## Quality clauses

| ID | Guarantee | Forbidden outcome | Precondition / stimulus | Oracle / observable | Expected result / tolerance | Test layer | Blocking |
|---|---|---|---|---|---|---|---|
| QC-001 | Production contains the documented fork delta on top of current upstream. | Updating upstream silently removes a documented customization. | Compare integration head with both `upstream/main` and the frozen fork inventory. | Upstream is an ancestor; inventory anchors and behavior tests pass. | Behind count is 0 at integration time and every retained customization has evidence. | Static / Integration | Yes |
| QC-002 | User, word, and timeline mute support expiry, saved-entry home/global scope and placeholder policy, reroutes-only mode, normal-notification rendering, actor filtering for aggregated notifications, and envelope/target filtering for timeline new arrivals. | Muted content leaks through a documented covered surface or unrelated content is hidden. | Load active, expired, malformed, scoped, and overlapping mute entries, including outer/target association combinations. | Pure mute-policy/combination tests plus app/web type/build and anchor checks. | Deterministic priority `block > user > word > timeline`; any matched block/hard-hide boundary remains unrevealable; expired entries never match when evaluated. | Unit / Integration | Yes |
| QC-003 | Mute records remain private and existing records remain usable. | A mute list is public, rewritten under an incompatible key, or lost during migration. | Read and update existing per-item KV mute records. | Client request URI, schema and policy assertions; compatibility fixture. | Same key namespace and private policy; re-mute updates the deterministic entry. | Unit / Contract | Yes |
| QC-004 | Blocked-user posts are completely hidden when block filtering is enabled. | A blocked post renders its body or a revealable placeholder. | Timeline contains a blocked author, including as an association target behind another mute. | Combined policy tests, both `MessageContainer` anchors, and app/web build checks. | A block or hard-hide match at either boundary cannot render a visible post or revealable placeholder. | Unit / Static / Integration | Yes |
| QC-005 | The fork integration does not reapply obsolete ActivityPub patches over the current upstream implementation. | Conflict resolution replaces current upstream AP behavior with the historical fork copy. | Compare AP-specific files and conflict resolutions with the frozen upstream cut, then build both clients. | Upstream ancestry/diff review and component build/type checks. | AP-specific implementation follows the merged upstream cut; only documented generic message-boundary behavior may differ. | Static / Integration | No |
| QC-006 | Legacy v1 messages remain retrievable without weakening owner or permission checks. | A response for another owner is accepted, 403 is bypassed, or uncertain association state causes a duplicate write. | v2 miss for a valid legacy URI, forged/mismatched envelope, 403, and own-association load failure. | Client/worldlib contract tests. | Valid legacy content loads; forged or unauthorized content is rejected; writes are disabled when state is unknown. | Unit / Contract | Yes |
| QC-007 | Logout, restore, subkey, follow, bridge-setting, and retained-domain recovery preserve the `dev` safety fixes. | Logout provisions credentials, partial settings overwrite good state, or recovery material is deleted before backup. | Exercise old/new follow keys, logged-out/v1 migration sessions, bridge load/save states, logout retention and recovery anchors. | Pure fork-policy tests, component-use/static anchors, and app/web build checks. | No automatic reenrollment after ordinary logout, no settings write before a valid load state, save failure rolls back, and destructive reset remains backup-gated. | Unit / Integration | Yes |
| QC-008 | Upstream synchronization is a reviewable merge into production, never an implicit reset. | `main` is force-reset to upstream or deploys before fork gates. | Run the documented sync command/workflow. | Git ancestry, generated integration branch/PR, required status checks. | No force push; production changes only after reviewed gates. | Static / Runtime | Yes |
| QC-009 | Production deploys exactly the tested `main` commit and rolls back on failed rollout or smoke test. | `/cc-info` differs from the target, broken assets become current, or failure loses the previous image. | Deploy a good commit and simulate build/rollout/smoke failure. | Deployer state, Kubernetes rollout, `/cc-info`, root page and referenced JS asset. | Exact SHA match; failure retains/restores previous image; retry backoff remains bounded at 10 minutes. | E2E / Runtime | Yes |
| QC-010 | Fork-specific behavior is discoverable without reading commit history. | A maintainer cannot tell which deltas must survive an upstream update. | Open the repository documentation. | Fork inventory maps each behavior to code anchors, tests, source PR and upstream status. | Every retained customization has a stable ID and owner/status. | Static | Yes |

## Invariants and state transitions

- INV-001: `upstream/main` is merged into an integration branch and then into production `main`; production is never synchronized by hard reset.
- INV-002: `main` is the source of truth deployed by the VPS; `dev` is historical until explicitly repurposed.
- INV-003: Mute persistence remains private, deterministic per type/target, and backward compatible.
- INV-004: Missing or failed mute loading fails open for timeline availability, but never changes stored mute data.
- INV-005: Legacy fallback never converts an authorization failure into a successful fetch.
- INV-006: Unknown own-association state prevents mutation rather than risking duplicate reactions.
- INV-007: A failed production build or rollout does not advance `deployed-sha` and keeps a recoverable previous image.

## Risk-to-gate matrix

| Risk / failure mode | Impact | Detection oracle | Required gate | Held out? | Owner |
|---|---|---|---|---|---|
| Fork behavior dropped during upstream merge | High user-visible regression | inventory anchors + focused behavior tests | fork-contract check and review | No | repository maintainer |
| Mute privacy/schema regression | Privacy/data compatibility | request/policy fixture | client/worldlib contract test | Yes | independent verifier |
| Legacy fallback accepts forged content | Security/data integrity | mismatched owner/signer fixture | client/worldlib negative test | Yes | independent verifier |
| Session recovery overwrites or provisions unexpectedly | Account loss/lockout | old-state and partial-failure fixtures | integration test/manual recovery matrix | Yes | repository maintainer |
| Wrong commit deployed | Production regression | `/cc-info` exact SHA plus asset smoke | VPS deployer acceptance | No | deployer |
| Upstream sync has unresolved semantic conflicts | Broad regression | diff classification and build failures | PR review + full build | No | repository maintainer |

## Falsification scenarios

1. Given an active home-only word mute, when the same post renders outside home scope, the implementation is wrong if both surfaces hide it.
2. Given an expired mute and an active lower-priority mute, the implementation is wrong if the expired entry wins or prevents the active entry from matching.
3. Given an ActivityPub attachment without blurhash, the implementation is wrong if rendering throws or replaces the post with an error boundary.
4. Given a transient ActivityPub 404 followed by success, the implementation is wrong if the object remains permanently missing or duplicate callers create an unbounded request burst.
5. Given a forged legacy envelope whose author or signer differs from the requested URI owner, the implementation is wrong if content renders.
6. Given own-association retrieval failure, the implementation is wrong if favorite/reaction writes remain enabled.
7. Given an upstream update that deletes a fork anchor, the implementation is wrong if the sync gate passes without an explicit inventory decision.
8. Given a production rollout whose `/cc-info` is not the target SHA, the implementation is wrong if the deployer records success.

## Required evidence

### Before merge

- [x] Static analysis: `git diff --check`, conflict-marker scan, fork inventory/anchor check, changed-file ESLint/Prettier.
- [x] Unit: mute policy/persistence and legacy fallback/partial-load negative-path tests.
- [x] Integration: `pnpm --workspace-concurrency=1 --filter web... build` and app build; session/bridge recovery review.
- [x] Contract: production deployer syntax/non-fast-forward/static validation.
- [ ] Release bootstrap: reviewed deployer installed and checksum-verified before merge, or the existing timer is paused.
- [x] Regression red-before / green-after: current `main` must fail the mute/fork-anchor gate; integration head must pass.

### After merge / rollout acceptance

- [ ] Runtime: VPS exact-SHA, root and referenced-asset smoke checks complete for the merged commit.
- [ ] Manual behavior: an existing account can create and remove a mute in both supported clients, and a covered timeline post is hidden according to its placeholder policy.

## Explicit non-guarantees

- Server-side delivery filtering, push-notification mute, filtering of the server-maintained unread counter, and word matching against ActivityPub/Bluesky content resolved outside the Concrnt envelope are not guaranteed in this change.
- Expiry is guaranteed at the next mute evaluation/resource refresh, not by an exact-time UI timer. The UI does not currently edit `scope` or `hidePlaceholder`, although saved compatible entries are honored.
- The old `dev` branch history will not be rewritten into a linear patch series.
- Third-party ActivityPub servers are not guaranteed to be available; only client retry/cache behavior is covered.

## Readiness decision

CONDITIONAL PRE-MERGE: all local static, unit, contract, and production-build gates pass. Do not merge until the release-bootstrap item above is complete; decide the `main` ruleset policy as part of repository administration. Runtime and manual acceptance remain post-rollout gates.

**この契約が保証対象にするもの:** 最新upstreamを含むproduction `main`で、文書化したフォーク独自挙動と安全なデプロイ・同期手順が維持されること。

**この契約が意図的に保証対象外とするもの:** Phase 2のミュート、サーバー／Bridge側変更、旧ブランチ履歴の整理そのもの。

**人間が決めなければならないこと:** 旧`dev`等の扱い、`main` ruleset の有効化、VPS deployer の先行導入または timer 停止。
