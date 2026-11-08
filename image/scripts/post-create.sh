#!/usr/bin/env bash
# Runs once, after the container is created: clone digio-michelin, and write the npm auth lines and the
# NODE_AUTH_TOKEN file that the shell profiles source.
# post-start.sh runs next, and at every start after that.
# A failed step is reported on stderr and the script exits 1 after running the rest.
set -euo pipefail
failed=0

SKILLS_DIR="$HOME/.digio/michelin"
if [ -d "$SKILLS_DIR/.git" ]; then
  git -C "$SKILLS_DIR" pull -q --ff-only || true
else
  git clone -q https://github.com/digio-nz/digio-michelin.git "$SKILLS_DIR" || echo "digio-michelin clone refused: grant the repository when the Codespace asks, or run gh auth refresh -s repo"
fi
export DIGIO_MICHELIN_ROOT="$SKILLS_DIR"

# Point every git push in this Codespace / desk container at Michelin's pre-push shim (secret-guard, then the
# repo's own .git/hooks and .githooks). The workbench image also bakes a system hooksPath at
# /opt/digio/michelin-hooks/shims; the global config here wins and tracks the cloned checkout.
# Worker sandboxes pin a different hooksPath via GIT_CONFIG_* (digio-skills dispatch) and call the
# guard from worker-pipeline.ts, so they do not double-run this path.
if [ -x "$SKILLS_DIR/hooks/install.sh" ]; then
  bash "$SKILLS_DIR/hooks/install.sh" --global     || { echo "hooks: global secret-guard install failed; git push is not guarded" >&2; failed=1; }
else
  echo "hooks: $SKILLS_DIR/hooks/install.sh missing; git push is not guarded" >&2
  failed=1
fi

# npm-auth.sh writes the @digio-nz scope line and the auth line, which names NODE_AUTH_TOKEN and never holds a value.
# node-auth-token.sh sets NODE_AUTH_TOKEN: the Codespace's GITHUB_TOKEN, else the desk workbench's gh token. It is copied
# to ~/.digio/node-auth-token.sh, which devcontainer.json names in BASH_ENV (non-interactive bash) and which the profiles
# source. A profile that is a symlink belongs to a dotfiles checkout, so it is skipped.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
bash "$SCRIPT_DIR/npm-auth.sh" apply >/dev/null || { echo "npm auth: cannot write ~/.npmrc" >&2; failed=1; }
AUTH_ENV="$HOME/.digio/node-auth-token.sh"
mkdir -p "$HOME/.digio"
cp "$SCRIPT_DIR/node-auth-token.sh" "$AUTH_ENV" || { echo "npm auth: cannot write $AUTH_ENV" >&2; failed=1; }
SOURCE_MARK='# digio node-auth-token'
# shellcheck disable=SC2016 # the profiles expand HOME when they run
SOURCE_LINE='[ -r "$HOME/.digio/node-auth-token.sh" ] && . "$HOME/.digio/node-auth-token.sh"'
# ~/.bashrc starts with an interactive-only guard, so the line goes above it; the other profiles take it at the end.
for profile in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshenv"; do
  [ -L "$profile" ] && continue
  grep -Fq "$SOURCE_MARK" "$profile" 2>/dev/null && continue
  if [ "$profile" = "$HOME/.bashrc" ] && [ -f "$profile" ]; then
    { printf '%s %s\n' "$SOURCE_LINE" "$SOURCE_MARK"; cat "$profile"; } > "$profile.new" && mv "$profile.new" "$profile"
  else
    printf '%s %s\n' "$SOURCE_LINE" "$SOURCE_MARK" >> "$profile"
  fi
done

# session-export reads DATABASE_URL from this file when DIGIO_HISTORY_DATABASE_URL is unset; a Codespace has the secret.
# post-start.sh links ~/devs later, so a first start finds the folder on the workspace disk.
devs="$HOME/devs"
[ -e "$devs" ] || [ ! -d "${DIGIO_WORKSPACES:-/workspaces}/devs" ] || devs="${DIGIO_WORKSPACES:-/workspaces}/devs"
HISTORY_ENV="${DIGIO_HISTORY_ENV:-$devs/digio-history/.env.local}"
HISTORY_REF=op://orchestrator/DIGIO_HISTORY_DATABASE_URL/credential
if [ -z "${DIGIO_HISTORY_DATABASE_URL:-}" ] && [ ! -s "$HISTORY_ENV" ]; then
  if [ ! -d "${HISTORY_ENV%/*}" ]; then
    echo "WARN: session export: ${HISTORY_ENV%/*} is missing, so each session export fails; clone digio-nz/digio-history there, then rerun $SCRIPT_DIR/post-create.sh" >&2
  elif printf 'DATABASE_URL={{ %s }}\n' "$HISTORY_REF" | op inject --force --out-file "$HISTORY_ENV" >/dev/null 2>&1; then
    echo "session export: wrote $HISTORY_ENV from 1Password"
  else
    echo "WARN: session export: op cannot read $HISTORY_REF, so each session export fails; sign op in, then rerun $SCRIPT_DIR/post-create.sh" >&2
  fi
fi

echo "workbench ready: node $(node --version), pnpm $(pnpm --version), gh $(gh --version | head -1)"
exit "$failed"
