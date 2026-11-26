#!/usr/bin/env bash
# BTranslate's tests. They need no network and no API key: the app's own checks first, then
# both AI protocols and the Google fallback against tests/mock_server.py, then the popup and
# the settings window drawn off screen (into build/uitest).
#   tests/run.sh          build if needed, then test
#   tests/run.sh --live   also use the real Google Translate (one sentence) and the real
#                         Keychain (a dummy key is saved, read and deleted)
#   tests/run.sh --screen also show a popup on screen for a few seconds, to check what a
#                         picture can't: your app stays in front, typing reaches the pencil's
#                         search field, a second language joins the popup (needs a working
#                         translation method in Settings)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BIN=build/BTranslate.app/Contents/MacOS/BTranslate
[ -x "$BIN" ] || ./build.sh
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
check "UI, off screen: the list's arrows and Make Default" \
    "list buttons: en,ru,lv,sr-Latn default=ru → en,ru,sr-Latn,lv default=ru → en,ru,sr-Latn,lv default=sr-Latn → ru,en,sr-Latn,lv default=sr-Latn" echo "$UI_OUT"
check "UI, off screen: pictures written" "source-picker.png" ls build/uitest

if [ "${1:-}" = "--live" ]; then
    check "Google, live" "source: Latvian" "$BIN" --print --engine google "Labdien! Kā jums klājas?"
    check "Keychain, live" "keychain: ok" "$BIN" --keychain-test
fi

if [ "${1:-}" = "--screen" ]; then
    check "On screen: focus, typing, picking and adding a language" "screen check: ok" "$BIN" --screen-check
fi

[ "$failed" = 0 ] && echo "All tests passed." || { echo "Some tests failed."; exit 1; }
