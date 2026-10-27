#!/usr/bin/env bash
# Product gates run on the Mac mini; jobs with App keys run on GitHub.
set -uo pipefail
file="${1:-}"
[ -f "$file" ] || { echo "selftest-workflow: no file ${file:-<none>}" >&2; exit 2; }
mini='[self-hosted, digio-orchestration]'
toggle="\${{ vars.PROCESS_HOSTED_RUNNER || 'ubuntu-latest' }}"
bad=0
on_mini=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *runs-on:*)
      value="${line#*runs-on:}"
      value="${value#"${value%%[![:space:]]*}"}"
      case "$value" in '${{'*) ;; *) value="${value%%#*}" ;; esac
      value="${value%"${value##*[![:space:]]}"}"
      if [ "$value" = "$mini" ]; then
        on_mini=1
      elif [ "$value" != "ubuntu-latest" ] && [ "$value" != "$toggle" ]; then
        echo "selftest-workflow: runs-on must be $mini, ubuntu-latest or $toggle; found: $value" >&2
        bad=1
      fi
      ;;
  esac
done < "$file"
if [ "$on_mini" -eq 0 ]; then
  echo "selftest-workflow: no job runs-on $mini; the Discipline job runs on the Mac mini" >&2
  bad=1
fi
if [ "$bad" -ne 0 ]; then
  exit 1
fi
echo "selftest-workflow: the Discipline job runs on the Mac mini. OK."
exit 0
