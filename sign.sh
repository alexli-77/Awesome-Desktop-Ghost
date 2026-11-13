#!/bin/bash
# sign.sh <app> — sign with a stable, self-signed identity.
#
# macOS ties the Screen Recording grant to the app's designated requirement.
# For an ad-hoc signature that is the code hash, which changes on every build,
# so each update loses the grant. Signed with the same certificate every time,
# the requirement stays `identifier "com.yangli.ghost" and certificate leaf =
# H"…"`, and the grant survives rebuilds.
#
# The first run creates the certificate in its own keychain
# (~/Library/Keychains/ghost-signing.keychain-db), whose random password is kept
# in the login keychain. The certificate doesn't need to be trusted: codesign
# accepts it as long as its keychain is in the search list, which this script
# arranges only for the duration of the signing.
set -euo pipefail
APP="$1"
NAME="Ghost Local Signing"
KC="$HOME/Library/Keychains/ghost-signing.keychain-db"
SVC="Ghost signing keychain"

make_identity() {
  local tmp p12pw kcpw
  tmp=$(mktemp -d)
  cat > "$tmp/c.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  # /usr/bin/openssl (LibreSSL): its PKCS#12 output is what `security import` reads.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/c.cnf" \
    -keyout "$tmp/k.pem" -out "$tmp/c.pem" 2>/dev/null
  p12pw=$(/usr/bin/openssl rand -hex 16)
  kcpw=$(/usr/bin/openssl rand -hex 24)
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/k.pem" -in "$tmp/c.pem" -name "$NAME" \
    -out "$tmp/s.p12" -passout "pass:$p12pw"
  security create-keychain -p "$kcpw" "$KC"
  security set-keychain-settings "$KC"                  # don't auto-lock
  security unlock-keychain -p "$kcpw" "$KC"
  security import "$tmp/s.p12" -k "$KC" -P "$p12pw" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$kcpw" "$KC" >/dev/null
  security add-generic-password -U -s "$SVC" -a "$USER" -w "$kcpw" -T /usr/bin/security
  rm -f "$tmp"/k.pem "$tmp"/c.pem "$tmp"/s.p12 "$tmp"/c.cnf   # the key now lives only in the keychain
  rmdir "$tmp"
  echo "Created signing identity \"$NAME\" in $KC"
}

[ -f "$KC" ] || make_identity
security unlock-keychain -p "$(security find-generic-password -s "$SVC" -a "$USER" -w)" "$KC"

# Put the keychain in the search list while signing, then restore the list.
ORIG=()
while IFS= read -r k; do
  k="${k#"${k%%[![:space:]]*}"}"; k="${k#\"}"; k="${k%\"}"
  [ -n "$k" ] && ORIG+=("$k")
done < <(security list-keychains -d user)
trap 'security list-keychains -d user -s "${ORIG[@]}"' EXIT
security list-keychains -d user -s "${ORIG[@]}" "$KC"

codesign --force --identifier com.yangli.ghost --sign "$NAME" "$APP"
