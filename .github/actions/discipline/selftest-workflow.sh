#!/usr/bin/env bash
# Every Discipline job runs on a GitHub-hosted runner, and every action is pinned to a commit.
set -uo pipefail
file="${1:-}"
[ -f "$file" ] || { echo "selftest-workflow: no file ${file:-<none>}" >&2; exit 2; }
bad=0
jobs=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *runs-on:*)
      value="${line#*runs-on:}"
      value="${value#"${value%%[![:space:]]*}"}"
      case "$value" in '${{'*) ;; *) value="${value%%#*}" ;; esac
      value="${value%"${value##*[![:space:]]}"}"
      jobs=$((jobs + 1))
      if [ "$value" != "ubuntu-latest" ]; then
        echo "selftest-workflow: runs-on must be literal ubuntu-latest; found: $value" >&2
        bad=1
      fi
      ;;
    *uses:*)
      value="${line#*uses:}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%%[[:space:]]*}"
      case "$value" in
        ./*) ;;
        *)
          if ! printf '%s' "$value" | grep -Eq '@[0-9a-f]{40}$'; then
            echo "selftest-workflow: uses must pin a 40-character commit; found: $value" >&2
            bad=1
          fi
          ;;
      esac
      ;;
  esac
done < "$file"
if [ "$jobs" -eq 0 ]; then
  echo "selftest-workflow: no job names a runner" >&2
  bad=1
fi
if [ "$bad" -ne 0 ]; then
  exit 1
fi
echo "selftest-workflow: every job is hosted and every action is pinned. OK."
exit 0
