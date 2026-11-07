#!/usr/bin/env bash
# host.sh: the commands that differ between macOS (BSD userland) and Linux (GNU coreutils), in one place.
# Source it from a script: . "<michelin root>/lib/host.sh". Each function knows the host and runs the right form.
#
#   host_os                               darwin or linux
#   host_mtime <file>                     the file's modification time, in epoch seconds
#   host_mode <file>                      the file's permission bits in octal, with the setuid, setgid and sticky bits, such as 600 or 4755
#   host_epoch <YYYY-MM-DD[THH:MM:SSZ]>   that UTC time, in epoch seconds
#   host_date <epoch> [+format]           that epoch second as UTC text; the default format is +%Y-%m-%dT%H:%M:%SZ
#   host_sed_i <sed args...> <file>...    sed in place, with no backup file left behind
#   host_hex [file]                       the bytes of the file, or of stdin, as lowercase hex with no spaces or newlines
#   host_timeout <seconds> <command...>   run the command; stop it after <seconds> and return 124, as GNU timeout does
#
# Use a portable form, not a helper, where one exists: $(( $(wc -l < f) )) for a count, date +%s for now.
# skill-creator.sh validate refuses the raw host-specific commands in a skill and names this file.
# Each function returns 0 on success, 2 on bad input, 3 when the host command fails; host_timeout returns the command's own.

# Run directly, it prints this header: it is a library.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; fi

host_os() {
  case "$(uname -s)" in
    Darwin) echo darwin ;;
    Linux) echo linux ;;
    *) echo "host_os: unsupported host $(uname -s)" >&2; return 3 ;;
  esac
}

_host_file() { # <function> <file>: a readable path, else a reason on stderr
  [ -n "${2:-}" ] && [ -e "$2" ] && return 0
  echo "$1: no such file: ${2:-<none>}" >&2; return 2
}

host_mtime() {
  _host_file host_mtime "${1:-}" || return
  case "$(host_os)" in
    darwin) stat -f %m "$1" ;;
    *) stat -c %Y "$1" ;;
  esac || return 3
}

host_mode() {
  _host_file host_mode "${1:-}" || return
  local mode
  # BSD %Lp drops the setuid, setgid and sticky bits; %Mp holds them. Print the octal as GNU %a does: no leading zero.
  case "$(host_os)" in
    darwin) mode="$(stat -f %Mp%Lp "$1")" || return 3; printf '%o\n' "$((8#$mode))" ;;
    *) stat -c %a "$1" || return 3 ;;
  esac
}

host_epoch() {
  local when="${1:-}"
  [[ "$when" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && when="${when}T00:00:00Z"
  [[ "$when" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo "host_epoch: want YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ, got '${1:-}'" >&2; return 2; }
  case "$(host_os)" in
    darwin) date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$when" +%s 2>/dev/null ;;
    *) date -u -d "${when%Z}+00:00" +%s 2>/dev/null ;;
  esac || { echo "host_epoch: not a date: '$1'" >&2; return 2; }
}

host_date() {
  local epoch="${1:-}" format="${2:-+%Y-%m-%dT%H:%M:%SZ}"
  [[ "$epoch" =~ ^-?[0-9]+$ ]] || { echo "host_date: want epoch seconds, got '$epoch'" >&2; return 2; }
  [[ "$format" == +* ]] || { echo "host_date: the format starts with +, got '$format'" >&2; return 2; }
  case "$(host_os)" in
    darwin) date -u -r "$epoch" "$format" ;;
    *) date -u -d "@$epoch" "$format" ;;
  esac || return 3
}

host_sed_i() {
  [ $# -ge 2 ] || { echo "host_sed_i: usage: host_sed_i <sed args...> <file>..." >&2; return 2; }
  case "$(host_os)" in
    darwin) sed -i '' "$@" ;;
    *) sed -i "$@" ;;
  esac
}

host_hex() {
  if [ $# -gt 0 ]; then
    _host_file host_hex "$1" || return
    od -An -v -tx1 "$1" | tr -d ' \n'
  else
    od -An -v -tx1 | tr -d ' \n'
  fi
}

host_timeout() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ $# -ge 2 ] || { echo "host_timeout: usage: host_timeout <seconds> <command...>" >&2; return 2; }
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else _host_timeout_bash "$@"; fi
}

# The fallback for a Mac without GNU coreutils. Like GNU timeout, it runs the command in its own process group and stops
# the whole group, so a child the command started stops too. The watcher writes nothing, so a caller that captures the
# command's output does not wait for the watcher's sleep.
_host_timeout_bash() {
  local secs="$1" flag rc
  shift
  flag="$(mktemp)" || return 3
  ( # job control gives the command its own process group; its job notices go to /dev/null, the command's stderr to fd 4
    set -m
    "$@" 0<&0 2>&4 4>&- &
    pid=$!
    (sleep "$secs"; kill -0 "$pid" 2>/dev/null && echo stopped >"$flag" && kill -TERM -- "-$pid") >/dev/null 2>&1 &
    watcher=$!
    wait "$pid"; rc=$?
    kill -- "-$watcher" 2>/dev/null
    exit "$rc"
  ) 4>&2 2>/dev/null
  rc=$?
  [ -s "$flag" ] && rc=124
  rm -f "$flag"
  return "$rc"
}
