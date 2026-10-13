#!/bin/sh
# Optional, one time: creates a self-signed code-signing certificate in your login keychain.
# build-app.sh signs with it automatically. Without it the app is ad-hoc signed, and macOS
# forgets the Accessibility / Input Monitoring permissions every time you rebuild.
set -e
NAME="SingleKey Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists."
    exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:singlekey 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:singlekey
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P singlekey -T /usr/bin/codesign
echo "Created \"$NAME\". Run ./scripts/build-app.sh to build a signed app."
