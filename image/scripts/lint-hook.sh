#!/usr/bin/env bash
# lint-hook: a hook of Claude Code and of Codex that runs after an agent edits a file. It runs the rules of the file's
# project on each file that changed: ast-grep when the project has an sgconfig.yml, and ESLint for a JavaScript or
# TypeScript file when the project has ESLint. Exit 2 gives the findings to the agent. It never blocks for a file that
# no rule covers, and a crash of a tool does not block the agent.
#
# Claude Code names the file in tool_input.file_path. Codex gives the text of the patch in tool_input.command, and each
# file is on a line "*** Add File: <path>" or "*** Update File: <path>".
set -uo pipefail
input="$(cat)"
files="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
patch="$(printf '%s' "$input" | jq -r '.tool_input.command // empty | if type == "array" then join("\n") else tostring end' 2>/dev/null)"
if [ -n "$patch" ]; then
  files="$files"$'\n'"$(printf '%s\n' "$patch" | sed -n 's/^\*\*\* \(Add\|Update\) File: //p')"
fi
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"

# up <file> <name pattern>: the nearest folder above the file that holds a match.
up() {
  local dir
  dir="$(dirname "$1")"
  while [ "$dir" != "/" ]; do
    if compgen -G "$dir/$2" >/dev/null; then printf '%s' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

found=""
broken=""
# note <tool> <exit code> <output>: 1 is a finding. Another code is a tool that did not run to its end.
note() {
  case "$2" in
    0) ;;
    1) found="$found$3"$'\n' ;;
    124) broken="${broken}lint-hook: $1 did not end in 60 seconds"$'\n' ;;
    *) broken="${broken}lint-hook: $1 exited $2: $(printf '%s' "$3" | tail -n 3 | tr '\n' ' ')"$'\n' ;;
  esac
}
while IFS= read -r file; do
  [ -n "$file" ] || continue
  case "$file" in /*) ;; *) file="${cwd:-$PWD}/$file" ;; esac
  [ -f "$file" ] || continue
  if root="$(up "$file" sgconfig.yml)" && command -v ast-grep >/dev/null 2>&1; then
    out="$(cd "$root" && timeout 60 ast-grep scan --color never "$file" 2>&1)"
    note ast-grep $? "$out"
  fi
  case "$file" in
    *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs)
      if root="$(up "$file" 'eslint.config.*')" && [ -x "$root/node_modules/.bin/eslint" ]; then
        out="$(cd "$root" && timeout 60 node_modules/.bin/eslint --quiet --no-warn-ignored "$file" 2>&1)"
        note ESLint $? "$out"
      fi
      ;;
  esac
done <<<"$files"
# A tool that broke is not the fault of the change, so it does not block the agent. It is still an error, with a name.
if [ -z "$found" ]; then
  [ -n "$broken" ] || exit 0
  printf '%s' "$broken" >&2
  exit 1
fi
{
  echo "The rules of this project found errors in the file that you changed. Fix the cause of each one; do not disable a rule."
  printf '%s' "$found"
} >&2
exit 2
