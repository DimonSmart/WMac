#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-Debug}"
xcodebuild -project WMac.xcodeproj -alltargets -configuration "$configuration" \
  SYMROOT="$PWD/.build/products" OBJROOT="$PWD/.build/objects" build
