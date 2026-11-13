#!/usr/bin/env bash
# shellcheck disable=SC2016 # the npmrc line and the fixtures hold ${NODE_AUTH_TOKEN} as text
# post-create.sh writes the @digio-nz scope line and the variable name, not a token value, to ~/.npmrc (npm-auth.sh), and the shell profile
# sets NODE_AUTH_TOKEN (node-auth-token.sh) from GITHUB_TOKEN in a Codespace, else GH_TOKEN, else gh auth token. The machines run the same two
# scripts from their Michelin clone, so npm-auth.sh remove and the GH_TOKEN case are proved here too.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# The Codespace and desk container definition, at the michelin root.
DEVCONTAINER="$DIR/../../.devcontainer/devcontainer.json"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
SENTINEL='ghp_selftest_sentinel_0123456789'

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Checks one home: the npmrc holds the scope line once and the variable name once and no value; no file under the home holds the sentinel.
check_home() {
  local home="$1"
  [ "$(grep -cFx '@digio-nz:registry=https://npm.pkg.github.com' "$home/.npmrc")" = 1 ] \
    || fail "$home/.npmrc does not hold the @digio-nz scope line exactly once: $(cat "$home/.npmrc")"
  [ "$(grep -c '_authToken' "$home/.npmrc")" = 1 ] || fail "$home/.npmrc does not hold exactly one _authToken line"
  grep -Fxq '//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}' "$home/.npmrc" \
    || fail "$home/.npmrc does not hold the variable name: $(cat "$home/.npmrc")"
  ! grep -rqF "$SENTINEL" "$home" || fail "a token value was written under $home"
}

# A Michelin clone with no scripts, so post-create.sh runs only its own steps; stub tools stand in for node, pnpm and gh.
mkdir -p "$TEST_DIR/bin"
for tool in node pnpm npm; do
  printf '#!/usr/bin/env bash\necho stub-%s\n' "$tool" > "$TEST_DIR/bin/$tool"
  chmod +x "$TEST_DIR/bin/$tool"
done
# The stub gh reads the sentinel from a file outside every test home, so no home holds the value unless a script wrote it there.
printf '%s' "$SENTINEL" > "$TEST_DIR/sentinel"
printf '#!/usr/bin/env bash\n[ "${1:-}" = auth ] && [ "${2:-}" = token ] && { cat "%s"; exit 0; }\n[ "${1:-}" = auth ] && exit 1\necho stub-gh\n' \
  "$TEST_DIR/sentinel" > "$TEST_DIR/bin/gh"
chmod +x "$TEST_DIR/bin/gh"
export PATH="$TEST_DIR/bin:$PATH"
# post-create.sh fails when no git hooksPath is in effect. The image names its baked hooks in the system gitconfig; this file stands in for it.
export GIT_CONFIG_SYSTEM="$TEST_DIR/system.gitconfig"
git config --file "$GIT_CONFIG_SYSTEM" core.hooksPath "$(cd "$DIR/../../hooks/shims" && pwd -P)"

run_post_create() {
  local home="$1"
  mkdir -p "$home/.digio/michelin"
  git -C "$home/.digio/michelin" init -q
  mkdir -p "$home/.digio/skills"
  git -C "$home/.digio/skills" init -q
  HOME="$home" GIT_CONFIG_GLOBAL="$home/.gitconfig" DIGIO_SKILLS_ROOT="$home/.digio/skills" bash "$DIR/post-create.sh" > "$TEST_DIR/out" 2>&1 \
    || fail "post-create.sh failed: $(cat "$TEST_DIR/out")"
  # A global hooksPath overrides the image's baked hooks, so post-create.sh must leave none.
  [ -z "$(HOME="$home" GIT_CONFIG_GLOBAL="$home/.gitconfig" git config --global --get core.hooksPath || true)" ] \
    || fail "post-create.sh set a global hooksPath"
}

# The BASH_ENV that devcontainer.json sets for the container; the checks below pass it to each shell as the container does.
BASH_ENV_PATH="$(sed -n 's/^ *"BASH_ENV": *"\(.*\)".*/\1/p' "$DEVCONTAINER")"
[ "$BASH_ENV_PATH" = /home/vscode/.digio/node-auth-token.sh ] || fail "devcontainer.json does not set BASH_ENV to the token file: '$BASH_ENV_PATH'"

# A home as the base image leaves it: Ubuntu's skel .bashrc has an interactive-only guard at the top.
skel_home() {
  mkdir -p "$1"
  cp /etc/skel/.bashrc /etc/skel/.profile "$1/"
  # The skel .profile prepends $HOME/bin after /etc/profile, which can reset PATH, so the stubs live here to survive bash -l.
  mkdir -p "$1/bin"
  cp "$TEST_DIR/bin/"* "$1/bin/"
}

# Prints NODE_AUTH_TOKEN as the given shell sees it, with no hand-sourcing. $1 home, $2 mode, rest: env assignments.
shell_token() {
  local home="$1" mode="$2"
  shift 2
  local envfile="$home/.digio/node-auth-token.sh"
  local path="$home/bin:$PATH"
  case "$mode" in
    c) env -i HOME="$home" PATH="$path" BASH_ENV="$envfile" "$@" bash -c 'printf %s "${NODE_AUTH_TOKEN:-}"' ;;
    lc) env -i HOME="$home" PATH="$path" "$@" bash -lc 'printf %s "${NODE_AUTH_TOKEN:-}"' ;;
    zc) env -i HOME="$home" PATH="$path" "$@" zsh -c 'printf %s "${NODE_AUTH_TOKEN:-}"' ;;
  esac
}

modes=(c lc)
if command -v zsh >/dev/null 2>&1; then
  modes+=(zc)
else
  echo "note: zsh is not installed here, so the zsh check did not run" >&2
fi

# Two runs leave one line and one source line in each profile.
home="$TEST_DIR/home-twice"
skel_home "$home"
run_post_create "$home"
run_post_create "$home"
check_home "$home"
for profile in .bashrc .profile .zshenv; do
  [ "$(grep -c 'digio node-auth-token' "$home/$profile")" = 1 ] || fail "$profile does not hold the source line once"
done
[ "$(head -1 "$home/.bashrc" | grep -c 'digio node-auth-token')" = 1 ] || fail "the source line is not above the interactive guard in .bashrc"

# In a Codespace, every shell sets NODE_AUTH_TOKEN from GITHUB_TOKEN.
for mode in "${modes[@]}"; do
  got="$(shell_token "$home" "$mode" CODESPACES=true GITHUB_TOKEN="$SENTINEL")"
  [ "$got" = "$SENTINEL" ] || fail "bash/zsh mode '$mode' in a Codespace did not take NODE_AUTH_TOKEN from GITHUB_TOKEN"
done

# On the desk workbench, every shell sets it from gh auth token and ignores GITHUB_TOKEN, so c and zc set it to a wrong value.
# lc leaves it unset: the skel .profile sources .bashrc before it prepends $HOME/bin, so the first sourcing runs the real gh, which echoes GITHUB_TOKEN; the .profile tail line retries with the stub.
for mode in "${modes[@]}"; do
  extra=()
  [ "$mode" = lc ] || extra=(GITHUB_TOKEN=codespace-only)
  got="$(shell_token "$home" "$mode" ${extra[@]+"${extra[@]}"})"
  [ "$got" = "$SENTINEL" ] || fail "mode '$mode' on the desk workbench did not take NODE_AUTH_TOKEN from gh auth token"
done

# A value already in the environment wins.
for mode in "${modes[@]}"; do
  got="$(shell_token "$home" "$mode" NODE_AUTH_TOKEN=preset)"
  [ "$got" = preset ] || fail "mode '$mode' overwrote a preset NODE_AUTH_TOKEN"
done

# On a machine, a GH_TOKEN in the environment (a Hermes job) wins over the gh login.
got="$(env -i HOME="$TEST_DIR" PATH="$PATH" GH_TOKEN=from-gh-token sh -c ". '$DIR/node-auth-token.sh'; printf %s \"\${NODE_AUTH_TOKEN:-}\"")"
[ "$got" = from-gh-token ] || fail "node-auth-token.sh did not take NODE_AUTH_TOKEN from GH_TOKEN: '$got'"
# With no token anywhere and no gh, the variable stays unset, not empty.
mkdir -p "$TEST_DIR/nogh"
ln -sf "$(command -v env)" "$TEST_DIR/nogh/env"
got="$(env -i HOME="$TEST_DIR" PATH="$TEST_DIR/nogh" /bin/sh -c ". '$DIR/node-auth-token.sh'; [ -z \"\${NODE_AUTH_TOKEN+set}\" ] && echo unset")"
[ "$got" = unset ] || fail "node-auth-token.sh left NODE_AUTH_TOKEN set with no token"

# npm-auth.sh: apply adds a line to a file with no final newline without gluing; remove takes out only its two lines.
rc="$TEST_DIR/machine-npmrc"
printf 'save-exact=true' > "$rc"
bash "$DIR/npm-auth.sh" apply --npmrc "$rc" > /dev/null || fail "npm-auth.sh apply failed"
bash "$DIR/npm-auth.sh" apply --npmrc "$rc" > "$TEST_DIR/again" || fail "a second npm-auth.sh apply failed"
grep -q '^appended' "$TEST_DIR/again" && fail "a second npm-auth.sh apply changed the file"
[ "$(head -1 "$rc")" = save-exact=true ] && [ "$(( $(wc -l < "$rc") ))" -eq 3 ] || fail "npm-auth.sh apply glued or repeated a line: $(cat "$rc")"
bash "$DIR/npm-auth.sh" remove --npmrc "$rc" > /dev/null || fail "npm-auth.sh remove failed"
[ "$(cat "$rc")" = save-exact=true ] || fail "npm-auth.sh remove did not leave only the other lines: $(cat "$rc")"
if bash "$DIR/npm-auth.sh" bogus 2>/dev/null; then fail "npm-auth.sh accepted a bad mode"; fi

# A profile that is a symlink (a dotfiles checkout) is left alone.
home="$TEST_DIR/home-link"
skel_home "$home"
mkdir -p "$TEST_DIR/dotfiles"
echo '# dotfiles zshenv' > "$TEST_DIR/dotfiles/zshenv"
ln -s "$TEST_DIR/dotfiles/zshenv" "$home/.zshenv"
run_post_create "$home"
[ "$(cat "$TEST_DIR/dotfiles/zshenv")" = '# dotfiles zshenv' ] || fail "post-create.sh wrote through a symlinked profile"

# Red proof: the old block appended to the end of the skel .bashrc, with no BASH_ENV, is blind to bash -c and bash -lc.
old="$TEST_DIR/home-old"
skel_home "$old"
cat >> "$old/.bashrc" <<'OLD'
if [ -z "${NODE_AUTH_TOKEN:-}" ] && [ -n "${CODESPACES:-}" ]; then export NODE_AUTH_TOKEN="${GITHUB_TOKEN:-}"; fi
OLD
# An interactive shell needs a terminal, so the .bashrc line is checked by position above.
got="$(env -i HOME="$old" PATH="$PATH" CODESPACES=true GITHUB_TOKEN="$SENTINEL" bash -lc 'printf %s "${NODE_AUTH_TOKEN:-}"')"
[ -z "$got" ] || fail "the red fixture is not red: the old append-at-end block reached bash -lc"
got="$(env -i HOME="$old" PATH="$PATH" CODESPACES=true GITHUB_TOKEN="$SENTINEL" bash -c 'printf %s "${NODE_AUTH_TOKEN:-}"')"
[ -z "$got" ] || fail "the red fixture is not red: the old append-at-end block reached bash -c"

# Red proof: an npmrc that holds a value fails the checker.
bad="$TEST_DIR/home-bad"
mkdir -p "$bad"
printf '%s\n' '@digio-nz:registry=https://npm.pkg.github.com' "//npm.pkg.github.com/:_authToken=$SENTINEL" > "$bad/.npmrc"
if (check_home "$bad") 2>/dev/null; then
  fail "check_home passed an npmrc that holds a token value"
fi

# Red proof: an npmrc with the auth line and no scope line fails the checker.
noscope="$TEST_DIR/home-noscope"
mkdir -p "$noscope"
echo '//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}' > "$noscope/.npmrc"
if (check_home "$noscope") 2>/dev/null; then
  fail "check_home passed an npmrc with no @digio-nz scope line"
fi

echo "npm auth self-test passed"
