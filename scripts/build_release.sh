#!/bin/bash
# Build an ad hoc-signed, self-contained app and a drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

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
  GK_APP_ENTITLEMENTS=GroundKeeper.AdHoc.entitlements \
  GK_CLASSIFIER_RELEASE_ENTITLEMENTS=ClassifierService/ClassifierService.AdHoc.entitlements \
  GK_SEARCH_RELEASE_ENTITLEMENTS=MerchantSearchService/MerchantSearch.AdHoc.entitlements \
  GK_SEARCH_BUNDLE_IDENTIFIER=com.groundkeeper.macos.merchant-search.adhoc \
  GK_CODE_SIGN_IDENTITY=- GK_CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= "CURRENT_PROJECT_VERSION=$GK_BUILD_NUMBER" \
  'OTHER_CODE_SIGN_FLAGS=--timestamp=none' build

# Custom Info.plist keys are not emitted by Xcode's generated-plist settings.
# Seal the distribution capability marker into the final app before testing it.
.venv/bin/python - "$app/Contents/Info.plist" <<'PYINFO'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info['GKDistributionChannel'] = 'adhoc'
path.write_bytes(plistlib.dumps(info))
PYINFO
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements apps/macos/GroundKeeper.AdHoc.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2> "$build_root/signature.txt"
grep -Fx "Signature=adhoc" "$build_root/signature.txt" >/dev/null
grep -Fx "TeamIdentifier=not set" "$build_root/signature.txt" >/dev/null
test -f "$app/Contents/XPCServices/GroundKeeperClassifier.xpc/Contents/Resources/Worker/groundkeeper/worker.py"
test -f "$app/Contents/Frameworks/libpython3.12.dylib"
test -f "$app/Contents/XPCServices/GroundKeeperMerchantSearch.xpc/Contents/Resources/Worker/groundkeeper/merchant_search.py"

# Smoke checks use fictional data and verify the bundled XPC/Python connection.
.venv/bin/python - "$app/Contents/MacOS/GroundKeeper" <<'PY'
import subprocess, sys
for mode in ('--ledger-smoke', '--queue-smoke', '--classifier-connection-smoke'):
    subprocess.run([sys.argv[1], '--setup-preview', mode, "--adhoc-release-smoke"], check=True, timeout=180)
for mode in ('--setup-smoke', '--receipt-workspace-smoke'):
    subprocess.run([sys.argv[1], '--setup-preview', mode, '--adhoc-release-smoke'],
                   check=True, timeout=120)
PY

image_root="$(mktemp -d "$build_root/image.XXXXXX")"
trap 'rm -rf "$image_root"' EXIT
ditto "$app" "$image_root/GroundKeeper.app"
ln -s /Applications "$image_root/Applications"
cp docs/install.md "$image_root/INSTALL.md"
ditto shortcuts "$image_root/Shortcuts"
hdiutil create -quiet -volname GroundKeeper -srcfolder "$image_root" \
  -format UDZO -ov "$build_root/assets/GroundKeeper-arm64.dmg"
codesign --force --sign - --timestamp=none "$build_root/assets/GroundKeeper-arm64.dmg"
hdiutil verify "$build_root/assets/GroundKeeper-arm64.dmg"
echo "Built $build_root/assets/GroundKeeper-arm64.dmg"
