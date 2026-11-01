#!/bin/bash
# Install the official stable release, retaining a previous copy for recovery.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $# == 0 ]] || fail 'Usage: ./scripts/install.sh (installs into ~/Applications/WMac.app)'
work="$(mktemp -d "${TMPDIR:-/tmp/}wmac-install.XXXXXX")"
mounted=0
cleanup() {
  if (( mounted )); then
    if ! hdiutil detach "$work/mount" >/dev/null; then
      echo "Could not detach image; retained temporary directory: $work" >&2
      return
    fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT
curl --fail --location --silent --show-error --connect-timeout 20 --max-time 300 --proto '=https' \
  https://api.github.com/repos/DimonSmart/WMac/releases/latest -o "$work/release.json"
python3 - "$work/release.json" > "$work/package" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1]))
version = release.get('tag_name', '').removeprefix('v')
assert re.fullmatch(r'\d+\.\d+(?:\.\d+)?', version), 'Invalid release tag'
assert not release.get('draft') and not release.get('prerelease'), 'Not a stable release'
assets = [a for a in release['assets'] if a['name'].startswith('WMac-') and a['name'].endswith('.dmg')]
assert len(assets) == 1, 'Expected exactly one WMac DMG'
a = assets[0]
m = re.fullmatch(r'WMac-' + re.escape(version) + r'-([1-9]\d*)\.dmg', a['name'])
assert m, 'Unexpected package name'
assert re.fullmatch(r'sha256:[0-9a-f]{64}', a.get('digest') or ''), 'Missing GitHub SHA-256'
assert a['browser_download_url'] == f"https://github.com/DimonSmart/WMac/releases/download/{release['tag_name']}/{a['name']}", 'Unexpected asset URL'
print(a['browser_download_url']); print(a['digest'][7:]); print(version); print(m[1])
PY
{ read -r url; read -r digest; read -r version; read -r build; } < "$work/package"
echo "Downloading official WMac $version ($build)…"
curl --fail --location --silent --show-error --connect-timeout 20 --max-time 300 --proto '=https' --proto-redir '=https' "$url" -o "$work/WMac.dmg"
actual="$(shasum -a 256 "$work/WMac.dmg")"
[[ "${actual%% *}" == "$digest" ]] || fail 'DMG checksum mismatch'
"$root/scripts/verify-release-dmg.sh" "$work/WMac.dmg" "$version" "$build"
mkdir "$work/mount"
hdiutil attach "$work/WMac.dmg" -readonly -nobrowse -mountpoint "$work/mount" >/dev/null
mounted=1
mkdir -p "$HOME/Applications"
destination="$HOME/Applications/WMac.app"
[[ ! -L "$destination" ]] || fail 'Destination must not be a symlink'
stage="$(mktemp -d "$HOME/Applications/.WMacInstall.XXXXXX")"
if ! ditto "$work/mount/WMac.app" "$stage/WMac.app"; then rm -rf "$stage"; fail 'Copy failed'; fi
if ! "$root/scripts/verify-release-app.sh" "$stage/WMac.app" "$version" "$build"; then
  rm -rf "$stage"; fail 'Copied app failed verification'
fi
if ! "$root/scripts/run.sh" --stop; then rm -rf "$stage"; fail 'Previous WMac is still running'; fi
backup=''
if [[ -e "$destination" ]]; then
  backup="$(mktemp -d "$HOME/Applications/.WMacPrevious.XXXXXX")"
  mv "$destination" "$backup/WMac.app"
fi
if ! mv "$stage/WMac.app" "$destination"; then
  if [[ -n "$backup" ]]; then mv "$backup/WMac.app" "$destination"; fi
  rm -rf "$stage"; fail 'Installation failed; previous copy restored'
fi
rmdir "$stage"
echo "Installed: $destination"
if [[ -n "$backup" ]]; then echo "Previous copy: $backup/WMac.app"; fi
"$root/scripts/run.sh" release
