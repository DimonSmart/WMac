#!/bin/bash
# Inspect the image itself, read-only. No Gatekeeper/notarization assessment.
set -euo pipefail
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $# == 3 ]] || fail 'Usage: verify-release-dmg.sh DMG VERSION BUILD'
dmg="$1"; version="$2"; build="$3"
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$dmg" ]] || fail 'Missing DMG'
hdiutil verify "$dmg"
mountpoint="$(mktemp -d "${TMPDIR:-/tmp/}wmac-image.XXXXXX")"
attached=0
cleanup() {
  if (( attached )); then
    hdiutil detach "$mountpoint" >/dev/null || hdiutil detach -force "$mountpoint" >/dev/null || return 1
  fi
  rmdir "$mountpoint"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Mark before attach so an interrupted/partially successful attach is cleaned too.
attached=1
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mountpoint"
[[ -L "$mountpoint/Applications" && "$(readlink "$mountpoint/Applications")" == /Applications ]] || fail 'Missing Applications drag-install link'
shopt -s dotglob nullglob
for entry in "$mountpoint"/*; do
  case "${entry##*/}" in
    WMac.app|Applications|.Trashes|.fseventsd) ;;
    *) fail "Unexpected image payload: ${entry##*/}" ;;
  esac
done
"$root/scripts/verify-release-app.sh" "$mountpoint/WMac.app" "$version" "$build"
hdiutil detach "$mountpoint"
attached=0
rmdir "$mountpoint"
trap - EXIT
echo 'PASS DMG: image integrity, read-only mounted payload and Applications link'
