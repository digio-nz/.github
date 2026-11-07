#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_DIR="$(mktemp -d)"
SCHEDULER_PID=""

cleanup() {
  if [ -n "$SCHEDULER_PID" ]; then
    kill "$SCHEDULER_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$SCHEDULER_PID" 2>/dev/null || break
      sleep 1
    done
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  echo "session-export sweep self-test failed: $*" >&2
  exit 1
}

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home/.digio/skills/skills/session-export/scripts"
cp "$DIR/session-export-sweep.sh" "$TEST_DIR/session-export-sweep.sh"
chmod +x "$TEST_DIR/session-export-sweep.sh"
touch "$TEST_DIR/home/.digio/skills/skills/session-export/scripts/session-export.ts"
# shellcheck disable=SC2016 # The node fixture expands these variables when it runs.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$SWEEP_CALLS"\n' > "$TEST_DIR/bin/node"
chmod +x "$TEST_DIR/bin/node"

export HOME="$TEST_DIR/home"
export PATH="$TEST_DIR/bin:$PATH"
export SWEEP_CALLS="$TEST_DIR/sweep-calls"
touch "$SWEEP_CALLS"
export SESSION_EXPORT_SWEEP_INTERVAL_SECONDS=1
export SESSION_EXPORT_SWEEP_PROC_ROOT="$TEST_DIR/no-proc"
export DIGIO_HISTORY_DATABASE_URL='postgres://self-test-value-that-must-not-be-logged'

output="$(bash "$TEST_DIR/session-export-sweep.sh" start "$HOME/.digio/skills")" \
  || fail "the scheduler did not start"
SCHEDULER_PID="$(cat "$HOME/.local/state/digio-workbench/session-export-sweep.pid")"
[[ "$output" == *"session-export scheduler: started"* ]] || fail "the start was not reported"

for _ in 1 2 3 4 5; do
  [ "$(( $(wc -l < "$SWEEP_CALLS" 2>/dev/null || echo 0) ))" -ge 2 ] && break
  sleep 1
done
[ "$(( $(wc -l < "$SWEEP_CALLS") ))" -ge 2 ] || fail "the scheduled sweep did not repeat"
grep -Fxq -- "--experimental-strip-types $HOME/.digio/skills/skills/session-export/scripts/session-export.ts sweep" "$SWEEP_CALLS" \
  || fail "the scheduler used the wrong session-export command"

second_output="$(bash "$TEST_DIR/session-export-sweep.sh" start "$HOME/.digio/skills")" \
  || fail "the repeated start failed"
[ "$(cat "$HOME/.local/state/digio-workbench/session-export-sweep.pid")" = "$SCHEDULER_PID" ] \
  || fail "the repeated start replaced the scheduler"
[[ "$second_output" == *"session-export scheduler: already running"* ]] \
  || fail "the repeated start did not report the existing scheduler"

kill "$SCHEDULER_PID"
for _ in 1 2 3 4 5; do
  kill -0 "$SCHEDULER_PID" 2>/dev/null || break
  sleep 1
done
kill -0 "$SCHEDULER_PID" 2>/dev/null && fail "the stopped scheduler did not exit"
old_pid="$SCHEDULER_PID"
bash "$TEST_DIR/session-export-sweep.sh" start "$HOME/.digio/skills" >/dev/null \
  || fail "the scheduler did not replace a stale pid file"
SCHEDULER_PID="$(cat "$HOME/.local/state/digio-workbench/session-export-sweep.pid")"
[ "$SCHEDULER_PID" != "$old_pid" ] || fail "the restart did not create a new scheduler"

log="$HOME/.local/state/digio-workbench/session-export-sweep.log"
[ -s "$log" ] || fail "the scheduler did not create its log"
grep -Eq '^[0-9TZ:-]+ sweep: exit 0$' "$log" || fail "the loop's sweep did not log its exit line"
if grep -Fq "$DIGIO_HISTORY_DATABASE_URL" "$log"; then
  fail "the scheduler wrote the database URL to its log"
fi

# once: the entrypoint the loop and dotfiles' jobs/session-sweep.sh both run.
once_log="$TEST_DIR/once.log"
once() { SESSION_SWEEP_LOG="$once_log" DIGIO_SKILLS_ROOT="$HOME/.digio/skills" bash "$TEST_DIR/session-export-sweep.sh" once "$@"; }
: > "$SWEEP_CALLS"
once "$TEST_DIR/logs" || fail "once failed"
grep -Fxq -- "--experimental-strip-types $HOME/.digio/skills/skills/session-export/scripts/session-export.ts sweep" "$SWEEP_CALLS" \
  || fail "once used the wrong session-export command"
grep -Eq "^[0-9TZ:-]+ sweep: start $TEST_DIR/logs\$" "$once_log" || fail "once did not log its start line"
grep -Eq '^[0-9TZ:-]+ sweep: exit 0$' "$once_log" || fail "once did not log its exit line"
SESSION_SWEEP_CMD="printenv CLAUDE_CONFIG_DIR" once "$TEST_DIR/logs" || fail "once failed with a logs directory"
grep -Fxq "$TEST_DIR/logs" "$once_log" || fail "the logs directory did not reach the sweep as CLAUDE_CONFIG_DIR"
if SESSION_SWEEP_CMD=false once; then fail "a failed sweep exited 0"; fi
tail -n1 "$once_log" | grep -Eq 'sweep: exit 1$' || fail "a failed sweep did not log exit 1"
seq 5000 >> "$once_log"
SESSION_SWEEP_CMD=true once || fail "once failed after a long log"
[ "$(( $(wc -l < "$once_log") ))" -le 2002 ] || fail "once did not keep the log short"
grep -Fq "$DIGIO_HISTORY_DATABASE_URL" "$once_log" && fail "once wrote the database URL to its log"

echo "session-export sweep self-test passed: once logs and passes the exit code on; the loop runs, logs, and remains single across starts"
