#!/usr/bin/env bash
# Builds build/BTranslate.app from Sources/ with the Swift compiler of the Command Line
# Tools (xcode-select --install). No Xcode project, no dependencies.
#
#   ./build.sh               for this Mac's processor
#   ./build.sh --universal   for Apple silicon and Intel in one app
# Env: BTRANSLATE_SIGN_IDENTITY: a code signing identity (default: ad hoc). The installer
#      gives this Mac's own, if tools/local-signing.sh has made one.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="$(cat VERSION)"
APP="build/BTranslate.app"
MIN_MACOS=14.0
# This Mac's processor, not this shell's: in a terminal that runs under Rosetta, uname says Intel.
archs=("$(uname -m)")
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && archs=(arm64)
[ "${1:-}" = "--universal" ] && archs=(arm64 x86_64)

# (/usr/bin/swiftc is there on every Mac, as a pointer to tools that may not be.)
xcrun --find swiftc >/dev/null 2>&1 || {
    echo "The Swift compiler is missing. Install the Command Line Tools: xcode-select --install" >&2
    exit 1
}

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
binaries=()
for arch in "${archs[@]}"; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" Sources/*.swift -o "build/BTranslate-$arch"
    binaries+=("build/BTranslate-$arch")
done
if [ "${#binaries[@]}" -gt 1 ]; then
    lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/BTranslate"
else
    cp "${binaries[0]}" "$APP/Contents/MacOS/BTranslate"
fi
rm -f "${binaries[@]}"

cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The languages BTranslate itself comes in: one Resources/<code>.lproj each. English is the
# text in the source, so en.lproj only says that English is there. (A mistake in a .strings
# file stops the build here.)
for lproj in Resources/*.lproj; do
    mkdir -p "$APP/Contents/Resources/$(basename "$lproj")"
    for strings in "$lproj"/*.strings; do
        plutil -convert binary1 -o "$APP/Contents/Resources/$(basename "$lproj")/$(basename "$strings")" "$strings"
    done
done
# Signed ad hoc, or with BTRANSLATE_SIGN_IDENTITY. If that identity can't be used (its key's
# use was not allowed, say), the app is signed ad hoc and the reason is said.
signed="ad hoc"
if [ -n "${BTRANSLATE_SIGN_IDENTITY:-}" ]; then
    if why="$(codesign --force --sign "$BTRANSLATE_SIGN_IDENTITY" "$APP" 2>&1)"; then
        signed="as $BTRANSLATE_SIGN_IDENTITY"
    else
        echo "Could not sign as \"$BTRANSLATE_SIGN_IDENTITY\" (${why##*: }). Signing ad hoc instead." >&2
    fi
fi
if [ "$signed" = "ad hoc" ]; then
    xattr -cr "$APP"  # what a synced folder hangs on files stops the signing
    codesign --force --sign - "$APP" 2>&1 | grep -v ': replacing existing signature$' >&2 || true
    codesign --verify "$APP" || { echo "The app could not be signed." >&2; exit 1; }
fi
echo "Built $APP ($VERSION, ${archs[*]}, signed $signed)"
