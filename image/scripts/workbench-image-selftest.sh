#!/usr/bin/env bash
# Offline: nothing is built, pushed or booted. Fixture lists and stub npm, vercel and docker commands stand in for the
# registries and the sandbox. Then the self-tests of the start scripts that the image runs.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd -P)"
CLI="$DIR/workbench-image.sh"
TOOLS="$DIR/tools.sh"
MICHELIN="$(cd "$DIR/../.." && pwd -P)"
export DIGIO_MICHELIN_ROOT="$MICHELIN" DIGIO_SKILLS_ROOT="${DIGIO_SKILLS_ROOT:-$HOME/devs/digio-skills}"
# The physical path: on macOS mktemp gives /var/..., a link to /private/var/..., and the tools resolve links.
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export DIGIO_SANDBOX_TEAM=team-x DIGIO_SANDBOX_PROJECT=proj-y
passes=0 failures=0
pass() { printf 'ok: %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
T=$'\t'

# --- workbench-image.sh: arguments and dry runs --------------------------------------------------------------------------

bash "$CLI" >/dev/null 2>&1; [ $? = 2 ] && pass "no verb exits 2" || fail "no verb"
bash "$CLI" nope >/dev/null 2>&1; [ $? = 2 ] && pass "unknown verb exits 2" || fail "unknown verb"
bash "$CLI" vcr-push --tag x --dry-run >/dev/null 2>&1; [ $? = 2 ] && pass "vcr-push is gone: the workflow pushes to VCR" || fail "vcr-push still a verb"
out="$(bash "$CLI" build --dry-run)"
grep -q "would run: npx --yes @devcontainers/cli build --workspace-folder $MICHELIN --config $MICHELIN/image/assets/image/devcontainer.json --image-name ghcr.io/digio-nz/workbench:latest --platform linux/amd64$" <<<"$out" \
  && pass "build --dry-run builds image/assets/image/devcontainer.json in this repo" || fail "build dry-run: $out"
out="$(bash "$CLI" build --tag 20261009 --platform linux/arm64 --push --dry-run)"; grep -q 'workbench:20261009 --platform linux/arm64 --push$' <<<"$out" && pass "build honours tag, platform and push" || fail "build flags: $out"
bash "$CLI" build --bogus >/dev/null 2>&1; [ $? = 2 ] && pass "an unknown flag exits 2" || fail "unknown flag"
out="$(bash "$CLI" publish --platform linux/amd64 --type trial --dry-run)"; grep -q -- 'gh workflow run build-image.yml --repo digio-nz/.github --ref main -f platforms=linux/amd64 -f type=trial$' <<<"$out" && pass "publish runs michelin's workflow with the platform and type" || fail "publish inputs: $out"
[ "$(bash "$CLI" publish --type weekly --dry-run >/dev/null 2>&1; echo $?)" = 2 ] && pass "publish refuses a type other than release or trial" || fail "publish bad type"
[ "$(bash "$CLI" publish --platform linux/arm64 --dry-run >/dev/null 2>&1; echo $?)" = 2 ] && pass "publish refuses a run with no linux/amd64 build: the publish job copies that build to VCR" || fail "publish arm64 only"
out="$(bash "$CLI" publish --ref fm/x --dry-run 2>&1)"; grep -q 'is a trial; only main moves latest' <<<"$out" && pass "publish says a release from a branch other than main is a trial" || fail "publish branch: $out"
# Each step that touches latest, the move and the wait, runs only for a non-trial build of main.
latest_steps="$(awk '/- name: .*latest/ { name = $0; getline; print name " :: " $0 }' "$MICHELIN/.github/workflows/build-image.yml")"
if [ "$(grep -c . <<<"$latest_steps")" = 2 ] && ! grep -v "if: env.TYPE != 'trial' && github.ref == 'refs/heads/main'" <<<"$latest_steps" | grep -q . \
  && grep -q 'TYPE=trial' "$MICHELIN/.github/workflows/build-image.yml"; then pass "the workflow moves latest only from main"; else fail "latest from a branch: $latest_steps"; fi
# The Vercel OIDC policy trusts main only, with a custom audience: each vcr-action step names it, and only main publishes.
wf="$MICHELIN/.github/workflows/build-image.yml"
uses="$(grep -c 'uses: vercel/vcr-action/' "$wf")"; aud="$(grep -c 'audience: https://github.com/digio-nz$' "$wf")"
if [ "$uses" -ge 3 ] && [ "$uses" = "$aud" ] && awk '/^  publish:/ { p = 1 } p && /^    if: github.ref == .refs\/heads\/main.$/ { f = 1 } END { exit !f }' "$wf"; then
  pass "each vcr-action step names the OIDC audience, and only a run of main publishes"; else fail "OIDC policy: $uses vcr-action steps, $aud audiences, or a publish job not limited to main"; fi
grep -q 'cancel-in-progress: false' "$MICHELIN/.github/workflows/build-image.yml" && pass "a run never cancels another between the two latest moves" || fail "cancel-in-progress"
out="$(bash "$CLI" publish --dry-run)"; grep -q -- '-f platforms=linux/amd64,linux/arm64 -f type=release$' <<<"$out" && pass "publish defaults to both architectures and a release" || fail "publish defaults: $out"

# --- tools.sh lint ---------------------------------------------------------------------------------------------------

rows="$(awk 'NF && $1 !~ /^#/ {n++} END {print n+0}' "$DIR/../references/tools.tsv")"
out="$(bash "$TOOLS" lint 2>&1)"; code=$?
[ "$code" = 0 ] && grep -q "^lint: ok, $rows rows$" <<<"$out" && pass "tools.sh lint passes the real list, Dockerfile and devcontainer.json" || fail "real lint: exit $code $out"
dockerfile="$MICHELIN/image/assets/image/Dockerfile"
! grep -qE 'npm install -g|corepack|curl[^|]*install' "$dockerfile" && pass "the Dockerfile has no npm install -g, no corepack and no installer curl" || fail "the Dockerfile installs a tool itself"
grep -q '"TOOLS_REFRESH": "${localEnv:TOOLS_REFRESH}"' "$MICHELIN/image/assets/image/devcontainer.json" \
  && grep -q 'TOOLS_REFRESH: \${{ github.run_id }}' "$MICHELIN/.github/workflows/build-image.yml" \
  && grep -q '^ARG TOOLS_REFRESH$' "$dockerfile" \
  && pass "each workflow image build invalidates the cached tool layers" || fail "the tool-layer cache key is absent"
grep -q 'cp .digio-skills/requirements.txt image/.build/skillport-requirements.txt' "$MICHELIN/.github/workflows/build-image.yml" \
  && grep -q '^COPY .build/skillport-requirements.txt /tmp/skillport-requirements.txt$' "$dockerfile" \
  && grep -q 'git -C "$skills_root" show "$skills_ref:requirements.txt"' "$CLI" \
  && pass "the image installs SkillPort from the latest stable public SkillPort requirements" \
  || fail "the SkillPort requirements source is absent"
grep -q 'cp -a hooks image/.build/michelin-hooks' "$MICHELIN/.github/workflows/build-image.yml" \
  && grep -q '^COPY .build/michelin-hooks/ /opt/digio/michelin-hooks/$' "$dockerfile" \
  && grep -q 'git config --system core.hooksPath /opt/digio/michelin-hooks/shims' "$dockerfile" \
  && grep -q 'cp -a "$MICHELIN/hooks" "$hooks_dir"' "$CLI" \
  && pass "the image bakes michelin's hooks and points the system hooksPath at their shims" \
  || fail "the image does not bake the secret-guard hooks"

# A fixture set that lint passes: one row for each source, a Dockerfile and a devcontainer.json.
mkdir -p "$tmp/fx"
cat > "$tmp/fx/good.tsv" <<EOF
# tool${T}command${T}source${T}package${T}version${T}probe${T}scope
jq${T}jq${T}apt${T}jq${T}latest${T}--version${T}all
nodejs${T}node${T}nodesource${T}current.x${T}latest${T}--version${T}all
gh-axi${T}gh-axi${T}npm${T}gh-axi${T}latest${T}--version${T}all
pnpm${T}pnpm${T}npm${T}pnpm${T}latest${T}--version${T}all
op${T}op${T}installer${T}1password-cli${T}latest${T}--version${T}all
actionlint${T}actionlint${T}gh-release${T}rhysd/actionlint${T}latest${T}--version${T}all
gh${T}gh${T}feature${T}ghcr.io/devcontainers/features/github-cli:latest${T}latest${T}--version${T}image
EOF
cat > "$tmp/fx/Dockerfile" <<'EOF'
FROM base
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates build-essential \
 && rm -rf /var/lib/apt/lists/*
RUN /opt/digio/tools/tools.sh apply --prefix /usr/local --sources npm && npm cache clean --force
RUN playwright install --with-deps chromium
EOF
printf '{\n  // a comment\n  "features": {\n    "ghcr.io/devcontainers/features/github-cli:latest": {}\n  }\n}\n' > "$tmp/fx/devcontainer.json"
export TOOLS_DOCKERFILE="$tmp/fx/Dockerfile" TOOLS_DEVCONTAINER="$tmp/fx/devcontainer.json"
lint() { bash "$TOOLS" --list "$1" lint 2>&1; }
out="$(lint "$tmp/fx/good.tsv")"; code=$?
[ "$code" = 0 ] && pass "lint passes a fixture set with latest for every tool" || fail "fixture lint: exit $code $out"

# with_row <name> <row>: the good list plus one row, as $tmp/fx/<name>.tsv.
with_row() { { cat "$tmp/fx/good.tsv"; printf '%s\n' "$2"; } > "$tmp/fx/$1.tsv"; echo "$tmp/fx/$1.tsv"; }
out="$(lint "$(with_row brew "fd${T}fd${T}brew${T}fd${T}latest${T}--version${T}all")")"; code=$?
[ "$code" = 1 ] && grep -q "brew.tsv:9: fd: unknown source \"brew\": fd${T}fd${T}brew" <<<"$out" && pass "a row with the source brew: lint exits 1 and names the row" || fail "brew: exit $code $out"
out="$(lint "$(with_row caret "# a reason${T}
fd${T}fd${T}apt${T}fd-find${T}^1.2${T}--version${T}all")")"; code=$?
[ "$code" = 1 ] && grep -q 'caret.tsv:10: fd: version "^1.2" is pinned; use latest' <<<"$out" && pass "a row with the version ^1.2: lint exits 1 and names the row" || fail "caret: exit $code $out"
out="$(lint "$(with_row twice "jq${T}jq${T}apt${T}jq${T}latest${T}--version${T}image")")"; code=$?
[ "$code" = 1 ] && grep -q 'twice.tsv:9: tool jq is listed twice (first at line 2)' <<<"$out" && pass "a tool twice: lint exits 1 and names the tool" || fail "twice: exit $code $out"
out="$(lint "$(with_row pin "fd${T}fd${T}apt${T}fd-find${T}9.0.0${T}--version${T}all")")"; code=$?
[ "$code" = 1 ] && grep -q 'pin.tsv:9: fd: version "9.0.0" is pinned; use latest' <<<"$out" && pass "a pin: lint exits 1 and names the row" || fail "pin: exit $code $out"
out="$(lint "$(with_row probe "fd${T}fd${T}apt${T}fd-find${T}latest${T}version${T}all")")"; code=$?
[ "$code" = 1 ] && grep -q 'probe.tsv:9: fd: invalid version probe "version"' <<<"$out" && pass "an invalid version probe: lint exits 1 and names the row" || fail "probe: exit $code $out"
out="$(lint "$(with_row nofn "mystery${T}mystery${T}installer${T}https://example.com/install.sh${T}latest${T}--version${T}all")")"; code=$?
[ "$code" = 1 ] && grep -q 'nofn.tsv:9: mystery: the installer row has no latest stable lookup in tools.sh' <<<"$out" \
  && grep -q 'nofn.tsv:9: mystery: the installer row has no install_mystery function in tools.sh' <<<"$out" \
  && pass "an installer row with no functions: lint exits 1 and names both gaps" || fail "no function: exit $code $out"
out="$(lint "$(with_row cols "fd${T}fd${T}apt${T}fd-find${T}latest${T}--version")")"; code=$?
[ "$code" = 1 ] && grep -q 'cols.tsv:9: the row has 6 columns, not 7' <<<"$out" && pass "a row of six columns: lint exits 1 and names it" || fail "columns: exit $code $out"
out="$(lint "$(with_row scope "fd${T}fd${T}apt${T}fd-find${T}latest${T}--version${T}desk")")"; code=$?
[ "$code" = 1 ] && grep -q 'scope.tsv:9: fd: unknown scope "desk"' <<<"$out" && pass "a row with an unknown scope: lint exits 1 and names it" || fail "scope: exit $code $out"
cp "$tmp/fx/Dockerfile" "$tmp/fx/Dockerfile.good"
printf 'RUN npm install -g foo\n' >> "$tmp/fx/Dockerfile"
out="$(lint "$tmp/fx/good.tsv")"; code=$?
[ "$code" = 1 ] && grep -q "Dockerfile:7: installs a tool outside tools.sh: npm install -g foo" <<<"$out" && pass "a fixture Dockerfile with RUN npm install -g foo: lint exits 1 and names the line" || fail "dockerfile npm: exit $code $out"
cp "$tmp/fx/Dockerfile.good" "$tmp/fx/Dockerfile"
printf 'RUN apt-get update && apt-get install -y \\\n      ca-certificates ripgrep\n' >> "$tmp/fx/Dockerfile"
out="$(lint "$tmp/fx/good.tsv")"; code=$?
[ "$code" = 1 ] && grep -q "Dockerfile:7: installs a tool outside tools.sh: apt ripgrep" <<<"$out" && pass "an apt-get install of a tool beside the base packages: lint names the package" || fail "dockerfile apt: exit $code $out"
cp "$tmp/fx/Dockerfile.good" "$tmp/fx/Dockerfile"
printf 'RUN curl -fsSL https://example.com/install.sh | sh\n' >> "$tmp/fx/Dockerfile"
out="$(lint "$tmp/fx/good.tsv")"; code=$?
[ "$code" = 1 ] && grep -q "Dockerfile:7: installs a tool outside tools.sh: curl -fsSL https://example.com/install.sh" <<<"$out" && pass "an installer curl in the Dockerfile: lint names the line" || fail "dockerfile curl: exit $code $out"
cp "$tmp/fx/Dockerfile.good" "$tmp/fx/Dockerfile"
printf 'RUN /opt/digio/skillport-venv/bin/pip install --no-cache-dir --upgrade -r /tmp/skillport-requirements.txt\n' >> "$tmp/fx/Dockerfile"
out="$(lint "$tmp/fx/good.tsv")"; code=$?
[ "$code" = 0 ] && pass "the public SkillPort requirements install is allowed" || fail "SkillPort requirement install: exit $code $out"
cp "$tmp/fx/Dockerfile.good" "$tmp/fx/Dockerfile"
printf 'RUN /opt/digio/skillport-venv/bin/pip install skillport\n' >> "$tmp/fx/Dockerfile"
out="$(lint "$tmp/fx/good.tsv")"; code=$?
[ "$code" = 1 ] && grep -q "Dockerfile:7: installs a tool outside tools.sh: /opt/digio/skillport-venv/bin/pip install skillport" <<<"$out" \
  && pass "an unmanaged SkillPort install is red" || fail "unmanaged SkillPort install: exit $code $out"
cp "$tmp/fx/Dockerfile.good" "$tmp/fx/Dockerfile"
cp "$tmp/fx/devcontainer.json" "$tmp/fx/devcontainer.good"
printf '{\n  "features": {\n    "ghcr.io/devcontainers/features/sshd:latest": {}\n  }\n}\n' > "$tmp/fx/devcontainer.json"
out="$(lint "$tmp/fx/good.tsv")"; code=$?
[ "$code" = 1 ] && grep -q "good.tsv:8: gh: the feature ghcr.io/devcontainers/features/github-cli:latest is not in $tmp/fx/devcontainer.json" <<<"$out" \
  && grep -q "devcontainer.json: the feature ghcr.io/devcontainers/features/sshd:latest has no row in" <<<"$out" \
  && pass "a feature row that devcontainer.json does not name, and the reverse: lint exits 1 and names each" || fail "features: exit $code $out"
cp "$tmp/fx/devcontainer.good" "$tmp/fx/devcontainer.json"
out="$(bash "$TOOLS" --list "$(with_row brew2 "fd${T}fd${T}brew${T}fd${T}latest${T}--version${T}all")" list 2>&1)"; code=$?
[ "$code" = 2 ] && grep -q 'bad list: .*unknown source "brew"' <<<"$out" && pass "list exits 2 on a bad list and names the fault" || fail "list bad: exit $code $out"

# --- tools.sh list and check -------------------------------------------------------------------------------------------

out="$(bash "$TOOLS" --list "$tmp/fx/good.tsv" list --scope all)"
[ "$(grep -c . <<<"$out")" = 6 ] && ! grep -q '^gh	' <<<"$out" && pass "list --scope all prints the all rows only" || fail "list scope: $out"
out="$(bash "$TOOLS" --list "$tmp/fx/good.tsv" list --source npm | cut -f1 | paste -sd' ' -)"
[ "$out" = "gh-axi pnpm" ] && pass "list --source npm prints the npm rows" || fail "list source: $out"

# Stub commands: each tool in a fixture list prints a version; npm answers the registry from $NPM_LATEST.
mkdir -p "$tmp/bin"
for c in alpha beta; do printf '#!/bin/sh\necho "%s 1.2.3"\n' "$c" > "$tmp/bin/$c"; done
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/noversion"
cat > "$tmp/bin/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_DIR/npm.log"
case "$1" in
  --version) echo 11.15.0 ;;
  view) [ -z "${NPM_OFFLINE:-}" ] || exit 1; echo "${NPM_LATEST:-1.2.3}" ;;
  install) [ -z "${NPM_FAIL:-}" ] || exit 1
    for a in "$@"; do case "$a" in --prefix) p=1 ;; *) if [ -n "${p:-}" ]; then prefix="$a"; p=; fi ;; esac; done
    spec="${*: -1}"; pkg="${spec%@*}"; ver="${spec##*@}"
    mkdir -p "$prefix/lib/node_modules/$pkg" "$prefix/bin" && printf '{\n  "name": "%s",\n  "version": "%s"\n}\n' "$pkg" "$ver" > "$prefix/lib/node_modules/$pkg/package.json"
    # npm links the package's executable into the prefix: <name>-pkg gives <name>.
    printf '#!/bin/sh\necho %s\n' "$ver" > "$prefix/bin/${pkg%-pkg}" && chmod +x "$prefix/bin/${pkg%-pkg}" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$tmp/bin/"*
export TEST_DIR="$tmp"
cat > "$tmp/fx/check.tsv" <<EOF
# tool${T}command${T}source${T}package${T}version${T}probe${T}scope
alpha${T}alpha${T}npm${T}alpha-pkg${T}latest${T}--version${T}all
beta${T}beta${T}npm${T}beta-pkg${T}latest${T}--version${T}all
quiet${T}noversion${T}apt${T}quiet${T}latest${T}--version${T}image
ghost${T}ghost-command-not-here${T}apt${T}ghost${T}latest${T}--version${T}all
EOF
out="$(PATH="$tmp/bin:$PATH" bash "$TOOLS" --list "$tmp/fx/check.tsv" check 2>&1)"; code=$?
[ "$code" = 1 ] && grep -qx 'ghost missing' <<<"$out" && grep -qx 'alpha present 1.2.3' <<<"$out" && grep -qx 'quiet present (no version)' <<<"$out" \
  && [ "$(tail -n 1 <<<"$out")" = 'tools: 3 present, 1 missing, 0 behind, 0 latest unavailable' ] && pass "check with a missing command: exit 1 and names the missing tool" || fail "check missing: exit $code $out"
out="$(PATH="$tmp/bin:$PATH" bash "$TOOLS" --list "$tmp/fx/check.tsv" check --scope all 2>&1)"
! grep -q '^quiet' <<<"$out" && [ "$(tail -n 1 <<<"$out")" = 'tools: 2 present, 1 missing, 0 behind, 0 latest unavailable' ] && pass "check --scope all checks the all rows only" || fail "check scope: $out"
grep -v ghost "$tmp/fx/check.tsv" > "$tmp/fx/present.tsv"
out="$(PATH="$tmp/bin:$PATH" NPM_LATEST=1.3.0 bash "$TOOLS" --list "$tmp/fx/present.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 3 ] && grep -qx 'alpha present 1.2.3 behind 1.3.0' <<<"$out" && grep -qx 'beta present 1.2.3 behind 1.3.0' <<<"$out" \
  && grep -qx 'quiet present; installed version unavailable from noversion --version' <<<"$out" \
  && grep -qx 'tools: 3 present, 0 missing, 2 behind, 1 latest unavailable' <<<"$out" \
  && pass "check --latest with stale and unverified tools: exits 3 and names each result" || fail "check latest: exit $code $out"
out="$(PATH="$tmp/bin:$PATH" NPM_OFFLINE=1 bash "$TOOLS" --list "$tmp/fx/present.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 3 ] && grep -qx 'alpha present 1.2.3; latest stable unavailable' <<<"$out" \
  && grep -qx 'beta present 1.2.3; latest stable unavailable' <<<"$out" \
  && grep -qx 'tools: 3 present, 0 missing, 0 behind, 3 latest unavailable' <<<"$out" \
  && pass "check --latest with an unavailable registry: exits 3 and names each unverified tool" || fail "check latest unavailable: exit $code $out"

# Every source and each feature lookup has a stale case and an unavailable case. The APT fixture differs only in its
# Debian revision, and the command fixture rejects a probe other than the one in its row.
mkdir -p "$tmp/latest-bin"
mkdir -p "$tmp/apt-lists"
printf 'fixture\n' > "$tmp/apt-lists/Packages"
cat > "$tmp/latest-bin/tool-version" <<'SH'
#!/bin/sh
name="$(basename "$0")"
case "$name:$1" in
  ffmpeg:-version | tmux:-V | unzip:-v | sshd:-V | *:--version) ;;
  *) exit 9 ;;
esac
[ "${PROBE_FAIL:-}" != "$name" ] || exit 9
echo "$name 1.2.3"
SH
for c in apt-tool ffmpeg tmux unzip node-tool npm-tool op grok actionlint gh sshd docker tailscale; do
  ln -s tool-version "$tmp/latest-bin/$c"
done
cat > "$tmp/latest-bin/npm" <<'SH'
#!/bin/sh
[ "$1" = view ] || exit 9
[ "${FAIL_LOOKUP:-}" != npm ] || exit 1
echo 1.3.0
SH
cat > "$tmp/latest-bin/apt-cache" <<'SH'
#!/bin/sh
[ "$1" = policy ] || exit 9
package="$2"
case "${FAIL_LOOKUP:-}:$package" in
  apt:apt-pkg | op:1password-cli | feature-sshd:openssh-server) candidate='(none)' ;;
  nodesource:nodejs) candidate='(none)' ;;
  *) candidate="${CANDIDATE_DEB_VERSION:-1:1.2.3-2}" ;;
esac
printf '  Installed: 1:1.2.3-1\n  Candidate: %s\n' "$candidate"
SH
cat > "$tmp/latest-bin/dpkg-query" <<'SH'
#!/bin/sh
for package do :; done
[ "${FAIL_DPKG_QUERY:-}" != "$package" ] || exit 1
echo "${INSTALLED_DEB_VERSION:-1:1.2.3-1}"
SH
ln -s "$(command -v dpkg)" "$tmp/latest-bin/dpkg"
cat > "$tmp/latest-bin/curl" <<'SH'
#!/bin/bash
url="${*: -1}"
case "$url" in
  https://nodejs.org/dist/index.json)
    [ "${FAIL_LOOKUP:-}" != nodesource ] || exit 22
    echo '[{"version":"v1.3.0"}]'; exit 0 ;;
  https://grok.example/cli/stable)
    [ "${FAIL_LOOKUP:-}" != grok ] || exit 22
    echo 1.3.0; exit 0 ;;
  *rhysd/actionlint/releases/latest) key=gh-release; repo=rhysd/actionlint; tag=v1.3.0 ;;
  *cli/cli/releases/latest) key=feature-gh; repo=cli/cli; tag=v1.3.0 ;;
  *moby/moby/releases/latest) key=feature-docker; repo=moby/moby; tag=docker-v1.3.0 ;;
  *tailscale/tailscale/releases/latest) key=feature-tailscale; repo=tailscale/tailscale; tag=v1.3.0 ;;
  *) exit 22 ;;
esac
[ "${FAIL_LOOKUP:-}" != "$key" ] || exit 22
printf 'https://github.com/%s/releases/tag/%s' "$repo" "$tag"
SH
chmod +x "$tmp/latest-bin/"*
cat > "$tmp/fx/all-latest.tsv" <<EOF
# tool${T}command${T}source${T}package${T}version${T}probe${T}scope
apt-tool${T}apt-tool${T}apt${T}apt-pkg${T}latest${T}--version${T}all
ffmpeg${T}ffmpeg${T}apt${T}ffmpeg-pkg${T}latest${T}-version${T}all
tmux${T}tmux${T}apt${T}tmux-pkg${T}latest${T}-V${T}all
unzip${T}unzip${T}apt${T}unzip-pkg${T}latest${T}-v${T}all
node-tool${T}node-tool${T}nodesource${T}current.x${T}latest${T}--version${T}all
npm-tool${T}npm-tool${T}npm${T}npm-tool-pkg${T}latest${T}--version${T}all
op${T}op${T}installer${T}1password-cli${T}latest${T}--version${T}all
grok${T}grok${T}installer${T}https://grok.example/cli${T}latest${T}--version${T}all
actionlint${T}actionlint${T}gh-release${T}rhysd/actionlint${T}latest${T}--version${T}all
gh${T}gh${T}feature${T}ghcr.io/devcontainers/features/github-cli:latest${T}latest${T}--version${T}all
sshd${T}sshd${T}feature${T}ghcr.io/devcontainers/features/sshd:latest${T}latest${T}-V${T}all
docker${T}docker${T}feature${T}ghcr.io/devcontainers/features/docker-outside-of-docker:latest${T}latest${T}--version${T}all
tailscale${T}tailscale${T}feature${T}ghcr.io/tailscale/codespace/tailscale:latest${T}latest${T}--version${T}all
EOF
out="$(PATH="$tmp/latest-bin:$PATH" TOOLS_APT_LISTS="$tmp/apt-lists" bash "$TOOLS" --list "$tmp/fx/all-latest.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 1 ] && grep -qx 'apt-tool present 1.2.3 behind 1:1.2.3-2' <<<"$out" \
  && grep -qx 'tmux present 1.2.3 behind 1:1.2.3-2' <<<"$out" \
  && grep -qx 'unzip present 1.2.3 behind 1:1.2.3-2' <<<"$out" \
  && grep -qx 'docker present 1.2.3 behind 1.3.0' <<<"$out" \
  && grep -qx 'tools: 13 present, 0 missing, 13 behind, 0 latest unavailable' <<<"$out" \
  && pass "check --latest: every source and special probe reports stale, including an APT revision" || fail "all latest stale: exit $code $out"
for case in apt:apt-tool nodesource:node-tool npm:npm-tool op:op grok:grok gh-release:actionlint feature-gh:gh feature-sshd:sshd feature-docker:docker feature-tailscale:tailscale; do
  lookup="${case%%:*}"; expected="${case#*:}"
  out="$(PATH="$tmp/latest-bin:$PATH" TOOLS_APT_LISTS="$tmp/apt-lists" FAIL_LOOKUP="$lookup" bash "$TOOLS" --list "$tmp/fx/all-latest.tsv" check --latest 2>&1)"; code=$?
  [ "$code" = 3 ] && grep -q "^$expected present .*latest stable unavailable$" <<<"$out" \
    && pass "check --latest: $lookup lookup unavailable is red" || fail "$lookup unavailable: exit $code $out"
done
# apply --sources installer for grok: a stub curl serves the stable pointer and a gzipped binary from the fixture dir.
mkdir -p "$tmp/grok-bin" "$tmp/grok-dl"
printf '#!/bin/sh\necho "grok ${GROK_FAKE_VERSION:-1.3.0}"\n' > "$tmp/grok-dl/grok"
gzip -c "$tmp/grok-dl/grok" > "$tmp/grok-dl/grok.gz"
cat > "$tmp/grok-bin/curl" <<SH
#!/bin/bash
out=""; while [ \$# -gt 1 ]; do [ "\$1" = -o ] && out="\$2"; shift; done
case "\$1" in
  https://grok.example/cli/stable) [ -z "\${FAIL_STABLE:-}" ] || exit 22; echo 1.3.0 ;;
  https://grok.example/cli/grok-1.3.0-*.gz) cp "$tmp/grok-dl/grok.gz" "\$out" ;;
  *) exit 22 ;;
esac
SH
chmod +x "$tmp/grok-bin/curl"
printf '# tool\tcommand\tsource\tpackage\tversion\tprobe\tscope\ngrok\tgrok\tinstaller\thttps://grok.example/cli\tlatest\t--version\timage\n' > "$tmp/fx/grok.tsv"
grok_apply() { PATH="$tmp/grok-bin:$PATH" bash "$TOOLS" --list "$tmp/fx/grok.tsv" apply --prefix "$1" --sources installer 2>&1; }
out="$(grok_apply "$tmp/grok-prefix")"; code=$?
[ "$code" = 0 ] && grep -qx 'installed grok 1.3.0' <<<"$out" && [ "$("$tmp/grok-prefix/bin/grok" --version)" = "grok 1.3.0" ] \
  && pass "install_grok installs the stable version that the channel names" || fail "grok install: exit $code $out"
out="$(grok_apply "$tmp/grok-prefix")"; code=$?
[ "$code" = 0 ] && grep -qx 'grok current 1.3.0' <<<"$out" && pass "install_grok keeps a current binary" || fail "grok current: exit $code $out"
out="$(GROK_FAKE_VERSION=9.9.9 grok_apply "$tmp/grok-wrong")"; code=$?
[ "$code" = 1 ] && grep -q "grok: the downloaded binary reports '9.9.9', not 1.3.0" <<<"$out" && [ ! -e "$tmp/grok-wrong/bin/grok" ] \
  && pass "install_grok refuses a binary that reports another version, and installs nothing" || fail "grok wrong version: exit $code $out"
out="$(FAIL_STABLE=1 grok_apply "$tmp/grok-none")"; code=$?
[ "$code" = 3 ] && grep -q 'grok: cannot read https://grok.example/cli/stable' <<<"$out" \
  && pass "install_grok exits 3 when the stable channel cannot be read" || fail "grok stable unreadable: exit $code $out"

# A changed upstream installer cannot start a daemon during the image build.
mkdir -p "$tmp/no-mistakes-bin"
cat > "$tmp/no-mistakes-bin/curl" <<'SH'
#!/bin/sh
case "$*" in
  *github.com/kunchenguid/no-mistakes/releases/latest*) printf 'https://github.com/kunchenguid/no-mistakes/releases/tag/v1.2.3' ;;
  *raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh*) printf '#!/bin/sh\nexit 0\n' ;;
  *) exit 22 ;;
esac
SH
chmod +x "$tmp/no-mistakes-bin/curl"
printf '# tool\tcommand\tsource\tpackage\tversion\tprobe\tscope\nno-mistakes\tno-mistakes\tinstaller\thttps://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh\tlatest\t--version\timage\n' > "$tmp/fx/no-mistakes.tsv"
out="$(PATH="$tmp/no-mistakes-bin:$PATH" bash "$TOOLS" --list "$tmp/fx/no-mistakes.tsv" apply --prefix "$tmp/no-mistakes-prefix" --sources installer 2>&1)"; code=$?
[ "$code" = 1 ] && grep -Fxq 'no-mistakes: the installer daemon restart changed; refusing to run it during an image build' <<<"$out" \
  && pass "install_no_mistakes fails when its daemon restart guard no longer matches" || fail "no-mistakes daemon guard: exit $code $out"

# apply --sources gh-release for uv: a stub curl serves the latest tag, the archive and its .sha256 file.
case "$(uname -s)" in Linux) uv_os=unknown-linux-gnu ;; *) uv_os=apple-darwin ;; esac
case "$(uname -m)" in x86_64 | amd64) uv_arch=x86_64 ;; *) uv_arch=aarch64 ;; esac
uv_asset="uv-$uv_arch-$uv_os.tar.gz"
mkdir -p "$tmp/uv-bin" "$tmp/uv-dl/uv-$uv_arch-$uv_os"
for b in uv uvx; do printf '#!/bin/sh\necho "%s 1.3.0"\n' "$b" > "$tmp/uv-dl/uv-$uv_arch-$uv_os/$b"; chmod +x "$tmp/uv-dl/uv-$uv_arch-$uv_os/$b"; done
tar -czf "$tmp/uv-dl/$uv_asset" -C "$tmp/uv-dl" "uv-$uv_arch-$uv_os"
cat > "$tmp/uv-bin/curl" <<SH
#!/bin/bash
out=""; effective=""; while [ \$# -gt 1 ]; do [ "\$1" = -o ] && out="\$2"; [ "\$1" = -w ] && effective=1; shift; done
case "\$1" in
  https://github.com/astral-sh/uv/releases/latest) [ -n "\$effective" ] && printf 'https://github.com/astral-sh/uv/releases/tag/1.3.0' ;;
  https://github.com/astral-sh/uv/releases/download/1.3.0/$uv_asset) cp "$tmp/uv-dl/$uv_asset" "\$out" ;;
  https://github.com/astral-sh/uv/releases/download/1.3.0/$uv_asset.sha256)
    if [ -n "\${BAD_SUM:-}" ]; then echo "0000  $uv_asset" > "\$out"; else echo "\$(sha256sum "$tmp/uv-dl/$uv_asset" 2>/dev/null || shasum -a 256 "$tmp/uv-dl/$uv_asset")" | awk '{ print \$1 "  $uv_asset" }' > "\$out"; fi ;;
  *) exit 22 ;;
esac
SH
chmod +x "$tmp/uv-bin/curl"
printf '# tool\tcommand\tsource\tpackage\tversion\tprobe\tscope\nuv\tuv\tgh-release\tastral-sh/uv\tlatest\t--version\timage\n' > "$tmp/fx/uv.tsv"
uv_apply() { PATH="$tmp/uv-bin:$PATH" bash "$TOOLS" --list "$tmp/fx/uv.tsv" apply --prefix "$1" --sources gh-release 2>&1; }
out="$(uv_apply "$tmp/uv-prefix")"; code=$?
[ "$code" = 0 ] && grep -qx 'installed uv 1.3.0' <<<"$out" && [ "$("$tmp/uv-prefix/bin/uvx" --version)" = "uvx 1.3.0" ] \
  && pass "install_uv installs uv and uvx from the latest release" || fail "uv install: exit $code $out"
out="$(uv_apply "$tmp/uv-prefix")"; code=$?
[ "$code" = 0 ] && grep -qx 'uv current 1.3.0' <<<"$out" && pass "install_uv keeps a current binary" || fail "uv current: exit $code $out"
out="$(BAD_SUM=1 uv_apply "$tmp/uv-bad")"; code=$?
[ "$code" = 1 ] && grep -q "uv: $uv_asset does not match its .sha256 file" <<<"$out" && [ ! -e "$tmp/uv-bad/bin/uv" ] \
  && pass "install_uv refuses an archive that does not match its .sha256 file, and installs nothing" || fail "uv bad checksum: exit $code $out"

# install_t3 installs the release's whole folder, with a link in bin, and checks it against SHA256SUMS.
case "$(uname -s)" in Darwin) t3_os=darwin ;; *) t3_os=linux ;; esac
case "$(uname -m)" in x86_64 | amd64) t3_arch=x64 ;; *) t3_arch=arm64 ;; esac
t3_asset="t3-1.3.0-$t3_os-$t3_arch.tar.gz"
mkdir -p "$tmp/t3-bin" "$tmp/t3-dl/t3-1.3.0/client"
printf '#!/bin/sh\necho "t3 v1.3.0"\n[ -f "$(dirname "$(readlink -f "$0")")/client/index.html" ]\n' > "$tmp/t3-dl/t3-1.3.0/t3"
chmod +x "$tmp/t3-dl/t3-1.3.0/t3"
touch "$tmp/t3-dl/t3-1.3.0/client/index.html"
tar -czf "$tmp/t3-dl/$t3_asset" -C "$tmp/t3-dl" t3-1.3.0
cat > "$tmp/t3-bin/curl" <<SH
#!/bin/bash
out=""; effective=""; while [ \$# -gt 1 ]; do [ "\$1" = -o ] && out="\$2"; [ "\$1" = -w ] && effective=1; shift; done
case "\$1" in
  https://github.com/pingdotgg/t3code/releases/latest) [ -n "\$effective" ] && printf 'https://github.com/pingdotgg/t3code/releases/tag/v1.3.0' ;;
  https://github.com/pingdotgg/t3code/releases/download/v1.3.0/$t3_asset) cp "$tmp/t3-dl/$t3_asset" "\$out" ;;
  https://github.com/pingdotgg/t3code/releases/download/v1.3.0/SHA256SUMS)
    if [ -n "\${BAD_SUM:-}" ]; then echo "0000  $t3_asset" > "\$out"; else (cd "$tmp/t3-dl" && { sha256sum "$t3_asset" 2>/dev/null || shasum -a 256 "$t3_asset"; }) > "\$out"; fi ;;
  *) exit 22 ;;
esac
SH
chmod +x "$tmp/t3-bin/curl"
printf '# tool\tcommand\tsource\tpackage\tversion\tprobe\tscope\nt3\tt3\tgh-release\tpingdotgg/t3code\tlatest\t--version\timage\n' > "$tmp/fx/t3.tsv"
t3_apply() { PATH="$tmp/t3-bin:$PATH" bash "$TOOLS" --list "$tmp/fx/t3.tsv" apply --prefix "$1" --sources gh-release 2>&1; }
out="$(t3_apply "$tmp/t3-prefix")"; code=$?
[ "$code" = 0 ] && grep -qx 'installed t3 1.3.0' <<<"$out" && [ -L "$tmp/t3-prefix/bin/t3" ] && "$tmp/t3-prefix/bin/t3" --version >/dev/null \
  && pass "install_t3 installs the release folder and runs it through the link in bin" || fail "t3 install: exit $code $out"
out="$(t3_apply "$tmp/t3-prefix")"; code=$?
[ "$code" = 0 ] && grep -qx 't3 current 1.3.0' <<<"$out" && pass "install_t3 keeps a current install" || fail "t3 current: exit $code $out"
out="$(BAD_SUM=1 t3_apply "$tmp/t3-bad")"; code=$?
[ "$code" = 1 ] && grep -q "t3: $t3_asset does not match the release's SHA256SUMS" <<<"$out" && [ ! -e "$tmp/t3-bad/bin/t3" ] \
  && pass "install_t3 refuses an archive that SHA256SUMS does not list, and installs nothing" || fail "t3 bad checksum: exit $code $out"

# version-lt and latest-release: the helpers dotfiles' status-output.sh calls for the machine-only tools.
bash "$TOOLS" version-lt 1.9.2 1.10.0 && ! bash "$TOOLS" version-lt 1.10.0 1.9.2 && ! bash "$TOOLS" version-lt 1.2.3 1.2.3 \
  && bash "$TOOLS" version-lt 1.2.3-rc1 1.2.4 && pass "version-lt compares each dotted number" || fail "version-lt"
out="$(PATH="$tmp/latest-bin:$PATH" bash "$TOOLS" latest-release moby/moby)"; code=$?
[ "$code" = 0 ] && [ "$out" = 1.3.0 ] && pass "latest-release prints the version with no tag prefix" || fail "latest-release: exit $code '$out'"
out="$(PATH="$tmp/latest-bin:$PATH" bash "$TOOLS" latest-release nobody/nothing)"; code=$?
[ "$code" = 3 ] && [ -z "$out" ] && pass "latest-release exits 3 and prints nothing when the release cannot be read" || fail "latest-release unavailable: exit $code '$out'"
out="$(PATH="$tmp/latest-bin:$PATH" TOOLS_APT_LISTS="$tmp/apt-lists" PROBE_FAIL=tmux bash "$TOOLS" --list "$tmp/fx/all-latest.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 3 ] && grep -qx 'tmux present; installed version unavailable from tmux -V' <<<"$out" \
  && pass "check --latest: a failed declared probe is red and names the tool and probe" || fail "probe unavailable: exit $code $out"

head -n 1 "$tmp/fx/all-latest.tsv" > "$tmp/fx/apt-only.tsv"
sed -n '2p' "$tmp/fx/all-latest.tsv" >> "$tmp/fx/apt-only.tsv"
mkdir -p "$tmp/empty-apt-lists"
out="$(PATH="$tmp/latest-bin:$PATH" TOOLS_APT_LISTS="$tmp/empty-apt-lists" bash "$TOOLS" --list "$tmp/fx/apt-only.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 3 ] && grep -qx 'apt-tool present 1.2.3; latest stable unavailable' <<<"$out" \
  && grep -qx "apt indexes: none in $tmp/empty-apt-lists; run apt-get update as root before check --latest" <<<"$out" \
  && pass "check --latest: empty APT lists are unverified and name the tool and the missing indexes" || fail "empty APT lists: exit $code $out"
out="$(PATH="$tmp/latest-bin:$PATH" TOOLS_APT_LISTS="$tmp/apt-lists" CANDIDATE_DEB_VERSION=1:1.2.3-1 bash "$TOOLS" --list "$tmp/fx/apt-only.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 0 ] && ! grep -q '^apt indexes:' <<<"$out" && grep -qx 'apt-tool present 1.2.3' <<<"$out" \
  && pass "check --latest: current APT lists verify the tool without an index note" || fail "current APT lists: exit $code $out"

# apply --sources apt as root, with stub apt-get and id: it refreshes the indexes, then installs each missing row and
# upgrades each present row whose candidate is newer.
mkdir -p "$tmp/apt-root-bin"
cat > "$tmp/apt-root-bin/id" <<'SH'
#!/bin/sh
[ "$1" = -u ] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
SH
cat > "$tmp/apt-root-bin/apt-get" <<'SH'
#!/bin/sh
echo "$*" >> "$TEST_DIR/apt-get.log"
case "$*" in
  "update -qq") [ -z "${APT_UPDATE_FAIL:-}" ] || exit 100 ;;
esac
SH
chmod +x "$tmp/apt-root-bin/"*
head -n 1 "$tmp/fx/all-latest.tsv" > "$tmp/fx/apt-apply.tsv"
sed -n '2p' "$tmp/fx/all-latest.tsv" >> "$tmp/fx/apt-apply.tsv"
printf 'ghost%sghost-command-not-here%sapt%sghost-pkg%slatest%s--version%sall\n' "$T" "$T" "$T" "$T" "$T" "$T" >> "$tmp/fx/apt-apply.tsv"
apt_apply() {
  rm -f "$tmp/apt-get.log"; mkdir -p "$tmp/apply-lists"; printf 'fixture\n' > "$tmp/apply-lists/Packages"
  env PATH="$tmp/apt-root-bin:$tmp/latest-bin:$PATH" TOOLS_APT_LISTS="$tmp/apply-lists" "$@" \
    bash "$TOOLS" --list "$tmp/fx/apt-apply.tsv" apply --prefix "$tmp/apt-prefix" --sources apt 2>&1
}
out="$(apt_apply)"; code=$?
[ "$code" = 0 ] && [ "$(sed -n 1p "$tmp/apt-get.log")" = 'update -qq' ] \
  && grep -qx 'install -y -qq --no-install-recommends apt-pkg ghost-pkg' "$tmp/apt-get.log" \
  && grep -qx 'apt: installed apt-tool ghost' <<<"$out" && [ ! -e "$tmp/apply-lists/Packages" ] \
  && pass "apply --sources apt refreshes the indexes, installs a missing row and upgrades an older present row" || fail "apply apt older: exit $code $out $(cat "$tmp/apt-get.log")"
out="$(apt_apply CANDIDATE_DEB_VERSION=1:1.2.3-1)"; code=$?
[ "$code" = 0 ] && grep -qx 'install -y -qq --no-install-recommends ghost-pkg' "$tmp/apt-get.log" \
  && pass "apply --sources apt leaves a current present row" || fail "apply apt current: exit $code $out $(cat "$tmp/apt-get.log")"
out="$(apt_apply FAIL_DPKG_QUERY=apt-pkg CANDIDATE_DEB_VERSION=1:1.2.3-1)"; code=$?
[ "$code" = 0 ] && grep -qx 'install -y -qq --no-install-recommends apt-pkg ghost-pkg' "$tmp/apt-get.log" \
  && pass "apply --sources apt installs the package of a present command that dpkg does not own" || fail "apply apt unowned: exit $code $out $(cat "$tmp/apt-get.log")"
out="$(apt_apply APT_UPDATE_FAIL=1)"; code=$?
[ "$code" = 3 ] && grep -q 'apt: cannot refresh the package indexes' <<<"$out" && ! grep -q '^install' "$tmp/apt-get.log" \
  && pass "apply --sources apt with a failed index refresh: exit 3, installs nothing" || fail "apply apt update fail: exit $code $out"
out="$(apt_apply FAIL_LOOKUP=apt)"; code=$?
[ "$code" = 3 ] && grep -qx 'apt: no candidate version for: apt-tool' <<<"$out" \
  && pass "apply --sources apt with no candidate for a present row: exit 3 and names the tool" || fail "apply apt no candidate: exit $code $out"
out="$(apt_apply STUB_UID=1000)"; code=$?
[ "$code" = 1 ] && grep -q 'apt: needs root' <<<"$out" && [ ! -e "$tmp/apt-get.log" ] \
  && pass "apply --sources apt without root: exit 1, runs no apt-get" || fail "apply apt non-root: exit $code $out"
out="$(PATH="$tmp/latest-bin:$PATH" TOOLS_APT_LISTS="$tmp/apt-lists" FAIL_DPKG_QUERY=apt-pkg bash "$TOOLS" --list "$tmp/fx/apt-only.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 3 ] && grep -qx 'apt-tool present 1.2.3; installed package version unavailable' <<<"$out" \
  && pass "check --latest: a failed installed-package lookup is red and names the tool" || fail "installed package unavailable: exit $code $out"
out="$(PATH="$tmp/latest-bin:$PATH" TOOLS_APT_LISTS="$tmp/apt-lists" INSTALLED_DEB_VERSION=1:1.2.3-10 CANDIDATE_DEB_VERSION=1:1.2.3-2 bash "$TOOLS" --list "$tmp/fx/apt-only.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 0 ] && grep -qx 'apt-tool present 1.2.3' <<<"$out" \
  && pass "check --latest: real dpkg ordering keeps a newer Debian revision current" || fail "Debian ordering: exit $code $out"
head -n 1 "$tmp/fx/all-latest.tsv" > "$tmp/fx/node-only.tsv"
sed -n '6p' "$tmp/fx/all-latest.tsv" >> "$tmp/fx/node-only.tsv"
out="$(PATH="$tmp/latest-bin:$PATH" TOOLS_APT_LISTS="$tmp/apt-lists" INSTALLED_DEB_VERSION=1:1.2.3-2 CANDIDATE_DEB_VERSION=1:1.2.3-2 bash "$TOOLS" --list "$tmp/fx/node-only.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 0 ] && grep -qx 'node-tool present 1.2.3' <<<"$out" \
  && pass "check --latest: Node compares with the NodeSource channel, not a newer upstream release" || fail "NodeSource channel: exit $code $out"

# HumanLayer help is local. A missing API child can succeed with its parent's help.
printf 'humanlayer\thumanlayer\tnpm\t@humanlayer/cli\tlatest\t--version\timage\n' > "$tmp/fx/humanlayer.tsv"
cat > "$tmp/bin/humanlayer" <<'SH'
#!/usr/bin/env bash
[ "${HUMANLAYER_DISABLE_SELF_UPDATE:-}" = 1 ] || [ "$1" = --version ] || exit 9
if [ "$1" = --version ]; then echo 0.31.0; exit 0; fi
path="$*"; path="${path% --help}"
if [ "${HL_MISSING:-}" = "$path" ]; then
  echo 'Usage: humanlayer api [options] [command]'; exit 0
fi
case "$path" in
  'daemon launch') flags='--launch-token --no-self-update' ;;
  'api auth daemon launch-token create'|'api sync online-hosts'|'api sessions list'|'api sessions interrupt'|'api artifacts list'|'api artifacts get'|'api hosts delete') flags='' ;;
  'api sessions create') flags='--host-id --working-directory' ;;
  'api tasks archive') flags='--cascade-to-sessions' ;;
  *) exit 9 ;;
esac
[ "${HL_HELP_FAIL:-}" != "$path" ] || exit 1
printf 'Usage: humanlayer %s [options]\n' "$path"
for flag in $flags; do
  [ "${HL_FLAG_MISSING:-}" = "$path $flag" ] || printf '  %s <value>  Description\n' "$flag"
done
exit 0
SH
mkdir -p "$tmp/hl-package/bin"
mv "$tmp/bin/humanlayer" "$tmp/hl-package/bin/humanlayer"
printf '{"name":"@humanlayer/cli","version":"0.31.222"}\n' > "$tmp/hl-package/package.json"
chmod +x "$tmp/hl-package/bin/humanlayer"
ln -s "$tmp/hl-package/bin/humanlayer" "$tmp/bin/humanlayer"
out="$(PATH="$tmp/bin:$PATH" bash "$TOOLS" --list "$tmp/fx/humanlayer.tsv" check 2>&1)"; code=$?
[ "$code" = 0 ] && grep -qx 'humanlayer present 0.31.0' <<<"$out" \
  && pass "HumanLayer supports every required capability without login or updates" || fail "HumanLayer supported: exit $code $out"
out="$(PATH="$tmp/bin:$PATH" NPM_LATEST=0.31.222 bash "$TOOLS" --list "$tmp/fx/humanlayer.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 0 ] && grep -Fxq 'humanlayer present 0.31.222' <<<"$out" \
  && pass "HumanLayer freshness uses the npm release, not the binary's fixed version" || fail "HumanLayer npm version: exit $code $out"
out="$(PATH="$tmp/bin:$PATH" NPM_LATEST=0.31.223 bash "$TOOLS" --list "$tmp/fx/humanlayer.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 1 ] && grep -Fxq 'humanlayer present 0.31.222 behind 0.31.223' <<<"$out" \
  && pass "HumanLayer freshness rejects an older npm release" || fail "HumanLayer stale npm: exit $code $out"
mv "$tmp/hl-package/package.json" "$tmp/hl-package/package.good"
out="$(PATH="$tmp/bin:$PATH" bash "$TOOLS" --list "$tmp/fx/humanlayer.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 3 ] && grep -Fxq 'humanlayer present; installed npm package version unavailable' <<<"$out" \
  && pass "HumanLayer freshness fails loudly without package metadata" || fail "HumanLayer absent metadata: exit $code $out"
mv "$tmp/hl-package/package.good" "$tmp/hl-package/package.json"
for path in 'daemon launch' 'api auth daemon launch-token create' 'api sync online-hosts' 'api sessions create' 'api sessions list' 'api sessions interrupt' 'api artifacts list' 'api artifacts get' 'api tasks archive' 'api hosts delete'; do
  out="$(PATH="$tmp/bin:$PATH" HL_MISSING="$path" bash "$TOOLS" --list "$tmp/fx/humanlayer.tsv" check 2>&1)"; code=$?
  [ "$code" = 1 ] && grep -Fxq "humanlayer present; missing capability: $path" <<<"$out" \
    && pass "HumanLayer below the floor lacks $path, even with parent help exit 0" || fail "HumanLayer $path: exit $code $out"
done
for capability in 'daemon launch --launch-token' 'daemon launch --no-self-update' 'api sessions create --host-id' 'api sessions create --working-directory' 'api tasks archive --cascade-to-sessions'; do
  out="$(PATH="$tmp/bin:$PATH" HL_FLAG_MISSING="$capability" bash "$TOOLS" --list "$tmp/fx/humanlayer.tsv" check 2>&1)"; code=$?
  [ "$code" = 1 ] && grep -Fxq "humanlayer present; missing capability: $capability" <<<"$out" \
    && pass "HumanLayer missing $capability is red" || fail "HumanLayer $capability: exit $code $out"
done
out="$(PATH="$tmp/bin:$PATH" HL_HELP_FAIL='api artifacts get' bash "$TOOLS" --list "$tmp/fx/humanlayer.tsv" check --latest 2>&1)"; code=$?
[ "$code" = 1 ] && grep -Fxq 'humanlayer present; missing capability: api artifacts get' <<<"$out" \
  && pass "HumanLayer help failure also fails check --latest" || fail "HumanLayer help failure: exit $code $out"

bash "$DIR/tools-npm-selftest.sh" || fail "npm install probes and Claude repair"

# --- tools.sh apply ----------------------------------------------------------------------------------------------------

prefix="$tmp/prefix"
mkdir -p "$prefix/lib/node_modules/beta-pkg"
printf '{\n  "name": "beta-pkg",\n  "version": "1.2.3"\n}\n' > "$prefix/lib/node_modules/beta-pkg/package.json"
mkdir -p "$prefix/bin" && printf '#!/bin/sh\necho 1.2.3\n' > "$prefix/bin/beta" && chmod +x "$prefix/bin/beta"
: > "$tmp/npm.log"
out="$(PATH="$tmp/bin:$PATH" bash "$TOOLS" --list "$tmp/fx/check.tsv" apply --prefix "$prefix" --sources npm 2>&1)"; code=$?
installs="$(grep -c '^install' "$tmp/npm.log")"
[ "$code" = 0 ] && [ "$installs" = 1 ] && grep -qx "install -g --prefix $prefix --no-audit --no-fund --loglevel=error alpha-pkg@1.2.3" "$tmp/npm.log" \
  && grep -qx 'beta current 1.2.3' <<<"$out" && [ "$(grep -c '^view' "$tmp/npm.log")" = 2 ] \
  && pass "apply --sources npm with a stub npm: one install for each missing row, none for a current row, one lookup each" || fail "apply npm: exit $code $out $(cat "$tmp/npm.log")"
# --scope all: a machine installs only the all rows, never an image row.
printf 'gamma\tgamma-command-not-here\tnpm\tgamma-pkg\tlatest\t--version\timage\n' >> "$tmp/fx/check.tsv"
: > "$tmp/npm.log"
out="$(PATH="$tmp/bin:$PATH" bash "$TOOLS" --list "$tmp/fx/check.tsv" apply --prefix "$prefix" --sources npm --scope all 2>&1)"; code=$?
[ "$code" = 0 ] && ! grep -q gamma "$tmp/npm.log" && grep -qx 'alpha current 1.2.3' <<<"$out" && pass "apply --scope all installs no image row" || fail "apply scope: exit $code $out $(cat "$tmp/npm.log")"
out="$(PATH="$tmp/bin:$PATH" bash "$TOOLS" --list "$tmp/fx/check.tsv" apply --prefix "$prefix" --sources npm 2>&1)"
grep -q 'gamma-pkg@1.2.3' "$tmp/npm.log" && pass "apply with no --scope, as the image runs it, installs the image rows too" || fail "apply image scope: $out"
# A current package whose executable is gone is reinstalled: apply exits 0 only when check then passes.
rm -f "$prefix/bin/beta"; : > "$tmp/npm.log"
out="$(PATH="$tmp/bin:$PATH" bash "$TOOLS" --list "$tmp/fx/present.tsv" apply --prefix "$prefix" --sources npm --scope all 2>&1)"; code=$?
[ "$code" = 0 ] && grep -qx "repair: beta 1.2.3 has no beta in $prefix/bin; reinstalling" <<<"$out" && grep -qx "install -g --prefix $prefix --no-audit --no-fund --loglevel=error beta-pkg@1.2.3" "$tmp/npm.log" \
  && pass "apply reinstalls a current package whose executable is absent" || fail "absent executable: exit $code $out $(cat "$tmp/npm.log")"
rm -f "$prefix/bin/beta"
out="$(PATH="$tmp/bin:$PATH" NPM_OFFLINE=1 bash "$TOOLS" --list "$tmp/fx/present.tsv" apply --prefix "$prefix" --sources npm --scope all 2>&1)"; code=$?
[ "$code" = 3 ] && grep -q 'the registry cannot be reached for beta-pkg; beta is missing' <<<"$out" && pass "apply offline names a package with no executable as missing, exit 3" || fail "absent executable offline: exit $code $out"
printf '#!/bin/sh\necho 1.2.3\n' > "$prefix/bin/beta" && chmod +x "$prefix/bin/beta"
rm -rf "$prefix/lib/node_modules/alpha-pkg" "$prefix/lib/node_modules/gamma-pkg"
out="$(PATH="$tmp/bin:$PATH" NPM_OFFLINE=1 bash "$TOOLS" --list "$tmp/fx/check.tsv" apply --prefix "$prefix" --sources npm 2>&1)"; code=$?
[ "$code" = 3 ] && grep -q 'the registry cannot be reached for alpha-pkg; alpha is missing' <<<"$out" && grep -q 'beta kept 1.2.3' <<<"$out" \
  && pass "apply with a stub npm that cannot reach the registry for a missing tool: exit 3, names the tool" || fail "apply offline: exit $code $out"
out="$(PATH="$tmp/bin:$PATH" NPM_FAIL=1 bash "$TOOLS" --list "$tmp/fx/check.tsv" apply --prefix "$prefix" --sources npm 2>&1)"; code=$?
[ "$code" = 1 ] && grep -q 'install failed: alpha alpha-pkg@1.2.3' <<<"$out" && pass "apply exits 1 and names the tool when an install fails" || fail "apply fail: exit $code $out"
out="$(bash "$TOOLS" --list "$tmp/fx/check.tsv" apply --prefix "$prefix" --sources feature 2>&1)"; code=$?
[ "$code" = 2 ] && pass "apply refuses the feature source: the devcontainer CLI installs features" || fail "apply feature: exit $code $out"
out="$(bash "$TOOLS" --list "$tmp/fx/check.tsv" apply --sources npm 2>&1)"; code=$?
[ "$code" = 2 ] && pass "apply without --prefix exits 2" || fail "apply no prefix: exit $code $out"

if grep -qF 'https://downloads.1password.com/linux/keys/1password.asc' "$TOOLS" \
  && grep -qF '/etc/debsig/policies/AC2D62742012EA22/1password.pol' "$TOOLS" \
  && grep -qF '/usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg' "$TOOLS" \
  && grep -qF 'signed-by=/usr/share/keyrings/1password-archive-keyring.gpg' "$TOOLS"; then
  pass "install_op configures the signed 1Password apt repository and its debsig policy"
else
  fail "install_op lacks the signed 1Password apt repository or its debsig policy"
fi
if grep -qF 'command -v op' "$DIR/image-selftest.sh" \
  && grep -qF -- '--version >/dev/null' "$DIR/image-selftest.sh"; then
  pass "the image self-test runs op --version"
else
  fail "the image self-test does not run op --version"
fi
if grep -qF 'command -v no-mistakes' "$DIR/image-selftest.sh" \
  && grep -qF 'no-mistakes did not report a version' "$DIR/image-selftest.sh"; then
  pass "the image self-test runs no-mistakes --version"
else
  fail "the image self-test does not run no-mistakes --version"
fi

# --- npm axi tools, from the real list, installed under the Dockerfile's npm prefix ------------------------

image_prefix="$(sed -n 's|.*tools\.sh apply --prefix \([^ ]*\) --sources npm.*|\1|p' "$dockerfile")"
npm_prefix="$tmp/image$image_prefix"
npm_list="$tmp/fx/npm-axi.tsv"
head -n 1 "$MICHELIN/image/references/tools.tsv" > "$npm_list"
npm_axi="$(awk -F'\t' '$2 ~ /-axi$/ && $3 == "npm" { print $2 }' "$MICHELIN/image/references/tools.tsv")"
for t in $npm_axi; do
  awk -F'\t' -v t="$t" '$2 == t && $3 == "npm"' "$MICHELIN/image/references/tools.tsv" | grep . >> "$npm_list" \
    || fail "npm axi tool $t has no npm row in tools.tsv"
done
PATH="$tmp/bin:$PATH" bash "$TOOLS" --list "$npm_list" apply --prefix "$npm_prefix" --sources npm >/dev/null 2>&1
for t in $npm_axi; do
  [ -x "$npm_prefix/bin/$t" ] && pass "npm axi tool $t is installed under the image prefix" \
    || fail "npm axi tool $t is missing under the image prefix"
done

# --- workbench-image.sh check and layers, with a stub vercel and docker ------------------------------------------------

mkdir -p "$tmp/vbin"
cat > "$tmp/vbin/vercel" <<'SH'
#!/bin/bash
printf '%s\n' "$*" > "$TEST_DIR/vercel.args"
case "${SANDBOX:-ok}" in
  down) echo "Error: sandbox failed to start" >&2; exit 1 ;;
  missing) printf 'user: vercel-sandbox\nhome: /home/vscode\njq present 1.7.1\ntailscale missing\ntools: 30 present, 1 missing, 0 behind, 0 latest unavailable\n'; exit 1 ;;
  floor) printf 'user: vercel-sandbox\nhome: /home/vscode\nhumanlayer present; missing capability: api hosts delete\nhumanlayer present 0.31.0 behind required capabilities\ntools: 1 present, 0 missing, 1 behind, 0 latest unavailable\n'; exit 1 ;;
  failed) printf 'tools: 1 present, 0 missing, 0 behind, 0 latest unavailable\n'; exit 1 ;;
  stale) printf 'user: vercel-sandbox\nhome: /home/vscode\njq present 1.7.1 behind 1.8.0\ntools: 31 present, 0 missing, 1 behind, 0 latest unavailable\n'; exit 1 ;;
  unknown) printf 'user: vercel-sandbox\nhome: /home/vscode\njq present 1.7.1; latest stable unavailable\ntools: 31 present, 0 missing, 0 behind, 1 latest unavailable\n'; exit 3 ;;
  mixed) printf 'user: vercel-sandbox\nhome: /home/vscode\ntailscale missing\njq present 1.7.1; latest stable unavailable\ntools: 30 present, 1 missing, 0 behind, 1 latest unavailable\n'; exit 3 ;;
  noindex) printf 'user: vercel-sandbox\nhome: /home/vscode\napt indexes: sudo -n apt-get update failed\napt indexes: none in /var/lib/apt/lists; run apt-get update as root before check --latest\njq present 1.7.1; latest stable unavailable\ntools: 31 present, 0 missing, 0 behind, 1 latest unavailable\n'; exit 3 ;;
  ok) printf 'user: vercel-sandbox\nhome: /home/vscode\njq present 1.7.1\ntools: 31 present, 0 missing, 0 behind, 0 latest unavailable\n' ;;
esac
SH
cat > "$tmp/vbin/docker" <<'SH'
#!/bin/bash
[ "$1 $2 $3 $4" = "buildx imagetools inspect --raw" ] || exit 9
case "$5" in
  *:big) printf '{"manifests":[{"digest":"sha256:arm","platform":{"os":"linux","architecture":"arm64"}},{"digest":"sha256:amd","platform":{"os":"linux","architecture":"amd64"}}]}\n' ;;
  *@sha256:amd) printf '{"layers":[{"digest":"sha256:small","size":1000},{"digest":"sha256:huge","size":2100000000}]}\n' ;;
  *:fine) printf '{"layers":[{"digest":"sha256:small","size":1000}]}\n' ;;
  *) echo "not found" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/vbin/"*
out="$(PATH="$tmp/vbin:$PATH" SANDBOX=ok bash "$CLI" check --tag 2026.10.15-1-trial 2>&1)"; code=$?
[ "$code" = 0 ] && grep -qx 'user: vercel-sandbox' <<<"$out" && grep -qx 'home: /home/vscode' <<<"$out" && grep -q -- '--image workbench:2026.10.15-1-trial' "$tmp/vercel.args" \
  && grep -q 'tools.sh check --scope image --latest' "$tmp/vercel.args" && pass "check verifies latest stable for the tools in the tag's sandbox" || fail "check ok: exit $code $out"
grep -q 'sudo -n apt-get update -qq [^;]*|| echo "apt indexes: sudo -n apt-get update failed"; /opt/digio/tools/tools.sh check --scope image --latest' "$tmp/vercel.args" \
  && pass "the sandbox refreshes the APT indexes that the devcontainer features delete, before the tool check" || fail "sandbox index refresh: $(cat "$tmp/vercel.args")"
out="$(PATH="$tmp/vbin:$PATH" SANDBOX=noindex bash "$CLI" check --tag x 2>&1)"; code=$?
[ "$code" = 3 ] && grep -qx 'apt indexes: sudo -n apt-get update failed' <<<"$out" && grep -q 'could not verify latest stable for: jq' <<<"$out" \
  && pass "workbench-image check with a failed index refresh: exit 3, names the refresh and the unverified tool" || fail "check noindex: exit $code $out"
out="$(PATH="$tmp/vbin:$PATH" SANDBOX=missing bash "$CLI" check --tag x 2>&1)"; code=$?
[ "$code" = 1 ] && grep -q 'missing: tailscale' <<<"$out" && pass "workbench-image check with a missing tool: exit 1 and names it" || fail "check missing: exit $code $out"
out="$(PATH="$tmp/vbin:$PATH" SANDBOX=stale bash "$CLI" check --tag x 2>&1)"; code=$?
[ "$code" = 1 ] && grep -q 'behind: jq' <<<"$out" && pass "workbench-image check with a stale tool: exit 1 and names it" || fail "check stale: exit $code $out"
out="$(PATH="$tmp/vbin:$PATH" SANDBOX=floor bash "$CLI" check --tag x 2>&1)"; code=$?
[ "$code" = 1 ] && grep -q 'missing capability: api hosts delete' <<<"$out" && grep -q 'behind: humanlayer' <<<"$out" \
  && pass "sandbox check preserves the missing HumanLayer capability" || fail "sandbox floor: exit $code $out"
out="$(PATH="$tmp/vbin:$PATH" SANDBOX=failed bash "$CLI" check --tag x 2>&1)"; code=$?
[ "$code" = 1 ] && grep -q 'tool check failed (exit 1)' <<<"$out" \
  && pass "sandbox check refuses a failed tool check with a healthy summary" || fail "sandbox failed: exit $code $out"
out="$(PATH="$tmp/vbin:$PATH" SANDBOX=unknown bash "$CLI" check --tag x 2>&1)"; code=$?
[ "$code" = 3 ] && grep -q 'could not verify latest stable for: jq' <<<"$out" && pass "workbench-image check with an unavailable lookup: exit 3 and names it" || fail "check unknown: exit $code $out"
out="$(PATH="$tmp/vbin:$PATH" SANDBOX=mixed bash "$CLI" check --tag x 2>&1)"; code=$?
[ "$code" = 3 ] && grep -q 'missing: tailscale' <<<"$out" && grep -q 'could not verify latest stable for: jq' <<<"$out" \
  && pass "workbench-image check reports missing and unverified tools together" || fail "check mixed: exit $code $out"
out="$(PATH="$tmp/vbin:$PATH" SANDBOX=down bash "$CLI" check --tag x 2>&1)"; code=$?
[ "$code" = 3 ] && grep -q 'did not start' <<<"$out" && pass "workbench-image check with a stub sandbox that does not start: exit 3" || fail "check down: exit $code $out"
out="$(PATH="$tmp/vbin:$PATH" bash "$CLI" layers --tag big 2>&1)"; code=$?
[ "$code" = 1 ] && grep -qx 'layer sha256:huge 2100000000 over 2 GB' <<<"$out" && grep -qx 'layer sha256:small 1000' <<<"$out" \
  && pass "workbench-image layers with a stub manifest that has a layer of 2.1 GB: exit 1, names the layer" || fail "layers big: exit $code $out"
out="$(PATH="$tmp/vbin:$PATH" bash "$CLI" layers --tag fine 2>&1)"; code=$?
[ "$code" = 0 ] && grep -q 'layers: 1 layers, each under 2 GB' <<<"$out" && pass "layers passes a build whose layers are each under 2 GB" || fail "layers fine: exit $code $out"
out="$(PATH="$tmp/vbin:$PATH" bash "$CLI" layers --tag gone 2>&1)"; code=$?
[ "$code" = 3 ] && pass "layers exits 3 when the registry cannot be read" || fail "layers gone: exit $code $out"
bash "$CLI" layers >/dev/null 2>&1; [ $? = 2 ] && pass "layers without --tag exits 2" || fail "layers no tag"

# --- the start scripts ---------------------------------------------------------------------------------------------------

for t in tailnet-start-selftest.sh session-export-sweep-selftest.sh humanlayer-daemon-selftest.sh git-hooks-selftest.sh workbench-start-selftest.sh; do
  out="$(bash "$DIR/$t" 2>&1)" && pass "$t" || fail "$t: $out"
done

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
