#!/usr/bin/env bash
# Builds build/BTranslate.app from Sources/ with the Swift compiler of the Command Line
# Tools (xcode-select --install). No Xcode project, no dependencies.
#
#   ./build.sh               for this Mac's processor
#   ./build.sh --universal   for Apple silicon and Intel in one app
# Env: BTRANSLATE_SIGN_IDENTITY: a code signing identity (default: ad hoc).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="$(cat VERSION)"
APP="build/BTranslate.app"
MIN_MACOS=14.0
archs=("$(uname -m)")
[ "${1:-}" = "--universal" ] && archs=(arm64 x86_64)

command -v swiftc >/dev/null || {
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
codesign --force --sign "${BTRANSLATE_SIGN_IDENTITY:--}" "$APP" 2>/dev/null
echo "Built $APP ($VERSION, ${archs[*]})"
