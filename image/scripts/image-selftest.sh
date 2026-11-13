#!/usr/bin/env bash
# Runs inside the built image, as the Build image workflow's last build step (devcontainers/ci runCmd): the image's own
# tool check and the self-tests of the start scripts that need the image.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

fail() {
  echo "image self-test failed: $*" >&2
  exit 1
}

# The image's copy of the list and the script, not the checkout's: this is what a sandbox gets.
out="$(/opt/digio/tools/tools.sh check --scope image)" || { echo "$out" >&2; fail "tools.sh check found a missing tool"; }
echo "$out"

OP_BIN="$(command -v op)" || fail "op is not on PATH"
"$OP_BIN" --version >/dev/null \
  || fail "op did not report a version"

NO_MISTAKES_BIN="$(command -v no-mistakes)" || fail "no-mistakes is not on PATH"
"$NO_MISTAKES_BIN" --version >/dev/null \
  || fail "no-mistakes did not report a version"

/opt/digio/tools/skills-manager-cli.sh check || fail "the image lacks the pinned Skills Manager CLI"

# Every push in the image runs secret-guard: the system gitconfig points at the baked shims, and a credential-shaped
# push to a throwaway local remote is refused through them.
[ "$(git config --system --get core.hooksPath)" = /opt/digio/michelin-hooks/shims ] \
  || fail "the system gitconfig does not point core.hooksPath at /opt/digio/michelin-hooks/shims"
bash /opt/digio/michelin-hooks/install.sh --system --check >/dev/null \
  || fail "the baked hooks fail install.sh --system --check"
probe="$(mktemp -d)"
(
  set -e
  for v in $(env | sed -n 's/^\(GIT_CONFIG[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done
  export GIT_CONFIG_GLOBAL=/dev/null
  git init -q --bare "$probe/remote.git"
  git init -q "$probe/repo"
  cd "$probe/repo"
  git -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m clean
  git push -q "$probe/remote.git" HEAD:refs/heads/probe
  printf 'DATABASE_URL=postgres://app:%s%s@db.example.invalid/probe\n' Abcdefghij 12345 > content
  git add content
  git -c user.name=probe -c user.email=probe@example.invalid commit -q -m leak
  ! git push -q "$probe/remote.git" HEAD:refs/heads/probe 2>"$probe/err"
  grep -q BLOCKED "$probe/err"
) || { rm -rf "$probe"; fail "a push in the image did not run secret-guard through the system hooksPath"; }
rm -rf "$probe"
echo "hooks: system hooksPath guards pushes (clean passes, credential BLOCKED)"

export DIGIO_SKILLS_ROOT="${DIGIO_SKILLS_ROOT:-$HOME/devs/digio-skills}"
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
trap 'rm -rf "$TEST_HOME"' EXIT

# The skills that the workbench and a worker get, installed for real into the scratch home.
mkdir -p "$HOME/.claude" "$HOME/.codex"
for consumer in workbench worker; do
  bash "$DIGIO_SKILLS_ROOT/lib/skills-install.sh" apply "$consumer" >/dev/null \
    && bash "$DIGIO_SKILLS_ROOT/lib/skills-install.sh" check "$consumer" \
    || fail "the $consumer skills do not install with the image's Skills Manager CLI"
  rm -rf "$HOME/.skills-manager" "$HOME/.claude/skills" "$HOME/.codex/skills"
done

bash "$DIR/session-export-sweep-selftest.sh"
bash "$DIR/humanlayer-daemon-selftest.sh"
[ "$(command -v humanlayer-daemon.sh)" = /usr/local/bin/humanlayer-daemon.sh ] \
  || fail "humanlayer-daemon.sh is not on PATH"
command -v flock >/dev/null || fail "humanlayer-daemon.sh needs flock, which is not on PATH"
bash "$DIR/npm-auth-selftest.sh"

echo "image self-test passed: tools, installed skills, git hooks and worker setup"
