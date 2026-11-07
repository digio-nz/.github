#!/usr/bin/env bash
# install.sh [<repo-dir>] [--global|--system] [--check]
#   Point core.hooksPath at this folder's shims.
#   Default: the current (or named) repo's local config.
#   --global: the calling user's global gitconfig (Codespace / desk post-create).
#   --system: the machine gitconfig (baked into the workbench image).
#   --check reports instead of writing.
#
# A shim exists per trigger folder: hooks/shims/<trigger> calls run.sh <trigger>. Adding a folder
# hooks/<trigger>/ and re-running this installs that trigger too.
# Fails closed when hooks/pre-push/secret-guard.sh is missing or unreadable.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd -P)"
repo="."
check=0
scope=local
for a in "$@"; do
  case "$a" in
    --check) check=1 ;;
    --global) scope=global ;;
    --system) scope=system ;;
    -*)
      echo "install: unknown flag $a (want --global, --system, --check)" >&2
      exit 2
      ;;
    *) repo="$a" ;;
  esac
done

guard="$DIR/pre-push/secret-guard.sh"
if [ ! -r "$guard" ]; then
  echo "install: $guard missing or unreadable; refusing to point hooksPath at an unguarded shim" >&2
  exit 1
fi

mkdir -p "$DIR/shims"
for d in "$DIR"/*/; do
  t="$(basename "$d")"
  [ "$t" = shims ] && continue
  shim="$DIR/shims/$t"
  [ -f "$shim" ] || {
    printf '#!/bin/sh\nexec sh "$(dirname "$0")/../run.sh" %s "$@"\n' "$t" > "$shim"
    chmod +x "$shim"
  }
done

case "$scope" in
  local)
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
      || { echo "install: $repo is not a git repository" >&2; exit 2; }
    current="$(git -C "$repo" config --local --get core.hooksPath || true)"
    if [ "$check" = 1 ]; then
      if [ "$current" = "$DIR/shims" ]; then
        echo "ok: $repo hooks -> $DIR/shims"
        exit 0
      fi
      echo "missing: $repo core.hooksPath is '${current:-unset}', want $DIR/shims"
      exit 1
    fi
    # A repo pointing at its own committed .githooks is safe to take over: run.sh chains to
    # .githooks/<trigger> after the michelin scripts, so the repo's hooks keep running.
    case "$current" in
      .githooks | .githooks/ | "$repo/.githooks" | "$(cd "$repo" && pwd -P)/.githooks")
        git -C "$repo" config --local core.hooksPath "$DIR/shims"
        echo "linked: $repo hooks -> $DIR/shims (was '$current'; its hooks still run via run.sh)"
        exit 0
        ;;
    esac
    # A repo that already opted into husky/lefthook (or another hooksPath) keeps it; print how to join.
    if [ -n "$current" ] && [ "$current" != "$DIR/shims" ]; then
      echo "found:   $repo has core.hooksPath set to '$current' (not this michelin checkout)" >&2
      echo "         leave it, or clear it and re-run: git -C '$repo' config --unset core.hooksPath" >&2
      echo "         then: bash '$DIR/install.sh' '$repo'" >&2
      exit 1
    fi
    git -C "$repo" config --local core.hooksPath "$DIR/shims"
    echo "installed: $repo hooks -> $DIR/shims ($(ls "$DIR/shims" | tr '\n' ' '))"
    ;;
  global|system)
    flag="--$scope"
    current="$(git config "$flag" --get core.hooksPath || true)"
    if [ "$check" = 1 ]; then
      if [ "$current" = "$DIR/shims" ]; then
        echo "ok: $scope hooks -> $DIR/shims"
        exit 0
      fi
      echo "missing: $scope core.hooksPath is '${current:-unset}', want $DIR/shims"
      exit 1
    fi
    git config "$flag" core.hooksPath "$DIR/shims"
    echo "installed: $scope hooks -> $DIR/shims ($(ls "$DIR/shims" | tr '\n' ' '))"
    ;;
esac
