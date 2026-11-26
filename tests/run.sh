#!/usr/bin/env bash
# BTranslate's tests. They need no network and no API key: the app's own checks first, then
# both AI protocols and the Google fallback against tests/mock_server.py, then the popup and
# the settings window drawn off screen (into build/uitest).
#   tests/run.sh          build if needed, then test
#   tests/run.sh --live   also use the real Google Translate (one sentence) and the real
#                         Keychain (a dummy key is saved, read and deleted)
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
logged "Anthropic: prompt names the script" 'Serbian, written in the Latin script'

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
check "Google: Serbian in Latin script" "EN:Dobar dan" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --print --engine google --to "Serbian (Latin)" "Добар дан"

check "Popup and settings draw off screen; the popup stays where it was moved" "popup stays where it was moved: yes" \
    env BTRANSLATE_GOOGLE_URL="$MOCK/google" "$BIN" --uitest build/uitest

if [ "${1:-}" = "--live" ]; then
    check "Google, live" "source: Latvian" "$BIN" --print --engine google "Labdien! Kā jums klājas?"
    check "Keychain, live" "keychain: ok" "$BIN" --keychain-test
fi

[ "$failed" = 0 ] && echo "All tests passed." || { echo "Some tests failed."; exit 1; }
