#!/usr/bin/env bash
# Removes BTranslate and what it has put on this Mac: the app, its Services menu item, its
# login item, its settings, its language pack, its caches and log, its saved API keys, the
# permissions macOS has given it, and the signing certificate tools/local-signing.sh made.
#   ./uninstall.sh              remove everything
#   ./uninstall.sh --keep-keys  leave the API keys in the Keychain

# Everything is inside main(), so a download cut short by the network cannot run half a script.
main() {
    set -euo pipefail

    local APP="$HOME/Applications/BTranslate.app"
    local BUNDLE_ID=io.github.baakhoff.btranslate
    local LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

    # In Russian where BTranslate itself was: the language chosen in its settings, or else the
    # first of the Mac's languages that it comes in (English and Russian).
    local ru="" language
    for language in $( { defaults read "$BUNDLE_ID" AppleLanguages || true; defaults read -g AppleLanguages || true; } 2>/dev/null | tr -d ' ",()' ); do
        case "$language" in
            ru|ru-*|ru_*) ru=1; break ;;
            en|en-*|en_*) break ;;
        esac
    done
    t() { if [ -n "$ru" ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }  # t "English" "Русский"

    # Out of the login items first: macOS keeps those by the app, which has to be there to ask.
    if [ -x "$APP/Contents/MacOS/BTranslate" ]; then
        "$APP/Contents/MacOS/BTranslate" --login off >/dev/null 2>&1 || true
    fi
    pkill -x BTranslate 2>/dev/null || true
    if [ -d "$APP" ]; then
        "$LSREGISTER" -u "$APP" 2>/dev/null || true
        rm -rf "$APP"
        t "Removed $APP" "Удалено: $APP"
    else
        t "There is no $APP (if you moved the app, put that copy in the Trash yourself)." \
          "Нет $APP (если вы переместили приложение, удалите эту копию в Корзину сами)."
    fi
    /System/Library/CoreServices/pbs -update 2>/dev/null || true
    if defaults delete "$BUNDLE_ID" >/dev/null 2>&1; then t "Removed the settings" "Настройки удалены"; fi

    # The language pack (also a download of it that was not finished), what macOS prepared of
    # it for the Neural Engine (a gigabyte among the caches), and the shortcut's log.
    local left found=""
    for left in "$HOME/Library/Application Support/BTranslate" "$HOME/Library/Caches/$BUNDLE_ID" \
                "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" \
                "$HOME/Library/WebKit/$BUNDLE_ID" "$HOME/Library/Logs/BTranslate.log"; do
        if [ -e "$left" ]; then
            rm -rf "$left"
            found=1
        fi
    done
    if [ -n "$found" ]; then t "Removed the language pack, the caches and the log" "Языковой пакет, кэш и журнал удалены"; fi

    # What macOS allowed the shortcut (Accessibility, recording the screen): off its lists.
    tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true

    if security delete-identity -c "BTranslate (this Mac)" >/dev/null 2>&1; then
        t "Removed the signing certificate \"BTranslate (this Mac)\" from the Keychain" \
          "Сертификат «BTranslate (this Mac)» удален из Связки ключей"
    fi

    if [ "${1:-}" != "--keep-keys" ]; then
        local provider
        for provider in anthropic openai gemini deepseek openrouter custom; do
            if security delete-generic-password -a "$provider" -s BTranslate >/dev/null 2>&1; then
                t "Removed the $provider API key from the Keychain" "Ключ API ($provider) удален из Связки ключей"
            fi
        done
    fi
    t "BTranslate is uninstalled." "BTranslate удален."
}

main "$@"
