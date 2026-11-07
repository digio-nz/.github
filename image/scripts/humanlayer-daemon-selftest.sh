#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_DIR="$(mktemp -d)"
DAEMON_PID=""

cleanup() {
  if [ -n "$DAEMON_PID" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$DAEMON_PID" 2>/dev/null || break
      sleep 1
    done
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  echo "humanlayer daemon self-test failed: $*" >&2
  exit 1
}

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home"
cp "$DIR/humanlayer-daemon.sh" "$TEST_DIR/humanlayer-daemon.sh"
chmod +x "$TEST_DIR/humanlayer-daemon.sh"
# The fixture behaves like the CLI: a refused launch names why and exits 1; a launch holds the foreground until killed.
cat > "$TEST_DIR/bin/humanlayer" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$* self-update=${HUMANLAYER_DISABLE_SELF_UPDATE:-unset} cwd=$PWD" >> "$DAEMON_CALLS"
if [ -n "${HUMANLAYER_NOT_LOGGED_IN:-}" ]; then
  echo 'Failed to launch daemon: Not logged in. Run `humanlayer login` first, or pass --token.'
  exit 1
fi
echo "Exchanging token for daemon credentials..."
echo "Starting daemon..."
while true; do sleep 1; done
STUB
chmod +x "$TEST_DIR/bin/humanlayer"

export HOME="$TEST_DIR/home"
export PATH="$TEST_DIR/bin:$PATH"
export DAEMON_CALLS="$TEST_DIR/daemon-calls"
touch "$DAEMON_CALLS"
export HUMANLAYER_DAEMON_START_TIMEOUT_SECONDS=5
export HUMANLAYER_DAEMON_PROC_ROOT="$TEST_DIR/no-proc"
state="$HOME/.local/state/digio-workbench"

if bash "$TEST_DIR/humanlayer-daemon.sh" check > "$TEST_DIR/out" 2>&1; then
  fail "check reported a daemon before any start"
fi
grep -Fq 'not running' "$TEST_DIR/out" || fail "check did not say the daemon is not running: $(cat "$TEST_DIR/out")"

if HUMANLAYER_NOT_LOGGED_IN=1 bash "$TEST_DIR/humanlayer-daemon.sh" start > "$TEST_DIR/out" 2>&1; then
  fail "start exited 0 when the launch was refused"
fi
grep -Fq 'Not logged in' "$TEST_DIR/out" || fail "the refused start did not name the reason: $(cat "$TEST_DIR/out")"
[ ! -e "$state/humanlayer-daemon.pid" ] || fail "the refused start left a pid file"

output="$(env -u CLAUDE_CODE_OAUTH_TOKEN bash "$TEST_DIR/humanlayer-daemon.sh" start 2>"$TEST_DIR/err")" || fail "the start failed: $output"
grep -Fq 'no CLAUDE_CODE_OAUTH_TOKEN' "$TEST_DIR/err" || fail "the start did not warn that Claude sessions will not be logged in: $(cat "$TEST_DIR/err")"
DAEMON_PID="$(cat "$state/humanlayer-daemon.pid")"
[[ "$output" == *"HumanLayer daemon: started"* ]] || fail "the start was not reported: $output"
kill -0 "$DAEMON_PID" || fail "the daemon is not running after the start"
grep -Fxq "daemon launch --no-self-update self-update=1 cwd=$HOME" "$DAEMON_CALLS" \
  || fail "the start used the wrong launch command: $(cat "$DAEMON_CALLS")"

second_output="$(bash "$TEST_DIR/humanlayer-daemon.sh" start)" || fail "the repeated start failed"
kill "$DAEMON_PID"; for _ in 1 2 3 4 5; do kill -0 "$DAEMON_PID" 2>/dev/null || break; sleep 1; done
CLAUDE_CODE_OAUTH_TOKEN=fixture bash "$TEST_DIR/humanlayer-daemon.sh" start >/dev/null 2>"$TEST_DIR/err" || fail "the start with a token failed"
DAEMON_PID="$(cat "$state/humanlayer-daemon.pid")"
! grep -Fq 'no CLAUDE_CODE_OAUTH_TOKEN' "$TEST_DIR/err" || fail "the start warned although a Claude token was set"
second_output="$(bash "$TEST_DIR/humanlayer-daemon.sh" start)" || fail "the repeated start failed"
[ "$(cat "$state/humanlayer-daemon.pid")" = "$DAEMON_PID" ] || fail "the repeated start replaced the daemon"
[[ "$second_output" == *"HumanLayer daemon: already running"* ]] \
  || fail "the repeated start did not report the existing daemon"
[ "$(( $(grep -c "daemon launch" "$DAEMON_CALLS") ))" -eq 3 ] || fail "the repeated start launched again: $(cat "$DAEMON_CALLS")"

check_output="$(bash "$TEST_DIR/humanlayer-daemon.sh" check)" || fail "check failed while the daemon runs"
[[ "$check_output" == *"running (pid $DAEMON_PID)"* ]] || fail "check did not report the daemon: $check_output"

kill "$DAEMON_PID"
for _ in 1 2 3 4 5; do
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 1
done
DAEMON_PID=""
if bash "$TEST_DIR/humanlayer-daemon.sh" check > "$TEST_DIR/out" 2>&1; then
  fail "check reported a daemon after it exited"
fi

if bash "$TEST_DIR/humanlayer-daemon.sh" > "$TEST_DIR/out" 2>&1; then
  fail "a missing verb exited 0"
fi
grep -Fq 'humanlayer-daemon.sh start' "$TEST_DIR/out" || fail "a missing verb did not print the usage"

echo "humanlayer daemon self-test passed: start runs the daemon once, names a refused launch, and check reports it"
