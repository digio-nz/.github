#!/usr/bin/env bash
# shellcheck disable=SC2016 # the fixture scripts expand their variables when they run
# The start scripts keep the workbench checkout current and install the workbench skills.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MICHELIN_HOOKS="$(cd "$DIR/../../hooks" && pwd -P)"
# shellcheck source=../../lib/host.sh
. "$DIR/../../lib/host.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TEST_DIR/devcontainer"
cp "$DIR/post-create.sh" "$DIR/post-start.sh" "$DIR/npm-auth.sh" "$DIR/node-auth-token.sh" "$TEST_DIR/devcontainer/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/devcontainer/tailnet-start.sh"
printf '#!/usr/bin/env bash\necho "session-export-sweep.sh $*" >> "$CALLS"\n[ -z "${FAIL_session_export_scheduler:-}" ]\n' \
  > "$TEST_DIR/devcontainer/session-export-sweep.sh"
printf '#!/usr/bin/env bash\necho "humanlayer-daemon.sh $*" >> "$CALLS"\n' \
  > "$TEST_DIR/devcontainer/humanlayer-daemon.sh"

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/skills-template/skills/skill-sets/scripts" \
  "$TEST_DIR/skills-template/skills/install-briefs/scripts" "$TEST_DIR/skills-template/skills/session-close/scripts" \
  "$TEST_DIR/skills-template/scripts"
for tool in node pnpm gh npm; do
  printf '#!/usr/bin/env bash\n[ "${1:-}" = auth ] && exit 1\necho stub-%s\n' "$tool" > "$TEST_DIR/bin/$tool"
  chmod +x "$TEST_DIR/bin/$tool"
done
printf '#!/usr/bin/env bash\necho "npm $*" >> "$CALLS"\n' > "$TEST_DIR/bin/npm"
cat > "$TEST_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$CALLS"
case "$*" in
  "config --global user.name"|"config --global user.email") [ -n "${GIT_IDENTITY:-}" ] || exit 1; echo "$GIT_IDENTITY" ;;
  *" status --porcelain") [ -z "${GIT_STATUS:-}" ] || echo "$GIT_STATUS" ;;
  *" rev-list --count HEAD..origin/main") echo "${GIT_BEHIND:-0}" ;;
esac
if [ "${1:-}" = clone ]; then
  target="${*: -1}"
  cp -R "$CLONE_SOURCE" "$target"
  mkdir -p "$target/.git"
fi
STUB
for command in claude codex; do
  cat > "$TEST_DIR/bin/$command" <<'STUB'
#!/usr/bin/env bash
echo "${0##*/} $*" >> "$CALLS"
STUB
  chmod +x "$TEST_DIR/bin/$command"
done
# op inject resolves the one reference post-create may ask for, into the file it names.
cat > "$TEST_DIR/bin/op" <<'STUB'
#!/usr/bin/env bash
echo "op $*" >> "$CALLS"
[ -z "${FAIL_op:-}" ] || exit 1
[ "$1 $2 $3" = "inject --force --out-file" ] || exit 2
sed 's|{{ op://orchestrator/DIGIO_HISTORY_DATABASE_URL/credential }}|postgres://fixture-history|' > "$4"
STUB
# The installer's own self-test in digio-skills drives the real CLI; here it records its call and the agent folders.
mkdir -p "$TEST_DIR/skills-template/lib"
printf '#!/usr/bin/env bash\necho "skills-install.sh $* claude=$([ -d "$HOME/.claude" ] && echo y) codex=$([ -d "$HOME/.codex" ] && echo y)" >> "$CALLS"\n[ -z "${FAIL_skills:-}" ]\n' \
  > "$TEST_DIR/skills-template/lib/skills-install.sh"
for script in install-briefs session-close; do
  printf '#!/usr/bin/env bash\necho "%s.sh $*" >> "$CALLS"\n' "$script" \
    > "$TEST_DIR/skills-template/skills/$script/scripts/$script.sh"
done
touch "$TEST_DIR/skills-template/package.json"
chmod +x "$TEST_DIR/bin/"* "$TEST_DIR/skills-template/skills/"*/scripts/*.sh
export PATH="$TEST_DIR/bin:$PATH" CALLS="$TEST_DIR/calls" CLONE_SOURCE="$TEST_DIR/skills-template"
unset DIGIO_SKILLS_ROOT CLAUDE_CONFIG_DIR CODESPACES CODESPACE_VSCODE_FOLDER DIGIO_HISTORY_DATABASE_URL DIGIO_HISTORY_ENV GIT_IDENTITY GIT_STATUS GIT_BEHIND
# A Codespace or workbench running this test has a real /workspaces; a case that wants one passes its own.
export DIGIO_WORKSPACES="$TEST_DIR/no-workspaces"

fixture_home() {
  local home="$TEST_DIR/home-$1"
  mkdir -p "$home/.digio/michelin/.git"
  # post-create installs the clone's git hooks globally and fails without them.
  cp -a "$MICHELIN_HOOKS" "$home/.digio/michelin/hooks"
  echo "$home"
}

: > "$CALLS"
home="$(fixture_home post-create)"
HOME="$home" bash "$TEST_DIR/devcontainer/post-create.sh" > "$TEST_DIR/out" 2>&1 \
  || fail "post-create failed: $(cat "$TEST_DIR/out")"
! grep -Eq 'skill-sets|skills.py|install-skills|install-briefs' "$CALLS" \
  || fail "post-create configured skills: $(cat "$CALLS")"
grep -Fxq "git config --global core.hooksPath $home/.digio/michelin/hooks/shims" "$CALLS" \
  || fail "post-create did not point the global hooksPath at the michelin shims: $(cat "$CALLS")"
grep -Fq "WARN: session export: $home/devs/digio-history is missing" "$TEST_DIR/out" \
  || fail "post-create did not warn that digio-history is missing: $(cat "$TEST_DIR/out")"

# A first start: ~/devs is not linked yet, so the history file goes to the workspace disk.
: > "$CALLS"
home="$(fixture_home history-write)"; ws="$TEST_DIR/ws-history"; mkdir -p "$ws/devs/digio-history"
HOME="$home" DIGIO_WORKSPACES="$ws" bash "$TEST_DIR/devcontainer/post-create.sh" > "$TEST_DIR/out" 2>&1 \
  || fail "post-create failed writing the history file: $(cat "$TEST_DIR/out")"
[ "$(cat "$ws/devs/digio-history/.env.local" 2>/dev/null)" = "DATABASE_URL=postgres://fixture-history" ] \
  || fail "post-create did not write DATABASE_URL from 1Password: $(cat "$TEST_DIR/out") $(cat "$CALLS")"
! grep -q fixture-history "$TEST_DIR/out" || fail "post-create printed the database URL"
: > "$CALLS"
HOME="$home" DIGIO_WORKSPACES="$ws" bash "$TEST_DIR/devcontainer/post-create.sh" > "$TEST_DIR/out" 2>&1 || fail "post-create failed with a history file"
! grep -q '^op ' "$CALLS" || fail "post-create read 1Password when the history file exists: $(cat "$CALLS")"
rm "$ws/devs/digio-history/.env.local"
HOME="$home" DIGIO_WORKSPACES="$ws" DIGIO_HISTORY_DATABASE_URL=set bash "$TEST_DIR/devcontainer/post-create.sh" > "$TEST_DIR/out" 2>&1 \
  || fail "post-create failed with the history secret"
! grep -q '^op ' "$CALLS" && [ ! -e "$ws/devs/digio-history/.env.local" ] || fail "post-create wrote the history file when the secret is set"
if HOME="$home" DIGIO_WORKSPACES="$ws" FAIL_op=1 bash "$TEST_DIR/devcontainer/post-create.sh" > "$TEST_DIR/out" 2>&1; then :; else
  fail "post-create failed when op could not read the history URL; it warns only: $(cat "$TEST_DIR/out")"
fi
grep -Fq "WARN: session export: op cannot read op://orchestrator/DIGIO_HISTORY_DATABASE_URL/credential" "$TEST_DIR/out" \
  || fail "post-create did not warn that op cannot read the history URL: $(cat "$TEST_DIR/out")"
[ ! -e "$ws/devs/digio-history/.env.local" ] || fail "post-create left a history file when op failed"

: > "$CALLS"
home="$(fixture_home post-start-clone)"
mkdir -p "$home/.claude/skills"; ln -s "$home/devs/digio-skills/skills/old" "$home/.claude/skills/old"
ln -s "$TEST_DIR/elsewhere" "$home/.claude/skills/kept"
HOME="$home" \
  bash "$TEST_DIR/devcontainer/post-start.sh" > "$TEST_DIR/out" 2>&1 \
  || fail "post-start failed after a fresh clone: $(cat "$TEST_DIR/out")"
grep -Fq "git clone -q https://github.com/digio-nz/digio-skills.git $home/devs/digio-skills" "$CALLS" \
  || fail "post-start did not clone digio-skills into ~/devs: $(cat "$CALLS")"
grep -Fxq "skills-install.sh apply workbench claude=y codex=y" "$CALLS" \
  || fail "post-start did not install the workbench skills after making the agent folders: $(cat "$CALLS")"
[ ! -L "$home/.claude/skills/old" ] && [ -L "$home/.claude/skills/kept" ] \
  || fail "post-start did not remove only the native link into the skills checkout"
grep -Fxq "codex mcp remove skillport" "$CALLS" && grep -Fxq "claude mcp remove --scope user skillport" "$CALLS" \
  || fail "post-start did not remove the old MCP entries: $(cat "$CALLS")"
! grep -q "mcp add" "$CALLS" || fail "post-start added an MCP server: $(cat "$CALLS")"
grep -Fxq "session-export-sweep.sh start $home/devs/digio-skills" "$CALLS" \
  || fail "post-start did not schedule session exports from the skills checkout"
! grep -q "humanlayer-daemon.sh" "$CALLS" || fail "post-start started the HumanLayer daemon: $(cat "$CALLS")"
! grep -q 'install-skills' "$CALLS" || fail "post-start still ran install-skills: $(cat "$CALLS")"
grep -Fxq "git config --global user.name digbycampbell" "$CALLS" \
  && grep -Fxq "git config --global user.email 96467498+digbycampbell@users.noreply.github.com" "$CALLS" \
  || fail "post-start did not set the hidden-email git identity: $(cat "$CALLS")"
! grep -q '^WARN: briefs' "$TEST_DIR/out" || fail "post-start warned about a clean, current brief checkout: $(cat "$TEST_DIR/out")"
grep -Fq "WARN: session export: no DIGIO_HISTORY_DATABASE_URL secret and no $home/devs/digio-history/.env.local" "$TEST_DIR/out" \
  || fail "post-start did not warn that session exports have no store: $(cat "$TEST_DIR/out")"

: > "$CALLS"
home="$(fixture_home post-start-pull)"
mkdir -p "$home/devs"
cp -R "$TEST_DIR/skills-template" "$home/devs/digio-skills"
mkdir -p "$home/devs/digio-skills/.git"
HOME="$home" \
  bash "$TEST_DIR/devcontainer/post-start.sh" > "$TEST_DIR/out" 2>&1 \
  || fail "post-start failed with an existing checkout: $(cat "$TEST_DIR/out")"
grep -Fxq "git -C $home/devs/digio-skills pull -q --ff-only" "$CALLS" \
  || fail "post-start did not pull the existing skills checkout: $(cat "$CALLS")"

: > "$CALLS"
home="$(fixture_home identity-kept)"
mkdir -p "$home/devs/digio-history"; echo DATABASE_URL=x > "$home/devs/digio-history/.env.local"
HOME="$home" GIT_IDENTITY=someone \
  bash "$TEST_DIR/devcontainer/post-start.sh" > "$TEST_DIR/out" 2>&1 || fail "post-start failed with a git identity: $(cat "$TEST_DIR/out")"
! grep -Eq '^git config --global user\.(name|email) ' "$CALLS" || fail "post-start replaced an existing git identity: $(cat "$CALLS")"
! grep -q 'WARN: session export' "$TEST_DIR/out" || fail "post-start warned about session export with a history file: $(cat "$TEST_DIR/out")"

home="$(fixture_home brief-drift)"
HOME="$home" GIT_STATUS=' M briefs/AGENTS.md' GIT_BEHIND=3 \
  bash "$TEST_DIR/devcontainer/post-start.sh" > "$TEST_DIR/out" 2>&1 || fail "post-start failed on a drifted brief checkout; it warns only: $(cat "$TEST_DIR/out")"
grep -Fq "WARN: briefs: $home/.digio/michelin has local changes" "$TEST_DIR/out" || fail "post-start did not warn about local brief changes: $(cat "$TEST_DIR/out")"
grep -Fq "WARN: briefs: $home/.digio/michelin is 3 commits behind origin/main" "$TEST_DIR/out" || fail "post-start did not warn that the briefs are behind: $(cat "$TEST_DIR/out")"

home="$TEST_DIR/home-no-michelin"; mkdir -p "$home"
HOME="$home" bash "$TEST_DIR/devcontainer/post-start.sh" > "$TEST_DIR/out" 2>&1
grep -Fq "WARN: briefs: $home/.digio/michelin is missing" "$TEST_DIR/out" || fail "post-start did not warn that the briefs are missing: $(cat "$TEST_DIR/out")"

: > "$CALLS"
home="$(fixture_home skills-failure)"
if HOME="$home" FAIL_skills=1 \
  bash "$TEST_DIR/devcontainer/post-start.sh" > "$TEST_DIR/out" 2>&1; then
  fail "post-start exited 0 when the skills install failed"
fi
grep -Fq 'skills: install failed' "$TEST_DIR/out" || fail "post-start did not name the skills install failure"
grep -Fq 'install-briefs.sh apply' "$CALLS" || fail "post-start stopped before installing briefs"

: > "$CALLS"
home="$(fixture_home scheduler-failure)"
if HOME="$home" FAIL_session_export_scheduler=1 \
  bash "$TEST_DIR/devcontainer/post-start.sh" > "$TEST_DIR/out" 2>&1; then
  fail "post-start exited 0 when the session-export scheduler failed"
fi
grep -Fq 'session-export scheduler failed to start' "$TEST_DIR/out" \
  || fail "post-start did not name the failed session-export scheduler"

: > "$CALLS"
start_with_workspaces() { # <home> <workspaces>
  HOME="$1" DIGIO_WORKSPACES="$2" \
    bash "$TEST_DIR/devcontainer/post-start.sh" > "$TEST_DIR/out" 2>&1
}
: > "$CALLS"
home="$(fixture_home devs-fresh)"; ws="$TEST_DIR/ws-fresh"; mkdir -p "$ws"
start_with_workspaces "$home" "$ws" || fail "post-start failed with a workspace disk: $(cat "$TEST_DIR/out")"
[ "$(readlink "$home/devs")" = "$ws/devs" ] || fail "post-start did not link ~/devs to the workspace devs folder"
[ -d "$ws/devs/digio-skills" ] || fail "digio-skills did not land in the workspace devs folder"
grep -q "^npm install --prefix $ws/devs/digio-skills " "$CALLS" \
  || fail "post-start installed through the ~/devs link, not the real path: $(grep '^npm' "$CALLS")"
! grep -q "insteadOf" "$CALLS" || fail "post-start routed git over HTTPS outside a Codespace"

home="$(fixture_home devs-move)"; ws="$TEST_DIR/ws-move"; mkdir -p "$ws" "$home/devs"
cp -R "$TEST_DIR/skills-template" "$home/devs/digio-skills"; mkdir -p "$home/devs/digio-skills/.git"
start_with_workspaces "$home" "$ws" || fail "post-start failed to move ~/devs: $(cat "$TEST_DIR/out")"
[ "$(readlink "$home/devs")" = "$ws/devs" ] && [ -d "$ws/devs/digio-skills/.git" ] || fail "post-start did not move ~/devs into the workspace devs folder"

home="$(fixture_home devs-clash)"; ws="$TEST_DIR/ws-clash"; mkdir -p "$ws/devs/digio-skills" "$home/devs/digio-skills"
if start_with_workspaces "$home" "$ws"; then fail "post-start exited 0 when ~/devs and the workspace disk both had digio-skills"; fi
grep -Fq "move $home/devs/digio-skills by hand" "$TEST_DIR/out" || fail "post-start did not name the clash: $(cat "$TEST_DIR/out")"
[ -d "$home/devs" ] && [ ! -L "$home/devs" ] || fail "post-start changed ~/devs despite the clash"

home="$(fixture_home devs-elsewhere)"; ws="$TEST_DIR/ws-elsewhere"; mkdir -p "$ws" "$TEST_DIR/other"; ln -s "$TEST_DIR/other" "$home/devs"
if start_with_workspaces "$home" "$ws"; then fail "post-start exited 0 when ~/devs linked elsewhere"; fi
grep -Fq "links to $TEST_DIR/other, not $ws/devs" "$TEST_DIR/out" || fail "post-start did not name the wrong link"

home="$(fixture_home devs-repoint)"; ws="$TEST_DIR/ws-repoint"; mkdir -p "$ws"; ln -s "$ws" "$home/devs"
start_with_workspaces "$home" "$ws" || fail "post-start failed to re-point an old ~/devs link: $(cat "$TEST_DIR/out")"
[ "$(readlink "$home/devs")" = "$ws/devs" ] || fail "post-start did not re-point ~/devs from the workspace root to its devs folder"

: > "$CALLS"
home="$(fixture_home devs-own)"; ws="$TEST_DIR/ws-own"; mkdir -p "$ws/digio-michelin"
CODESPACES=true CODESPACE_VSCODE_FOLDER="$ws/digio-michelin" start_with_workspaces "$home" "$ws" \
  || fail "post-start failed in a Codespace: $(cat "$TEST_DIR/out")"
[ "$(readlink "$ws/devs/digio-michelin")" = "$ws/digio-michelin" ] || fail "post-start did not link the codespace's own repo into devs"
grep -Fq 'git config --global url.https://github.com/.insteadOf git@github.com:' "$CALLS" \
  || fail "post-start did not route git@github.com: over HTTPS in a Codespace: $(cat "$CALLS")"

home="$(fixture_home logins-desk)"; ws="$TEST_DIR/ws-logins-desk"; mkdir -p "$ws"
start_with_workspaces "$home" "$ws" || fail "post-start failed at a desk: $(cat "$TEST_DIR/out")"
[ ! -L "$home/.codex" ] && [ ! -e "$ws/.home" ] || fail "post-start moved logins outside a Codespace"

home="$(fixture_home logins-fresh)"; ws="$TEST_DIR/ws-logins-fresh"; mkdir -p "$ws"
CODESPACES=true start_with_workspaces "$home" "$ws" || fail "post-start failed to keep logins: $(cat "$TEST_DIR/out")"
[ "$(readlink "$home/.codex")" = "$ws/.home/codex" ] && [ "$(readlink "$home/.humanlayer/riptide")" = "$ws/.home/humanlayer-riptide" ] \
  || fail "post-start did not link the Codex and HumanLayer folders to the kept disk"
[ "$(host_mode "$ws/.home")" = 700 ] || fail "the login store is not private"

home="$(fixture_home logins-move)"; ws="$TEST_DIR/ws-logins-move"; mkdir -p "$ws" "$home/.codex"; echo login > "$home/.codex/auth.json"
CODESPACES=true start_with_workspaces "$home" "$ws" || fail "post-start failed to move a login: $(cat "$TEST_DIR/out")"
[ "$(cat "$ws/.home/codex/auth.json")" = login ] && [ -L "$home/.codex" ] || fail "post-start did not move an existing login onto the kept disk"

home="$(fixture_home logins-kept)"; ws="$TEST_DIR/ws-logins-kept"; mkdir -p "$ws/.home/codex" "$home/.codex"
echo kept > "$ws/.home/codex/auth.json"; echo fresh > "$home/.codex/config.toml"
CODESPACES=true start_with_workspaces "$home" "$ws" || fail "post-start failed with a kept login: $(cat "$TEST_DIR/out")"
[ "$(cat "$home/.codex/auth.json")" = kept ] && ls "$ws/.home"/replaced-codex-*/config.toml >/dev/null 2>&1 \
  || fail "post-start did not keep the kept login and set the fresh folder aside"

home="$(fixture_home logins-elsewhere)"; ws="$TEST_DIR/ws-logins-elsewhere"; mkdir -p "$ws" "$TEST_DIR/codex-other"; ln -s "$TEST_DIR/codex-other" "$home/.codex"
if CODESPACES=true start_with_workspaces "$home" "$ws"; then fail "post-start exited 0 when ~/.codex linked elsewhere"; fi
grep -Fq "links to $TEST_DIR/codex-other, not $ws/.home/codex" "$TEST_DIR/out" || fail "post-start did not name the wrong login link"

# A rebuild keeps only the workspace disk: the second start, in an empty home, finds the repos and logins there.
: > "$CALLS"
home="$(fixture_home rebuild)"; ws="$TEST_DIR/ws-rebuild"; mkdir -p "$ws/digio-michelin" "$home/.codex"; echo login > "$home/.codex/auth.json"
CODESPACES=true CODESPACE_VSCODE_FOLDER="$ws/digio-michelin" start_with_workspaces "$home" "$ws" \
  || fail "post-start failed before the rebuild: $(cat "$TEST_DIR/out")"
echo work > "$ws/devs/digio-skills/uncommitted.txt"
rm -rf "$home"; home="$(fixture_home rebuild)"
: > "$CALLS"
CODESPACES=true CODESPACE_VSCODE_FOLDER="$ws/digio-michelin" start_with_workspaces "$home" "$ws" \
  || fail "post-start failed after the rebuild: $(cat "$TEST_DIR/out")"
[ "$(cat "$home/devs/digio-skills/uncommitted.txt" 2>/dev/null)" = work ] || fail "the rebuild lost work in ~/devs"
[ "$(readlink "$ws/devs/digio-michelin")" = "$ws/digio-michelin" ] || fail "the rebuild lost the link to the codespace's own repo"
[ "$(cat "$home/.codex/auth.json" 2>/dev/null)" = login ] || fail "the rebuild lost the Codex login"
grep -Fxq "git -C $home/devs/digio-skills pull -q --ff-only" "$CALLS" && ! grep -q 'clone.*digio-skills' "$CALLS" \
  || fail "after the rebuild post-start did not reuse the kept digio-skills checkout: $(cat "$CALLS")"

# The image's CMD, where no dev container tool runs the slots: post-create.sh, then post-start.sh, in the background, then the command.
cmd_start() { # <home> [post-create exit]: run workbench-start.sh with stub start scripts; waits for its log
  local h="$1" s="$1/.digio/github/image/scripts"
  if [ -n "${2:-}" ]; then
    mkdir -p "$s" "$h/.digio/github/.git"
    printf 'echo "create $BASH_ENV" >> "%s/order"; exit %s\n' "$h" "$2" > "$s/post-create.sh"
    printf 'echo start >> "%s/order"\n' "$h" > "$s/post-start.sh"
  fi
  HOME="$h" bash "$DIR/workbench-start.sh" sh -c 'echo "command $WORKBENCH" >> "$HOME/order"' || return 1
  for _ in $(seq 50); do grep -q '^start: exit' "$h/.local/state/digio-workbench/start.log" 2>/dev/null && return 0; sleep 0.1; done
  fail "workbench-start.sh wrote no exit line: $(cat "$h/.local/state/digio-workbench/start.log" 2>/dev/null)"
}
h="$TEST_DIR/cmd-ok"; cmd_start "$h" 0
[ "$(tail -n 1 "$h/.local/state/digio-workbench/start.log")" = "start: exit 0" ] || fail "workbench-start.sh did not log a clean start"
grep -Fxq "create $h/.digio/node-auth-token.sh" "$h/order" || fail "workbench-start.sh did not set BASH_ENV as the dev container does: $(cat "$h/order")"
grep -Fxq "command 1" "$h/order" || fail "workbench-start.sh did not exec its command with WORKBENCH set: $(cat "$h/order")"
[ "$(grep -v '^command' "$h/order" | cut -d' ' -f1 | tr '\n' ' ')" = "create start " ] || fail "workbench-start.sh did not run post-create.sh, then post-start.sh: $(cat "$h/order")"
: > "$h/order"; : > "$CALLS"; cmd_start "$h"
grep -Fxq "git -C $h/.digio/github pull -q --ff-only" "$CALLS" || fail "workbench-start.sh did not pull the start-up scripts at the next start: $(cat "$CALLS")"
[ "$(grep -v '^command' "$h/order")" = start ] || fail "workbench-start.sh reran post-create.sh at the next start; a dev container runs it once: $(cat "$h/order")"
h="$TEST_DIR/cmd-create-fails"; cmd_start "$h" 1
[ "$(tail -n 1 "$h/.local/state/digio-workbench/start.log")" = "start: exit 1" ] || fail "workbench-start.sh hid a failed post-create.sh"
! grep -qx start "$h/order" || fail "workbench-start.sh ran post-start.sh after post-create.sh failed; a dev container does not"
: > "$h/order"; cmd_start "$h"
grep -q '^create' "$h/order" || fail "workbench-start.sh did not retry a failed post-create.sh at the next start"
: > "$CALLS"; h="$TEST_DIR/cmd-fresh"; mkdir -p "$h"
cmd_start "$h"
grep -Fxq "git clone -q https://github.com/digio-nz/.github.git $h/.digio/github" "$CALLS" || fail "workbench-start.sh did not clone digio-nz/.github into a fresh home: $(cat "$CALLS")"
grep -q '^start: exit [1-9]' "$h/.local/state/digio-workbench/start.log" || fail "workbench-start.sh hid a start-up with no start-up scripts"
grep -Fxq "command 1" "$h/order" || fail "workbench-start.sh did not start its command when the start-up failed"
grep -Fxq 'CMD ["/usr/local/bin/workbench-start.sh"]' "$DIR/../assets/image/Dockerfile" || fail "the image CMD is not workbench-start.sh"
grep -Fq '"BASH_ENV": "/home/vscode/.digio/node-auth-token.sh"' "$DIR/../../.devcontainer/devcontainer.json" \
  || fail "devcontainer.json BASH_ENV no longer matches workbench-start.sh"

echo "workbench start self-test passed: the image CMD runs the dev container start-up, then T3, post-start sets the hidden-email git identity and warns on drifted briefs, post-create writes the session-export store from 1Password or warns, a rebuild keeps ~/devs and the logins, post-start links ~/devs to the workspace devs folder, keeps Codespace logins on the kept disk, routes Codespace git over HTTPS, installs the workbench skills, leaves the HumanLayer daemon stopped and fails loudly"
