#!/usr/bin/env bash
# git-hooks.sh passes only when a pre-push hook is in effect, and removes a global core.hooksPath left in the
# digio-michelin clone. Each case runs real git against a system and a global gitconfig in a temp folder.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
for v in $(env | sed -n 's/^\(GIT_[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done
unset XDG_CONFIG_HOME

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The image's baked hooks: this repository's hooks folder, named in a system gitconfig.
cp -a "$DIR/../../hooks" "$TEST_DIR/baked"
BAKED="$TEST_DIR/baked/shims"
[ -x "$BAKED/pre-push" ] || fail "the fixture has no executable pre-push shim"

# new_home <name> [system hooksPath] [global hooksPath]: a home whose two gitconfig files this test owns.
new_home() {
  HOME="$TEST_DIR/home-$1"
  export HOME GIT_CONFIG_SYSTEM="$HOME/system.gitconfig" GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_SYSTEM"; : > "$GIT_CONFIG_GLOBAL"
  [ -z "${2:-}" ] || git config --system core.hooksPath "$2"
  [ -z "${3:-}" ] || git config --global core.hooksPath "$3"
}
check() { bash "$DIR/git-hooks.sh" > "$TEST_DIR/out" 2>&1; }
global() { git config --global --get core.hooksPath || true; }
# guards_push <name>: a clean push passes and a credential-shaped push is BLOCKED, through the hooksPath in effect.
guards_push() {
  local probe="$TEST_DIR/probe-$1"
  git init -q --bare "$probe/remote.git"
  git init -q "$probe/repo"
  (
    cd "$probe/repo"
    git -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m clean
    git push -q "$probe/remote.git" HEAD:refs/heads/probe || exit 1
    printf 'DATABASE_URL=postgres://app:%s%s@db.example.invalid/probe\n' Abcdefghij 12345 > content
    git add content
    git -c user.name=probe -c user.email=probe@example.invalid commit -q -m leak
    ! git push -q "$probe/remote.git" HEAD:refs/heads/probe 2>"$probe/err" && grep -q BLOCKED "$probe/err"
  )
}

new_home baked "$BAKED"
check || fail "the baked system hooksPath did not pass: $(cat "$TEST_DIR/out")"
[ -z "$(global)" ] || fail "git-hooks.sh wrote a global core.hooksPath: $(global)"
guards_push baked || fail "a push with only the system hooksPath did not run secret-guard"

# A home from an older image: the global path is in the Michelin clone, whose hooks are gone.
new_home stale "$BAKED" "$TEST_DIR/home-stale/.digio/michelin/hooks/shims"
check || fail "a stale global hooksPath failed the check; it must be removed: $(cat "$TEST_DIR/out")"
[ -z "$(global)" ] || fail "the stale global core.hooksPath was kept: $(global)"
grep -Fq "removed the global core.hooksPath '$TEST_DIR/home-stale/.digio/michelin/hooks/shims'" "$TEST_DIR/out" \
  || fail "git-hooks.sh did not name the path it removed: $(cat "$TEST_DIR/out")"
guards_push stale || fail "a push after the stale global hooksPath was removed did not run secret-guard"

# The same home on an image with no baked hooks: the clone's hooks stay in effect, and the check fails.
new_home stale-no-system "" "$TEST_DIR/home-stale-no-system/.digio/michelin/hooks/shims"
if check; then fail "a global hooksPath in the Michelin clone passed with no system hooksPath"; fi
grep -Fq "recreate the container from a current workbench image" "$TEST_DIR/out" || fail "the failure did not name the fix: $(cat "$TEST_DIR/out")"
[ "$(global)" = "$HOME/.digio/michelin/hooks/shims" ] || fail "git-hooks.sh removed the only hooksPath: '$(global)'"

new_home none
if check; then fail "no core.hooksPath passed"; fi
grep -Fq "core.hooksPath is 'unset' and has no pre-push hook; git push is not guarded" "$TEST_DIR/out" \
  || fail "the failure did not name an unset hooksPath: $(cat "$TEST_DIR/out")"

new_home missing-folder "$TEST_DIR/gone/shims"
if check; then fail "a system hooksPath with no folder passed"; fi
grep -Fq "core.hooksPath is '$TEST_DIR/gone/shims' and has no pre-push hook" "$TEST_DIR/out" \
  || fail "the failure did not name the missing folder: $(cat "$TEST_DIR/out")"

# A global path outside the Michelin clone overrides the system one, so it is the one checked.
new_home other-global "$BAKED" "$TEST_DIR/gone/shims"
if check; then fail "a global hooksPath with no pre-push hook passed because the system one has it"; fi
[ "$(global)" = "$TEST_DIR/gone/shims" ] || fail "git-hooks.sh changed a global hooksPath outside the Michelin clone"
cp -a "$DIR/../../hooks" "$TEST_DIR/own"
new_home own-global "$BAKED" "$TEST_DIR/own/shims"
check || fail "a working global hooksPath outside the Michelin clone failed: $(cat "$TEST_DIR/out")"
[ "$(global)" = "$TEST_DIR/own/shims" ] || fail "git-hooks.sh changed a working global hooksPath"

echo "git hooks self-test passed: the baked hooksPath guards a push, a stale global path in the Michelin clone is removed, and no pre-push hook fails loudly"
