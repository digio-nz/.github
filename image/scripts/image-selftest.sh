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

skills-manager-cli --version >/dev/null \
  || fail "skills-manager-cli did not report a version"

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

export DIGIO_SKILLS_ROOT="${DIGIO_SKILLS_ROOT:-$HOME/.digio/skills}"
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
trap 'rm -rf "$TEST_HOME"' EXIT

# The deploy that post-start.sh runs, on the pinned skills checkout: each link of the factory preset reaches a skill.
mkdir -p "$HOME/.claude/skills" "$HOME/.codex/skills"
for agent in claude_code codex; do
  skills-manager-cli --skills-root "$(cd "$DIGIO_SKILLS_ROOT/skills" && pwd -P)" presets deploy factory --agent "$agent" >/dev/null \
    || fail "skills-manager-cli cannot deploy the factory preset for $agent"
done
for folder in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
  [ -n "$(find "$folder" -maxdepth 1 -type l 2>/dev/null)" ] || fail "the factory preset put no link in $folder"
  for link in "$folder"/*; do
    [ -f "$link/SKILL.md" ] || fail "$link does not reach a skill"
  done
done

bash "$DIR/session-export-sweep-selftest.sh"
bash "$DIR/humanlayer-daemon-selftest.sh"
[ "$(command -v humanlayer-daemon.sh)" = /usr/local/bin/humanlayer-daemon.sh ] \
  || fail "humanlayer-daemon.sh is not on PATH"
command -v flock >/dev/null || fail "humanlayer-daemon.sh needs flock, which is not on PATH"
bash "$DIR/npm-auth-selftest.sh"
# The start scripts' hooks check, on the image's own system gitconfig and a home with no global one.
bash "$DIR/git-hooks.sh" || fail "git-hooks.sh does not accept the image's baked hooksPath"

echo "image self-test passed: tools, skills, git hooks and worker setup"
