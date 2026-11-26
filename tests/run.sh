#!/usr/bin/env bash
# BTranslate's tests. They need no network and no API key: the app's own checks first, then
# both AI protocols and the Google fallback against tests/mock_server.py, then the popup and
# the settings window drawn off screen (into build/uitest; in Russian into build/uitest-ru),
# then what the popup does without a connection.
#   tests/run.sh          build if needed, then test
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

BIN=build/BTranslate.app/Contents/MacOS/BTranslate
[ -x "$BIN" ] || ./build.sh
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
export BTRANSLATE_ACCESSIBILITY=off BTRANSLATE_LOGIN=off
DEAD="http://127.0.0.1:9"  # nothing listens there: a request ends as it does without internet
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
    -googleEnabled YES -defaultEngine google -languages '(en, ru, lv)' -defaultLanguage ru 2>&1 || true)"
check "UI, off screen: the popup stays where it was moved" "popup stays where it was moved: yes" echo "$UI_OUT"
check "UI, off screen: the picker adds a language" "picker adds a language to the list: yes" echo "$UI_OUT"
check "UI, off screen: the pencil's picker searches" "source picker finds: ltg, la, lv" echo "$UI_OUT"
check "UI, off screen: the original's language set by hand" "the original's language can be set by hand: yes" echo "$UI_OUT"
check "UI, off screen: the popup opens with the default language" "popup text: RU:" echo "$UI_OUT"
check "UI, off screen: several languages at once" "several languages at once: yes (ru, en, lv)" echo "$UI_OUT"
check "UI, off screen: the list's arrows, Make Default and Make Second" \
    "list buttons: en,ru,lv,sr-Latn default=ru second=en → en,ru,sr-Latn,lv default=ru second=en → en,ru,sr-Latn,lv default=sr-Latn second=en → ru,en,sr-Latn,lv default=sr-Latn second=en → ru,en,sr-Latn,lv default=sr-Latn second=lv" echo "$UI_OUT"
check "UI, off screen: pictures written" "source-picker.png" ls build/uitest
check "UI, off screen: every text of the settings window fits" "settings window, every text fits: yes" echo "$UI_OUT"
check "UI, off screen: the menu of BTranslate's own language" "language menu: the Mac's, en, ru" echo "$UI_OUT"

# The same in Russian: longer words in the same windows.
UI_RU="$(env BTRANSLATE_LANGUAGE=ru BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --uitest build/uitest-ru \
    -AppleLanguages '(ru)' -googleEnabled YES -defaultEngine google -languages '(en, ru, lv)' -defaultLanguage ru 2>&1 || true)"
check "UI in Russian: it is in Russian" "interface language: ru" echo "$UI_RU"
check "UI in Russian: every text of the settings window fits" "settings window, every text fits: yes" echo "$UI_RU"
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
SET_OUT="$("$BIN" --offline-uitest settings -googleEnabled YES -deviceEnabled YES -languages '(en, ru, fr, lv)' -defaultLanguage ru build/uitest 2>&1 || true)"
check "Settings: which languages work without internet" "offline marks: en installed, ru installed, fr downloadable, lv downloadable" echo "$SET_OUT"
check "Settings: Download is offered for the languages that need one" "Download offered: en no, ru no, fr yes, lv yes" echo "$SET_OUT"
check "Settings, with the offline marks: every text fits" "settings window, every text fits: yes" echo "$SET_OUT"
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
"$BIN" --pack-remove > /dev/null

# The installer's question about the language pack: its step alone, for the app just built.
INST=(BTRANSLATE_INSTALLER_TEST=pack BTRANSLATE_TEST_APP="$PWD/build/BTranslate.app")
check "Installer: the language pack, wanted" "The language pack is installed." \
    env "${INST[@]}" BTRANSLATE_PACK=yes BTRANSLATE_PACK_URL="$MOCK/pack" ./install.sh
"$BIN" --pack-remove > /dev/null
check "Installer: the language pack, not wanted" "The language pack is not installed. To get it later: BTranslate's settings → Translation → Download (906 MB)." \
    env "${INST[@]}" BTRANSLATE_PACK=no ./install.sh
check "Installer: the language pack is not at its address" "It may not be published yet." \
    env "${INST[@]}" BTRANSLATE_PACK=yes BTRANSLATE_PACK_URL="$MOCK/nothing" ./install.sh
check "Installer, in Russian: the language pack" "Языковой пакет установлен." \
    env "${INST[@]}" BTRANSLATE_LANGUAGE=ru BTRANSLATE_PACK=yes BTRANSLATE_PACK_URL="$MOCK/pack" ./install.sh
"$BIN" --pack-remove > /dev/null

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
T=(-googleEnabled YES -defaultEngine google -languages '(en, ru, lv)' -defaultLanguage ru -typingLanguage none -setupDone YES)
check "Shortcut: ⌃⌥T unless another is set" 'shortcut: ⌃⌥T (kept as "control+option+17")' "$BIN" --shortcut-check
check "Shortcut: macOS takes one and lets it go" $'macOS takes a shortcut: yes (⌃⌥⇧⌘F19)\nand lets it go: yes' "$BIN" --shortcut-check
check "Shortcut: another one from the settings" "shortcut: ⌃⌥⇧K" "$BIN" -shortcut "control+option+shift+40" --shortcut-check
check "Shortcut: none" "shortcut: none" "$BIN" -shortcut "" --shortcut-check
PAGE="$("$BIN" "${T[@]}" --shortcut-page --picture build/uitest 2>&1 || true)"
check "Shortcut's page: asks for the permission while there is none" "permission: asked for" echo "$PAGE"
check "Shortcut's page: a click and three keys record one" 'recorded: ⌃⌥⇧K (kept as "control+option+shift+40")' echo "$PAGE"
check "Shortcut's page: a letter alone is not taken, and ⌫ takes the shortcut away" $'a letter alone: still waiting\nafter ⌫: None' echo "$PAGE"
check "Shortcut's page: every text fits" "every text of the page fits: yes" echo "$PAGE"
check "Shortcut's page: with the permission, and opening at login" $'permission: given\nopens at login: ticked' \
    env BTRANSLATE_ACCESSIBILITY=on BTRANSLATE_LOGIN=on "$BIN" "${T[@]}" --shortcut-page
check "Shortcut's page: on a first setup, opening at login is ticked" "opens at login: ticked" "$BIN" "${T[@]}" -setupDone NO --shortcut-page
check "Login item: read and set (a stand-in for macOS's list)" "opens at login: yes" "$BIN" --login on
check "Shortcut's page, in Russian: every text fits" "every text of the page fits: yes" \
    env BTRANSLATE_LANGUAGE=ru "$BIN" "${T[@]}" --shortcut-page --picture build/uitest-ru

# Typing in another language: the panel off screen, with a stand-in for the other app's text
# field. The text is typed in two goes, its first sentence and then all of it.
typing() { env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" "$@" 2>&1 || true; }
TYPED="$(typing --type-check "A sentence of its own. And a second one?" --picture build/uitest)"
check "Typing: written into the field while it is typed" $'typed: A sentence of its own. \n   in the field: EN:A sentence of its own. ; the panel shows: (nothing); live' echo "$TYPED"
check "Typing: Return keeps it" "after Return: panel closed, in the field: EN:A sentence of its own. EN:And a second one?, pasted: (nothing)" echo "$TYPED"
check "Typing: a finished sentence is translated once" "1" grep -c '"q": "A sentence of its own."' "$LOG"
check "Typing: every text of the panel fits" "every text of the panel fits: yes" echo "$TYPED"
check "Typing: the language chosen in the panel" "in the field: LV:Hello" typing --to Latvian --type-check "Hello"
check "Typing: Esc takes it back out" "after Esc: panel closed, in the field: (nothing)" typing --esc --type-check "Good morning."
NOFIELD="$(typing --field none --type-check "Good morning." --picture build/uitest)"
check "Typing: a field that can't be written into: the panel shows the translation" "in the field: (nothing); the panel shows: EN:Good morning.; atEnd" echo "$NOFIELD"
check "Typing: and Return pastes it" "after Return: panel closed, in the field: (nothing), pasted: EN:Good morning." echo "$NOFIELD"
check "Typing: a field that stops taking text: Return copies the translation" "copied: EN:Good morning. EN:How are you?" \
    typing --field stuck --type-check "Good morning. How are you?"
check "Typing: without a translation the panel says why, and Return does not close it" \
    $'the panel shows: No internet connection.; live\nhint: ↩ done   ⎋ take it back\nafter Return: panel STILL OPEN' \
    env BTRANSLATE_GOOGLE_URL="$DEAD" "$BIN" "${T[@]}" -deviceEnabled NO --type-check "Good morning."
check "Typing, in Russian: every text of the panel fits" "every text of the panel fits: yes" \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" --field none --type-check "Good morning." --picture build/uitest-ru

# A window, translated: a picture that stands for a window (a heading, a paragraph, a list on
# a dark side bar, buttons, lines in Latvian, Serbian and Russian) is read by macOS,
# translated and painted over. The mock translator takes Cyrillic letters for Russian.
"$BIN" --picture-make build/uitest/window.png
PICTURE="$(typing --picture-check build/uitest/window.png --picture build/uitest)"
check "Picture: a paragraph's lines are read as one text" "lines) The quick brown fox" echo "$PICTURE"
check "Picture: the rows of a list are texts of their own" $'\n   Bearbeiten → RU2:Bearbeiten\n' echo "$PICTURE"
check "Picture: a text already in that language stays as it is" "Сегодня хорошая погода = stays" echo "$PICTURE"
check "Picture: numbers and signs are left alone" "= no words" echo "$PICTURE"
check "Picture: the translations are painted over the originals" "texts painted over" echo "$PICTURE"
logged "Picture: all its texts go to Google in one request" '"q": \["'
check "Picture: by an AI model, as numbered lines; a text the model leaves out is counted" \
    "not translated: 1 (The model left some texts out of its answer.)" \
    env BTRANSLATE_PROVIDER=anthropic BTRANSLATE_BASE_URL="$MOCK/anthropic" BTRANSLATE_API_KEY=test-key \
    "$BIN" "${T[@]}" --picture-check build/uitest/window.png --engine ai
WINDOW="$(typing --picture-window-check build/uitest/window.png --picture build/uitest)"
check "Picture: its window, read in a process of its own" "the bar says: Translation into Russian" echo "$WINDOW"
check "Picture: every text of its window fits" "every text of the window fits: yes" echo "$WINDOW"
check "Picture: no connection is said in its window" "the bar says: No internet connection." \
    env BTRANSLATE_GOOGLE_URL="$DEAD" "$BIN" "${T[@]}" --picture-window-check build/uitest/window.png
check "Picture, in Russian: its window" "the bar says: Перевод на русский" \
    env BTRANSLATE_LANGUAGE=ru BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" "${T[@]}" --picture-window-check build/uitest/window.png --picture build/uitest-ru

if [ "${1:-}" = "--live" ]; then
    check "Google, live" "source: Latvian" "$BIN" --print --engine google "Labdien! Kā jums klājas?"
    check "Keychain, live" "keychain: ok" "$BIN" --keychain-test
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
