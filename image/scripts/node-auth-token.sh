# shellcheck shell=sh
# node-auth-token.sh: sets NODE_AUTH_TOKEN, the token npm sends to GitHub Packages (npm.pkg.github.com), when it is unset.
# Sourced, never run, by every shell: POSIX sh, quiet, and it writes no file. npm-auth.sh writes the npmrc lines that read it.
#   a NODE_AUTH_TOKEN already set wins;
#   in a Codespace (CODESPACES), the Codespace's GITHUB_TOKEN;
#   else a GH_TOKEN already in the environment (a Hermes job on a machine);
#   else the gh login: gh auth token. gh runs without BASH_ENV, or a gh that is a bash script would source this file again.
# The workbench copies this file to ~/.digio/node-auth-token.sh, which BASH_ENV and the shell profiles source (post-create.sh).
# A machine sources it from its Michelin clone through dotfiles' shell/agent-env.sh, which skips it on a machine that builds
# no Digio apps.
if [ -z "${NODE_AUTH_TOKEN:-}" ]; then
  if [ -n "${CODESPACES:-}" ]; then
    [ -z "${GITHUB_TOKEN:-}" ] || NODE_AUTH_TOKEN="$GITHUB_TOKEN"
  elif [ -n "${GH_TOKEN:-}" ]; then
    NODE_AUTH_TOKEN="$GH_TOKEN"
  elif command -v gh >/dev/null 2>&1; then
    NODE_AUTH_TOKEN="$(env -u BASH_ENV gh auth token 2>/dev/null)" || NODE_AUTH_TOKEN=""
  fi
  if [ -n "${NODE_AUTH_TOKEN:-}" ]; then export NODE_AUTH_TOKEN; else unset NODE_AUTH_TOKEN; fi
fi
