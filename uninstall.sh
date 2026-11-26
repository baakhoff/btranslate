#!/usr/bin/env bash
# Removes BTranslate: the app, its Services menu item, its settings and its saved API keys.
#   ./uninstall.sh              remove everything
#   ./uninstall.sh --keep-keys  leave the API keys in the Keychain
set -euo pipefail

APP="$HOME/Applications/BTranslate.app"
BUNDLE_ID=io.github.baakhoff.btranslate
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

pkill -x BTranslate 2>/dev/null || true
if [ -d "$APP" ]; then
    "$LSREGISTER" -u "$APP" 2>/dev/null || true
    rm -rf "$APP"
    echo "Removed $APP"
fi
/System/Library/CoreServices/pbs -update
defaults delete "$BUNDLE_ID" 2>/dev/null && echo "Removed the settings" || true

if [ "${1:-}" != "--keep-keys" ]; then
    for provider in anthropic openai gemini deepseek openrouter custom; do
        security delete-generic-password -a "$provider" -s BTranslate >/dev/null 2>&1 \
            && echo "Removed the $provider API key from the Keychain" || true
    done
fi
echo "BTranslate is uninstalled."
