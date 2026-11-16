#!/usr/bin/env bash
# lint-hook: a PostToolUse hook of Claude Code. After an edit of a file, it runs the rules of that file's project on
# that one file: ast-grep when the project has an sgconfig.yml, and ESLint for a JavaScript or TypeScript file when the
# project has ESLint. Exit 2 gives the findings to the agent. It never blocks for a file that no rule covers, and a
# crash of a tool does not block the agent.
set -uo pipefail
input="$(cat)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$file" ] && [ -f "$file" ] || exit 0

# up <name pattern>: the nearest folder above the file that holds a match.
up() {
  local dir
  dir="$(dirname "$file")"
  while [ "$dir" != "/" ]; do
    if compgen -G "$dir/$1" >/dev/null; then printf '%s' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

found=""
if root="$(up sgconfig.yml)" && command -v ast-grep >/dev/null 2>&1; then
  out="$(cd "$root" && timeout 60 ast-grep scan --color never "$file" 2>&1)"
  [ $? -ne 1 ] || found="$found$out"$'\n'
fi
case "$file" in
  *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs)
    if root="$(up 'eslint.config.*')" && [ -x "$root/node_modules/.bin/eslint" ]; then
      out="$(cd "$root" && timeout 60 node_modules/.bin/eslint --quiet --no-warn-ignored "$file" 2>&1)"
      [ $? -ne 1 ] || found="$found$out"$'\n'
    fi
    ;;
esac
[ -n "$found" ] || exit 0
{
  echo "The rules of this project found errors in the file that you changed. Fix the cause of each one; do not disable a rule."
  printf '%s' "$found"
} >&2
exit 2
