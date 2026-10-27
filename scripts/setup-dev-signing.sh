#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
config="$root/LocalSigning.xcconfig"
workdir=''
tmp_config=''

fail() { echo "ERROR: $*" >&2; exit 1; }
cleanup() {
  [[ -z "$tmp_config" ]] || rm -f "$tmp_config"
  [[ -z "$workdir" ]] || rm -rf "$workdir"
}
trap cleanup EXIT
for tool in security openssl awk; do
  command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"
done

identity_list() { security find-identity -p codesigning; }
identity_is_available() {
  awk -v identity="$1" '$2 == identity { found=1 } END { exit !found }'
}
configured_identity() {
  awk -F= '/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=/ { value=substr($0, index($0, "=")+1); sub(/[[:space:]]*#.*/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value }' "$1"
}

identities="$(identity_list)"
valid_identities="$(security find-identity -v -p codesigning)"
if [[ -f "$config" ]]; then
  count="$(awk '/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=/ { count++ } END { print count+0 }' "$config")"
  [[ "$count" == 1 ]] || fail 'Existing LocalSigning.xcconfig must contain exactly one CODE_SIGN_IDENTITY fingerprint; review it before changing it.'
  current="$(configured_identity "$config")"
  [[ "$current" =~ ^[[:xdigit:]]{40}$ ]] || fail 'Existing LocalSigning.xcconfig has an invalid certificate fingerprint; review it before changing it.'
  if identity_is_available "$current" <<<"$identities"; then
    echo "Reusing configured code-signing identity $current."
    exit 0
  fi
  fail "LocalSigning.xcconfig points to unavailable identity $current. Review/remove that ignored local file before running setup again."
fi

identity="$(awk '/"Apple Development: / { print $2; exit }' <<<"$valid_identities")"
identity_source='existing Apple Development certificate'

if [[ -z "$identity" ]]; then
  identity="$(awk '/"WMac Local Development Signing"/ { print $2; exit }' <<<"$identities")"
  if [[ -n "$identity" ]]; then
    identity_source='existing WMac local self-signed certificate'
  else
    keychain="$(security default-keychain -d user | sed -e 's/^[[:space:]]*//' -e 's/^"//' -e 's/"$//')"
    [[ -n "$keychain" ]] || fail 'Could not resolve the default user Keychain.'
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/wmac-dev-signing.XXXXXX")"
    chmod 700 "$workdir"

    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
      -keyout "$workdir/private-key.pem" -out "$workdir/certificate.pem" \
      -subj '/CN=WMac Local Development Signing' \
      -addext 'basicConstraints=critical,CA:FALSE' \
      -addext 'keyUsage=critical,digitalSignature' \
      -addext 'extendedKeyUsage=codeSigning' >/dev/null 2>&1 \
      || fail 'OpenSSL could not create the temporary local code-signing certificate.'
    p12_password="$(openssl rand -hex 32)" || fail 'OpenSSL could not create a temporary import password.'
    openssl pkcs12 -export -legacy -inkey "$workdir/private-key.pem" \
      -in "$workdir/certificate.pem" -out "$workdir/identity.p12" \
      -name 'WMac Local Development Signing' -passout "pass:$p12_password" \
      || fail 'OpenSSL could not prepare the temporary Keychain import.'
    chmod 600 "$workdir/private-key.pem" "$workdir/certificate.pem" "$workdir/identity.p12"

    # Import directly into the user's default Keychain. The private key is
    # marked non-extractable and only /usr/bin/codesign may access it. The
    # temporary import password is random, never saved, and not printed.
    security import "$workdir/identity.p12" -k "$keychain" -P "$p12_password" -x -T /usr/bin/codesign \
      || fail 'Could not import the self-signed identity into the default Keychain.'
    unset p12_password
    identities="$(identity_list)"
    identity="$(awk '/"WMac Local Development Signing"/ { print $2; exit }' <<<"$identities")"
    [[ -n "$identity" ]] || fail 'The imported certificate is not a valid codesigning identity. LocalSigning.xcconfig was not created; inspect Keychain Access.'
    identity_source='new WMac local self-signed certificate in the default Keychain'
  fi
fi

[[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || fail 'The selected code-signing identity did not provide a valid SHA-1 fingerprint.'
if ! identity_is_available "$identity" <<<"$identities"; then
  fail 'The selected identity is not present in the default Keychain.'
fi

tmp_config="$(mktemp "$root/.LocalSigning.xcconfig.XXXXXX")"
chmod 600 "$tmp_config"
cat >"$tmp_config" <<EOF
// Generated locally by scripts/setup-dev-signing.sh; this file is git-ignored.
CODE_SIGN_IDENTITY = $identity
EOF
mv "$tmp_config" "$config"
tmp_config=''
echo "Configured Debug signing with $identity_source."
echo "Certificate SHA-1: $identity"
echo "Private key remains in the default user Keychain; no key or certificate file is retained in the repository."
