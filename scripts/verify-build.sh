#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for configuration in Debug Release; do
  for product in WMac WMacMultiFixture WMacSingleFixture WMacProbe; do
    binary=".build/products/$configuration/$product"
    if [[ "$product" != WMacProbe ]]; then binary="$binary.app/Contents/MacOS/$product"; fi
    architectures="$(lipo -archs "$binary")"
    [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]
    echo "PASS $configuration $product architectures=$architectures"
  done
  helper=".build/products/$configuration/WMac.app/Contents/Helpers/WMacDockWatchdog"
  [[ -x "$helper" ]]
  architectures="$(lipo -archs "$helper")"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]
  echo "PASS $configuration WMacDockWatchdog architectures=$architectures"
  plist=".build/products/$configuration/WMac.app/Contents/Info.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == '14.0' ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == 'app.wmac.WMac' ]]
  echo "PASS $configuration minimum OS=14.0 bundle=app.wmac.WMac"
done
