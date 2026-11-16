#!/usr/bin/env bash
# lint-hook-selftest: offline. Stand-ins for ESLint and ast-grep prove each exit of lint-hook.sh.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="$DIR/lint-hook.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
check() { # <name> <want exit> <file> [want text on stderr]
  local name="$1" want="$2" file="$3" text="${4:-}" got err
  err="$(printf '{"tool_input":{"file_path":"%s"}}' "$file" | bash "$HOOK" 2>&1 >/dev/null)" && got=0 || got=$?
  if [ "$got" = "$want" ] && { [ -z "$text" ] || grep -q "$text" <<<"$err"; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $name: exit $got, want $want; stderr: $err" >&2
  fi
}
project() { # <dir> <exit of the stand-in>
  mkdir -p "$1/node_modules/.bin" "$1/src"
  : > "$1/eslint.config.mjs"
  printf '#!/bin/sh\necho "stand-in finding for $*"\nexit %s\n' "$2" > "$1/node_modules/.bin/eslint"
  chmod +x "$1/node_modules/.bin/eslint"
  : > "$1/src/a.tsx"
  : > "$1/src/notes.md"
}
project "$tmp/bad" 1
project "$tmp/good" 0
project "$tmp/broken" 2
mkdir -p "$tmp/plain/src" && : > "$tmp/plain/src/a.ts"

check "a finding goes to the agent" 2 "$tmp/bad/src/a.tsx" "stand-in finding"
check "the message tells the agent not to disable a rule" 2 "$tmp/bad/src/a.tsx" "do not disable a rule"
check "a clean file passes" 0 "$tmp/good/src/a.tsx"
check "a file that is not JavaScript or TypeScript passes" 0 "$tmp/bad/src/notes.md"
check "a project with no ESLint passes" 0 "$tmp/plain/src/a.ts"
check "a crash of ESLint does not block the agent" 0 "$tmp/broken/src/a.tsx"
check "a file that does not exist passes" 0 "$tmp/bad/src/gone.tsx"

# ast-grep: a stand-in on PATH, and a project with an sgconfig.yml. The stand-in exits with the number in its file.
mkdir -p "$tmp/bin" "$tmp/sg/scripts"
# shellcheck disable=SC2016 # the stand-in expands these when it runs, not this script
printf '#!/bin/sh\necho "stand-in ast-grep finding for $*"\nexit "$(cat "%s/sg-exit")"\n' "$tmp" > "$tmp/bin/ast-grep"
chmod +x "$tmp/bin/ast-grep"
: > "$tmp/sg/sgconfig.yml"
: > "$tmp/sg/scripts/run.sh"
PATH="$tmp/bin:$PATH"
export PATH
echo 1 > "$tmp/sg-exit"
check "an ast-grep finding goes to the agent, for a file of any kind" 2 "$tmp/sg/scripts/run.sh" "stand-in ast-grep finding"
echo 0 > "$tmp/sg-exit"
check "a file that ast-grep passes is clean" 0 "$tmp/sg/scripts/run.sh"
echo 2 > "$tmp/sg-exit"
check "a crash of ast-grep does not block the agent" 0 "$tmp/sg/scripts/run.sh"
echo 1 > "$tmp/sg-exit"
check "a project with no sgconfig.yml does not run ast-grep" 0 "$tmp/plain/src/a.ts"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
