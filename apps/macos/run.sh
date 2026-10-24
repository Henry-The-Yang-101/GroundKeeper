#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/build.sh"
open "$script_dir/../../.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app"
