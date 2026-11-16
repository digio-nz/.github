#!/usr/bin/env bash
# lint-hook: a PostToolUse hook of Claude Code. After an edit of a JavaScript or TypeScript file, it runs the
# ESLint of that file's project on that one file. Exit 2 gives the findings to the agent. It never blocks for a file
# that no ESLint covers.
set -uo pipefail
input="$(cat)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$file" ] && [ -f "$file" ] || exit 0
case "$file" in *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs) ;; *) exit 0 ;; esac
dir="$(dirname "$file")"
root=""
while [ "$dir" != "/" ]; do
  if ls "$dir"/eslint.config.* >/dev/null 2>&1; then root="$dir"; break; fi
  dir="$(dirname "$dir")"
done
[ -n "$root" ] && [ -x "$root/node_modules/.bin/eslint" ] || exit 0
out="$(cd "$root" && timeout 60 node_modules/.bin/eslint --quiet --no-warn-ignored "$file" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || exit 0
{
  echo "ESLint found errors in the file that you changed. Fix the cause of each one; do not disable a rule."
  printf '%s\n' "$out"
} >&2
exit 2
