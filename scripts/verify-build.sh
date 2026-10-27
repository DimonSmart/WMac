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

  app=".build/products/$configuration/WMac.app"
  codesign --verify --deep --strict "$app"
  signature="$(codesign --display --verbose=4 "$app" 2>&1)"
  [[ "$signature" == *'runtime'* ]] || { echo "ERROR: $configuration Hardened Runtime is missing" >&2; exit 1; }
  entitlements="$(codesign --display --entitlements :- "$app" 2>/dev/null || true)"
  if [[ "$configuration" == Debug ]]; then
    [[ "$signature" != *'Signature=adhoc'* && "$signature" == *'Authority='* ]] || { echo 'ERROR: Debug must use a persistent code-signing identity' >&2; exit 1; }
    [[ "$entitlements" == *'com.apple.security.get-task-allow'* && "$entitlements" == *'<true/>'* ]] || { echo 'ERROR: Debug WMac must include get-task-allow for LLDB' >&2; exit 1; }
    echo 'PASS Debug signature: persistent identity, Hardened Runtime, get-task-allow=true'
  else
    [[ "$signature" == *'Signature=adhoc'* ]] || { echo 'ERROR: Release must retain its ad-hoc signature strategy' >&2; exit 1; }
    [[ "$entitlements" != *'com.apple.security.get-task-allow'* ]] || { echo 'ERROR: Release must not include get-task-allow' >&2; exit 1; }
    echo 'PASS Release signature: ad-hoc, Hardened Runtime, no get-task-allow'
  fi
done
