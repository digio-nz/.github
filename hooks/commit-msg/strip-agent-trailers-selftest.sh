#!/usr/bin/env bash
# Offline proof for hooks/commit-msg/strip-agent-trailers.sh: agent trailers go, human
# trailers and the message body stay, and no temp file is left behind.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd -P)/strip-agent-trailers.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passes=0 failures=0
pass() { printf 'ok: %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# case <name> <input> <expected>
case_() {
  local name="$1" input="$2" expected="$3" msg="$tmp/$1.msg"
  printf '%s' "$input" > "$msg"
  sh "$HOOK" "$msg"
  if [ "$(cat "$msg")" = "$expected" ]; then pass "$name"; else fail "$name: got [$(cat "$msg")]"; fi
}

case_ "a Claude co-author trailer is removed" \
  $'fix: thing\n\nBody.\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' \
  $'fix: thing\n\nBody.'
case_ "any case and a session trailer are removed" \
  $'fix: thing\n\nco-authored-by: claude opus\nClaude-Session: abc123\n' \
  $'fix: thing'
case_ "a human co-author trailer stays" \
  $'fix: thing\n\nCo-Authored-By: Ada Lovelace <ada@example.com>\nCo-Authored-By: Claude <x@y>\n' \
  $'fix: thing\n\nCo-Authored-By: Ada Lovelace <ada@example.com>'
case_ "a message with no trailer is unchanged" \
  $'docs: one line\n\nTwo paragraphs.\n\nStill here.' \
  $'docs: one line\n\nTwo paragraphs.\n\nStill here.'
case_ "a body line mentioning Claude mid-sentence stays" \
  $'chore: x\n\nAsked Claude-Session handling to move.\n' \
  $'chore: x\n\nAsked Claude-Session handling to move.'

if sh "$HOOK" "$tmp/does-not-exist"; then pass "a missing message file is a clean no-op"; else fail "a missing message file failed"; fi
if [ -z "$(find "$tmp" -name '*.strip-agent-trailers.*')" ]; then pass "no temp file is left behind"; else fail "a temp file was left behind"; fi

printf '\nstrip-agent-trailers selftest: %d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
