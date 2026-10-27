#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh Debug
mkdir -p .build/tests
xcrun swiftc -swift-version 6 -o .build/tests/ModelTests Sources/Core/*.swift Tests/*.swift
.build/tests/ModelTests
probe="$PWD/.build/products/Debug/WMacProbe"
for argument in "$@"; do
  if [[ "$argument" == --require-ax ]]; then
    requirement="$(codesign -d -r - "$probe" 2>&1)"
    echo "AX trust is checked inside WMacProbe at $probe; its designated requirement is: $requirement"
    echo 'This is not WMac.app. Grant the entry shown by System Settings; if macOS attributes the command-line caller to Terminal or another host, grant that displayed entry. No permission is changed by this script.'
    break
  fi
done
if (( $# )); then
  "$probe" "$PWD/.build/products/Debug" "$@"
else
  "$probe" "$PWD/.build/products/Debug"
fi
