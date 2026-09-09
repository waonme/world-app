#!/usr/bin/env bash

set -Eeuo pipefail

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "run this script inside the world-app repository" >&2
  exit 1
}
cd "$repository_root"

require_file() {
  local path=$1
  if [ ! -f "$path" ]; then
    echo "fork contract anchor is missing: $path" >&2
    exit 1
  fi
}

require_match() {
  local pattern=$1
  local path=$2
  if command -v rg >/dev/null 2>&1; then
    rg --quiet --fixed-strings -- "$pattern" "$path" && return 0
  elif grep -Fq -- "$pattern" "$path"; then
    return 0
  fi
  {
    echo "fork contract anchor '$pattern' is missing from $path" >&2
    exit 1
  }
}

require_file FORK.md
require_file .github/workflows/upstream-status.yaml
require_match "merge-base --is-ancestor upstream/main origin/main" .github/workflows/upstream-status.yaml
require_match "merge-base --is-ancestor refs/remotes/upstream/main HEAD" .github/workflows/build-check.yaml
for id in F-001 F-002 F-003 F-004 F-005 F-006; do
  require_match "$id" FORK.md
done

# F-001: policy, persistence, settings route and covered surfaces.
require_file worldlib/src/mute.ts
require_file worldlib/test/mute.test.cjs
require_match "private.json" worldlib/src/client.ts
require_match "this.mutes.refresh()" worldlib/src/client.ts
require_match 'path="settings/mute"' web/src/main.tsx
require_match "MuteSettingsView" app/src/views/Settings.tsx
for path in web/src/components/NotificationTimeline.tsx app/src/components/NotificationTimeline.tsx \
  web/src/components/RealtimeTimeline.tsx app/src/components/RealtimeTimeline.tsx; do
  require_match "findMute" "$path"
done
for path in web/src/components/message/main.tsx app/src/components/message/main.tsx; do
  require_match "useMuteCheck" "$path"
  require_match "combineMuteMatches" "$path"
done
for path in web/src/components/message/MessageActions.tsx app/src/components/message/MessageActions.tsx; do
  require_match 'key="muteAuthor"' "$path"
  require_match "MuteDurationSelect" "$path"
  require_match ".mute({ type: 'user', target: props.message.author, expiresAt })" "$path"
done

# F-002: constrained v1 fallback and mutation guards after partial loads.
require_match "/api/v1/message/" client/src/api.ts
require_file client/test/legacy-v1.test.cjs
require_file worldlib/test/legacy-message.test.cjs
require_match "response.content.author !== parsed.owner" client/src/api.ts
require_match "legacy.signer !== parsed.owner" client/src/api.ts
require_match "if (!this.ownAssociationsLoaded)" worldlib/src/message.ts

# F-003/F-004: old follow keys and explicit session recovery markers.
require_file worldlib/src/forkCompatibility.ts
require_file worldlib/test/fork-compatibility.test.cjs
require_match "legacyFollowKey" web/src/utils/bluesky.ts
require_match "legacyFollowKey" app/src/utils/bluesky.ts
require_match "decideStoredSessionAction" web/src/contexts/Client.tsx
require_match "WEB_LOGOUT_STORAGE_KEYS" web/src/contexts/Client.tsx
require_match "canWriteBridgeSettings" web/src/views/Bluesky.tsx
require_match "canWriteBridgeSettings" app/src/views/Bluesky.tsx
require_match "provisionSubkey" web/src/lib/subkey.ts
require_match "recoveryBackupExported" web/src/components/EmergencyKit.tsx
require_match "disabled={!exported}" web/src/components/ResetSessionButton.tsx
require_match "runAfterSuccessfulBackup" app/src/components/BackupKeyButton.tsx
require_match "onBackupComplete" app/src/components/ResetSessionButton.tsx
require_match "resolverCCID" app/src/views/Welcome.tsx
require_match "Web は recovery data の生成とブラウザ管理 download の開始を成功境界とする。" FORK.md
require_match "browser-managed download is initiated" .quality/contracts/upstream-friendly-fork.md
require_match "anchor.click()" web/src/components/EmergencyKit.tsx
require_match "anchor.click()" web/src/components/ResetSessionButton.tsx

# F-005: immutable SHA image and deployed-commit smoke check.
require_file ops/vps-deployer/deploy-lib.sh
require_file ops/vps-deployer/test-deploy.sh
require_file ops/vps-deployer/world-app-vps-deploy.service
require_file scripts/test-prepare-upstream-sync.sh
require_match 'expected_image="localhost/world-app:$target_sha"' ops/vps-deployer/deploy.sh
require_match "/cc-info" ops/vps-deployer/deploy-lib.sh
require_match "verify_exact_worktree" ops/vps-deployer/deploy.sh
require_match "WORLD_APP_ALLOW_INITIAL_BOOTSTRAP" ops/vps-deployer/deploy.sh
require_match "trap finish_deployment EXIT" ops/vps-deployer/deploy.sh
require_match "verify_http_deployment_once" ops/vps-deployer/deploy.sh
require_match "recover_inflight_deployment" ops/vps-deployer/deploy.sh
require_match "create_deployment_transaction" ops/vps-deployer/deploy.sh
require_match "commit_deployment_success" ops/vps-deployer/deploy.sh
require_match "require_mirror_origin_repository" ops/vps-deployer/deploy.sh
require_match "TimeoutStopSec=6min" ops/vps-deployer/world-app-vps-deploy.service
require_match "TimeoutStartSec=60min" ops/vps-deployer/world-app-vps-deploy.service
require_match "KillMode=control-group" ops/vps-deployer/world-app-vps-deploy.service
require_match "wait_for_deployment_rollout" ops/vps-deployer/deploy-lib.sh
require_match "timeout --signal=TERM --kill-after=10s 210s" ops/vps-deployer/deploy-lib.sh
require_match '"resourceVersion": "$prepatch_resource_version"' ops/vps-deployer/deploy.sh
require_match "world-app.waon.me/deploy-transaction" ops/vps-deployer/deploy.sh
require_match "require_mirror_without_url_rewrites" ops/vps-deployer/deploy.sh
require_match "require_mirror_without_object_indirection" ops/vps-deployer/deploy.sh
require_match "require_fresh_mirror_config" ops/vps-deployer/deploy.sh
require_match "GIT_NO_REPLACE_OBJECTS=1" ops/vps-deployer/deploy-lib.sh
require_match "core.attributesFile=/dev/null" ops/vps-deployer/deploy-lib.sh
require_match "-u GIT_SSL_NO_VERIFY" ops/vps-deployer/deploy-lib.sh
require_match "-u HTTPS_PROXY" ops/vps-deployer/deploy-lib.sh
require_match "fsck --full --strict" ops/vps-deployer/deploy.sh
require_match "run_isolated_git clone --mirror --no-tags" ops/vps-deployer/deploy.sh
require_match "hash-object --no-filters" ops/vps-deployer/deploy-lib.sh
require_match "require_remote_repository origin waonme/world-app" scripts/prepare-upstream-sync.sh
require_match "require_remote_repository upstream concrnt/world-app" scripts/prepare-upstream-sync.sh
require_match "require_no_local_url_rewrites" scripts/prepare-upstream-sync.sh
require_match "require_safe_invocation_config" scripts/prepare-upstream-sync.sh
require_match "require_no_local_object_indirection" scripts/prepare-upstream-sync.sh
require_match "require_no_hidden_index_entries" scripts/prepare-upstream-sync.sh
require_match "require_direct_ref" scripts/prepare-upstream-sync.sh
require_match "require_ref_path_without_symlinks" scripts/prepare-upstream-sync.sh
require_match "snapshot_refs_except" scripts/prepare-upstream-sync.sh
require_match "require_checked_out_main" scripts/prepare-upstream-sync.sh
require_match "require_git_attribute_source_support" scripts/prepare-upstream-sync.sh
require_match "GIT_NO_REPLACE_OBJECTS=1" scripts/prepare-upstream-sync.sh
require_match "core.attributesFile=/dev/null" scripts/prepare-upstream-sync.sh
require_match '|http\..*|' scripts/prepare-upstream-sync.sh
require_match '|diff\..*|' scripts/prepare-upstream-sync.sh
require_match "-u GIT_SSL_NO_VERIFY" scripts/prepare-upstream-sync.sh
require_match "-u HTTPS_PROXY" scripts/prepare-upstream-sync.sh
require_match "--no-write-fetch-head --no-prune" scripts/prepare-upstream-sync.sh
require_match 'GIT_ATTR_SOURCE=$attribute_source' scripts/prepare-upstream-sync.sh
require_match "fetch_canonical_main origin https://github.com/waonme/world-app.git" scripts/prepare-upstream-sync.sh
require_match "fetch_canonical_main upstream https://github.com/concrnt/world-app.git" scripts/prepare-upstream-sync.sh
require_match 'run_trusted_merge_git "$local_main" merge --no-ff "$upstream_sha"' scripts/prepare-upstream-sync.sh
require_match 'if [ "$merge_parents" != "$local_main $upstream_sha" ]' scripts/prepare-upstream-sync.sh
require_match "symbolic-origin-ref" scripts/test-prepare-upstream-sync.sh
require_match "symbolic-upstream-ref" scripts/test-prepare-upstream-sync.sh
require_match "filesystem-ref-symlink" scripts/test-prepare-upstream-sync.sh
require_match "filesystem-parent-symlink" scripts/test-prepare-upstream-sync.sh
require_match "failed-fetch-ref-mutation" scripts/test-prepare-upstream-sync.sh
for path in .github/workflows/build-check.yaml ops/vps-deployer/deploy.sh; do
  require_match "ops/vps-deployer/test-deploy.sh" "$path"
  require_match "scripts/test-prepare-upstream-sync.sh" "$path"
done

# F-006: upstream UI refresh and legacy-WebKit compatibility guards.
require_file web/src/views/postReplyDestinations.ts
require_file web/test/post-reply-destinations.test.mjs
require_match "reconcileReplyDestinations" web/src/views/Post.tsx
require_file ui/src/ui/popoverPlacement.ts
require_file ui/test/popover-placement.test.mjs
require_match "getCenteredPopoverFallbackPlacement" ui/src/ui/Popover.tsx
for path in web/src/components/TimelinePicker.tsx app/src/components/TimelinePicker.tsx; do
  require_match "anchorRef={dropdownAnchorRef}" "$path"
  require_match "matchAnchorWidth" "$path"
done

echo "fork contract anchors are present"
