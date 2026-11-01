#!/bin/bash
# Select a precise app path and gracefully retire any previous WMac process.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-debug}"
case "$mode" in
  debug) ./scripts/build.sh Debug; app="$PWD/.build/products/Debug/WMac.app" ;;
  release) app="${WMAC_INSTALLED_APP:-$HOME/Applications/WMac.app}" ;;
  --stop) app='' ;;
  *) echo 'Usage: ./scripts/run.sh [debug|release]' >&2; exit 2 ;;
esac
if [[ "$mode" != --stop && ! -d "$app" ]]; then
  echo "Application not found: $app. Run ./scripts/install.sh for the official release." >&2
  exit 1
fi
# NSApplication termination runs WMac's save and Dock restoration hooks.
xcrun swift -e '
import AppKit
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "app.wmac.WMac")
for app in apps { app.terminate() }
let deadline = Date().addingTimeInterval(30)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
if apps.contains(where: { !$0.isTerminated }) {
    fputs("WMac did not quit. Close it normally and retry.\n", stderr)
    exit(1)
}
'
if [[ "$mode" != --stop ]]; then
  echo "Launching: $app"
  open -n "$app"
fi
