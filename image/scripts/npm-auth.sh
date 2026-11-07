#!/usr/bin/env bash
# npm-auth: the npm side of the GitHub Packages login, for the workbench and for the machines.
#
#   npm-auth.sh apply [--npmrc <file>]    add the @digio-nz scope line and the auth line, each once
#   npm-auth.sh remove [--npmrc <file>]   take both lines out again; the rest of the file stays
#
# npm reads a registry token only from an _authToken line in an npmrc. The line holds the variable name
# ${NODE_AUTH_TOKEN}, never a value; node-auth-token.sh, beside this file, sets the variable in each shell. The scope
# line sends @digio-nz packages to GitHub Packages from any directory, as the consumer repos' own .npmrc does.
# The npmrc is --npmrc, else ~/.npmrc. A new file is created with mode 0600. Each line printed names what changed:
# "appended:", "removed:" or "ok:". post-create.sh runs apply in the workbench; dotfiles' deploy-machine.sh runs apply,
# or remove on a machine that builds no Digio apps. Exit 0 OK, 1 the npmrc cannot be written, 2 bad usage.
set -uo pipefail

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

SCOPE_LINE='@digio-nz:registry=https://npm.pkg.github.com'
# shellcheck disable=SC2016 # the file holds the variable name
AUTH_LINE='//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}'

mode="${1:-}"
[ $# -gt 0 ] && shift
npmrc="$HOME/.npmrc"
while [ $# -gt 0 ]; do
  case "$1" in
    --npmrc) [ $# -ge 2 ] || usage; npmrc="$2"; shift 2 ;;
    *) usage ;;
  esac
done

ensure_line() {
  if [ -f "$npmrc" ] && grep -qxF -- "$1" "$npmrc"; then
    echo "ok:       $npmrc already has $1"
    return 0
  fi
  # A file with no final newline would glue the new line to its last one.
  if [ -s "$npmrc" ] && [ -n "$(tail -c1 "$npmrc")" ]; then echo >>"$npmrc" || return 1; fi
  ( umask 077; printf '%s\n' "$1" >>"$npmrc" ) || return 1
  echo "appended: $npmrc <- $1"
}

remove_line() {
  local kept
  [ -f "$npmrc" ] && grep -qxF -- "$1" "$npmrc" || return 0
  kept="$(grep -vxF -- "$1" "$npmrc" || true)"
  if [ -n "$kept" ]; then printf '%s\n' "$kept" >"$npmrc"; else : >"$npmrc"; fi || return 1
  echo "removed:  $npmrc -= $1"
}

case "$mode" in
  apply) step=ensure_line ;;
  remove) step=remove_line ;;
  *) usage ;;
esac
if ! { "$step" "$SCOPE_LINE" && "$step" "$AUTH_LINE"; }; then
  echo "npm-auth: cannot write $npmrc" >&2
  exit 1
fi
