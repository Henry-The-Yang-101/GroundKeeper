#!/bin/bash
# Build a signed, self-contained app and a drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GK_SIGNING_IDENTITY:?Set GK_SIGNING_IDENTITY to a Developer ID Application identity}"
: "${GK_TEAM_ID:?Set GK_TEAM_ID to your Apple team ID}"
: "${GK_BUILD_NUMBER:?Set GK_BUILD_NUMBER to a positive build number}"
[[ "$GK_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build number' >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'An Apple silicon runner is required' >&2; exit 1; }

build_root="${GK_RELEASE_ROOT:-$PWD/.local/releases/build}"
mkdir -p "$build_root/assets"
build_root="$(cd "$build_root" && pwd)"
app="$build_root/DerivedData/Build/Products/Release/GroundKeeper.app"

.venv/bin/python -m scripts.prepare_classifier_runtime
xcodebuild -quiet -project apps/macos/GroundKeeper.xcodeproj -scheme GroundKeeper \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$build_root/DerivedData" \
  "GK_CODE_SIGN_IDENTITY=$GK_SIGNING_IDENTITY" GK_CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=$GK_SIGNING_IDENTITY" CODE_SIGN_STYLE=Manual \
  "DEVELOPMENT_TEAM=$GK_TEAM_ID" "CURRENT_PROJECT_VERSION=$GK_BUILD_NUMBER" \
  'OTHER_CODE_SIGN_FLAGS=--timestamp' build

codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2> "$build_root/signature.txt"
grep -F "Authority=Developer ID Application:" "$build_root/signature.txt" >/dev/null
grep -Fx "TeamIdentifier=$GK_TEAM_ID" "$build_root/signature.txt" >/dev/null
test -f "$app/Contents/XPCServices/GroundKeeperClassifier.xpc/Contents/Resources/Worker/groundkeeper/worker.py"
test -f "$app/Contents/XPCServices/GroundKeeperClassifier.xpc/Contents/Frameworks/libpython3.12.dylib"

# This Release smoke mode uses fictional data in a temporary ledger.
# The queue smoke entry point is compiled only in Debug builds.
.venv/bin/python - "$app/Contents/MacOS/GroundKeeper" <<'PY'
import subprocess, sys
subprocess.run([sys.argv[1], '--ledger-smoke'], check=True, timeout=180)
PY

mkdir "$build_root/image"
ditto "$app" "$build_root/image/GroundKeeper.app"
ln -s /Applications "$build_root/image/Applications"
cp docs/install.md "$build_root/image/INSTALL.md"
ditto shortcuts "$build_root/image/Shortcuts"
hdiutil create -quiet -volname GroundKeeper -srcfolder "$build_root/image" \
  -format UDZO -ov "$build_root/assets/GroundKeeper-arm64.dmg"
codesign --force --sign "$GK_SIGNING_IDENTITY" --timestamp "$build_root/assets/GroundKeeper-arm64.dmg"
echo "Built $build_root/assets/GroundKeeper-arm64.dmg"
