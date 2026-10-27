#!/bin/bash
# Offline preparation for GitHub Releases. Successful evidence is written last.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
fail() { echo "ERROR: $*" >&2; exit 1; }
usage() { echo 'Usage: ./scripts/release.sh [VERSION BUILD] (defaults: 0.1.0 1)'; }
if [[ $# == 1 && "$1" == --help ]]; then usage; exit 0; fi
[[ $# == 0 || $# == 2 ]] || { usage >&2; exit 2; }
version="${1:-0.1.0}"; build="${2:-1}"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail 'VERSION must be numeric major.minor[.patch]'
[[ "$build" =~ ^[1-9][0-9]*$ ]] || fail 'BUILD must be a positive integer'
for tool in xcodebuild codesign hdiutil ditto lipo shasum; do
  command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"
done
xcrun --find vtool >/dev/null
mkdir -p "$root/.build/distribution"
output="$(mktemp -d "$root/.build/distribution/release-$version-$build.XXXXXX")"
echo "Preparation directory: $output"
# Build only the shipping target; no prior development products are reused.
xcodebuild -project WMac.xcodeproj -target WMac -configuration Release \
  SYMROOT="$output/products" OBJROOT="$output/objects" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" build >"$output/build.log" 2>&1 || fail "Build failed; see $output/build.log"
mkdir "$output/stage"
app="$output/stage/WMac.app"
ditto "$output/products/Release/WMac.app" "$app"
helper="$app/Contents/Helpers/WMacDockWatchdog"
[[ -x "$helper" ]] || fail 'Dock watchdog helper not embedded'
codesign --force --sign - --options runtime --timestamp=none "$helper"
codesign --force --sign - --options runtime --timestamp=none "$app"
"$root/scripts/verify-release-app.sh" "$app" "$version" "$build" >"$output/app-verification.log" 2>&1 || fail "App verification failed; see $output/app-verification.log"
ln -s /Applications "$output/stage/Applications"
pending="$output/WMac-$version-$build.unverified.dmg"
dmg="$output/WMac-$version-$build.dmg"
hdiutil create -srcfolder "$output/stage" -volname 'WMac!' -format UDZO "$pending" >"$output/image-build.log" 2>&1 || fail "Image creation failed; see $output/image-build.log"
"$root/scripts/verify-release-dmg.sh" "$pending" "$version" "$build" >"$output/image-verification.log" 2>&1 || fail "Image verification failed; see $output/image-verification.log"
mv "$pending" "$dmg"
(cd "$output" && shasum -a 256 "${dmg##*/}" > SHA256.txt)
echo 'Automated local checks passed. Ad-hoc signed with Hardened Runtime. No trusted developer identity, notarization or Gatekeeper approval is claimed. Downloaded first-launch and hardware acceptance remain manual.' >"$output/AUTOMATED-CHECKS-PASSED.txt"
echo "DMG: $dmg"
echo "Checksum and logs: $output"
