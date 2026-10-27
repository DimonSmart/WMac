#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh Debug
mkdir -p .build/tests
xcrun swiftc -swift-version 6 -o .build/tests/ModelTests Sources/Core/*.swift Tests/*.swift
.build/tests/ModelTests
if (( $# )); then
  .build/products/Debug/WMacProbe "$PWD/.build/products/Debug" "$@"
else
  .build/products/Debug/WMacProbe "$PWD/.build/products/Debug"
fi
