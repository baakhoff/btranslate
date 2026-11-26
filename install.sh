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
# Env: BTRANSLATE_PACK=yes|no downloads the language pack, or not, without asking. Asked
#        otherwise, when BTranslate is installed for the first time on a Mac with Apple
#        silicon and there is a terminal to ask in.
#      BTRANSLATE_REF=main installs the main branch instead of the release tag.
#      BTRANSLATE_ARCHIVE=<url> installs from another source archive (.tar.gz).
#      BTRANSLATE_SIGN_IDENTITY: a code signing identity for the app (default: this Mac's
#        own certificate if tools/local-signing.sh has made one, else ad hoc).
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
    # (BTRANSLATE_LANGUAGE=en|ru sets it, as it does for the app: the tests use that.)
    local ru="" language
    for language in ${BTRANSLATE_LANGUAGE:-} $( { defaults read "$BUNDLE_ID" AppleLanguages || true; defaults read -g AppleLanguages || true; } 2>/dev/null | tr -d ' ",()' ); do
        case "$language" in
            ru|ru-*|ru_*) ru=1; break ;;
            en|en-*|en_*) break ;;
        esac
    done
    t() { if [ -n "$ru" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }  # t "English" "Русский"
    die() { printf '%s: %s\n' "$(t "BTranslate installer" "Установщик BTranslate")" "$*" >&2; exit 1; }

    # The language pack (README, "The language pack"): BTranslate works properly without
    # internet only with it. An optional download all the same, so it is asked about, when
    # BTranslate is installed for the first time (`first`). Leaves in `hint` what to say at
    # the end if the pack is not there.
    language_pack() {
        local bin="$APP/Contents/MacOS/BTranslate" pack="${BTRANSLATE_PACK:-ask}" size=""
        if "$bin" --pack 2>/dev/null | grep -q "language pack: installed"; then
            pack=there
        else
            size="$("$bin" --pack 2>/dev/null | sed -n 's/^download: \([0-9]*\) MB$/\1/p')"
            size="${size:-906} $(t "MB" "МБ")"
        fi
        if [ "$pack" = ask ]; then
            pack=no
            if [ -n "$first" ] && [ "$(uname -m)" = arm64 ]; then
                say "$(t "The language pack (recommended)" "Языковой пакет (рекомендуется)")"
                if [ -n "$ru" ]; then
                    cat <<TEXT
Он нужен BTranslate, чтобы полноценно работать без интернета: добавляет около
140 языков, которые macOS не переводит офлайн (латышский, сербский и другие),
и сам определяет язык текста. Работает на Neural Engine. Загрузка: $size.
Только для некоммерческого использования (лицензия модели: CC-BY-NC 4.0).
TEXT
                else
                    cat <<TEXT
BTranslate needs it to work properly without internet: it adds about 140
languages that macOS can't translate offline (Latvian, Serbian and more) and
tells a text's language itself. It runs on the Neural Engine. Download: $size.
Non-commercial use only (the model's licence: CC-BY-NC 4.0).
TEXT
                fi
                # The question goes to the terminal: with "curl … | bash" the script itself is on
                # standard input. No terminal, no answer: then nothing is downloaded.
                local answer="" asked=""
                printf '%s ' "$(t "Download it now? [Y/n]" "Загрузить сейчас? [Y/n]")"
                if [ -t 0 ]; then
                    read -r answer && asked=1
                elif { read -r answer < /dev/tty; } 2>/dev/null; then
                    asked=1
                fi
                if [ -z "$asked" ]; then
                    printf '\n%s\n' "$(t "(No terminal to ask in: not downloaded.)" "(Спросить негде: не загружено.)")"
                else
                    case "$answer" in
                        n|N|no|No|NO|н|Н|нет|Нет|НЕТ) ;;
                        *) pack=yes ;;
                    esac
                fi
            fi
        fi
        if [ "$pack" = yes ]; then
            say "$(t "Downloading the language pack" "Загрузка языкового пакета") ($size)"
            local line
            "$bin" --pack-install 2>/dev/null | while IFS= read -r line; do
                case "$line" in
                    "downloading: "*) printf '\r    %s  ' "${line#downloading: }" ;;
                    "preparing"*) printf '\r%s\n' "$(t "macOS is preparing the pack for the Neural Engine (up to a minute)…" "macOS готовит пакет для Neural Engine (до минуты)…")" ;;
                    "language pack: installed") printf '%s\n' "$(t "The language pack is installed." "Языковой пакет установлен.")" ;;
                    "language pack: FAILED: "*) printf '\r%s\n' "${line#language pack: FAILED: }" ;;
                esac
            done || true
        fi
        if [ "$pack" != there ] && ! "$bin" --pack 2>/dev/null | grep -q "language pack: installed"; then
            hint="$(t "The language pack is not installed. To get it later: BTranslate's settings → Translation → Download ($size)." \
                      "Языковой пакет не установлен. Загрузить его позже: настройки BTranslate → «Перевод» → «Загрузить» ($size).")"
        fi
    }

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

    # For tests/run.sh: only the language pack's step, as on a first install, for the app at
    # BTRANSLATE_TEST_APP.
    if [ "${BTRANSLATE_INSTALLER_TEST:-}" = pack ]; then
        APP="$BTRANSLATE_TEST_APP"
        local first=1 hint=""
        language_pack
        if [ -n "$hint" ]; then printf '\n%s\n' "$hint"; fi
        return 0
    fi
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

    # With a certificate of this Mac's own (tools/local-signing.sh makes one), every build is
    # the same app to macOS, and the permission the shortcut needs outlasts an update.
    if [ -z "${BTRANSLATE_SIGN_IDENTITY:-}" ] \
        && security find-identity -p codesigning 2>/dev/null | grep -q '"BTranslate (this Mac)"'; then
        export BTRANSLATE_SIGN_IDENTITY="BTranslate (this Mac)"
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

    # macOS makes its reader of pictures ready for an app the first time the app reads one,
    # which takes some twenty seconds: have it done now, in the background, and not when
    # the first window is translated.
    ( "$APP/Contents/MacOS/BTranslate" --prepare-reading >/dev/null 2>&1 & )

    local first=1
    [ "$(defaults read "$BUNDLE_ID" setupDone 2>/dev/null || true)" = 1 ] && first=
    local hint=""
    language_pack

    if [ -n "$start" ]; then
        if [ -z "$first" ]; then
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

Сочетание клавиш ⌃⌥T в любом приложении: перевод выделенного текста; в текстовом
поле — панель, чтобы писать на другом языке; иначе — перевод окна целиком.
Ему нужно ваше разрешение: «Системные настройки» → «Конфиденциальность и
безопасность» → «Универсальный доступ» → BTranslate. После обновления BTranslate
уберите его из этого списка кнопкой «–» и добавьте снова (это не нужно, если
tools/local-signing.sh создал для этого Mac сертификат).
Сочетание работает, пока BTranslate запущен: в его настройках включено
открытие при входе в систему.

Настройки (способы перевода, провайдер ИИ, модель, ключ API, языки, сочетание
клавиш): откройте BTranslate через Spotlight или Finder либо нажмите на
шестеренку в окне перевода.
TEXT
    else
        cat <<'TEXT'
Select text in any app, right-click it and choose Services → BTranslate.
(An app that was already open may need a restart before the menu item shows.)

The shortcut ⌃⌥T in any app: selected text is translated; in a text field it opens
a panel to type in another language; otherwise it translates a whole window.
It needs your permission: System Settings → Privacy & Security → Accessibility →
BTranslate. After an update of BTranslate, take it off that list with "–" and add
it again (not needed once tools/local-signing.sh has made this Mac a certificate).
It works while BTranslate runs: its settings have it open when you log in.

Settings (methods, AI provider, model, API key, languages, the shortcut): open
BTranslate from Spotlight or Finder, or click the gear in the popup.
TEXT
    fi
    if [ -n "$hint" ]; then printf '\n%s\n' "$hint"; fi
}

main "$@"
