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

# This run has no start script, and the dev container tool of the build gives the user the uid of the runner.
nix-setup.sh || fail "nix-setup.sh did not set up /nix for $(id -un)"
# An evaluation proves that the user can write the store, which a version line does not.
[ "$(nix eval --expr '1 + 1')" = 2 ] \
  || fail "nix did not evaluate an expression as $(id -un)"

[ -r /etc/claude-code/managed-settings.json ] \
  || fail "$(id -un) cannot read /etc/claude-code/managed-settings.json, so Claude Code gets no managed settings"
jq -e '.enabledPlugins["egm@egm"] == true and (.extraKnownMarketplaces.egm.source.ref | length == 40)' /etc/claude-code/managed-settings.json >/dev/null \
  || fail "the managed settings of Claude Code do not turn on the egm plugin at a pinned commit"

hook="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' /etc/claude-code/managed-settings.json)"
[ -x "$hook" ] || fail "the managed settings of Claude Code name the lint hook $hook, and it is not a program in the image"

[ -r /etc/codex/requirements.toml ] \
  || fail "$(id -un) cannot read /etc/codex/requirements.toml, so Codex gets no managed hook"
grep -Fq "command = \"$hook\"" /etc/codex/requirements.toml \
  || fail "the managed requirements of Codex do not name the lint hook $hook that Claude Code has"

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

node_major="$(cat "$DIR/../references/node-major")"
[ "$(node --version | sed -E 's/^v([0-9]+)\..*$/\1/')" = "$node_major" ] \
  || fail "node is $(node --version), and image/references/node-major declares Node $node_major"

python3 -I -c 'import yaml' || fail "the system python3 has no PyYAML"

# A product that pins another Playwright adds its browser build to this folder with npx playwright install.
browsers="${PLAYWRIGHT_BROWSERS_PATH:-}"
{ [ -d "$browsers" ] && [ -w "$browsers" ] && [ -z "$(find "$browsers" ! -writable -print -quit)" ]; } \
  || fail "$(id -un) cannot write each file of PLAYWRIGHT_BROWSERS_PATH '${browsers}', so a product cannot add its browser build"
node -e 'require(process.argv[1]).chromium.launch().then((b) => b.close())' "$(dirname "$(readlink -f "$(command -v playwright)")")" \
  || fail "the image's playwright cannot launch its chromium from $browsers"
echo "playwright: $(id -un) can write $browsers, and the image's chromium launches"

# The Postgres of the tools.tsv row: the user makes, starts and queries a cluster of their own, as a product does.
pg_package="$(/opt/digio/tools/tools.sh list | awk -F'\t' '$1 == "postgresql" { print $4 }')"
pg_major="${pg_package#postgresql-}"
pg_bin="/usr/lib/postgresql/$pg_major/bin"
{ [ -n "$pg_package" ] && [ -x "$pg_bin/initdb" ] && [ -x "$pg_bin/pg_ctl" ] && [ -x "$pg_bin/postgres" ]; } \
  || fail "the image has no Postgres server ${pg_major:-(no postgresql row)} in $pg_bin"
[ -z "$(pg_lsclusters -h)" ] || fail "the image holds a Postgres cluster: $(pg_lsclusters -h)"
pg="$(mktemp -d)"
pg_version="$(
  set -e
  "$pg_bin/initdb" -D "$pg/data" -U postgres --auth=trust >/dev/null
  "$pg_bin/pg_ctl" -D "$pg/data" -l "$pg/log" -o "-c listen_addresses='' -k $pg" -w start >/dev/null
  trap '"$pg_bin/pg_ctl" -D "$pg/data" -m fast -w stop >/dev/null' EXIT
  psql -h "$pg" -U postgres -d postgres -tAc 'SHOW server_version_num'
)" || { cat "$pg/log" >&2 2>/dev/null; rm -rf "$pg"; fail "$(id -un) cannot make, start and query a Postgres $pg_major cluster"; }
rm -rf "$pg"
[ "${pg_version:0:${#pg_major}}" = "$pg_major" ] || fail "the Postgres server is $pg_version, not major $pg_major"
echo "postgresql: $(id -un) ran a Postgres $pg_version cluster, and the image holds none"

export DIGIO_SKILLS_ROOT="${DIGIO_SKILLS_ROOT:-$HOME/.digio/skills}"
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
trap 'rm -rf "$TEST_HOME"' EXIT

# The link step that post-start.sh runs, on the pinned skills checkout: each link of the factory preset reaches a skill.
for agent in claude_code codex; do
  bash "$DIGIO_SKILLS_ROOT/lib/skill-links.sh" apply factory "$agent" \
    || fail "skill-links.sh cannot link the factory preset for $agent"
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

echo "image self-test passed: tools, Node major, PyYAML, Playwright, Postgres, skills, git hooks and worker setup"
