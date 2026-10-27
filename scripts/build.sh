#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-Debug}"

fail() { echo "ERROR: $*" >&2; exit 1; }

if [[ "$configuration" == Debug ]]; then
  signing_config="$PWD/LocalSigning.xcconfig"
  [[ -f "$signing_config" ]] || fail 'Debug signing is not configured. Run ./scripts/setup-dev-signing.sh first.'

  identity_count="$(awk '/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=/ { count++ } END { print count+0 }' "$signing_config")"
  [[ "$identity_count" == 1 ]] || fail 'LocalSigning.xcconfig must contain exactly one CODE_SIGN_IDENTITY fingerprint.'
  identity="$(awk -F= '/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=/ { value=substr($0, index($0, "=")+1); sub(/[[:space:]]*#.*/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value }' "$signing_config")"
  [[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || fail 'CODE_SIGN_IDENTITY must be a 40-character certificate SHA-1 fingerprint.'

  identities="$(security find-identity -p codesigning)"
  if ! awk -v identity="$identity" '$2 == identity { found=1 } END { exit !found }' <<<"$identities"; then
    fail "Configured signing identity $identity is unavailable or invalid in the Keychain. Run ./scripts/setup-dev-signing.sh after checking the local config."
  fi

  xcodebuild -project WMac.xcodeproj -alltargets -configuration "$configuration" \
    SYMROOT="$PWD/.build/products" OBJROOT="$PWD/.build/objects" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" build

  app="$PWD/.build/products/Debug/WMac.app"
  codesign --verify --deep --strict "$app" || fail 'Debug app signature verification failed.'
  signature="$(codesign --display --verbose=4 "$app" 2>&1)"
  [[ "$signature" != *'Signature=adhoc'* && "$signature" == *'Authority='* ]] || fail 'Debug app did not use the configured persistent signing identity.'
  echo "PASS Debug signature identity=$identity"
elif [[ "$configuration" == Release ]]; then
  # Keep Release independent of LocalSigning.xcconfig and local development certificates.
  xcodebuild -project WMac.xcodeproj -alltargets -configuration "$configuration" \
    SYMROOT="$PWD/.build/products" OBJROOT="$PWD/.build/objects" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build
else
  xcodebuild -project WMac.xcodeproj -alltargets -configuration "$configuration" \
    SYMROOT="$PWD/.build/products" OBJROOT="$PWD/.build/objects" build
fi
