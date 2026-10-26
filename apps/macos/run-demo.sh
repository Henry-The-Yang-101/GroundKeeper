#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
build=true
instance=""
preview_mode="--spending-preview"
usage() {
  echo "Usage: $0 [--no-build] [--instance NAME] [--categories] [--transactions] [--recording] [--captures]"
  echo "Open a fresh fictional spending demo; --instance gives it a unique app name and path."
  echo "Use --recording for 20 current-month transactions plus 5 per week for the previous 12 weeks."
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) build=false; shift ;;
    --transactions) preview_mode="--transaction-preview"; shift ;;
    --categories) preview_mode="--category-preview"; shift ;;
    --recording) preview_mode="--recording-preview"; shift ;;
    --captures) preview_mode="--capture-review-preview"; shift ;;
    --instance)
      [[ $# -ge 2 && "$2" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,39}$ ]] || { echo "Instance names must be 1–40 letters, digits or hyphens, starting with a letter." >&2; exit 2; }
      instance="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if $build; then "$script_dir/build.sh"; fi
app="$repo_dir/.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app"
[[ -x "$app/Contents/MacOS/GroundKeeper" ]] || { echo "Build the Debug app first: $script_dir/build.sh" >&2; exit 1; }
if [[ -n "$instance" ]]; then
  # A unique path/name separates demo windows. Retain the host bundle ID because
  # the classifier XPC service authenticates it; preview flags isolate the vault.
  signing_identity="$(codesign -d --verbose=2 "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  [[ -n "$signing_identity" ]] || { echo "Named demos require a locally signed Debug build; use run-demo.sh without --instance for an ad-hoc build." >&2; exit 1; }
  token="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  destination="$repo_dir/.local/macos/Demos/$instance-$token"
  mkdir -p "$destination"
  demo_app="$destination/GroundKeeper Demo $instance.app"
  ditto "$app" "$demo_app"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$demo_app/Contents/Info.plist")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName GroundKeeper Demo $instance" "$demo_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string GroundKeeper Demo $instance" "$demo_app/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName GroundKeeper Demo $instance" "$demo_app/Contents/Info.plist"
  # Keep the sandbox and hardened runtime, but omit entitlements tied to the
  # original app ID. Sign with the build's identity so nested libraries retain
  # matching Team IDs; do not disable library validation for the demo.
  demo_entitlements="$destination/demo-entitlements.plist"
  codesign -d --entitlements :- "$app" > "$demo_entitlements" 2>/dev/null
  for entitlement in com.apple.application-identifier com.apple.developer.team-identifier keychain-access-groups; do
    /usr/libexec/PlistBuddy -c "Delete :$entitlement" "$demo_entitlements" 2>/dev/null || true
  done
  rm -f "$demo_app/Contents/embedded.provisionprofile"
  codesign --force --sign "$signing_identity" --entitlements "$demo_entitlements" --options runtime "$demo_app"
  codesign --verify --strict "$demo_app"
  app="$demo_app"
  echo "Demo bundle ID: $bundle_id"
fi
# Passing preview flags to an existing live-vault instance is unsafe: always -n.
open -n "$app" --args --setup-preview --ui-preview "$preview_mode"
echo "Demo app: $app"
