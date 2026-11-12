#!/usr/bin/env bash
# post-create.sh and post-start.sh run this: every git push in the container must run secret-guard.
# The image bakes the hooks and names their shims in the system gitconfig. A global core.hooksPath overrides the system
# one, and git runs no hook when the path is missing, so this exits 1 and names the fault when no pre-push hook is in effect.
# A home made by an older image holds a global core.hooksPath in its digio-michelin clone; this removes it.
set -euo pipefail

guarded() { [ -n "$1" ] && [ -x "$1/pre-push" ]; }

system="$(git config --system --type=path --get core.hooksPath || true)"
global="$(git config --global --type=path --get core.hooksPath || true)"
case "$global" in
  */.digio/michelin/hooks/*)
    if ! guarded "$system"; then
      echo "hooks: the global core.hooksPath is '$global', in the digio-michelin clone, and the system core.hooksPath '${system:-unset}' has no pre-push hook; recreate the container from a current workbench image" >&2
      exit 1
    fi
    git config --global --unset-all core.hooksPath \
      || { echo "hooks: cannot remove the global core.hooksPath '$global'; it overrides the image's hooks at $system" >&2; exit 1; }
    echo "hooks: removed the global core.hooksPath '$global'; the image's hooks at $system guard git push"
    global=
    ;;
esac
path="${global:-$system}"
guarded "$path" || { echo "hooks: core.hooksPath is '${path:-unset}' and has no pre-push hook; git push is not guarded" >&2; exit 1; }
