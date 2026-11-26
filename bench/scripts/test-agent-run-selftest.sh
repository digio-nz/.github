#!/usr/bin/env bash
# Offline self-test of test-agent-run.sh, with a stub of docker.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$DIR/test-agent-run.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
passes=0 failures=0
pass() { echo "ok: $1"; passes=$((passes + 1)); }
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

mkdir -p "$TEST_DIR/bin"
# The stub answers as a running bench. CLAUDE_FAIL is a part of the email of each person whose run fails, and NOT_RUNNING a stopped container.
cat > "$TEST_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$CALLS"
case "$1" in
  inspect) [ "${*: -1}" = "${NOT_RUNNING:-}" ] && echo false || echo true ;;
  exec)
    shift 4
    case "$1 $3" in
      "bash host") [ "$5" != https://refused.example ] ;;
      "bash people") printf 'one@example.com\ntwo@example.com\n' ;;
      "claude "*)
        for word in "$@"; do case "$word" in *"person "*"${CLAUDE_FAIL:-none}"*) echo "usage limit" >&2; exit 1 ;; esac; done
        printf '%s\n' '{"type":"system"}' '{"type":"result","result":"# Report\nline two"}' ;;
    esac ;;
  cp) mkdir -p "$3" ;;
esac
STUB
chmod +x "$TEST_DIR/bin/docker"
export PATH="$TEST_DIR/bin:$PATH" CALLS="$TEST_DIR/calls" TEST_AGENT_RUN_PAUSE=0

run() { : > "$CALLS"; RESULTS="$TEST_DIR/$1" bash "$SCRIPT" "${@:2}" > "$TEST_DIR/out" 2>&1; }

ROUNDS=2 run two demo https://ok.example 1; code=$?
[ "$code" = 0 ] && pass "two rounds with reports exit 0" || fail "a good run gave exit $code: $(cat "$TEST_DIR/out")"
[ -e "$TEST_DIR/two/r02-two.md" ] && [ ! -e "$TEST_DIR/two/r03-one.md" ] \
  && pass "ROUNDS stops after that many rounds" || fail "ROUNDS did not stop the runs: $(ls "$TEST_DIR/two")"
[ "$(cat "$TEST_DIR/two/r01-one.md")" = $'# Report\nline two' ] && pass "the report is the result of the session" || fail "the report is [$(cat "$TEST_DIR/two/r01-one.md")]"
grep -q '^| 1 | one@example.com | .* | 0 | # Report |$' "$TEST_DIR/two/index.md" && pass "the index has a row for each run" || fail "the index: $(cat "$TEST_DIR/two/index.md")"
[ -d "$TEST_DIR/two/browser-output" ] && pass "the output of test-browser is copied" || fail "no browser-output folder"

ROUNDS=1 run skip demo https://ok.example 1 vacation
grep -q 'Skip the feature: vacation\.' "$CALLS" && pass "the task names the feature to skip" || fail "the task has no skip: $(grep claude "$CALLS")"

ROUNDS=1 CLAUDE_FAIL=two run onefails demo https://ok.example 1; code=$?
[ "$code" = 1 ] && grep -q 'FAIL: test-agent-run: r01-two exited 1 with no report' "$TEST_DIR/out" \
  && pass "a failed run exits 1 and names the run" || fail "a failed run gave exit $code: $(cat "$TEST_DIR/out")"

ROUNDS=5 CLAUDE_FAIL=@ run allfail demo https://ok.example 1; code=$?
[ "$code" = 1 ] && grep -q 'three runs in a row failed' "$TEST_DIR/out" && [ ! -e "$TEST_DIR/allfail/r03-one.md" ] \
  && pass "three failed runs in a row stop the runs" || fail "the runs did not stop: exit $code: $(cat "$TEST_DIR/out")"

NOT_RUNNING=test-bench-test-browser-1 run stopped demo https://ok.example 1; code=$?
[ "$code" = 1 ] && grep -q 'test-bench-test-browser-1 is not running' "$TEST_DIR/out" && pass "a stopped container stops the start" || fail "exit $code: $(cat "$TEST_DIR/out")"

run refused demo https://refused.example 1; code=$?
[ "$code" = 1 ] && grep -q 'refuses https://refused.example' "$TEST_DIR/out" && ! grep -q ' claude -p' "$CALLS" \
  && pass "an address that the plan refuses starts no run" || fail "exit $code: $(cat "$TEST_DIR/out")"

run badhours demo https://ok.example 0; code=$?
[ "$code" = 2 ] && grep -q 'hours must be a number' "$TEST_DIR/out" && pass "hours of 0 is bad usage" || fail "exit $code: $(cat "$TEST_DIR/out")"

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
