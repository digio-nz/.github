#!/usr/bin/env bash
# workbench-start.sh [command...]: the image's CMD, for a container that no dev container tool starts, such as the one on msi.
# Codespaces, VS Code and the devcontainer CLI replace CMD and run post-create.sh and post-start.sh from their own slots.
# This runs them on the same lifecycle in the background: post-create.sh until it succeeds once in this home,
# then post-start.sh at each start. Then it execs T3, or the command given.
# The last line of its log, "start: exit N", is the start-up result.
set -u
# The same as .devcontainer/devcontainer.json containerEnv; T3 and the agents it starts inherit it.
export WORKBENCH=1 BASH_ENV="$HOME/.digio/node-auth-token.sh"
michelin="$HOME/.digio/michelin"
state="$HOME/.local/state/digio-workbench"
mkdir -p "$state"
{
  [ -d "$michelin/.git" ] || git clone -q https://github.com/digio-nz/digio-michelin.git "$michelin" \
    || echo "digio-michelin clone failed: run gh auth login in the container, then restart it" >&2
  { [ -e "$state/created" ] || { bash "$michelin/image/scripts/post-create.sh" && touch "$state/created"; }; } \
    && bash "$michelin/image/scripts/post-start.sh"
  echo "start: exit $?"
} > "$state/start.log" 2>&1 &
[ "$#" -gt 0 ] || set -- t3 --no-browser --host 0.0.0.0 --port 3773
exec "$@"
