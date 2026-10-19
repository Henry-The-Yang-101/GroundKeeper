#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
derived_data="$repo_dir/.local/macos/DerivedData"

(cd "$repo_dir" && .venv/bin/python -m scripts.prepare_classifier_runtime)

build_args=(
  -quiet
  -project "$script_dir/GroundKeeper.xcodeproj"
  -scheme GroundKeeper
  -configuration Debug
  -destination "platform=macOS,arch=$(uname -m)"
  -derivedDataPath "$derived_data"
)
if [[ -f "$repo_dir/.local/macos/Signing.xcconfig" ]]; then
  build_args+=(-allowProvisioningUpdates GK_APP_ENTITLEMENTS=GroundKeeper.Keychain.entitlements)
fi
xcodebuild "${build_args[@]}" build

open "$derived_data/Build/Products/Debug/GroundKeeper.app"
