#!/usr/bin/env bash
# workbench-start.sh [command...]: the image's CMD, for a container that no dev container tool starts, such as the one on msi.
# Codespaces, VS Code and the devcontainer CLI replace CMD and run post-create.sh and post-start.sh from their own slots.
# This runs them from a digio-nz/.github checkout at ~/.digio/github, which each start pulls, on the same lifecycle in the
# background: post-create.sh until it succeeds once in this home, then post-start.sh at each start.
# Then it execs T3, or the command given.
# The last line of its log, "start: exit N", is the start-up result.
set -u
# The same as .devcontainer/devcontainer.json containerEnv; T3 and the agents it starts inherit it.
export WORKBENCH=1 BASH_ENV="$HOME/.digio/node-auth-token.sh"
# The token of the workbench's 1Password service account. T3 and each agent that it starts inherit it, so `op read` needs no sign-in.
token_file="$HOME/.config/digio/op-workbench"
if [ -r "$token_file" ]; then OP_SERVICE_ACCOUNT_TOKEN="$(tr -d '[:space:]' < "$token_file")"; export OP_SERVICE_ACCOUNT_TOKEN; fi
scripts="$HOME/.digio/github"
state="$HOME/.local/state/digio-workbench"
mkdir -p "$state"
# With a service account, this script runs itself once more inside `op run`. The start scripts, T3 and each agent then have each
# value of the reference file in their environment, and no value goes to a file. `op run` hides a value that a process prints.
# The first call is a test with a time limit. When 1Password does not answer, the start goes on with no values, and post-start.sh
# reports the line in op-env.fail.
refs="${WORKBENCH_OP_ENV:-/opt/digio/workbench-op.env}"
if [ -z "${WORKBENCH_OP_ENV_LOADED:-}" ]; then
  rm -f "$state/op-env.fail"
  if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ -r "$refs" ]; then
    if timeout 45 op run --env-file "$refs" -- true 2>"$state/op-run.err"; then
      WORKBENCH_OP_ENV_LOADED=1 exec op run --env-file "$refs" -- "$0" "$@"
    fi
    echo "FAIL: workbench: op did not read each reference of $refs in 45 seconds, so T3 and the start scripts have no credential: $(tr '\n' ' ' < "$state/op-run.err")" > "$state/op-env.fail"
  fi
fi
{
  if [ -d "$scripts/.git" ]; then
    git -C "$scripts" pull -q --ff-only || echo "digio-nz/.github refresh failed; using the existing checkout" >&2
  else
    git clone -q https://github.com/digio-nz/.github.git "$scripts" || echo "digio-nz/.github clone failed" >&2
  fi
  { [ -e "$state/created" ] || { bash "$scripts/image/scripts/post-create.sh" && touch "$state/created"; }; } \
    && bash "$scripts/image/scripts/post-start.sh"
  echo "start: exit $?"
} > "$state/start.log" 2>&1 &
[ "$#" -gt 0 ] || set -- t3 --no-browser --host 0.0.0.0 --port 3773
exec "$@"
