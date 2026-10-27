#!/usr/bin/env bash
# Self-test for release.sh. It builds scratch git repos with merge commits and a bare origin: no network, no registry,
# no GitHub, no token. Stub npm and gh commands go first on PATH and record each call. The stub npm answers view and
# publish from a scratch registry folder and passes every other verb, such as pack, to the real npm. The stub gh
# answers release view and release create from a scratch folder of Releases.
# Each check is a single-quoted string that check() evals later, so SC2016 and SC2034 are false positives here.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cli="${RELEASE_SH:-$here/release.sh}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

for tool in git node npm; do command -v "$tool" >/dev/null || { echo "FAIL $tool is not on PATH" >&2; exit 1; }; done
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global init.defaultBranch main
git config --global user.name selftest
git config --global user.email selftest@example.invalid
git config --global advice.detachedHead false

# The stubs. STUB holds the call log, the registry (one file per name@version) and the Releases (one notes file each).
export STUB="$tmp/stub" REAL_NPM GITHUB_REPOSITORY=digio-nz/pkg
REAL_NPM="$(command -v npm)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "npm $*" >> "$STUB/calls"
case "$1" in
  view)
    if [ -n "${NPM_VIEW_ERROR:-}" ]; then echo "npm error code $NPM_VIEW_ERROR" >&2; echo "npm error $NPM_VIEW_ERROR stub" >&2; exit 1; fi
    if [ -e "$STUB/registry/$2" ]; then echo "${2##*@}"; exit 0; fi
    echo "npm error code E404" >&2; echo "npm error 404 No match found for version ${2##*@}" >&2; exit 1 ;;
  publish)
    spec="$(node -p 'const p = require("./package.json"); p.name + "@" + p.version')"
    echo "$spec $(cksum < src/index.ts | awk '{ print $1 }')" >> "$STUB/published"
    d="$(mktemp -d)"; "$REAL_NPM" pack --ignore-scripts --silent --pack-destination "$d" >/dev/null
    tar -tzf "$d"/*.tgz | sed 's|^package/||' | LC_ALL=C sort | paste -sd ' ' - > "$STUB/tree-${spec##*/}"
    mkdir -p "$(dirname "$STUB/registry/$spec")"; touch "$STUB/registry/$spec" ;;
  *) exec "$REAL_NPM" "$@" ;;
esac
EOF
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$STUB/calls"
case "$1 $2" in
  "release view") [ -e "$STUB/releases/$3" ] && exit 0; echo "release not found" >&2; exit 1 ;;
  "release create")
    tag="$3"; shift 3
    while [ $# -gt 0 ]; do [ "$1" = --notes-file ] && cp "$2" "$STUB/releases/$tag"; shift; done ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/npm" "$tmp/bin/gh"

# fresh: a new origin and a clone at $w, with one commit of a valid package on main. Empty stub state.
n=0
fresh() {
  n=$((n + 1)); w="$tmp/w$n"; o="$tmp/o$n.git"; package_dir=.
  rm -rf "$STUB"; mkdir -p "$STUB/registry" "$STUB/releases"; : > "$STUB/calls"; : > "$STUB/published"
  git init -q --bare "$o"
  git init -q "$w"
  mkdir -p "$w/src" "$w/.github"
  cat > "$w/package.json" <<'EOF'
{
  "name": "@digio-nz/pkg",
  "version": "0.0.0",
  "type": "module",
  "files": ["src"],
  "exports": { ".": "./src/index.ts" },
  "repository": { "type": "git", "url": "https://github.com/digio-nz/pkg.git" },
  "publishConfig": { "registry": "https://npm.pkg.github.com" }
}
EOF
  echo start > "$w/src/index.ts"; echo readme > "$w/README.md"; echo agents > "$w/AGENTS.md"; echo ci > "$w/.github/ci.yml"
  git -C "$w" add -A; git -C "$w" commit -qm "chore: start"
  git -C "$w" remote add origin "$o"; git -C "$w" push -q origin main
}
# fresh_subfolder: move the package into packages/pkg, and leave a repository-level semver tag that belongs to
# another artifact. A package in a subfolder must have its own tag namespace and read its tree from that folder.
fresh_subfolder() {
  fresh
  mkdir -p "$w/packages/pkg"
  git -C "$w" mv package.json README.md src packages/pkg/
  git -C "$w" commit -qm "chore: move package into a subfolder"
  git -C "$w" push -q origin main
  git -C "$w" tag v9.0.0
  git -C "$w" push -q origin v9.0.0
  package_dir=packages/pkg
}
# merge <title> [file]: on a branch, change the file (src/index.ts by default), then merge it into main with a merge
# commit whose title is <title>, and push main.
merge() {
  local f="${2:-src/index.ts}" b="b$RANDOM"
  git -C "$w" checkout -q -b "$b"
  echo "$1 $RANDOM" >> "$w/$f"; git -C "$w" add -A; git -C "$w" commit -qm "work for $1"
  git -C "$w" checkout -q main; git -C "$w" merge -q --no-ff -m "$1" "$b"; git -C "$w" branch -q -D "$b"
  git -C "$w" push -q origin main
}
# tag <version>: tag main's tip v<version> and push the tag; the registry holds the version and it has a Release.
tag() {
  git -C "$w" tag "v$1"; git -C "$w" push -q origin "v$1"
  mkdir -p "$STUB/registry/@digio-nz"; touch "$STUB/registry/@digio-nz/pkg@$1"; echo "- old" > "$STUB/releases/v$1"
}
# run <args>: run release.sh in $w with the stubs; rc, out (stdout) and err (stderr) hold the result.
run() {
  rc=0; (cd "$w/$package_dir" && PATH="$tmp/bin:$PATH" bash "$cli" "$@") >"$tmp/out" 2>"$tmp/err" || rc=$?
  out="$(cat "$tmp/out")"; err="$(cat "$tmp/err")"
}
first() { awk 'NR == 1' "$tmp/out"; }
sum_of() { cksum | awk '{ print $1 }'; }
origin_tags() { git --git-dir="$o" tag --list | paste -sd ' ' -; }

# The bump.
fresh; run next
check "no tag: next prints 0.1.0" '[ "$rc" = 0 ] && [ "$(first)" = 0.1.0 ]'

fresh; tag 0.3.0; merge "fix: a"; merge "chore(templates): b"; run next
check "0.3.0 with fix: a and chore(templates): b: 0.3.1" '[ "$rc" = 0 ] && [ "$(first)" = 0.3.1 ]'
check "next names each title that decided it" 'grep -qx "  patch  fix: a" "$tmp/out" && grep -qx "  patch  chore(templates): b" "$tmp/out"'

fresh; tag 0.3.0; merge "feat: a"; run next
check "0.3.0 with feat: a: 0.4.0" '[ "$(first)" = 0.4.0 ]'
fresh; tag 0.3.0; merge "feat!: a"; run next
check "0.3.0 with feat!: a: 0.4.0, not 1.0.0" '[ "$(first)" = 0.4.0 ]'
fresh; tag 0.3.0; merge "fix(auth)!: a"; run next
check "0.3.0 with fix(auth)!: a: 0.4.0" '[ "$(first)" = 0.4.0 ]'
fresh; tag 0.3.0; merge "process: deploy templates"; run next
check "0.3.0 with process: deploy templates: 0.3.1" '[ "$(first)" = 0.3.1 ]'
fresh; tag 1.2.3; merge "feat!: a"; run next
check "1.2.3 with feat!: a: 2.0.0" '[ "$(first)" = 2.0.0 ]'
fresh; tag 1.2.3; merge "feat: a"; run next
check "1.2.3 with feat: a: 1.3.0" '[ "$(first)" = 1.3.0 ]'
fresh; tag 1.2.3; merge "fix: a"; run next
check "1.2.3 with fix: a: 1.2.4" '[ "$(first)" = 1.2.4 ]'

fresh; tag 0.2.0; merge "P1.4 feat(icons): x"; run next
check "0.2.0 with P1.4 feat(icons): x: 0.3.0" '[ "$(first)" = 0.3.0 ]'
fresh; tag 0.2.0; merge "P1.1 fix(css): x"; run next
check "0.2.0 with P1.1 fix(css): x: 0.2.1" '[ "$(first)" = 0.2.1 ]'
fresh; tag 0.2.0; merge "#12 feat: x"; run next
check "0.2.0 with #12 feat: x: 0.3.0" '[ "$(first)" = 0.3.0 ]'
fresh; tag 0.2.0; merge "P3 feat: x"; run next
check "0.2.0 with P3 feat: x: 0.3.0" '[ "$(first)" = 0.3.0 ]'
fresh; tag 0.2.0; merge "P1.4 feat!: x"; run next
check "0.2.0 with P1.4 feat!: x: 0.3.0" '[ "$(first)" = 0.3.0 ]'
fresh; tag 1.2.3; merge "P1.4 feat!: x"; run next
check "1.2.3 with P1.4 feat!: x: 2.0.0" '[ "$(first)" = 2.0.0 ]'
fresh; tag 0.2.0; merge "P1.4 chore: x"; run next
check "0.2.0 with P1.4 chore: x: 0.2.1" '[ "$(first)" = 0.2.1 ]'
fresh; tag 0.2.0; merge "Px feat: x"; run next
check "0.2.0 with Px feat: x, not a plan ref: 0.2.1" '[ "$(first)" = 0.2.1 ]'
fresh; tag 0.9.0; tag 0.10.0; merge "fix: a"; run next
check "the last tag is the highest by version, not by text: v0.10.0 before v0.9.0" '[ "$(first)" = 0.10.1 ]'

# A pull request: HEAD is GitHub's synthetic merge of the branch into main. Its title would make 2.0.0.
fresh; tag 1.2.3
git -C "$w" checkout -q -b pr; echo pr >> "$w/src/index.ts"; git -C "$w" commit -qam "work on the pr"
git -C "$w" checkout -q --detach origin/main; git -C "$w" merge -q --no-ff -m "feat!: the synthetic merge" pr
run next --title "feat: x" --base origin/main
check "a pull request: the PR title counts and the synthetic merge commit does not (1.3.0)" '[ "$rc" = 0 ] && [ "$(first)" = 1.3.0 ] && grep -qx "  minor  feat: x" "$tmp/out" && ! grep -q synthetic "$tmp/out"'
run next --base no-such-ref
check "next with a --base that is no commit: exit 1, names it" '[ "$rc" = 1 ] && grep -q "no commit no-such-ref" <<<"$err"'

# Only a merge that changes a package input decides the bump and goes in the Release.
fresh; tag 0.3.0; merge "feat(ci): x" .github/ci.yml; merge "fix: y"; run next
check "0.3.0, feat(ci): x on .github/ only, then fix: y on src/: 0.3.1" '[ "$rc" = 0 ] && [ "$(first)" = 0.3.1 ] && grep -qx "  patch  fix: y" "$tmp/out" && ! grep -q "feat(ci)" "$tmp/out"'
run publish
check "the Release lists only the titles that changed the package" '[ "$rc" = 0 ] && [ "$(cat "$STUB/releases/v0.3.1")" = "- fix: y" ]'
fresh; tag 1.2.3; merge "feat!: ci" .github/ci.yml; merge "fix: y"; run next
check "1.2.3, feat!: ci on .github/ only, then fix: y on src/: 1.2.4" '[ "$(first)" = 1.2.4 ]'
fresh; tag 0.3.0; merge "fix: a"
git -C "$w" checkout -q -b pr; echo ci2 >> "$w/.github/ci.yml"; git -C "$w" commit -qam "work on the pr"
git -C "$w" checkout -q --detach origin/main; git -C "$w" merge -q --no-ff -m "Merge pr into main" pr
run next --title "feat: ci only" --base origin/main
check "a pull request that changes no package input: its title does not count (0.3.1)" '[ "$rc" = 0 ] && [ "$(first)" = 0.3.1 ] && ! grep -q "feat: ci only" "$tmp/out"'

# A stacked pull request: its base is a lower phase's branch, and the titles come from that base.
fresh; tag 0.3.0
git -C "$w" checkout -q -b plan-x
git -C "$w" checkout -q -b lower; echo lower >> "$w/src/index.ts"; git -C "$w" commit -qam "work on lower"
git -C "$w" checkout -q plan-x; git -C "$w" merge -q --no-ff -m "feat: lower" lower; git -C "$w" push -q origin plan-x
git -C "$w" checkout -q -b upper; echo upper >> "$w/src/index.ts"; git -C "$w" commit -qam "work on upper"
git -C "$w" checkout -q --detach origin/plan-x; git -C "$w" merge -q --no-ff -m "Merge upper into plan-x" upper
run next --title "fix: upper" --base origin/plan-x
check "a stacked pull request: the titles of its base branch count (feat: lower makes 0.4.0)" '[ "$rc" = 0 ] && [ "$(first)" = 0.4.0 ] && grep -qx "  minor  feat: lower" "$tmp/out" && grep -qx "  patch  fix: upper" "$tmp/out"'

# unchanged: only files outside the tarball changed since the tag.
fresh; tag 0.3.0; merge "fix: ci" .github/ci.yml; merge "docs(agents): x" AGENTS.md; run next
check "only .github/ and AGENTS.md changed: next prints unchanged since v0.3.0, exit 0" '[ "$rc" = 0 ] && [ "$out" = "unchanged since v0.3.0" ]'
run publish
check "only .github/ and AGENTS.md changed: publish prints unchanged, exit 0" '[ "$rc" = 0 ] && grep -qx "unchanged since v0.3.0" "$tmp/out"'
check "only .github/ and AGENTS.md changed: publish calls no npm publish" '! grep -q "^npm publish" "$STUB/calls"'
check "only .github/ and AGENTS.md changed: publish pushes no tag" '[ "$(origin_tags)" = v0.3.0 ]'

fresh; tag 0.3.0; merge "docs: readme" README.md; run next
check "README.md changed since the tag: a release (0.3.1), decided by its title" '[ "$rc" = 0 ] && [ "$(first)" = 0.3.1 ] && grep -qx "  patch  docs: readme" "$tmp/out"'

# check: one case for each fault, and a valid package.
# set_pkg <jq-like node expression on p>: change the package.json of $w.
set_pkg() { node -e 'const fs = require("fs"); const f = process.argv[1]; const p = JSON.parse(fs.readFileSync(f)); (new Function("p", process.argv[2]))(p); fs.writeFileSync(f, JSON.stringify(p, null, 2));' "$w/package.json" "$1"; }
# A package with a build script: each pack installs and builds the tree first, and every file in the folder is an input.
# built: give $w a build script that writes dist/index.js from src/index.ts, and ship dist only.
built() {
  set_pkg 'p.files = ["dist"]; delete p.exports; p.scripts = { build: "node -e \"require(\\\"fs\\\").mkdirSync(\\\"dist\\\", {recursive: true}); require(\\\"fs\\\").copyFileSync(\\\"src/index.ts\\\", \\\"dist/index.js\\\")\"" }'
  git -C "$w" commit -qam "chore: build"; git -C "$w" push -q origin main
}
fresh; built; tag 0.3.0; merge "feat: a"; run publish
check "a build script: publish builds the tree and the tarball holds dist/ and no src/" '[ "$rc" = 0 ] && [ "$(cat "$STUB/tree-pkg@0.4.0")" = "README.md dist/index.js package.json" ]'
check "a build script: a merge that changes a source outside files decides the bump (feat: a makes 0.4.0)" 'grep -q "^@digio-nz/pkg@0.4.0 " "$STUB/published" && [ "$(cat "$STUB/releases/v0.4.0")" = "- feat: a" ]'
fresh; built; tag 0.3.0; merge "fix: ci" .github/ci.yml; run next
check "a build script: only .github/ changed: unchanged since v0.3.0" '[ "$rc" = 0 ] && [ "$out" = "unchanged since v0.3.0" ]'
fresh; built; set_pkg 'p.scripts.build = "exit 1"'; git -C "$w" commit -qam "fix: break the build"; tag 0.3.0; merge "fix: a"; run next
check "a build script that fails: exit 1, names the tree" '[ "$rc" = 1 ] && grep -q "the build of the tree at" <<<"$err"'

fresh; run check
check "check: a valid package.json exits 0" '[ "$rc" = 0 ] && [ -z "$err" ]'
GITHUB_REPOSITORY='' run check
check "check with no GITHUB_REPOSITORY: exit 1, names it" '[ "$rc" = 1 ] && grep -q GITHUB_REPOSITORY <<<"$err"'
fresh; set_pkg 'p.name = "@digio/auth-types"'; run check
check "check with name @digio/auth-types: exit 1, names the scope" '[ "$rc" = 1 ] && grep -q "@digio/auth-types. is outside the @digio-nz scope" <<<"$err"'
fresh; set_pkg 'p.private = true'; run check
check "check with \"private\": true: exit 1, names private" '[ "$rc" = 1 ] && grep -q "\"private\": true" <<<"$err"'
fresh; set_pkg 'delete p.files'; run check
check "check with no files: exit 1, names files" '[ "$rc" = 1 ] && grep -q "no files list" <<<"$err"'
fresh; set_pkg 'p.files = []'; run check
check "check with an empty files list: exit 1, names files" '[ "$rc" = 1 ] && grep -q "no files list" <<<"$err"'
fresh; set_pkg 'p.repository.url = "git+https://github.com/digio-nz/other.git"'; run check
check "check with a repository URL of another repo: exit 1, names both URLs" '[ "$rc" = 1 ] && grep -q "git+https://github.com/digio-nz/other.git is another repo than https://github.com/digio-nz/pkg" <<<"$err"'
fresh; set_pkg 'p.repository = "github:digio-nz/pkg"'; run check
check "check reads the short repository form github:owner/name" '[ "$rc" = 0 ]'
fresh; set_pkg 'delete p.repository'; run check
check "check with no repository: exit 1, names the repo it wants" '[ "$rc" = 1 ] && grep -q "no repository URL; it must be https://github.com/digio-nz/pkg" <<<"$err"'
fresh; set_pkg 'p.version = "0.3.0"'; run check
check "check with \"version\": \"0.3.0\": exit 1, names the version" '[ "$rc" = 1 ] && grep -q "version is .0.3.0." <<<"$err"'
fresh; set_pkg 'p.name = "x"; p.private = true'; run check
check "check names each fault, not only the first" '[ "$rc" = 1 ] && [ "$(grep -c "^fault: " <<<"$err")" = 2 ]'

# publish: a normal release.
fresh; tag 0.3.0; merge "feat: a"; merge "fix: b"; run publish
check "publish: exit 0" '[ "$rc" = 0 ]'
check "publish: pushes the tag v0.4.0 on HEAD" '[ "$(git --git-dir="$o" rev-parse "v0.4.0^{commit}")" = "$(git -C "$w" rev-parse HEAD)" ]'
check "publish: publishes 0.4.0 from the tree at HEAD" '[ "$(cat "$STUB/published")" = "@digio-nz/pkg@0.4.0 $(sum_of < "$w/src/index.ts")" ]'
check "publish: the Release body lists the merge-commit titles" '[ "$(cat "$STUB/releases/v0.4.0")" = "$(printf -- "- feat: a\n- fix: b")" ]'
check "publish: the tag push comes before npm publish, and npm publish before the Release" '[ "$(grep -n "^npm publish" "$STUB/calls" | cut -d: -f1)" -lt "$(grep -n "^gh release create v0.4.0" "$STUB/calls" | cut -d: -f1)" ]'
check "publish: commits nothing and leaves the working copy at 0.0.0" '[ -z "$(git -C "$w" status --porcelain)" ] && grep -q "\"version\": \"0.0.0\"" "$w/package.json" && [ "$(git --git-dir="$o" rev-parse main)" = "$(git -C "$w" rev-parse HEAD)" ]'
run publish
check "publish run again on the same HEAD: unchanged since v0.4.0, no second npm publish" '[ "$rc" = 0 ] && grep -qx "unchanged since v0.4.0" "$tmp/out" && [ "$(grep -c "^npm publish" "$STUB/calls")" = 1 ]'

fresh; merge "feat: first"; run publish
check "publish with no tag: publishes 0.1.0 and tags v0.1.0" '[ "$rc" = 0 ] && grep -q "^@digio-nz/pkg@0.1.0 " "$STUB/published" && [ "$(origin_tags)" = v0.1.0 ]'
check "publish with no tag: the Release lists every title" '[ "$(cat "$STUB/releases/v0.1.0")" = "$(printf -- "- chore: start\n- feat: first")" ]'

fresh_subfolder; run publish
check "a package in a subfolder: ignores repository-level semver tags and publishes 0.1.0" '[ "$rc" = 0 ] && grep -q "^@digio-nz/pkg@0.1.0 " "$STUB/published"'
check "a package in a subfolder: tags and releases pkg-v0.1.0" '[ "$(origin_tags)" = "pkg-v0.1.0 v9.0.0" ] && [ -e "$STUB/releases/pkg-v0.1.0" ]'
check "a package in a subfolder: publishes only the selected package tree" '[ "$(cat "$STUB/tree-pkg@0.1.0")" = "README.md package.json src/index.ts" ]'

# publish: a run before failed part way.
fresh; tag 0.3.0; merge "fix: a"; git -C "$w" tag v0.3.1; git -C "$w" push -q origin v0.3.1
merge "fix: after"; at_tag="$(git -C "$w" show v0.3.1:src/index.ts | sum_of)"; run publish
check "tag v0.3.1 exists and the registry has no 0.3.1: publish publishes 0.3.1 from the tag's tree" '[ "$rc" = 0 ] && [ "$(awk "NR == 1" "$STUB/published")" = "@digio-nz/pkg@0.3.1 $at_tag" ]'
check "tag v0.3.1 with no Release: publish writes its Release from the titles since v0.3.0" '[ "$(cat "$STUB/releases/v0.3.1")" = "- fix: a" ]'
check "then publish releases the merge after the tag as 0.3.2" '[ "$(awk "NR == 2" "$STUB/published")" = "@digio-nz/pkg@0.3.2 $(sum_of < "$w/src/index.ts")" ] && [ "$(cat "$STUB/releases/v0.3.2")" = "- fix: after" ]'

fresh; tag 0.3.0; merge "fix: a"; tag 0.3.1; rm "$STUB/releases/v0.3.1"; run publish
check "tag and package exist, no Release: publish writes only the Release" '[ "$rc" = 0 ] && [ "$(cat "$STUB/releases/v0.3.1")" = "- fix: a" ] && ! grep -q "^npm publish" "$STUB/calls" && [ "$(origin_tags)" = "v0.3.0 v0.3.1" ]'

fresh; tag 0.3.0; merge "fix: a"; NPM_VIEW_ERROR=E401 run publish
check "the stub npm view exits with E401: exit 1, names E401" '[ "$rc" = 1 ] && grep -q "failed with E401" <<<"$err"'
check "the stub npm view exits with E401: no npm publish, no tag" '! grep -q "^npm publish" "$STUB/calls" && [ "$(origin_tags)" = v0.3.0 ]'

fresh; tag 0.3.0; merge "fix: a"
printf '#!/bin/sh\necho "stub: refused" >&2\nexit 1\n' > "$o/hooks/pre-receive"; chmod +x "$o/hooks/pre-receive"
run publish
check "the tag push fails: exit 1, names it" '[ "$rc" = 1 ] && grep -q "the push of the tag v0.3.1 failed" <<<"$err"'
check "the tag push fails: no npm publish, no Release, no tag left here" '! grep -q "^npm publish" "$STUB/calls" && [ ! -e "$STUB/releases/v0.3.1" ] && ! git -C "$w" rev-parse -q --verify refs/tags/v0.3.1 >/dev/null'

fresh; tag 0.3.0; merge "fix: a"; stale="$(git -C "$w" rev-parse main)"
merge "feat: b"; tag 0.4.0; git -C "$w" checkout -q --detach "$stale"; run publish
check "a HEAD that lacks a higher tag (a stale run): exit 1, names the tag, publishes nothing" '[ "$rc" = 1 ] && grep -q "the tag v0.4.0 is not in HEAD" <<<"$err" && ! grep -q "^npm publish" "$STUB/calls"'

fresh; set_pkg 'p.private = true'; git -C "$w" commit -qam "fix: private"; run publish
check "publish refuses a package.json with a fault, and publishes nothing" '[ "$rc" = 1 ] && grep -q "^fault: " <<<"$err" && ! grep -q "^npm publish" "$STUB/calls"'

fresh; tag 0.3.0; merge "feat: external source"
cp "$w/package.json" "$tmp/source-manifest.json"
cat > "$tmp/materializer.sh" <<'SOURCE'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  inputs) [ "${EMPTY_SOURCE_INPUTS:-0}" = 1 ] || echo . ;;
  tree)
    [ "${FAIL_SOURCE:-0}" = 0 ] || exit 1
    mkdir -p "$3"
    git archive "$2" | tar -xf - -C "$3"
    ;;
esac
SOURCE
PACKAGE_MANIFEST="$tmp/source-manifest.json" PACKAGE_SOURCE_SCRIPT="$tmp/materializer.sh" run next
check "external source keeps the release history and bumps the existing version" '[ "$rc" = 0 ] && [ "$(first)" = 0.4.0 ]'
FAIL_SOURCE=1 PACKAGE_MANIFEST="$tmp/source-manifest.json" PACKAGE_SOURCE_SCRIPT="$tmp/materializer.sh" run next
check "external source failure is loud and cannot produce a release plan" '[ "$rc" = 1 ] && grep -q "package source at .* failed" <<<"$err"'
EMPTY_SOURCE_INPUTS=1 PACKAGE_MANIFEST="$tmp/source-manifest.json" PACKAGE_SOURCE_SCRIPT="$tmp/materializer.sh" run next
check "external source with no inputs fails loudly" '[ "$rc" = 1 ] && grep -q "package source has no inputs" <<<"$err"'


# The workflow: a shared repo's required check is "release / plan", so the reusable workflow's first job is plan.
wf="$here/../../workflows/package-release.yml"
check "package-release.yml has the jobs plan and publish, named so" 'grep -qx "  plan:" "$wf" && grep -qx "    name: plan" "$wf" && grep -qx "  publish:" "$wf" && grep -qx "    name: publish" "$wf"'
check "package-release.yml: a pull request plans against its own base branch" 'grep -qF "format('"'"'origin/{0}'"'"', github.base_ref)" "$wf"'
check "package-release.yml: plan reads no registry, so it asks for no packages permission" '[ "$(grep -cE "^ +packages:" "$wf")" = 1 ] && grep -qx "      packages: write" "$wf"'

run usage-verb
check "an unknown verb: exit 2" '[ "$rc" = 2 ]'

echo "selftest: $pass passed, $fail failed"
[ "$fail" = 0 ]
