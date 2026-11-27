#!/usr/bin/env bash
# BTranslate's tests. They need no network and no API key: the app's own checks first, then
# both AI protocols and the Google fallback against tests/mock_server.py, then the popup and
# the settings window drawn off screen (into build/uitest; in Russian into build/uitest-ru),
# then what the popup does without a connection.
#   tests/run.sh          build if the sources are newer than the app, then test
#   tests/run.sh --live   also use the real Google Translate (one sentence), the real
#                         Keychain (a dummy key is saved, read and deleted), BTranslate's
#                         real preferences (Russian is chosen, read back, and your choice put
#                         back) and Apple's translation on this Mac, where it has German and English
#   tests/run.sh --screen also show a popup on screen for a few seconds, to check what a
#                         picture can't: your app stays in front, typing reaches the pencil's
#                         search field, a second language joins the popup (needs a working
#                         translation method in Settings)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP_BIN=build/BTranslate.app/Contents/MacOS/BTranslate
if [ ! -x "$APP_BIN" ] || [ -n "$(find Sources Resources build.sh VERSION -newer "$APP_BIN" -print -quit)" ]; then ./build.sh; fi
# Every run of the app in these tests ends after four minutes at the latest: a run that hangs
# fails its check, and the tests go on. (Its first reading of a picture can take a minute.)
BIN=build/BTranslate-for-tests
printf '#!/bin/sh\nexec /usr/bin/perl -e '"'"'alarm shift; exec @ARGV or die "could not start: $!\\n"'"'"' 240 "%s" "$@"\n' "$PWD/$APP_BIN" > "$BIN"
chmod +x "$BIN"
# The checks below read the app's English texts, whatever language this Mac or your own
# BTranslate is set to. The Russian ones say so.
export BTRANSLATE_LANGUAGE=en
# The Offline method is Apple's translation, which a Mac may not have (it needs macOS 26, and
# on some Macs downloads). A stand-in answers for it here: it has English, Russian and German,
# French and Spanish "need a download", and it translates "Tag" from German into Russian as
# "OFFLINE de>ru: Tag".
export BTRANSLATE_OFFLINE=mock
# The shortcut needs macOS's permission to read the app in front, and works while BTranslate
# opens at login. Both are stood in for here (neither is there, unless a check says so): no
# check reads another app, asks macOS for a permission, changes the login items or touches
# the clipboard.
export BTRANSLATE_ACCESSIBILITY=off BTRANSLATE_LOGIN=off BTRANSLATE_SCREEN=off
# Nor does any depend on this Mac: there are no saved API keys (a check that needs a key gives
# one), and there is a network, whatever the real one is (the checks of none take it away).
export BTRANSLATE_KEYCHAIN=off BTRANSLATE_CONNECTION=on
DEAD="http://127.0.0.1:9"  # nothing listens there: a request ends as it does without internet
# No check asks GitHub for a newer version of BTranslate: unless a check says otherwise, the
# app looks where nothing listens. An update runs only a stand-in command a check gives (without
# one a check refuses), and writes into a log of the tests' own.
export BTRANSLATE_UPDATE_URL="$DEAD" BTRANSLATE_UPDATE_LOG="$PWD/build/update-test.log"
unset BTRANSLATE_UPDATE_COMMAND BTRANSLATE_UPDATE_WAITING BTRANSLATE_VERSION BTRANSLATE_SIGNED BTRANSLATE_AUTOUPDATE
# Settings are given to a run as -key value arguments. These say that nothing is chosen yet
# for the typing panel and for a window, and nothing about updates, whatever your own settings say.
NONE=(-secondLanguage none -typingLanguage none -typingEngine none -windowLanguage none -windowEngine none
      -checkForUpdates YES -autoUpdate NO -lastUpdateCheck '' -updateTo '' -autoUpdateFailed '')
# The language pack (NLLB-200) is kept in a folder of the tests' own: empty, unless a test
# installs the miniature pack of the mock server there. A pack you have installed is not touched.
export BTRANSLATE_PACK_DIR="$PWD/build/test-pack"
rm -rf "$BTRANSLATE_PACK_DIR"
PORT="${BTRANSLATE_TEST_PORT:-18766}"
MOCK="http://127.0.0.1:$PORT"
LOG=build/mock.log

python3 -I tests/mock_server.py "$PORT" > "$LOG" &
mock=$!
trap 'kill "$mock" 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "$MOCK/" && break; sleep 0.1; done
kill -0 "$mock" 2>/dev/null || { echo "The mock server did not start. Is port $PORT taken? (BTRANSLATE_TEST_PORT sets another.)"; exit 1; }

failed=0
# check NAME EXPECTED COMMAND...: the command's output must contain EXPECTED.
check() {
    local name="$1" expected="$2" out
    shift 2
    out="$("$@" 2>&1 || true)"
    if [[ "$out" == *"$expected"* ]]; then
        echo "ok    $name"
    else
        echo "FAIL  $name"; echo "      expected: $expected"; echo "      got:      ${out//$'\n'/ | }"
        failed=1
    fi
}
# logged NAME PATTERN: the mock server must have seen a request matching PATTERN.
logged() {
    if grep -q -- "$2" "$LOG"; then echo "ok    $1"; else echo "FAIL  $1 (no request matching: $2)"; failed=1; fi
}
# seen PATTERN: how many requests matching PATTERN the mock server has seen.
seen() { echo "seen $(grep -c -- "$1" "$LOG" || true) time(s)"; }
ai() {  # ai PROVIDER PATH [args...]: a headless AI translation against the mock server
    local provider="$1" path="$2"
    shift 2
    BTRANSLATE_PROVIDER="$provider" BTRANSLATE_BASE_URL="$MOCK/$path" BTRANSLATE_API_KEY="${KEY:-test-key}" \
        "$BIN" --print --engine ai "$@"
}
TRANSLATED=$'source: Latvian | updates: 4\nHello! How are you?\nSecond line.'

check "selftest" "selftest: ok" "$BIN" --selftest
check "selftest, in Russian" "selftest: ok" env BTRANSLATE_LANGUAGE=ru "$BIN" --selftest
check "Every text has its translation" "strings: ok" python3 -I tools/check-strings.py

check "Anthropic: streaming, thinking skipped" "$TRANSLATED" ai anthropic anthropic "Labdien"
logged "Anthropic: model, effort, version header" '"anthropic-version": "2026-10-21".*"model": "claude-haiku-5-5", "output_config": {"effort": "low"}'
check "Anthropic: older model (no effort setting)" "$TRANSLATED" ai anthropic anthropic-old "Labdien"
check "Anthropic: refusal" "declined to translate" ai anthropic anthropic-refusal "Labdien"
KEY=wrong-key check "Anthropic: bad key" "API key was refused (HTTP 401): invalid x-api-key" ai anthropic anthropic "Labdien"
check "Anthropic: target language in the prompt" "$TRANSLATED" ai anthropic anthropic --to "Serbian (Latin)" "Labdien"
logged "Anthropic: prompt names the alphabet" 'Serbian written in the Latin alphabet (srpski, latinica)'
check "AI: a language by its code" "$TRANSLATED" ai anthropic anthropic --to ru "Labdien"
logged "AI: told the language in English and in its own name" 'Translate into Russian (русский):'
logged "AI: the text is marked off from the instruction" '<text>\\nLabdien\\n</text>'

check "OpenAI-style: streaming" "$TRANSLATED" ai deepseek openai "Labdien"
logged "OpenAI-style: bearer key, default model" '"authorization": "Bearer test-key".*"model": "deepseek-chat"'
check "OpenRouter: retry without the reasoning field" "$TRANSLATED" ai openrouter openrouter-strict "Labdien"
check "Model list: Anthropic" $'claude-haiku-5-5\nclaude-sonnet-5-5' \
    env BTRANSLATE_PROVIDER=anthropic BTRANSLATE_BASE_URL="$MOCK/anthropic" BTRANSLATE_API_KEY=test-key "$BIN" --models
check "Model list: sorted, prefix removed" $'alpha\nzeta' \
    env BTRANSLATE_PROVIDER=openai BTRANSLATE_BASE_URL="$MOCK/openai" BTRANSLATE_API_KEY=test-key "$BIN" --models

check "Google: first endpoint" $'source: Latvian | updates: 1\nEN:Labdien & čau' \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --print --engine google "Labdien & čau"
check "Google: falls back when rate-limited" $'source: Latvian | updates: 1\nEN2:Labdien' \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google429" "$BIN" --print --engine google "Labdien"
check "Google: Serbian in Latin script" "SR:Dobar dan" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --print --engine google --to "Serbian (Latin)" "Добар дан"
check "Google: Serbian handed back in Latin letters becomes Cyrillic" "SR:Добар дан, идемо у Docker (open-source)" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --print --engine google --from sr --to "Serbian (Cyrillic)" "Dobar dan, idemo u Docker (open-source)"
check "Google: the original's language given" $'source: Lithuanian | updates: 1\nEN:Labas' \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --print --engine google --from lt "Labas"
logged "Google: it is asked for that language" 'translate_a/single?client=gtx&sl=lt&'
check "Google: the same through the second endpoint" $'source: Lithuanian | updates: 1\nEN2:Labas' \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google429" "$BIN" --print --engine google --from lt "Labas"
check "AI: the original's language given" "source: Lithuanian" ai anthropic anthropic --from Lithuanian --to ru "Labas"
logged "AI: told to read the text as that language" 'The text is written in Lithuanian (lietuvių)'
logged "AI: the user turn names both languages" 'Translate from Lithuanian (lietuvių) into Russian (русский):'

check "Russian: the detected language's name" $'source: Латышский | updates: 1\nEN:Labdien' \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --print --engine google "Labdien"
check "Russian: an error message" "Ключ API отклонен (HTTP 401): invalid x-api-key" \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_PROVIDER=anthropic BTRANSLATE_BASE_URL="$MOCK/anthropic" BTRANSLATE_API_KEY=wrong-key \
    "$BIN" --print --engine ai "Labdien"
check "Russian: the AI is still told the languages in English" "source: Литовский" \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_PROVIDER=anthropic BTRANSLATE_BASE_URL="$MOCK/anthropic-ru" BTRANSLATE_API_KEY=test-key \
    "$BIN" --print --engine ai --from литовский --to русский "Labas"
check "Russian: the AI is told every language as in English" "same" bash -c \
    "diff <('$BIN' --prompts) <(BTRANSLATE_LANGUAGE=ru '$BIN' -AppleLanguages '(ru)' --prompts) >/dev/null && echo same"
logged "Russian: the prompt is the same" 'Translate from Lithuanian (lietuvių) into Russian (русский):.*/anthropic-ru/messages'

check "No connection: said plainly" "ERROR: No internet connection." \
    env BTRANSLATE_GOOGLE_URL="$DEAD" "$BIN" --print --engine google "Labdien"
check "No connection: a local AI server that is not running is another matter" "The AI server at 127.0.0.1:9 is not answering. Is it running?" \
    env BTRANSLATE_PROVIDER=custom BTRANSLATE_BASE_URL="$DEAD/v1" BTRANSLATE_API_KEY=x "$BIN" --print --engine ai "Labdien"
check "Offline method: a translation, the language told on the Mac" $'source: German | updates: 1\nOFFLINE de>ru: Guten Tag! Wie geht es Ihnen heute?' \
    "$BIN" --print --engine device --to ru "Guten Tag! Wie geht es Ihnen heute?"
check "Offline method: the original's language given, line breaks kept" $'OFFLINE de>en: Eins\n\nOFFLINE de>en: Zwei' \
    "$BIN" --print --engine device --from de --to en $'Eins\n\nZwei'
check "Offline method: a language neither macOS nor the language pack has" "The Offline method has no Abkhaz." \
    "$BIN" --print --engine device --from de --to ab "Guten Tag"
check "Offline method: a language only the language pack has, and it is not installed" \
    "needs the NLLB-200 language pack (German → Latvian). Download it in Settings" "$BIN" --print --engine device --from de --to lv "Guten Tag"
check "Offline method: Latvian is told by its own letters" "needs the NLLB-200 language pack (Latvian → Russian)" \
    "$BIN" --print --engine device --to ru "Rīt es būšu birojā no deviņiem līdz pieciem."
check "Offline method: a language that needs a download" "are not downloaded yet (German → French). Download them in Settings" \
    "$BIN" --print --engine device --from de --to fr "Guten Tag"
check "Offline method: already in that language" $'source: German | updates: 1\nGuten Tag' \
    "$BIN" --print --engine device --from de --to de "Guten Tag"

LONG="This is the first sentence, and it is here to fill one piece. $(printf 'Another sentence that makes the text longer than one piece. %.0s' 1 2 3 4)"
check "Speech: Google's voice, in pieces" "google voice xx: 2 piece(s)" \
    env BTRANSLATE_GOOGLE_SPEECH_URL="$MOCK/speech" "$BIN" -googleVoice YES --speech-check xx "$LONG"
logged "Speech: the text goes in the request body" '"rpc": "jQ1olc", "text": "This is the first sentence'
check "Speech: no voice when Google's is turned off" "no voice for" "$BIN" -googleVoice NO --speech-check xx "Hello"
check "Speech: a voice of this Mac, without sound" "mac voice en-" "$BIN" --speech-check en "Hello there."

# -key value arguments override the saved settings for this run only.
UI_OUT="$(env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --uitest build/uitest \
    -googleEnabled YES -defaultEngine google -languages '(en, ru, lv)' -defaultLanguage ru "${NONE[@]}" 2>&1 || true)"
check "UI, off screen: the popup stays where it was moved" "popup stays where it was moved: yes" echo "$UI_OUT"
check "UI, off screen: the picker adds a language" "picker adds a language to the list: yes" echo "$UI_OUT"
check "UI, off screen: the pencil's picker searches" "source picker finds: ltg, la, lv" echo "$UI_OUT"
check "UI, off screen: the original's language set by hand" "the original's language can be set by hand: yes" echo "$UI_OUT"
check "UI, off screen: the popup opens with the default language" "popup text: RU:" echo "$UI_OUT"
check "UI, off screen: several languages at once" "several languages at once: yes (ru, en, lv)" echo "$UI_OUT"
check "UI, off screen: the list's arrows, Make Default and Make Second" \
    "list buttons: en,ru,lv,sr-Latn default=ru second=en → en,ru,sr-Latn,lv default=ru second=en → en,ru,sr-Latn,lv default=sr-Latn second=en → ru,en,sr-Latn,lv default=sr-Latn second=en → ru,en,sr-Latn,lv default=sr-Latn second=lv" echo "$UI_OUT"
check "UI, off screen: the language to write in follows the list" "language to write in: lv → ru → lv" echo "$UI_OUT"
check "UI, off screen: pictures written" "source-picker.png" ls build/uitest
check "UI, off screen: every text of the settings window fits" "settings window, every text fits: yes" echo "$UI_OUT"
check "UI, off screen: every page of the settings window fits a small screen" "they fit a small screen" echo "$UI_OUT"
check "UI, off screen: the page tabs end within the page" "page tabs fit the page: yes" echo "$UI_OUT"
check "UI, off screen: the menu of BTranslate's own language" "language menu: the Mac's, en, ru" echo "$UI_OUT"

# The same in Russian: longer words in the same windows.
UI_RU="$(env BTRANSLATE_LANGUAGE=ru BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --uitest build/uitest-ru \
    -AppleLanguages '(ru)' -googleEnabled YES -defaultEngine google -languages '(en, ru, lv)' -defaultLanguage ru 2>&1 || true)"
check "UI in Russian: it is in Russian" "interface language: ru" echo "$UI_RU"
check "UI in Russian: every text of the settings window fits" "settings window, every text fits: yes" echo "$UI_RU"
check "UI in Russian: every page of the settings window fits a small screen" "they fit a small screen" echo "$UI_RU"
check "UI in Russian: the five page tabs end within the page (at its margin, where they had to be narrowed)" "page tabs fit the page: yes" echo "$UI_RU"
check "UI in Russian: the picker finds languages by their English names too" "source picker finds: ltg, la, lv" echo "$UI_RU"
check "UI in Russian: several languages at once" "several languages at once: yes (ru, en, lv)" echo "$UI_RU"
check "UI in Russian: the original's language set by hand" "the original's language can be set by hand: yes" echo "$UI_RU"
check "UI in Russian: pictures written" "settings-languages.png" ls build/uitest-ru

# Without a connection (Google's address cuts the first request off, or nothing listens there).
OFF=(-googleEnabled YES -aiEnabled NO -defaultEngine google -defaultLanguage ru)
OFF_OUT="$(env BTRANSLATE_GOOGLE_URL="$MOCK/googleflaky1-switch" "$BIN" --offline-uitest switch "${OFF[@]}" -deviceEnabled YES -languages '(ru, lv)' build/uitest 2>&1 || true)"
check "No connection: the popup goes over to the Offline method" \
    "switch, without a connection: method device, no connection shown: yes, texts: OFFLINE de>ru: Guten Tag!" echo "$OFF_OUT"
check "No connection: a language the Offline method can't do here waits" \
    "needs the NLLB-200 language pack (German → Latvian). / No internet connection. BTranslate will translate as soon as it is back." echo "$OFF_OUT"
check "No connection: the first method takes over again when the connection is back" \
    "switch, the connection is back: method google, no connection shown: no, texts: RU:Guten Tag! Ich bin morgen von neun bis fünf im Büro. | LV:Guten Tag!" echo "$OFF_OUT"
WAIT_OUT="$(env BTRANSLATE_GOOGLE_URL="$MOCK/googleflaky1-wait" "$BIN" --offline-uitest wait "${OFF[@]}" -deviceEnabled NO -languages '(ru)' build/uitest 2>&1 || true)"
check "No connection, Offline method turned off: the popup waits" \
    "wait, without a connection: method google, no connection shown: yes, texts: No internet connection. BTranslate will translate as soon as it is back." echo "$WAIT_OUT"
check "No connection, Offline method turned off: it translates when the connection is back" \
    "wait, the connection is back: method google, no connection shown: no, texts: RU:Guten Tag!" echo "$WAIT_OUT"
STAY_OUT="$(env BTRANSLATE_GOOGLE_URL="$DEAD" "$BIN" --offline-uitest switch "${OFF[@]}" -deviceEnabled YES -languages '(ru, en)' build/uitest 2>&1 || true)"
check "No connection: what was translated offline stays when the connection is back" \
    "switch, the connection is back: method device, no connection shown: no, texts: OFFLINE de>ru: Guten Tag! Ich bin morgen von neun bis fünf im Büro. | OFFLINE de>en: Guten Tag!" echo "$STAY_OUT"
SET_OUT="$("$BIN" --offline-uitest settings -googleEnabled YES -aiEnabled NO -deviceEnabled YES -defaultEngine google -languages '(en, ru, fr, lv)' -defaultLanguage ru "${NONE[@]}" build/uitest 2>&1 || true)"
check "Settings: which languages work without internet" "offline marks: en installed, ru installed, fr downloadable, lv downloadable" echo "$SET_OUT"
check "Settings: Download is offered for the languages that need one" "Download offered: en no, ru no, fr yes, lv yes" echo "$SET_OUT"
check "Settings, with the offline marks: every text fits" "settings window, every text fits: yes" echo "$SET_OUT"
check "Settings: until one is chosen, typing and a window open with the popup's method, and each with its own language" \
    "each opens with: popup google ru, typing google en, window google ru" echo "$SET_OUT"
SET_RU="$(env BTRANSLATE_LANGUAGE=ru "$BIN" --offline-uitest settings -AppleLanguages '(ru)' -googleEnabled YES -deviceEnabled YES -languages '(en, ru, fr, lv)' build/uitest-ru 2>&1 || true)"
check "Settings in Russian, with the offline marks: every text fits" "settings window, every text fits: yes" echo "$SET_RU"

# A popup made off screen (BTranslate --popup-check): what it turns to, which methods it offers.
POP=(-googleEnabled YES -defaultEngine google -recentSources '()')
LV="Labdien! Kā jums klājas?"
check "Second default: a text in the default language goes into the next language of the list" "   en: EN:Labdien!" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --popup-check "$LV" "${POP[@]}" -languages '(en, ru, lv)' -defaultLanguage lv -secondLanguage ''
check "Second default: the one chosen in Settings" "   ru: RU:Labdien!" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --popup-check "$LV" "${POP[@]}" -languages '(en, ru, lv)' -defaultLanguage lv -secondLanguage ru
check "Second default: a text in another language keeps the default" "   ru: RU:Labdien!" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --popup-check "$LV" "${POP[@]}" -languages '(en, ru, lv)' -defaultLanguage ru -secondLanguage en
check "Second default: none with one language in the list" "   lv: LV:Labdien!" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --popup-check "$LV" "${POP[@]}" -languages '(lv)' -defaultLanguage lv
AI=(-aiEnabled YES -aiProvider openai -deviceEnabled YES -languages '(en, ru)' -defaultLanguage ru)
check "AI model without a key: not among the popup's methods" "methods google, device;" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" BTRANSLATE_KEYCHAIN=off "$BIN" --popup-check "Labdien" "${POP[@]}" "${AI[@]}"
check "AI model with a key: among them" "methods google, ai, device;" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" BTRANSLATE_API_KEY=test-key "$BIN" --popup-check "Labdien" "${POP[@]}" "${AI[@]}"
check "AI model on a server of your own: its address is enough" "methods google, ai, device;" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" BTRANSLATE_KEYCHAIN=off "$BIN" --popup-check "Labdien" "${POP[@]}" "${AI[@]}" -aiProvider custom -aiBaseURL "$MOCK/openai"
check "AI model on a server of your own, no address: not among them" "methods google, device;" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" BTRANSLATE_KEYCHAIN=off "$BIN" --popup-check "Labdien" "${POP[@]}" "${AI[@]}" -aiProvider custom -aiBaseURL ''
check "Settings: \"opens with\" leaves the AI model out until it has a key" "opens with: google, device" \
    env BTRANSLATE_KEYCHAIN=off "$BIN" --offline-uitest settings -googleEnabled YES "${AI[@]}" build/uitest
check "Settings: \"opens with\" has the AI model once it has one" "opens with: google, ai, device" \
    env BTRANSLATE_API_KEY=test-key "$BIN" --offline-uitest settings -googleEnabled YES "${AI[@]}" build/uitest
check "Settings: the method and the language chosen for typing and for a window" "each opens with: popup google ru, typing device ru, window ai en" \
    env BTRANSLATE_API_KEY=test-key "$BIN" --offline-uitest settings -googleEnabled YES "${AI[@]}" -defaultEngine google \
    -typingEngine device -typingLanguage ru -windowEngine ai -windowLanguage en build/uitest
check "Settings: a method chosen for them that can't be used now gives way to the popup's" "each opens with: popup google ru, typing google en, window google ru" \
    "$BIN" --offline-uitest settings -googleEnabled YES "${AI[@]}" -defaultEngine google "${NONE[@]}" -typingEngine ai -windowEngine ai build/uitest

# Reading aloud where only Google's voice could do it, without internet: a note under the
# speaker button says why it can't be done. (Nothing is played, and nothing beeps.)
SPEAK=(-googleEnabled YES -aiEnabled NO -defaultEngine google -recentSources '()' -googleVoice YES -languages '(ab)' -defaultLanguage ab)
NOTE="the speaker's notice: No internet connection: this text can't be read aloud now. This Mac has no voice for Abkhaz, and Google's voice needs internet."
check "Reading aloud without a network: a note says why it can't be done" "$NOTE" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" BTRANSLATE_CONNECTION=off "$BIN" --popup-check "Hello" --speak "${SPEAK[@]}"
check "Reading aloud, Google's voice out of reach: the same note" "$NOTE" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" BTRANSLATE_GOOGLE_SPEECH_URL="$DEAD" "$BIN" --popup-check "Hello" --speak "${SPEAK[@]}"
check "Reading aloud without a network, in Russian" "У этого Mac нет голоса для этого языка (абхазский), а голосу Google нужен интернет." \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_GOOGLE_URL="$MOCK/google" BTRANSLATE_CONNECTION=off "$BIN" --popup-check "Hello" --speak "${SPEAK[@]}"
check "Reading aloud with a voice of the Mac needs no network: no note" "the speaker's notice: none" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" BTRANSLATE_CONNECTION=off "$BIN" --popup-check "Labdien" --speak "${SPEAK[@]}" -languages '(en)' -defaultLanguage en

# Where the Offline method can't translate for want of the language pack, the popup offers it.
GER="Guten Tag! Ich bin morgen von neun bis fünf im Büro."
OFFER=(-googleEnabled YES -aiEnabled NO -deviceEnabled YES -languages '(lv, ru)' -defaultLanguage lv -recentSources '()')
check "Language pack offered: a button under the message downloads it" \
    "(German → Latvian). [Download Language Pack (906 MB)]" "$BIN" --popup-check "$GER" "${OFFER[@]}" -defaultEngine device
check "Language pack offered: the bar names the language the Mac told" "the original: German" "$BIN" --popup-check "$GER" "${OFFER[@]}" -defaultEngine device
check "Language pack offered: also when the popup went offline for lack of a connection" \
    "BTranslate will translate as soon as it is back. [Download Language Pack (906 MB)]" \
    env BTRANSLATE_GOOGLE_URL="$DEAD" "$BIN" --popup-check "$GER" "${OFFER[@]}" -defaultEngine google
check "Language pack offered: without a network, the download waits for one" \
    "/ The language pack will be downloaded as soon as there is an internet connection." \
    env BTRANSLATE_CONNECTION=off "$BIN" --popup-check "$GER" --download "${OFFER[@]}" -defaultEngine device
check "Language pack offered: nothing at the address is said so, and the button stays" \
    "It may not be published yet. [Download Language Pack (906 MB)]" \
    env BTRANSLATE_PACK_URL="$MOCK/nothing" "$BIN" --popup-check "$GER" --download "${OFFER[@]}" -defaultEngine device
check "Language pack offered: not where the pack would not help" "   ab: The Offline method has no Abkhaz." \
    "$BIN" --popup-check "$GER" "${OFFER[@]}" -languages '(ab)' -defaultLanguage ab -defaultEngine device
check "Language pack offered: the button downloads it, and the popup translates again" "with the pack: methods" \
    env BTRANSLATE_PACK_URL="$MOCK/pack" "$BIN" --popup-check "$GER" --download "${OFFER[@]}" -defaultEngine device
"$BIN" --pack-remove > /dev/null || true

# The installer's question about the language pack: its step alone, for the app just built.
INST=(BTRANSLATE_INSTALLER_TEST=pack BTRANSLATE_TEST_APP="$PWD/build/BTranslate.app")
check "Installer: the language pack, wanted" "The language pack is installed." \
    env "${INST[@]}" BTRANSLATE_PACK=yes BTRANSLATE_PACK_URL="$MOCK/pack" ./install.sh
"$BIN" --pack-remove > /dev/null || true
check "Installer: the language pack, not wanted" "The language pack is not installed. To get it later: BTranslate's settings → Translation → Download (906 MB)." \
    env "${INST[@]}" BTRANSLATE_PACK=no ./install.sh
check "Installer: BTRANSLATE_PACK said another way" "The language pack is installed." \
    env "${INST[@]}" BTRANSLATE_PACK=YES BTRANSLATE_PACK_URL="$MOCK/pack" ./install.sh
"$BIN" --pack-remove > /dev/null || true
check "Installer: and said wrongly" "say yes or no" env "${INST[@]}" BTRANSLATE_PACK=maybe ./install.sh
check "Installer: the language pack is not at its address" "It may not be published yet." \
    env "${INST[@]}" BTRANSLATE_PACK=yes BTRANSLATE_PACK_URL="$MOCK/nothing" ./install.sh
check "Installer, in Russian: the language pack" "Языковой пакет установлен." \
    env "${INST[@]}" BTRANSLATE_LANGUAGE=ru BTRANSLATE_PACK=yes BTRANSLATE_PACK_URL="$MOCK/pack" ./install.sh
"$BIN" --pack-remove > /dev/null || true

# Updates. The check asks the mock server, where VERSION says 1.10.0; BTRANSLATE_VERSION is the
# version the app takes itself for. Each run gets every update setting as an argument (OWN
# first, so that a check can say otherwise after it): a copy of BTranslate installed on this
# Mac has its own, and with "install updates automatically" ticked there a check would go on
# to update instead of saying what it found.
OWN=(-checkForUpdates YES -autoUpdate NO -autoUpdateFailed '')
upd() { env BTRANSLATE_UPDATE_URL="$MOCK/$1" BTRANSLATE_VERSION="$2" "$BIN" "${OWN[@]}" "${@:3}" -lastUpdateCheck '' -updateTo ''; }
check "Updates: a newer version, its release there" "update check: available: 1.10.0" upd update 1.9.0 --update-check
logged "Updates: VERSION is asked for" '"method": "GET", "path": "/update/VERSION"'
logged "Updates: and whether the release's source is there" '"method": "HEAD", "path": "/update/archive/refs/tags/v1.10.0.tar.gz"'
check "Updates: the day's check is kept" "last check kept: yes" upd update 1.9.0 --update-check
check "Updates: a newer version without its release yet is no update" "update check: up to date" upd update-norelease 1.9.0 --update-check
check "Updates: the same version" "update check: up to date" upd update 1.10.0 --update-check
check "Updates: an older one" "update check: up to date" upd update 1.11.0 --update-check
check "Updates: nonsense for a version" "update check: could not check: GitHub's answer is not a version number." upd update-nonsense 1.9.0 --update-check
check "Updates: nothing answering" $'update check: could not check: No internet connection.\nlast check kept: no' \
    env BTRANSLATE_VERSION=1.9.0 "$BIN" "${OWN[@]}" --update-check
check "Updates: the daily check, with the setting on" "update check: available: 1.10.0" upd update 1.9.0 --update-check --scheduled -checkForUpdates YES
check "Updates: none with checkForUpdates off" "update check: not done (checkForUpdates is off)" \
    upd update 1.9.0 --update-check --scheduled -checkForUpdates NO
check "Updates: none while the last check is less than a day old" "update check: not done (the last one is less than a day old)" \
    env BTRANSLATE_UPDATE_URL="$MOCK/update" BTRANSLATE_VERSION=1.9.0 "$BIN" "${OWN[@]}" --update-check --scheduled \
    -lastUpdateCheck "$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)"
check "Updates: and again once it is a day old" "update check: available: 1.10.0" \
    env BTRANSLATE_UPDATE_URL="$MOCK/update" BTRANSLATE_VERSION=1.9.0 "$BIN" "${OWN[@]}" --update-check --scheduled \
    -lastUpdateCheck "$(date -u -v-25H +%Y-%m-%dT%H:%M:%SZ)"
check "Updates: a last check in the future (the clock was set back) does not hold off the next" "update check: available: 1.10.0" \
    env BTRANSLATE_UPDATE_URL="$MOCK/update" BTRANSLATE_VERSION=1.9.0 "$BIN" "${OWN[@]}" --update-check --scheduled \
    -lastUpdateCheck "$(date -u -v+30d +%Y-%m-%dT%H:%M:%SZ)"

# The Update button, with a stand-in for the installer.
UPLOG="$BTRANSLATE_UPDATE_LOG"
rm -f "$UPLOG"
run_update() { env BTRANSLATE_UPDATE_WAITING=1.10.0 BTRANSLATE_VERSION=1.9.0 "$@" "$BIN" --update-run ${UPDAUTO:+--auto} -checkForUpdates YES -autoUpdate NO -updateTo '' -autoUpdateFailed ''; }
UPDAUTO=""  # --auto: as an automatic update
UPDATED="$(run_update BTRANSLATE_UPDATE_COMMAND='echo "pack: $BTRANSLATE_PACK, automatic updates: $BTRANSLATE_AUTOUPDATE"' 2>&1 || true)"
check "Update: the button starts the command" "update to 1.10.0: updating to 1.10.0" echo "$UPDATED"
check "Update: and notes what it started, before it starts it" "the note it keeps: from 1.9.0 to 1.10.0, asked by the user" echo "$UPDATED"
check "Update: the installer is told to leave the language pack and the automatic updates as they are" \
    "pack: no, automatic updates: keep" cat "$UPLOG"
check "Update: what it printed went into the log, after a line saying what was started" $'BTranslate 1.9.0 → 1.10.0\npack: no' cat "$UPLOG"
FAILED="$(run_update BTRANSLATE_UPDATE_COMMAND='echo "Building BTranslate"; echo "the build failed here" >&2; exit 3' 2>&1 || true)"
check "Update: a command that fails shows its last line and the log's path" \
    "the About page says: The update did not work: the build failed here / The installer's log: " echo "$FAILED"
check "Update: and the note goes" "the note then: none" echo "$FAILED"
# The installer's own line, curl … | bash, where the download fails: bash then reads nothing and
# ends with 0, and only pipefail makes the update fail as it did.
NONET="$(run_update BTRANSLATE_UPDATE_COMMAND="/usr/bin/curl -fsSL $DEAD/install.sh | /bin/bash" 2>&1 || true)"
check "Update: a download that fails is a failed update, not one still on offer" "once the command has ended: update failed: curl: (7)" echo "$NONET"
check "Update: one the user asked for that failed does not hold off automatic updates" "tried again by itself: yes" echo "$NONET"
UPDAUTO=1
check "Update: an automatic one that failed is not tried again by itself" "tried again by itself: no, Update still offers it" \
    run_update BTRANSLATE_UPDATE_COMMAND='exit 1'
UPDAUTO=""
check "Update: an automatic one is noted as such" "the note it keeps: from 1.9.0 to 1.10.0, automatic" \
    env BTRANSLATE_UPDATE_WAITING=1.10.0 BTRANSLATE_VERSION=1.9.0 BTRANSLATE_UPDATE_COMMAND=true "$BIN" --update-run --auto -updateTo '' -autoUpdateFailed ''
check "Update: a check without the stand-in never runs the installer" \
    "update to 1.10.0: update failed: a check never runs the real installer" env BTRANSLATE_UPDATE_WAITING=1.10.0 "$BIN" --update-run -updateTo ''

# The automatic update: a version found, with the setting on or off.
AUTO=(BTRANSLATE_VERSION=1.9.0 BTRANSLATE_UPDATE_COMMAND='echo automatic')
check "Automatic update: starts with the setting on and nothing showing" \
    "a version found, nothing showing: available: 9.9.9 → updating to 9.9.9" env "${AUTO[@]}" "$BIN" -autoUpdate YES -updateTo '' -autoUpdateFailed '' --update-auto-check
AUTO_POP="$(env "${AUTO[@]}" BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" -autoUpdate YES -updateTo '' -autoUpdateFailed '' "${POP[@]}" -languages '(en)' \
    --update-auto-check --showing popup 2>&1 || true)"
check "Automatic update: waits while a popup is showing" "a version found, a popup showing: available: 9.9.9; the update started: no" echo "$AUTO_POP"
check "Automatic update: and starts once it is gone" "the popup closed: available: 9.9.9 → updating to 9.9.9" echo "$AUTO_POP"
check "Automatic update: does not start with the setting off" "a version found, nothing showing: available: 9.9.9; the update started: no" \
    env "${AUTO[@]}" "$BIN" -autoUpdate NO -updateTo '' -autoUpdateFailed '' --update-auto-check
check "Automatic update: not again for a version whose automatic update failed" "a version found, nothing showing: available: 9.9.9; the update started: no" \
    env "${AUTO[@]}" "$BIN" -autoUpdate YES -updateTo '' -autoUpdateFailed 9.9.9 --update-auto-check
check "Automatic update: but for the next one" "a version found, nothing showing: available: 9.9.9 → updating to 9.9.9" \
    env "${AUTO[@]}" "$BIN" -autoUpdate YES -updateTo '' -autoUpdateFailed 9.9.8 --update-auto-check

# The start after an update: the note of what was started is given as arguments.
printf 'Building BTranslate 1.10.0\nno Command Line Tools here\n' > build/update-note.log  # what the installer left in its log
note() { env BTRANSLATE_VERSION="$1" BTRANSLATE_UPDATE_LOG="$PWD/build/update-note.log" "$BIN" -updateFrom 1.9.0 -updateTo 1.10.0 -updateAsked "$2" -autoUpdateFailed '' --update-note-check; }
check "After an update the user asked for: the version reached, the note goes, the settings open on About" \
    "at the start: installed: 1.10.0; the note then: none; the settings open on the About page: yes" note 1.10.0 YES
check "After an automatic update: the same, and nothing opens" \
    "at the start: installed: 1.10.0; the note then: none; the settings open on the About page: no" note 1.10.0 NO
check "An update that did not arrive says so" \
    "at the start: update failed: The update to 1.10.0 did not finish. no Command Line Tools here; the note then: none; the settings open on the About page: no" note 1.9.0 YES
check "Without a note, nothing happens at the start" "at the start: never checked; the note then: none" \
    env BTRANSLATE_VERSION=1.9.0 "$BIN" -updateTo '' --update-note-check

# The gears, while a newer version waits.
WAITING_GEAR='gear: tinted, tooltip “BTranslate 9.9.9 is available. Click to see it in the settings.”, opens the About page'
check "Gear of the popup: tinted while a version waits, and it opens the About page" "$WAITING_GEAR" \
    env BTRANSLATE_UPDATE_WAITING=9.9.9 BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --popup-check "Labdien" "${POP[@]}" -languages '(en)'
check "Gear of the popup: plain otherwise" "gear: plain, tooltip “BTranslate settings”, opens the settings" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --popup-check "Labdien" "${POP[@]}" -languages '(en)'
check "Gear of the typing panel, while a version waits" "$WAITING_GEAR" \
    env BTRANSLATE_UPDATE_WAITING=9.9.9 BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${NONE[@]}" -googleEnabled YES -languages '(en, ru)' --type-check "Hello"

# The About page in every state of the update, signed ad hoc and with this Mac's certificate,
# in English and in Russian: every text fits, and the window a small screen.
ABOUT=(-checkForUpdates YES -autoUpdate NO -lastUpdateCheck '' -updateTo '' -autoUpdateFailed '')
for signed in adhoc own; do
    for language in en ru; do
        OUT="$(env BTRANSLATE_LANGUAGE=$language BTRANSLATE_SIGNED=$signed BTRANSLATE_VERSION=1.9.0 "$BIN" -AppleLanguages "($language)" "${ABOUT[@]}" \
            --about-check --picture "build/uitest-about-$language-$signed" 2>&1 || true)"
        check "About page ($language, $signed): every text fits in every state" "every state: every text fits: yes" echo "$OUT"
        check "About page ($language, $signed): and it fits a small screen" "it fits a small screen" echo "$OUT"
        check "About page ($language, $signed): the note about the permissions $([ $signed = adhoc ] && echo "where signed ad hoc" || echo "only where signed ad hoc")" \
            "ad hoc note: $([ $signed = adhoc ] && echo shown || echo hidden)" echo "$OUT"
    done
done
OUT="$(env BTRANSLATE_SIGNED=adhoc BTRANSLATE_VERSION=1.9.0 "$BIN" "${ABOUT[@]}" --about-check 2>&1 || true)"
check "About page: Update while a version waits" "about, available: BTranslate 9.10.11 is available. This one is 1.9.0. [Update]" echo "$OUT"
check "About page: Check Now otherwise" "about, never: BTranslate has not looked for a newer version yet. [Check Now]" echo "$OUT"
check "About page: while it checks, a spinner and the button off" "about, checking: Looking for a newer version… [Check Now, off, spinning]" echo "$OUT"
check "About page: while it updates, the same" "[Update, off, spinning]" echo "$OUT"
check "About page: the two ticks as the settings give them" "ticks: daily on, automatic off;" echo "$OUT"
check "About page, in Russian: a check that failed" "Не удалось проверить, есть ли новая версия: Нет подключения к интернету." \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_SIGNED=adhoc BTRANSLATE_VERSION=1.9.0 "$BIN" -AppleLanguages '(ru)' "${ABOUT[@]}" --about-check
check "About page: the automatic tick is off while the daily check is" "automatic on (off while the daily check is)" \
    env BTRANSLATE_SIGNED=adhoc "$BIN" -checkForUpdates NO -autoUpdate YES -lastUpdateCheck '' -updateTo '' --about-check

# The installer's question about updating by itself: its step alone. The answer comes on
# standard input; the certificate and the setting are stood in for, and nothing is stored.
askauto() { local answer="$1"; shift; printf '%s' "$answer" | env BTRANSLATE_INSTALLER_TEST=autoupdate "$@" ./install.sh 2>&1; }
check "Installer: updates, Enter on a Mac with its own certificate: yes" $'[Y/n] autoUpdate would be stored: yes' askauto $'\n' BTRANSLATE_TEST_CERT=yes
check "Installer: updates, Enter on a Mac without one: no" $'[y/N] autoUpdate would be stored: no' askauto $'\n' BTRANSLATE_TEST_CERT=no
check "Installer: updates, without a certificate the question says why its default is no" \
    "macOS would want the shortcut's permissions given again" askauto $'\n' BTRANSLATE_TEST_CERT=no
check "Installer: updates, y without a certificate" "autoUpdate would be stored: yes" askauto $'y\n' BTRANSLATE_TEST_CERT=no
check "Installer: updates, n with one" "autoUpdate would be stored: no" askauto $'n\n' BTRANSLATE_TEST_CERT=yes
check "Installer: updates, the Y key in the Russian layout" "autoUpdate would be stored: yes" askauto $'н\n' BTRANSLATE_TEST_CERT=no BTRANSLATE_LANGUAGE=en
check "Installer: updates, wrong answers three times: nothing stored" "(No answer: nothing changed." askauto $'maybe\nperhaps\nlater\n' BTRANSLATE_TEST_CERT=no
check "Installer: updates, nothing asked when the setting is there already" "Nothing asked: the setting is there already." \
    askauto $'y\n' BTRANSLATE_TEST_CERT=no BTRANSLATE_TEST_AUTOUPDATE=0
check "Installer: updates, BTRANSLATE_AUTOUPDATE answers without asking" "autoUpdate would be stored: yes" \
    bash -c 'out="$(env BTRANSLATE_INSTALLER_TEST=autoupdate BTRANSLATE_AUTOUPDATE=YES ./install.sh < /dev/null 2>&1)"; [[ "$out" == *"[y/N]"* ]] && echo "ASKED: $out" || echo "$out"'
check "Installer: updates, keep (the app's own Update): nothing asked or stored" "nothing: yes" \
    bash -c '[ -z "$(printf "y\n" | env BTRANSLATE_INSTALLER_TEST=autoupdate BTRANSLATE_AUTOUPDATE=keep ./install.sh 2>&1)" ] && echo "nothing: yes"'
check "Installer: updates, said wrongly" "say yes or no" env BTRANSLATE_INSTALLER_TEST=autoupdate BTRANSLATE_AUTOUPDATE=maybe ./install.sh
check "Installer, in Russian: updates, with its own certificate" "Устанавливать обновления автоматически? [Д/н] autoUpdate would be stored: yes" \
    askauto $'д\n' BTRANSLATE_TEST_CERT=yes BTRANSLATE_LANGUAGE=ru
check "Installer, in Russian: updates, without one" "сочетания клавиш (tools/local-signing.sh не создал здесь сертификат)." \
    askauto $'\n' BTRANSLATE_TEST_CERT=no BTRANSLATE_LANGUAGE=ru
check "Installer, in Russian: the N key in the Russian layout says no" "autoUpdate would be stored: no" \
    askauto $'н\n' BTRANSLATE_TEST_CERT=yes BTRANSLATE_LANGUAGE=ru
check "Installer, in Russian: the Д key in a Latin layout says yes" "autoUpdate would be stored: yes" \
    askauto $'l\n' BTRANSLATE_TEST_CERT=no BTRANSLATE_LANGUAGE=ru
check "Installer, in Russian: a lone y (also the Н key in a Latin layout) is no answer, and it asks again" \
    $'Введите «да» или «нет».\nУстанавливать обновления автоматически? [Д/н] autoUpdate would be stored: no' \
    askauto $'y\nнет\n' BTRANSLATE_TEST_CERT=yes BTRANSLATE_LANGUAGE=ru
check "Installer, in Russian: Y three times turns nothing on" "(Ответа нет: ничего не изменено." \
    askauto $'Y\ny\nY\n' BTRANSLATE_TEST_CERT=yes BTRANSLATE_LANGUAGE=ru
check "Installer, in Russian: да says yes" "autoUpdate would be stored: yes" askauto $'да\n' BTRANSLATE_TEST_CERT=no BTRANSLATE_LANGUAGE=ru

# The language pack's detector of a text's language, on a made-up file of a few rows: the app
# must read it as the Python that wrote it does (tools/nllb/lid.py toy).
TOY_OUT="$("$BIN" --detect-check tests/detect-toy.json tests/detect-toy.bin 2>&1 || true)"
check "Detector: words, letter groups and packed numbers, read as the Python reads them" "detector: 9 of 9 texts" echo "$TOY_OUT"
check "Detector: its answers as shares, and the user's own languages counting for more" "counting for more: yes" echo "$TOY_OUT"
check "Detector: none without the language pack" "the language pack is not installed, or has no detector" "$BIN" --detect "Labdien"

# The language pack: downloaded from the mock server (a miniature one), checked and installed.
pack() { env BTRANSLATE_PACK_URL="$MOCK/$1" "$BIN" "${@:2}"; }
check "Language pack: not there to begin with" "language pack: not installed" "$BIN" --pack
check "Language pack: a damaged file is refused" "the file nllb200-v1-note.txt arrived damaged" pack pack-damaged --pack-install
check "Language pack: nothing at the address" "not at its address (HTTP 404)" pack nothing --pack-install
mkdir -p "$BTRANSLATE_PACK_DIR/incoming" && printf '<s>\t\n<pa' > "$BTRANSLATE_PACK_DIR/incoming/tokens.tsv"  # a download that stopped early
check "Language pack: downloaded, checked and installed" "language pack: installed" pack pack --pack-install
logged "Language pack: an unfinished file is gone on with, not begun anew" '"range": "bytes=8-".*nllb200-v1-tokens.tsv'
check "Language pack: there now" "language pack: installed, version 1, 2 languages" "$BIN" --pack
check "Language pack: the Languages page marks its languages" "lv installed" \
    "$BIN" --offline-uitest settings -googleEnabled YES -deviceEnabled YES -languages '(en, lv)' build/uitest
check "Language pack: removed" "language pack: removed" "$BIN" --pack-remove
check "Language pack: gone again" "language pack: not installed" "$BIN" --pack

# The shortcut: as the settings keep it, and its page of the settings.
T=(-googleEnabled YES -aiEnabled NO -defaultEngine google -languages '(en, ru, lv)' -defaultLanguage ru "${NONE[@]}" -setupDone YES)
check "Shortcut: ⌃⌥T as the settings keep it" 'shortcut: ⌃⌥T (kept as "control+option+17")' "$BIN" -shortcut "control+option+17" --shortcut-check
check "Shortcut: macOS takes one and lets it go" $'macOS takes a shortcut: yes (⌃⌥⇧⌘F19)\nand lets it go: yes' "$BIN" -shortcut "control+option+17" --shortcut-check
check "Shortcut: another one from the settings" "shortcut: ⌃⌥⇧K" "$BIN" -shortcut "control+option+shift+40" --shortcut-check
check "Shortcut: none" "shortcut: none" "$BIN" -shortcut "" --shortcut-check
check "An option the app does not know ends it: no second BTranslate starts by mistake" "unknown option --no-such-option" "$BIN" --no-such-option
check "So does a mode without its value" "unknown option --login" "$BIN" --login
PAGE="$("$BIN" "${T[@]}" --shortcut-page --picture build/uitest 2>&1 || true)"
check "Shortcut's page: asks for the permission while there is none" "permission: asked for" echo "$PAGE"
check "Shortcut's page: a click and three keys record one" 'recorded: ⌃⌥⇧K (kept as "control+option+shift+40")' echo "$PAGE"
check "Shortcut's page: a letter alone is not taken, and ⌫ takes the shortcut away" $'a letter alone: still waiting\nafter ⌫: None' echo "$PAGE"
check "Shortcut's page: every text fits" "every text of the page fits: yes" echo "$PAGE"
check "Shortcut's page: with the permissions, and opening at login" $'permission: given\npermission for a window\'s picture: given\nopens at login: ticked' \
    env BTRANSLATE_ACCESSIBILITY=on BTRANSLATE_SCREEN=on BTRANSLATE_LOGIN=on "$BIN" "${T[@]}" --shortcut-page
check "Shortcut's page: asks for the permission to record the screen too" "permission for a window's picture: asked for" echo "$PAGE"
check "Shortcut's page: on a first setup, opening at login is ticked" "opens at login: ticked" "$BIN" "${T[@]}" -setupDone NO --shortcut-page
check "Login item: read and set (a stand-in for macOS's list)" "opens at login: yes" "$BIN" --login on
check "Shortcut's page, in Russian: every text fits" "every text of the page fits: yes" \
    env BTRANSLATE_LANGUAGE=ru "$BIN" "${T[@]}" --shortcut-page --picture build/uitest-ru

# Typing in another language: the panel off screen, with a stand-in for the other app's text
# field. The text is typed in two goes, its first sentence and then all of it.
typing() { env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" "$@" 2>&1 || true; }
MODEL=(BTRANSLATE_PROVIDER=anthropic BTRANSLATE_BASE_URL="$MOCK/anthropic" BTRANSLATE_API_KEY=test-key)  # an AI model to choose
TYPED="$(typing --type-check "A sentence of its own. And a second one?" --picture build/uitest)"
check "Typing: written into the field while it is typed" $'typed: A sentence of its own. \n   in the field: EN:A sentence of its own. ; the panel shows: (nothing); live' echo "$TYPED"
check "Typing: Return keeps it" "after Return: panel closed, in the field: EN:A sentence of its own. EN:And a second one?, pasted: (nothing)" echo "$TYPED"
check "Typing: a finished sentence is translated once" "seen 1 time(s)" seen '"q": "A sentence of its own."'
check "Typing: every text of the panel fits" "every text of the panel fits: yes" echo "$TYPED"
check "Typing: the language chosen in the panel" "in the field: LV:Hello" typing --to Latvian --type-check "Hello"
check "Typing: the panel opens with the language of the settings" "writes in: lv" typing -typingLanguage lv --type-check "Hello"
check "Typing: and with the second default while none is set" "writes in: en" typing --type-check "Hello"
check "Typing: the panel opens with the popup's method while none is set for it" "translates with: google" typing --type-check "Hello"
check "Typing: and with the one of the settings" $'translates with: ai\ntyped: Good morning.\n   in the field: Hello! How are you? / Second line.' \
    env "${MODEL[@]}" BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" -typingEngine ai --type-check "Good morning."
check "Typing: one that can't be used now gives way to the popup's" "translates with: google" typing -typingEngine ai --type-check "Hello"
check "Typing: another method chosen in the panel translates what is typed anew" \
    $'   in the field: EN:Good morning.; the panel shows: (nothing); live\nwith ai:\n   in the field: Hello! How are you? / Second line.' \
    env "${MODEL[@]}" BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" --with ai --type-check "Good morning."
check "Typing: Esc takes it back out" "after Esc: panel closed, in the field: (nothing)" typing --esc --type-check "Good morning."
NOFIELD="$(typing --field none --type-check "Good morning." --picture build/uitest)"
check "Typing: a field that can't be written into: the panel shows the translation" "in the field: (nothing); the panel shows: EN:Good morning.; atEnd" echo "$NOFIELD"
check "Typing: and Return pastes it" "after Return: panel closed, in the field: (nothing), pasted: EN:Good morning." echo "$NOFIELD"
check "Typing: a field that stops taking text: Return copies the translation" "copied: EN:Good morning. EN:How are you?" \
    typing --field stuck --type-check "Good morning. How are you?"
check "Typing: a click elsewhere ends the panel, and pastes and copies nothing" \
    "after a click elsewhere: panel closed, in the field: (nothing), pasted: (nothing), copied: (nothing)" \
    typing --field none --click --type-check "Good morning."
check "Typing: a click elsewhere keeps what is written there" "after a click elsewhere: panel closed, in the field: EN:Good morning., pasted: (nothing)" \
    typing --click --type-check "Good morning."
check "Typing: Esc while a text is on its way into a slow field takes that out too" \
    $'Esc while the text is on its way: yes\nafter Esc: panel closed, in the field: (nothing)' \
    typing --field slow --esc-early --type-check "Good morning."
check "Typing: without a translation the panel says why, and Return does not close it" \
    $'the panel shows: No internet connection.; live\nhint: ↩ done   ⎋ take it back\nafter Return: panel STILL OPEN' \
    env BTRANSLATE_GOOGLE_URL="$DEAD" "$BIN" "${T[@]}" -deviceEnabled NO --type-check "Good morning."
check "Typing, in Russian: every text of the panel fits" "every text of the panel fits: yes" \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" --field none --type-check "Good morning." --picture build/uitest-ru

# A window, translated: a picture that stands for a window (a heading, a paragraph, a list on
# a dark side bar, buttons, lines in Latvian, Serbian and Russian) is read by macOS,
# translated and painted over. The mock translator takes Cyrillic letters for Russian.
"$BIN" --picture-make build/uitest/window.png || true
PICTURE="$(typing --picture-check build/uitest/window.png --picture build/uitest)"
check "Picture: a paragraph's lines are read as one text" "lines) The quick brown fox" echo "$PICTURE"
check "Picture: the rows of a list are texts of their own" $'\n   Bearbeiten → RU2:Bearbeiten\n' echo "$PICTURE"
check "Picture: a text already in that language stays as it is" "Сегодня хорошая погода = stays" echo "$PICTURE"
check "Picture: numbers and signs are left alone" "= no words" echo "$PICTURE"
check "Picture: the translations are painted over the originals" "texts painted over" echo "$PICTURE"
logged "Picture: all its texts go to Google in one request" '"q": \["'
check "Picture: by an AI model, as numbered lines; a text the model leaves out is counted" \
    "not translated: 1 (The model left some texts out of its answer.)" \
    env "${MODEL[@]}" "$BIN" "${T[@]}" --picture-check build/uitest/window.png --engine ai
# Offline. How many of the picture's texts can't be translated depends on the Mac: on what its
# reader makes of the letters, and on what its recognizer takes each text for. So the checks
# hold what does not: the first such text says why, and the texts after it are translated.
OFFPIC="$("$BIN" "${T[@]}" -deviceEnabled YES -recentSources '()' --picture-check build/uitest/window.png --engine device 2>&1 || true)"
check "Picture: offline, each text is translated from its own language" \
    $'   Welcome back → OFFLINE en>ru: Welcome back\n   Datei öffnen → OFFLINE de>ru: Datei öffnen' echo "$OFFPIC"
check "Picture: offline, a text in a language it has not got says so" "(This offline translation needs the NLLB-200 language pack (" echo "$OFFPIC"
check "Picture: offline, and the texts after that one are translated all the same" "   Save changes → OFFLINE en>ru: Save changes" echo "$OFFPIC"
# A page of hundreds of texts (the one the reader of pictures is made ready with). The mock
# server's "slow" addresses take a third of a second over each request and write down how
# many they were answering at once.
"$BIN" --picture-make build/uitest/many.png --many || true
MANY="$(env BTRANSLATE_GOOGLE_URL="$MOCK/googleslow" "$BIN" "${T[@]}" --picture-check build/uitest/many.png --to lv 2>&1 || true)"
check "Picture: a page of hundreds of texts is read and translated" "with words; into lv by google" echo "$MANY"
logged "Picture: its requests go to Google three at a time" '"path": "googleslow", "together": 3'
check "Picture: and never more than three" "seen 0 time(s)" seen '"path": "googleslow", "together": \([4-9]\|[1-9][0-9]\)'
env "${MODEL[@]}" BTRANSLATE_BASE_URL="$MOCK/anthropicslow" "$BIN" "${T[@]}" --picture-check build/uitest/many.png --engine ai --to lv > /dev/null 2>&1 || true
logged "Picture: its requests go to an AI provider four at a time" '"path": "anthropicslow", "together": 4'
check "Picture: and never more than four" "seen 0 time(s)" seen '"path": "anthropicslow", "together": \([5-9]\|[1-9][0-9]\)'
env BTRANSLATE_KEYCHAIN=off BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" -aiEnabled YES -aiProvider custom -aiBaseURL "$MOCK/openaislow" \
    --picture-check build/uitest/many.png --engine ai --to lv > /dev/null 2>&1 || true
logged "Picture: to a server of your own, one at a time" '"path": "openaislow", "together": 1'
check "Picture: and never two" "seen 0 time(s)" seen '"path": "openaislow", "together": \([2-9]\|[1-9][0-9]\)'
WINDOW="$(typing --picture-window-check build/uitest/window.png --picture build/uitest)"
check "Picture: its window, read in a process of its own" "the bar says: Translation into Russian" echo "$WINDOW"
check "Gear of the translated window, while a version waits" "$WAITING_GEAR" \
    env BTRANSLATE_UPDATE_WAITING=9.9.9 BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" --picture-window-check build/uitest/window.png
check "Picture: every text of its window fits" "every text of the window fits: yes" echo "$WINDOW"
check "Picture: while none is set for a window, it is the popup's method and the default language" "by google into ru" echo "$WINDOW"
CHOSEN="$(env "${MODEL[@]}" BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" -windowEngine ai -windowLanguage lv \
    --picture-window-check build/uitest/window.png --then google 2>&1 || true)"
check "Picture: its window opens with the method and the language of the settings" "by ai into lv" echo "$CHOSEN"
check "Picture: another method chosen in its bar translates the texts anew" "by google into lv" echo "$CHOSEN"
check "Picture: the bar names the language" "the bar says: Translation into Latvian" echo "$CHOSEN"
# A window as tall as the screen (here: taller than any): its picture is shown smaller, so that
# the bar under it, with the selectors, stays on the screen.
sips -z 4000 1800 build/uitest/window.png --out build/uitest/window-tall.png > /dev/null 2>&1 || true
check "Picture: under the picture of a window as tall as the screen, the bar stays on the screen" "the window is on its screen, bar and all: yes" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" --picture-window-check build/uitest/window-tall.png
# The picture of a narrow window gets a window wide enough for its bar; the Russian one is the widest.
sips -c 1040 560 build/uitest/window.png --out build/uitest/window-narrow.png > /dev/null 2>&1 || true
check "Picture: the bar fits under a narrow window's picture too" "every text of the window fits: yes" \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" --picture-window-check build/uitest/window-narrow.png --picture build/uitest/narrow
check "Picture: no connection is said in its window" "the bar says: No internet connection." \
    env BTRANSLATE_GOOGLE_URL="$DEAD" "$BIN" "${T[@]}" --picture-window-check build/uitest/window.png
check "Picture, in Russian: its window" "the bar says: Перевод на русский" \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" --picture-window-check build/uitest/window.png --picture build/uitest-ru
# Selecting and copying its texts: the steps of --act go to the window as the mouse's and the
# keys' events would, and what would be copied is printed: nothing reaches the clipboard. The
# checks hold texts every macOS reads alike, and never how many texts the picture has.
act() { local steps="$1"; shift; typing --picture-window-check build/uitest/window.png --act "$steps" "$@"; }
CLICK="$(act "click Welcome back; highlight; copy; click nothing; copy")"
check "Picture, selecting: a click on a text selects it, and the bar says so" \
    $'» click Welcome back\nselected: Welcome back; the bar says now: Selected: 1. ⌘C copies the text.' echo "$CLICK"
check "Picture, selecting: its highlight lies over the text" $'» highlight\nthe highlight lies over each selected text: yes' echo "$CLICK"
check "Picture, copying: ⌘C copies the selected text's translation" $'» copy\ncopied the text: RU2:Welcome back\n' echo "$CLICK"
check "Picture, selecting: a click where there is no text selects nothing" $'» click nothing\nselected: (nothing);' echo "$CLICK"
check "Picture, copying: with nothing selected, ⌘C copies the picture" $'» copy\ncopied the picture' echo "$CLICK"
DRAG="$(act "drag Datei öffnen .. Hilfe; copy")"
check "Picture, selecting: a drag shows its rectangle and selects what it touches, while it is dragged" \
    "while it is dragged: its rectangle shows: yes; selected: Datei öffnen / Bearbeiten / Einstellungen / Hilfe"$'\n' echo "$DRAG"
check "Picture, copying: the rows of the side bar, from the top down, one to a line" \
    "copied the text: RU2:Datei öffnen | RU2:Bearbeiten | RU2:Einstellungen | RU2:Hilfe"$'\n' echo "$DRAG"
SHIFT="$(act "click Welcome back; shift-click Save changes; shift-click Welcome back; cmd-click Bearbeiten; copy button")"
check "Picture, selecting: ⇧-click adds a text" $'» shift-click Save changes\nselected: Welcome back / Save changes;' echo "$SHIFT"
check "Picture, selecting: ⇧-click on a selected text takes it out" $'» shift-click Welcome back\nselected: Save changes;' echo "$SHIFT"
check "Picture, selecting: ⌘-click adds a text, in reading order" $'» cmd-click Bearbeiten\nselected: Bearbeiten / Save changes;' echo "$SHIFT"
check "Picture, copying: the Copy button copies the selection" $'» copy button\ncopied the text: RU2:Bearbeiten | RU2:Save changes\n' echo "$SHIFT"
check "Picture, selecting: ⌘A selects every text, none of them twice" "every text selected, none twice: yes" act "select all"
ORIGINAL="$(act "click Welcome back; original; copy; menu Welcome back; original; menu Welcome back; choose Copy the Original; menu Сегодня; copy")"
check "Picture, copying: with Original on, the same selection gives the original" \
    $'Original: on\nselected: Welcome back; the bar says now: Selected: 1. ⌘C copies the text.; the window: open\n» copy\ncopied the text: Welcome back\n' echo "$ORIGINAL"
check "Picture, the menu: with Original on, it offers the translation" "menu: Copy | Copy the Translation | Select All" echo "$ORIGINAL"
check "Picture, the menu: over the translations, it offers the original" "menu: Copy | Copy the Original | Select All" echo "$ORIGINAL"
check "Picture, the menu: Copy the Original" $'» choose Copy the Original\ncopied the text: Welcome back\n' echo "$ORIGINAL"
check "Picture, the menu: a text that stayed as it was has no other version to offer" "menu: Copy | Select All" echo "$ORIGINAL"
check "Picture, copying: a text that stayed as it was is copied as it is" $'» copy\ncopied the text: Сегодня хорошая погода\n' echo "$ORIGINAL"
check "Picture, selecting: Esc takes the selection away and leaves the window; Esc again closes it" \
    $'» esc\nselected: (nothing); the bar says now: Translation into Russian; the window: open\n» esc\nselected: (nothing); the bar says now: Translation into Russian; the window: closed' \
    act "click Welcome back; esc; esc"
check "Picture, selecting: the selection stays when another method translates the window anew" \
    $'by google into ru\n» copy\ncopied the text: RU2:Welcome back\nselected: Welcome back;' \
    env "${MODEL[@]}" BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" -windowEngine ai \
    --picture-window-check build/uitest/window.png --act "click Welcome back; method google; copy"
check "Picture, selecting: the highlights follow the window when it is made smaller" $'» highlight\nthe highlight lies over each selected text: yes' \
    act "click Welcome back; shift-click Hilfe; size 520x360; highlight"
# A window taller than its picture has room above and below it, a wider one left and right: the
# picture is centred, and a text is found and highlighted where it is drawn, not where it would be
# at the window's top left corner.
TALL="$(act "size 700x560; click Welcome back; shift-click Hilfe; highlight")"
check "Picture, selecting: in a window taller than its picture, the picture has room above and below" "margins: above and below" echo "$TALL"
check "Picture, selecting: and the highlights lie over its texts" $'» highlight\nthe highlight lies over each selected text: yes' echo "$TALL"
WIDE="$(act "size 900x300; click Save changes; shift-click Datei öffnen; highlight")"
check "Picture, selecting: in a window wider than its picture, the picture has room left and right" "margins: left and right" echo "$WIDE"
check "Picture, selecting: and a click finds its texts" $'» shift-click Datei öffnen\nselected: Datei öffnen / Save changes;' echo "$WIDE"
check "Picture, selecting: and the highlights lie over them" $'» highlight\nthe highlight lies over each selected text: yes' echo "$WIDE"
# Where nothing could be translated, the texts can still be selected, and are copied as they
# are; and the error stays in the bar: the selection and a copy do not take its place.
FAILED="$(env BTRANSLATE_GOOGLE_URL="$DEAD" "$BIN" "${T[@]}" --picture-window-check build/uitest/window.png --act "click Welcome back; copy" 2>&1 || true)"
check "Picture, selecting: with no connection, its texts can be selected, and the error stays in the bar, in red" \
    $'» click Welcome back\nselected: Welcome back; the bar says now: No internet connection. (in red);' echo "$FAILED"
check "Picture, copying: with no connection, a text is copied as it is, and the error still stays" \
    $'» copy\ncopied the text: Welcome back\nselected: Welcome back; the bar says now: No internet connection. (in red);' echo "$FAILED"
SELECTED="$(act "drag Datei öffnen .. Hilfe; shift-click Welcome back" --picture build/uitest/selected)"
check "Picture, selecting: drawn with a selection, every text of the window fits" "every text of the window fits: yes" echo "$SELECTED"
check "Picture, selecting: drawn with a selection, the window is on its screen" "the window is on its screen, bar and all: yes" echo "$SELECTED"
check "Picture, selecting, in Russian: every text of the window fits" "every text of the window fits: yes" \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" --picture-window-check build/uitest/window.png \
    --act "drag Datei öffnen .. Hilfe; shift-click Welcome back" --picture build/uitest-ru/selected

if [ "${1:-}" = "--live" ]; then
    check "Google, live" "source: Latvian" env -u BTRANSLATE_CONNECTION "$BIN" --print --engine google "Labdien! Kā jums klājas?"
    check "Keychain, live" "keychain: ok" env -u BTRANSLATE_KEYCHAIN "$BIN" --keychain-test
    check "BTranslate's language, live: chosen and read back" "language choice: ok" "$BIN" --language-test
    if env -u BTRANSLATE_OFFLINE "$BIN" --offline de en | grep -q "de → en: installed"; then
        check "Offline method, live: Apple's translation on this Mac" "source: German" \
            env -u BTRANSLATE_OFFLINE "$BIN" --print --engine device --to en "Guten Tag! Wie geht es Ihnen heute?"
        check "Offline method, live: the Download button's way to macOS" "download check: ok" env -u BTRANSLATE_OFFLINE "$BIN" --download-check
    else
        echo "skip  Offline method, live (this Mac has not got German and English for it)"
    fi
    # The real language pack, if you have installed it: its tokenizer against Meta's, and one
    # translation on the Neural Engine, after which the model must be gone from memory.
    if env -u BTRANSLATE_PACK_DIR "$BIN" --pack | grep -q "language pack: installed"; then
        PACK_OUT="$(env -u BTRANSLATE_PACK_DIR -u BTRANSLATE_OFFLINE "$BIN" --pack-check tests/nllb-tokens.json 2>&1 || true)"
        check "Language pack, live: the tokenizer agrees with Meta's" "tokenizer: 60 of 60 texts" echo "$PACK_OUT"
        check "Language pack, live: a translation on the Neural Engine" "Здравствуйте" echo "$PACK_OUT"
        check "Language pack, live: the model is let go after the translation" "model let go after the translation: yes" echo "$PACK_OUT"
        check "Language pack, live: Serbian through the Offline method" "source: Serbian" \
            env -u BTRANSLATE_PACK_DIR -u BTRANSLATE_OFFLINE "$BIN" --print --engine device --to ru "Јуче смо били на пијаци и купили свеже воће."
        # Its detector: the arithmetic against the Python's, and languages the Mac's own
        # recognizer does not know (it takes Persian for Arabic and Tajik for Bulgarian).
        # (With a list of languages of the test's own: yours would have a say in the answers.)
        live() { env -u BTRANSLATE_PACK_DIR -u BTRANSLATE_OFFLINE "$BIN" -languages '(en, ru)' -recentSources '()' "$@"; }
        check "Detector, live: the pack's file, read as the Python reads it" "detector: 69 of 69 texts" live --detect-check tests/detect-vectors.json
        check "Detector, live: Persian" "taken for: Persian" live --detect "فردا از ساعت نه تا پنج در دفتر خواهم بود."
        check "Detector, live: Tajik" "taken for: Tajik" live --detect "Пагоҳ ман аз соати нӯҳ то панҷ дар идора хоҳам буд."
        check "Detector, live: a notice in capitals" "taken for: Latvian" live --detect "SMĒĶĒT AIZLIEGTS! LŪDZU, IZMANTOJIET CITU IEEJU."
        check "Detector, live: two words that are Lombard to the detector alone" "taken for: English" live --detect "Sign in"
        check "Detector, live: one word is too little to be sure, and the popup says what it may be" "it may be English" \
            live --print --engine device --to ru "hello"
        check "Detector, live: a text of digits is nobody's" "the popup would ask" live --detect "12345 !!!"
        check "Detector, live: Persian through the Offline method" "source: Persian" \
            live --print --engine device --to en "فردا از ساعت نه تا پنج در دفتر خواهم بود."
    else
        echo "skip  Language pack, live (it is not installed on this Mac)"
    fi
fi

if [ "${1:-}" = "--screen" ]; then
    check "On screen: focus, typing, picking and adding a language" "screen check: ok" "$BIN" --screen-check
fi

[ "$failed" = 0 ] && echo "All tests passed." || { echo "Some tests failed."; exit 1; }
