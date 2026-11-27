#!/usr/bin/env bash
# BTranslate installer for macOS 14 or later (Apple silicon and Intel).
#
# One line (downloads the release and builds it on your Mac; no sudo):
#   curl -fsSL https://raw.githubusercontent.com/baakhoff/btranslate/main/install.sh | bash
# From a checkout:
#   ./install.sh [options]
#
# Options:
#   --no-start   do not start BTranslate (and its settings window) at the end
#   --version    print the version this installer installs
# Env: BTRANSLATE_PACK=yes|no downloads the language pack, or not, without asking. Asked
#        otherwise, when BTranslate is installed for the first time on a Mac with Apple
#        silicon and there is a terminal to ask in.
#      BTRANSLATE_AUTOUPDATE=yes|no turns BTranslate's automatic updates on or off without
#        asking. Asked otherwise, once, when that setting has never been set and there is a
#        terminal to ask in. keep: neither asked nor changed (BTranslate's own Update says so).
#      BTRANSLATE_REF=main installs the main branch instead of the release tag.
#      BTRANSLATE_ARCHIVE=<url> installs from another source archive (.tar.gz).
#      BTRANSLATE_SIGN_IDENTITY: a code signing identity for the app (default: this Mac's
#        own certificate if tools/local-signing.sh has made one, else ad hoc).
#
# Needs the Command Line Tools for the Swift compiler: xcode-select --install
# Speaks Russian on a Mac whose first language (of English and Russian) is Russian.
# Installs ~/Applications/BTranslate.app, tells macOS about its Services menu item and starts
# it; the language pack, if you want it, goes to ~/Library/Application Support/BTranslate.
# Your settings stay in ~/Library/Preferences/io.github.baakhoff.btranslate.plist and your
# API key in the Keychain. Undo: uninstall.sh.

# Everything is inside main(), so a download cut short by the network cannot run half
# a script.
main() {
    set -euo pipefail

    local VERSION=1.1.0
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
        local bin="$APP/Contents/MacOS/BTranslate" pack="" size=""
        case "$(printf '%s' "${BTRANSLATE_PACK:-ask}" | tr '[:upper:]' '[:lower:]')" in
            ask) pack=ask ;;
            yes|y|1|true|on) pack=yes ;;
            no|n|0|false|off) pack=no ;;
            *) die "$(t "BTRANSLATE_PACK is \"$BTRANSLATE_PACK\": say yes or no." "BTRANSLATE_PACK=\"$BTRANSLATE_PACK\": укажите yes или no.")" ;;
        esac
        if "$bin" --pack 2>/dev/null | grep -q "language pack: installed"; then
            pack=there
        else
            size="$("$bin" --pack 2>/dev/null | sed -n 's/^download: \([0-9]*\) MB$/\1/p')"
            size="${size:-906} $(t "MB" "МБ")"
        fi
        if [ "$pack" = ask ]; then
            pack=no
            if [ -n "$first" ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then  # (not uname: it says Intel in a Rosetta terminal)
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
                # A key answers by what is printed on it, whichever layout is on: in the Russian
                # layout the Y key types "н" and the N key "т"; in a Latin one the Д key types "l".
                local answer="" asked="" tries=0
                while [ -z "$asked" ] && [ "$tries" -lt 3 ]; do
                    tries=$((tries + 1))
                    printf '%s ' "$(t "Download it now? [Y/n]" "Загрузить сейчас? [Д/н]")"
                    if [ -t 0 ]; then
                        read -r answer || break
                    elif ! { read -r answer < /dev/tty; } 2>/dev/null; then
                        break
                    fi
                    case "$answer" in
                        ""|y|Y|yes|Yes|YES|д|Д|да|Да|ДА) pack=yes; asked=1 ;;
                        n|N|no|No|NO|нет|Нет|НЕТ|т|Т) asked=1 ;;
                        н|Н) asked=1; [ -n "$ru" ] || pack=yes ;;
                        l|L) if [ -n "$ru" ]; then pack=yes; asked=1; fi ;;
                    esac
                done
                if [ -z "$asked" ]; then
                    printf '\n%s\n' "$(t "(No answer: not downloaded.)" "(Ответа нет: не загружено.)")"
                fi
            fi
        fi
        if [ "$pack" = yes ]; then
            say "$(t "Downloading the language pack" "Загрузка языкового пакета") ($size)"
            # Ctrl-C stops the download, not the installer: what has arrived is kept, and the
            # download goes on from there when it is started again in BTranslate's settings.
            trap 'printf "\n"' INT
            local line
            "$bin" --pack-install 2>/dev/null | while IFS= read -r line; do
                case "$line" in
                    "downloading: "*) printf '\r    %s  ' "${line#downloading: }" ;;
                    "preparing"*) printf '\r%s\n' "$(t "macOS is preparing the pack for the Neural Engine (up to a minute)…" "macOS готовит пакет для Neural Engine (до минуты)…")" ;;
                    "language pack: installed") printf '%s\n' "$(t "The language pack is installed." "Языковой пакет установлен.")" ;;
                    "language pack: FAILED: "*) printf '\r%s\n' "${line#language pack: FAILED: }" ;;
                esac
            done || true
            trap - INT
        fi
        if [ "$pack" != there ] && ! "$bin" --pack 2>/dev/null | grep -q "language pack: installed"; then
            hint="$(t "The language pack is not installed. To get it later: BTranslate's settings → Translation → Download ($size)." \
                      "Языковой пакет не установлен. Загрузить его позже: настройки BTranslate → «Перевод» → «Загрузить» ($size).")"
        fi
    }

    # Updates that install themselves (README, "Updates"): BTranslate looks for a newer version
    # once a day, and with this on runs this installer by itself. Asked once: when the setting
    # has never been set (a first install, or the first update to a version that has updates)
    # and there is a terminal to ask on. Its default is yes only where this Mac signs
    # BTranslate with its own certificate: elsewhere every update takes the shortcut's
    # permissions away, which nobody should get by surprise.
    # It is asked before the download and the build, and the answer is stored only once the new
    # app is in place: an installer stopped at the question (Ctrl-C) has then changed nothing,
    # and has not ended the BTranslate that runs.
    # The test seam (BTRANSLATE_INSTALLER_TEST=autoupdate) reads the answer from standard
    # input, stands in for the certificate and the setting, and prints what it would store.
    local testing_auto="" autoupdate=""
    [ "${BTRANSLATE_INSTALLER_TEST:-}" = autoupdate ] && testing_auto=1
    auto_update() {
        local want="" cert=""
        case "$(printf '%s' "${BTRANSLATE_AUTOUPDATE:-ask}" | tr '[:upper:]' '[:lower:]')" in
            ask) want=ask ;;
            keep) return 0 ;;
            yes|y|1|true|on) want=yes ;;
            no|n|0|false|off) want=no ;;
            *) die "$(t "BTRANSLATE_AUTOUPDATE is \"$BTRANSLATE_AUTOUPDATE\": say yes or no." "BTRANSLATE_AUTOUPDATE=\"$BTRANSLATE_AUTOUPDATE\": укажите yes или no.")" ;;
        esac
        if [ "$want" = ask ]; then
            local saved
            if [ -n "$testing_auto" ]; then saved="${BTRANSLATE_TEST_AUTOUPDATE:-}"; else saved="$(defaults read "$BUNDLE_ID" autoUpdate 2>/dev/null || true)"; fi
            if [ -n "$saved" ]; then
                [ -z "$testing_auto" ] || echo "Nothing asked: the setting is there already."
                return 0
            fi
            # A terminal to ask on: standard input, or else the terminal itself ("curl … | bash").
            # Started by the app there is neither.
            if [ -z "$testing_auto" ] && ! [ -t 0 ] && ! { : < /dev/tty; } 2>/dev/null; then return 0; fi
            if [ -n "$testing_auto" ]; then
                [ "${BTRANSLATE_TEST_CERT:-no}" = yes ] && cert=1
            elif security find-identity -p codesigning 2>/dev/null | grep -F '"BTranslate (this Mac)"' >/dev/null; then
                cert=1  # (not grep -q: it would stop reading, and pipefail would take security's broken pipe for "no")
            fi
            say "$(t "Updates" "Обновления")"
            t "BTranslate looks for a newer version once a day (one small request to GitHub).
It can also install it by itself, as this installer does: your settings stay." \
              "BTranslate раз в день проверяет, есть ли новая версия (один небольшой запрос к GitHub).
Он может и сам устанавливать ее, как этот установщик: ваши настройки сохраняются."
            printf '\n'
            if [ -z "$cert" ]; then
                t "On this Mac, macOS would want the shortcut's permissions given again after each
update (tools/local-signing.sh has made no certificate here)." \
                  "На этом Mac после каждого обновления macOS потребует снова дать разрешения для
сочетания клавиш (tools/local-signing.sh не создал здесь сертификат)."
                printf '\n'
            fi
            # The keys answer as the pack's question has it: by what is printed on them.
            local answer="" asked="" tries=0 yes_default=""
            [ -n "$cert" ] && yes_default=1
            want=""
            while [ -z "$asked" ] && [ "$tries" -lt 3 ]; do
                tries=$((tries + 1))
                if [ -n "$yes_default" ]; then
                    printf '%s ' "$(t "Install updates automatically? [Y/n]" "Устанавливать обновления автоматически? [Д/н]")"
                else
                    printf '%s ' "$(t "Install updates automatically? [y/N]" "Устанавливать обновления автоматически? [д/Н]")"
                fi
                if [ -n "$testing_auto" ] || [ -t 0 ]; then
                    read -r answer || break
                elif ! { read -r answer < /dev/tty; } 2>/dev/null; then
                    break
                fi
                case "$answer" in
                    "") asked=1; if [ -n "$yes_default" ]; then want=yes; else want=no; fi ;;
                    # In Russian a lone y is as likely the key printed «Н» in a Latin layout: no answer.
                    y|Y) if [ -n "$ru" ]; then printf '%s\n' "Введите «да» или «нет»."; else want=yes; asked=1; fi ;;
                    yes|Yes|YES|д|Д|да|Да|ДА) want=yes; asked=1 ;;
                    n|N|no|No|NO|нет|Нет|НЕТ|т|Т) want=no; asked=1 ;;
                    н|Н) asked=1; if [ -n "$ru" ]; then want=no; else want=yes; fi ;;
                    l|L) if [ -n "$ru" ]; then want=yes; asked=1; fi ;;
                esac
            done
            if [ -z "$asked" ]; then
                printf '\n%s\n' "$(t "(No answer: nothing changed. BTranslate's settings → About has the switch.)" \
                                       "(Ответа нет: ничего не изменено. Переключатель — в настройках BTranslate → «О программе».)")"
                return 0
            fi
        fi
        if [ -n "$testing_auto" ]; then
            echo "autoUpdate would be stored: $want"
        else
            autoupdate="$want"
        fi
    }

    local start=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-start) start= ;;
            --version) echo "BTranslate installer $VERSION"; return 0 ;;
            -h|--help)
                if [ -f "${BASH_SOURCE[0]:-}" ]; then
                    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
                else  # piped from curl: there is no file to read the text above from
                    echo "BTranslate installer $VERSION. Options: --no-start, --version. https://github.com/$REPO#install"
                fi
                return 0 ;;
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
    if [ -n "$testing_auto" ]; then
        auto_update
        return 0
    fi
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$major" -ge 14 ] || die "$(t "macOS 14 or later is needed (this Mac has $(sw_vers -productVersion))." \
                                     "нужна macOS 14 или новее (на этом Mac — $(sw_vers -productVersion)).")"
    xcrun --find swiftc >/dev/null 2>&1 \
        || die "$(t "the Swift compiler is missing. Install the Command Line Tools with: xcode-select --install   then run this again." \
                    "нет компилятора Swift. Установите Command Line Tools командой: xcode-select --install   и запустите установку снова.")"
    auto_update

    # The source: this checkout, or the release downloaded to a temporary folder.
    local src="" tmp=""
    # (Piped from curl there is no such file, whatever bash then calls the script.)
    if [ -f "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/Sources/main.swift" ]; then
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
        && security find-identity -p codesigning 2>/dev/null | grep -F '"BTranslate (this Mac)"' >/dev/null; then
        export BTRANSLATE_SIGN_IDENTITY="BTranslate (this Mac)"
    fi

    say "$(t "Building" "Сборка") BTranslate $(cat "$src/VERSION")"
    bash "$src/build.sh" || die "$(t "the build failed. If the lines above are the compiler's about the Swift language, the Command Line Tools are too old for this version: update them (System Settings → General → Software Update) and run this again." \
                                     "сборка не удалась. Если строки выше — ошибки компилятора о языке Swift, то Command Line Tools устарели для этой версии: обновите их («Системные настройки» → «Основные» → «Обновление ПО») и запустите установку снова.")"

    say "$(t "Installing" "Установка в") $APP"
    pkill -x BTranslate 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$APP"
    ditto "$src/build/BTranslate.app" "$APP"
    # Tell macOS about the app and its Services menu item.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
    /System/Library/CoreServices/pbs -update || true

    # macOS makes its reader of pictures ready for an app the first time the app reads one,
    # which can take a minute: have a start made now, in the background. (The app does the
    # same when it starts: started by macOS, it is another case to macOS than started here.)
    ( "$APP/Contents/MacOS/BTranslate" --prepare-reading >/dev/null 2>&1 & )

    local first=1
    [ "$(defaults read "$BUNDLE_ID" setupDone 2>/dev/null || true)" = 1 ] && first=
    local hint=""
    language_pack
    case "$autoupdate" in
        yes) defaults write "$BUNDLE_ID" autoUpdate -bool true ;;
        no) defaults write "$BUNDLE_ID" autoUpdate -bool false ;;
    esac

    if [ -n "$start" ]; then
        if [ -z "$first" ]; then
            open -g "$APP" --args --background   # an update: keep the settings, no window
        else
            open "$APP"                          # first install: the settings window
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
