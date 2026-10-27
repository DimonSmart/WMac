#!/bin/bash
# Read-only verification; never modifies signatures, trust or quarantine.
set -euo pipefail
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $# == 3 ]] || fail 'Usage: verify-release-app.sh APP VERSION BUILD'
app="$1"; version="$2"; build="$3"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$build" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid expected version/build'
[[ -d "$app" && ! -L "$app" ]] || fail 'Missing application directory'
plist="$app/Contents/Info.plist"
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
[[ "$(value CFBundleIdentifier)" == app.wmac.WMac ]] || fail 'Unexpected bundle identity'
[[ "$(value CFBundleDisplayName)" == 'WMac!' ]] || fail 'Unexpected display name'
[[ "$(value CFBundleIconFile)" == 'AppIcon' && -s "$app/Contents/Resources/AppIcon.icns" ]] || fail 'App icon is missing'
[[ "$(value LSMinimumSystemVersion)" == 14.0 ]] || fail 'Unexpected minimum OS'
[[ "$(value CFBundleExecutable)" == WMac && "$(value CFBundlePackageType)" == APPL ]] || fail 'Unexpected application type/executable'
[[ "$(value CFBundleShortVersionString)" == "$version" && "$(value CFBundleVersion)" == "$build" ]] || fail 'Unexpected version/build'
for language in en ru; do
  localized="$app/Contents/Resources/$language.lproj/InfoPlist.strings"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$localized")" == 'WMac!' ]] || fail "Missing $language display name"
done
binary="$app/Contents/MacOS/WMac"
architectures="$(lipo -archs "$binary")"
[[ "$architectures" == 'x86_64 arm64' || "$architectures" == 'arm64 x86_64' ]] || fail 'Exactly arm64 and x86_64 required'
for architecture in arm64 x86_64; do
  xcrun vtool -arch "$architecture" -show-build "$binary" | awk '
    $1 == "platform" { platform = ($2 == "MACOS") }
    $1 == "minos" { found = 1; if ($2 != "14.0") bad = 1 }
    END { if (!found || bad || !platform) exit 1 }' || fail "Unexpected $architecture deployment metadata"
done
helper="$app/Contents/Helpers/WMacDockWatchdog"
[[ -f "$helper" && -x "$helper" && ! -L "$helper" ]] || fail 'Dock helper missing or not executable'
helper_architectures="$(lipo -archs "$helper")"
[[ "$helper_architectures" == 'x86_64 arm64' || "$helper_architectures" == 'arm64 x86_64' ]] || fail 'Dock helper must be universal'
for architecture in arm64 x86_64; do
  xcrun vtool -arch "$architecture" -show-build "$helper" | awk '
    $1 == "platform" { platform = ($2 == "MACOS") }
    $1 == "minos" { found = 1; if ($2 != "14.0") bad = 1 }
    END { if (!found || bad || !platform) exit 1 }' || fail "Unexpected helper $architecture deployment metadata"
  helper_signature="$(codesign -d --arch "$architecture" --verbose=4 "$helper" 2>&1)"
  [[ "$helper_signature" =~ flags=.*[\(,]runtime[\),] ]] || fail "Dock helper $architecture Hardened Runtime required"
done
codesign --verify --strict --verbose=2 "$helper"
codesign --verify --deep --strict --verbose=2 "$app"
for architecture in arm64 x86_64; do
  signature="$(codesign -d --arch "$architecture" --verbose=4 "$app" 2>&1)"
  [[ "$signature" =~ flags=.*[\(,]runtime[\),] ]] || fail "$architecture Hardened Runtime required"
  [[ "$signature" == *'Signature=adhoc'* ]] || fail "$architecture expected local ad-hoc signature"
  entitlements="$(codesign -d --arch "$architecture" --entitlements :- "$app" 2>/dev/null)"
  [[ "$entitlements" != *'get-task-allow'* ]] || fail "$architecture debug entitlement must be absent"
done
echo "PASS app: universal, macOS 14.0, stable identity, RU/EN name, version $version ($build), ad-hoc signature with Hardened Runtime; no debug entitlement"
