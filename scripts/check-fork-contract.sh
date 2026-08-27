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
    rg --quiet --fixed-strings "$pattern" "$path" && return 0
  elif grep -Fq -- "$pattern" "$path"; then
    return 0
  fi
  {
    echo "fork contract anchor '$pattern' is missing from $path" >&2
    exit 1
  }
}

require_file FORK.md
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

# F-005: immutable SHA image and deployed-commit smoke check.
require_match 'expected_image="localhost/world-app:$target_sha"' ops/vps-deployer/deploy.sh
require_match "/cc-info" ops/vps-deployer/deploy.sh

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
