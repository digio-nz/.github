#!/usr/bin/env bash
# humanlayer-daemon: run the HumanLayer daemon for this user, so the workbench is an online HumanLayer host.
#
#   humanlayer-daemon.sh start   start the daemon in the background, once; a running daemon is left alone
#   humanlayer-daemon.sh check   report whether the daemon runs
#
# The daemon needs a HumanLayer login (`humanlayer login`); its session lives under ~/.humanlayer and a rebuild clears it.
# The daemon keeps the image's CLI version: HUMANLAYER_DISABLE_SELF_UPDATE=1 and --no-self-update.
# State lives in ${XDG_STATE_HOME:-~/.local/state}/digio-workbench/: humanlayer-daemon.pid and humanlayer-daemon.log.
# Exit: 0 running or started; 1 not running, or the start failed and stderr names why; 2 usage.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/digio-workbench"
PID_FILE="$STATE_DIR/humanlayer-daemon.pid"
LOG_FILE="$STATE_DIR/humanlayer-daemon.log"
LOCK_FILE="$STATE_DIR/humanlayer-daemon.start.lock"
START_TIMEOUT_SECONDS="${HUMANLAYER_DAEMON_START_TIMEOUT_SECONDS:-30}"
PROC_ROOT="${HUMANLAYER_DAEMON_PROC_ROOT:-/proc}"

fail() {
  echo "HumanLayer daemon: $*" >&2
  exit 1
}

process_is_daemon() {
  local pid="$1" command_line
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "$PROC_ROOT/$pid/cmdline" ]; then
    command_line="$(tr '\0' ' ' < "$PROC_ROOT/$pid/cmdline")"
  else
    # No /proc on macOS: ps prints the same argument list, space-separated.
    command_line="$(ps -o args= -p "$pid" 2>/dev/null)" || return 1
  fi
  [[ "$command_line" == *"humanlayer daemon launch"* ]]
}

running_pid() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  process_is_daemon "$pid" || return 1
  echo "$pid"
}

start() {
  local pid waited=0
  command -v humanlayer >/dev/null 2>&1 || fail "cannot start because humanlayer is not on PATH"
  command -v flock >/dev/null 2>&1 || fail "cannot start because flock is not on PATH"
  [[ "$START_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "start timeout must be a positive integer"
  mkdir -p "$STATE_DIR" || fail "cannot create $STATE_DIR"

  exec 9>"$LOCK_FILE"
  flock 9

  if pid="$(running_pid)"; then
    echo "HumanLayer daemon: already running (pid $pid)"
    return
  fi
  rm -f "$PID_FILE"
  # A Claude session on this host logs in with the token the daemon inherits, or with the host's own Claude login.
  if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]; then
    echo "HumanLayer daemon: no CLAUDE_CODE_OAUTH_TOKEN in this environment and no Claude login on this host: Claude sessions here will not be logged in" >&2
  fi

  : > "$LOG_FILE"
  cd "$HOME" || fail "cannot enter $HOME"
  # The daemon runs in the foreground, so nohup keeps it past this shell; the launch exchanges the login for a daemon token.
  HUMANLAYER_DISABLE_SELF_UPDATE=1 nohup humanlayer daemon launch --no-self-update 9>&- </dev/null >>"$LOG_FILE" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  # The launch prints "Starting daemon..." once it holds a daemon token; a refused launch exits first and names why.
  while [ "$waited" -lt "$((START_TIMEOUT_SECONDS * 10))" ]; do
    if grep -q 'Starting daemon' "$LOG_FILE" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
      echo "HumanLayer daemon: started (pid $pid, log $LOG_FILE)"
      return
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE"
      fail "launch exited: $(tail -n 1 "$LOG_FILE" 2>/dev/null || echo "no output")"
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  fail "no start message within $START_TIMEOUT_SECONDS seconds; the launch still runs as pid $pid, see $LOG_FILE"
}

check() {
  local pid
  if pid="$(running_pid)"; then
    echo "HumanLayer daemon: running (pid $pid)"
  else
    fail "not running; start it with: bash ${BASH_SOURCE[0]} start"
  fi
}

case "${1:-}" in
  start) start ;;
  check) check ;;
  *) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
