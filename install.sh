#!/usr/bin/env bash
# BTranslate installer for macOS 14 or later (Apple silicon and Intel).
#
# One line (downloads the release and builds it on your Mac; no sudo):
#   curl -fsSL https://raw.githubusercontent.com/baakhoff/btranslate/main/install.sh | bash
# From a checkout:
#   ./install.sh [options]
#
# Options:
#   --no-start   do not start BTranslate (and its setup window) at the end
#   --version    print the version this installer installs
# Env: BTRANSLATE_REF=main installs the main branch instead of the release tag.
#      BTRANSLATE_ARCHIVE=<url> installs from another source archive (.tar.gz).
#      BTRANSLATE_SIGN_IDENTITY: a code signing identity for the app (default: ad hoc).
#
# Needs the Command Line Tools for the Swift compiler: xcode-select --install
# Speaks Russian on a Mac whose first language (of English and Russian) is Russian.
# Installs ~/Applications/BTranslate.app and nothing else. Your settings stay in
# ~/Library/Preferences/io.github.baakhoff.btranslate.plist and your API key in the Keychain.
# Undo: uninstall.sh.

# Everything is inside main(), so a download cut short by the network cannot run half
# a script.
main() {
    set -euo pipefail

    local VERSION=1.0.0
    local REPO=baakhoff/btranslate
    local APP="$HOME/Applications/BTranslate.app"
    local BUNDLE_ID=io.github.baakhoff.btranslate

    if [ -t 1 ]; then
        say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
    else
        say() { printf '\n==> %s\n' "$*"; }
    fi
    # In Russian where BTranslate itself would be: the language chosen in its settings, or
    # else the first of the Mac's languages that it comes in (English and Russian).
    local ru="" language
    for language in $( { defaults read "$BUNDLE_ID" AppleLanguages || true; defaults read -g AppleLanguages || true; } 2>/dev/null | tr -d ' ",()' ); do
        case "$language" in
            ru|ru-*|ru_*) ru=1; break ;;
            en|en-*|en_*) break ;;
        esac
    done
    t() { if [ -n "$ru" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }  # t "English" "Русский"
    die() { printf '%s: %s\n' "$(t "BTranslate installer" "Установщик BTranslate")" "$*" >&2; exit 1; }

    local start=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-start) start= ;;
            --version) echo "BTranslate installer $VERSION"; return 0 ;;
            -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; return 0 ;;
            *) die "$(t "unknown option: $1 (see --help)" "неизвестный параметр: $1 (см. --help)")" ;;
        esac
        shift
    done

    [ "$(uname -s)" = Darwin ] || die "BTranslate is a macOS app."
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$major" -ge 14 ] || die "$(t "macOS 14 or later is needed (this Mac has $(sw_vers -productVersion))." \
                                     "нужна macOS 14 или новее (на этом Mac — $(sw_vers -productVersion)).")"
    xcrun --find swiftc >/dev/null 2>&1 \
        || die "$(t "the Swift compiler is missing. Install the Command Line Tools with: xcode-select --install   then run this again." \
                    "нет компилятора Swift. Установите Command Line Tools командой: xcode-select --install   и запустите установку снова.")"

    # The source: this checkout, or the release downloaded to a temporary folder.
    local src="" tmp=""
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/Sources/main.swift" ]; then
        src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    else
        local ref="refs/tags/v$VERSION"
        [ -n "${BTRANSLATE_REF:-}" ] && ref="refs/heads/$BTRANSLATE_REF"
        local archive="${BTRANSLATE_ARCHIVE:-https://github.com/$REPO/archive/$ref.tar.gz}"
        say "$(t "Downloading" "Загрузка") BTranslate ${BTRANSLATE_REF:-$VERSION}"
        tmp="$(mktemp -d)"
        # shellcheck disable=SC2064  # expand $tmp now: it is a local, gone when the trap runs
        trap "rm -rf '$tmp'" EXIT
        curl -fsSL "$archive" | tar -xz -C "$tmp" --strip-components 1 \
            || die "$(t "could not download $archive" "не удалось загрузить $archive")"
        [ -f "$tmp/Sources/main.swift" ] \
            || die "$(t "$archive is not a BTranslate source archive." "$archive — не архив с исходным кодом BTranslate.")"
        src="$tmp"
    fi

    say "$(t "Building" "Сборка") BTranslate $(cat "$src/VERSION")"
    bash "$src/build.sh"

    say "$(t "Installing" "Установка в") $APP"
    pkill -x BTranslate 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$APP"
    ditto "$src/build/BTranslate.app" "$APP"
    # Tell macOS about the app and its Services menu item.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
    /System/Library/CoreServices/pbs -update

    if [ -n "$start" ]; then
        if [ "$(defaults read "$BUNDLE_ID" setupDone 2>/dev/null || true)" = 1 ]; then
            open -g "$APP" --args --background   # an update: keep the settings, no window
        else
            open "$APP"                          # first install: the setup window
        fi
    fi

    say "BTranslate $(cat "$src/VERSION") $(t "is installed" "установлен")"
    if [ -n "$ru" ]; then
        cat <<'TEXT'
Выделите текст в любом приложении, нажмите на него правой кнопкой мыши и
выберите «Службы» → «BTranslate».
(Приложение, которое уже было открыто, возможно, придется перезапустить, чтобы
в нем появился этот пункт меню.)

Настройки (способы перевода, провайдер ИИ, модель, ключ API, языки): откройте
BTranslate через Spotlight или Finder либо нажмите на шестеренку в окне перевода.
Сочетание клавиш: «Системные настройки» → «Клавиатура» → «Сочетания клавиш…»
→ «Службы» → «Текст» → «BTranslate».
TEXT
    else
        cat <<'TEXT'
Select text in any app, right-click it and choose Services → BTranslate.
(An app that was already open may need a restart before the menu item shows.)

Settings (methods, AI provider, model, API key, languages): open BTranslate from
Spotlight or Finder, or click the gear in the popup.
Keyboard shortcut: System Settings → Keyboard → Keyboard Shortcuts… → Services
→ Text → BTranslate.
TEXT
    fi
}

main "$@"
