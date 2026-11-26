#!/usr/bin/env bash
# Removes BTranslate: the app, its Services menu item, its settings, its language pack and
# its saved API keys.
#   ./uninstall.sh              remove everything
#   ./uninstall.sh --keep-keys  leave the API keys in the Keychain
set -euo pipefail

APP="$HOME/Applications/BTranslate.app"
BUNDLE_ID=io.github.baakhoff.btranslate
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# In Russian where BTranslate itself was: the language chosen in its settings, or else the
# first of the Mac's languages that it comes in (English and Russian).
ru=""
for language in $( { defaults read "$BUNDLE_ID" AppleLanguages || true; defaults read -g AppleLanguages || true; } 2>/dev/null | tr -d ' ",()' ); do
    case "$language" in
        ru|ru-*|ru_*) ru=1; break ;;
        en|en-*|en_*) break ;;
    esac
done
t() { if [ -n "$ru" ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }  # t "English" "Русский"

pkill -x BTranslate 2>/dev/null || true
if [ -d "$APP" ]; then
    "$LSREGISTER" -u "$APP" 2>/dev/null || true
    rm -rf "$APP"
    t "Removed $APP" "Удалено: $APP"
fi
/System/Library/CoreServices/pbs -update
defaults delete "$BUNDLE_ID" 2>/dev/null && t "Removed the settings" "Настройки удалены" || true
SUPPORT="$HOME/Library/Application Support/BTranslate"
if [ -d "$SUPPORT" ]; then
    rm -rf "$SUPPORT"
    t "Removed the language pack" "Языковой пакет удален"
fi

if [ "${1:-}" != "--keep-keys" ]; then
    for provider in anthropic openai gemini deepseek openrouter custom; do
        security delete-generic-password -a "$provider" -s BTranslate >/dev/null 2>&1 \
            && t "Removed the $provider API key from the Keychain" "Ключ API ($provider) удален из Связки ключей" || true
    done
fi
t "BTranslate is uninstalled." "BTranslate удален."
