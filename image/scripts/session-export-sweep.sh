#!/usr/bin/env bash
# session-export-sweep: the one entrypoint of digio-skills' session-export sweep, for the workbench and the machines.
#
#   session-export-sweep.sh once [<claude config dir>]   run one sweep and append it to the log; exit with the sweep's code
#   session-export-sweep.sh start <skills-dir>           start the workbench's 15-minute loop for this user, once
#
# The sweep saves each Claude Code session the SessionEnd hook missed (a crash, a closed pane, a reboot) and keeps a
# long-running session current. once sweeps one Claude Code logs directory, <claude config dir> else
# ${CLAUDE_CONFIG_DIR:-~/.claude}, with digio-skills at ${DIGIO_SKILLS_ROOT:-~/devs/digio-skills}. It writes the sweep's
# output to SESSION_SWEEP_LOG (default ~/.local/state/session-export/sweep.log), between a start line and an exit line:
#   2026-10-12T05:30:00Z sweep: start /home/digby/.claude
#   2026-10-12T05:30:04Z sweep: exit 0
# and keeps the log to its last 2000 lines. A reader takes the result from the last exit line.
# The schedulers are thin wrappers around once: post-start.sh runs start in the workbench, a nohup loop with a pid file
# and its log in ${XDG_STATE_HOME:-~/.local/state}/digio-workbench/; dotfiles' jobs/session-sweep.sh runs once from a
# systemd user timer or a LaunchAgent. The store URL is DIGIO_HISTORY_DATABASE_URL, else the file DIGIO_HISTORY_ENV
# names (session-export reads them); nothing here reads or prints it. SESSION_SWEEP_CMD replaces node and the sweep, for
# tests.
set -uo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/digio-workbench"
PID_FILE="$STATE_DIR/session-export-sweep.pid"
LOG_FILE="$STATE_DIR/session-export-sweep.log"
LOCK_FILE="$STATE_DIR/session-export-sweep.start.lock"
INTERVAL_SECONDS="${SESSION_EXPORT_SWEEP_INTERVAL_SECONDS:-900}"
PROC_ROOT="${SESSION_EXPORT_SWEEP_PROC_ROOT:-/proc}"

fail() {
  echo "session-export scheduler: $*" >&2
  exit 1
}

sweep_once() {
  local skills="${DIGIO_SKILLS_ROOT:-$HOME/devs/digio-skills}"
  local log="${SESSION_SWEEP_LOG:-$HOME/.local/state/session-export/sweep.log}"
  local logs="${1:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}" d rc
  export CLAUDE_CONFIG_DIR="$logs"
  # A scheduler starts this with a bare PATH; node lives in one of these. A directory already on PATH keeps its place.
  for d in /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin" "$HOME/.nix-profile/bin"; do
    case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$d:$PATH" ;; esac
  done
  export PATH
  mkdir -p "$(dirname "$log")" || exit 1
  if [ -f "$log" ] && [ "$(( $(wc -l <"$log") ))" -gt 4000 ]; then
    tail -n 2000 "$log" >"$log.tmp" && mv "$log.tmp" "$log"
  fi
  {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) sweep: start $logs"
    if [ -n "${SESSION_SWEEP_CMD:-}" ]; then
      $SESSION_SWEEP_CMD
    else
      node --experimental-strip-types "$skills/skills/session-export/scripts/session-export.ts" sweep
    fi
    rc=$?
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) sweep: exit $rc"
  } >>"$log" 2>&1
  exit "$rc"
}

process_is_scheduler() {
  local pid="$1" command_line
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "$PROC_ROOT/$pid/cmdline" ]; then
    command_line="$(tr '\0' ' ' < "$PROC_ROOT/$pid/cmdline")"
  else
    # No /proc on macOS: ps prints the same argument list, space-separated.
    command_line="$(ps -o args= -p "$pid" 2>/dev/null)" || return 1
  fi
  [[ "$command_line" == *"$SCRIPT_PATH run "* ]]
}

run_loop() {
  local current_pid child_pid=""
  export DIGIO_SKILLS_ROOT="$1" SESSION_SWEEP_LOG="$LOG_FILE"

  cleanup() {
    current_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ "$current_pid" != "$$" ] || rm -f "$PID_FILE"
  }
  stop() {
    [ -z "$child_pid" ] || kill "$child_pid" 2>/dev/null || true
    exit 0
  }
  trap cleanup EXIT
  trap stop INT TERM

  while true; do
    # once writes its own start and exit lines; a failed sweep is its exit line.
    bash "$SCRIPT_PATH" once &
    child_pid=$!
    wait "$child_pid" || true
    child_pid=""
    sleep "$INTERVAL_SECONDS" &
    child_pid=$!
    wait "$child_pid" || true
    child_pid=""
  done
}

start_scheduler() {
  local skills_dir="$1" exporter pid started=0
  exporter="$skills_dir/skills/session-export/scripts/session-export.ts"

  command -v node >/dev/null 2>&1 || fail "cannot start because node is not on PATH"
  command -v flock >/dev/null 2>&1 || fail "cannot start because flock is not on PATH"
  [ -f "$exporter" ] || fail "cannot start because $exporter is missing"
  [[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "interval must be a positive integer"
  mkdir -p "$STATE_DIR" || fail "cannot create $STATE_DIR"

  exec 9>"$LOCK_FILE"
  flock 9

  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if process_is_scheduler "$pid"; then
    echo "session-export scheduler: already running (pid $pid)"
    return
  fi
  rm -f "$PID_FILE"

  nohup "$SCRIPT_PATH" run "$skills_dir" 9>&- >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  for _ in {1..20}; do
    if process_is_scheduler "$pid"; then
      started=1
      break
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if [ "$started" -ne 1 ]; then
    rm -f "$PID_FILE"
    fail "failed to start"
  fi
  echo "session-export scheduler: started (pid $pid, log $LOG_FILE)"
}

case "${1:-}" in
  once)
    [ "$#" -le 2 ] || fail "usage: $0 once [<claude config dir>]"
    sweep_once "${2:-}"
    ;;
  start)
    [ "$#" -eq 2 ] || fail "usage: $0 start <skills-dir>"
    start_scheduler "$2"
    ;;
  run)
    [ "$#" -eq 2 ] || fail "invalid run arguments"
    run_loop "$2"
    ;;
  *)
    fail "usage: $0 once [<claude config dir>] | start <skills-dir>"
    ;;
esac
