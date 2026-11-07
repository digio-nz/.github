#!/bin/sh
# run.sh <trigger> [git hook args] < stdin
#
# Runs every executable in hooks/<trigger>/ whose name does not end in -selftest.sh, in name order,
# feeding each the same stdin Git gave the hook. The first non-zero exit stops the push or commit.
# Then it chains to the repository's own hook of the same name under .git/hooks, if one exists, and
# to a committed .githooks/<trigger> (the way digio-nz/dotfiles chains), so a global core.hooksPath
# never silences either. run-selftest.sh beside it pins it.
# install.sh points core.hooksPath at hooks/shims/, whose one-line files call this with their trigger.
#
# pre-push fails closed when secret-guard.sh is missing or unreadable: a bare hooks folder must not
# let a credential-shaped push through.
set -u
dir="$(cd "$(dirname "$0")" && pwd -P)"
trigger="${1:?trigger}"; shift
stdin_capture="$(mktemp)"
trap 'rm -f "$stdin_capture"' EXIT
cat > "$stdin_capture"

if [ "$trigger" = pre-push ]; then
  guard="$dir/pre-push/secret-guard.sh"
  if [ ! -r "$guard" ]; then
    echo "BLOCKED: $guard not found or unreadable; credential-shaped additions cannot be checked" >&2
    michelin="$(dirname "$dir")"
    quoted="$(printf '%s' "$michelin" | sed "s/'/'\\\\''/g")"
    if [ -e "$michelin/.git" ]; then
      printf "fix: git -C '%s' pull --ff-only && git -C '%s' restore --source=HEAD -- hooks/pre-push/secret-guard.sh\n" \
        "$quoted" "$quoted" >&2
    else
      printf "fix: restore hooks/pre-push/secret-guard.sh under '%s'\n" "$quoted" >&2
    fi
    exit 1
  fi
fi

for hook in "$dir/$trigger"/*.sh; do
  [ -f "$hook" ] || continue
  case "$hook" in *-selftest.sh) continue ;; esac
  sh "$hook" "$@" < "$stdin_capture" || exit $?
done
# The repository's own hooks folder, never the hooksPath: --git-path hooks resolves to core.hooksPath, which is
# this folder's shims/, and chaining there would call run.sh again without end.
own="$(git rev-parse --git-common-dir 2>/dev/null)/hooks/$trigger"
if [ -x "$own" ]; then "$own" "$@" < "$stdin_capture" || exit $?; fi
# Committed hooks (.githooks/): only reached when we own hooksPath; otherwise Git would already run them.
toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || toplevel=
if [ -n "$toplevel" ]; then
  committed="$toplevel/.githooks/$trigger"
  if [ -x "$committed" ]; then
    "$committed" "$@" < "$stdin_capture" || exit $?
  fi
fi
exit 0
