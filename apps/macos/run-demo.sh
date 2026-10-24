#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  "") [[ $# == 0 ]] || exit 2; "$script_dir/build.sh" ;;
  --no-build) [[ $# == 1 ]] || exit 2 ;;
  --help|-h) echo "Usage: $0 [--no-build]"; echo "Build and open a fresh fictional spending demo; --no-build reuses the Debug app."; exit 0 ;;
  *) echo "Usage: $0 [--no-build]" >&2; exit 2 ;;
esac
app="$script_dir/../../.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app"
[[ -x "$app/Contents/MacOS/GroundKeeper" ]] || { echo "Build the Debug app first: $script_dir/build.sh" >&2; exit 1; }
# A new instance is essential: passing flags to an existing live-vault instance is unsafe.
open -n "$app" --args --setup-preview --ui-preview --spending-preview
