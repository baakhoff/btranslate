#!/usr/bin/env bash
# A signing certificate of this Mac's own for BTranslate, so that macOS takes every build of
# the app for the same app.
#
# Why: the shortcut needs macOS's Accessibility permission. BTranslate has no developer
# signature, and macOS ties a permission to the exact build of such an app: after every
# update the permission has to be given again. Signed with one certificate, all builds are
# one app to macOS, and the permission stays.
#
#   tools/local-signing.sh            make the certificate "BTranslate (this Mac)" in your
#                                     login keychain (nothing is sent anywhere; no sudo)
#   tools/local-signing.sh --remove   take it out of the keychain again
#
# build.sh, and so install.sh, sign with it when it is there. The first time, macOS asks for
# your Mac's password to let codesign use the certificate's key: "Allow" asks again at every
# build, "Always Allow" never again.
#
# What it means: whoever can use this certificate can make a program that macOS takes for
# BTranslate, with BTranslate's permissions. Its key never leaves your keychain; with "Always
# Allow", any program of yours that runs codesign can sign with it.
set -euo pipefail

NAME="BTranslate (this Mac)"
keychain="$(security default-keychain -d user | sed -e 's/^ *"//' -e 's/"$//')"

if [ "${1:-}" = "--remove" ]; then
    if security delete-identity -c "$NAME" "$keychain" >/dev/null 2>&1; then
        echo "Removed the certificate \"$NAME\". Builds are signed ad hoc again."
    else
        echo "There is no certificate \"$NAME\" in $keychain."
    fi
    exit 0
fi

if security find-identity -p codesigning "$keychain" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "The certificate \"$NAME\" is there already."
    exit 0
fi

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/request.cnf" <<CNF
[req]
distinguished_name = name
x509_extensions = uses
prompt = no
[name]
CN = $NAME
[uses]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
# A key and a certificate that signs code and nothing else, good for ten years.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/request.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/certificate.pem" 2>/dev/null
# Into the keychain by way of a file locked with a password made up for this once. (The key
# is called in the keychain what the file is called: macOS asks about it by that name.)
pass="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/certificate.pem" -name "$NAME" \
    -out "$tmp/$NAME.p12" -passout "pass:$pass"
security import "$tmp/$NAME.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning "$keychain" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "Made the certificate \"$NAME\" in $keychain."
    echo "The next build is signed with it: macOS will ask for your password, once or every time (see above)."
else
    echo "The certificate did not get into the keychain." >&2
    exit 1
fi
