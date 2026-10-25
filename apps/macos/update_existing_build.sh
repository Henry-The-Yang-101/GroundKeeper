#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
app="$repo_dir/.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app"

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

# Finish building before interrupting the currently running app.
"$script_dir/build.sh"

echo "Restarting GroundKeeper with your existing vault…"
# Match the exact app path so other builds and isolated demos stay open.
# AppKit requests a normal quit, allowing the app to close its database cleanly.
/usr/bin/swift - "$app" <<'SWIFT'
import AppKit
import Foundation

let target = URL(fileURLWithPath: CommandLine.arguments.last!).standardizedFileURL
let applications = NSWorkspace.shared.runningApplications.filter {
    $0.bundleURL?.standardizedFileURL == target
}
for application in applications {
    guard application.terminate() else {
        fputs("GroundKeeper could not quit. Quit it with Command-Q, then run this script again.\n", stderr)
        exit(1)
    }
}
let deadline = Date().addingTimeInterval(60)
while applications.contains(where: { !$0.isTerminated }) {
    guard Date() < deadline else {
        fputs("GroundKeeper is still closing. Finish any open dialog and rerun this script.\n", stderr)
        exit(1)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
}
SWIFT

# No preview flags: use the normal bundle identity, preferences and saved vault.
open "$app"
echo "Opened the updated GroundKeeper build with your existing vault."
