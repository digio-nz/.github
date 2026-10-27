#!/usr/bin/env bash
# release.sh: release a shared npm package of digio-nz from its own repo, on each merge to main (briefs/versioning.md).
#
#   release.sh check                                name each fault in ./package.json
#   release.sh next [--title <t>] [--base <ref>]    print the next version and each title that decided it,
#                                                   or "unchanged since v<version>"
#   release.sh publish                              tag, publish and write the GitHub Release of the next version
#   release.sh test                                 run release-selftest.sh beside this file
#
# It reads package.json in the current folder and the repo from GITHUB_REPOSITORY (owner/name). The folder can be a
# subfolder of the repo, such as digio-skills' package folder. It needs git, node and npm; publish also needs gh,
# with NODE_AUTH_TOKEN for the registry and GH_TOKEN for the Release.
# The composite action beside it (action.yml) runs it, and .github/workflows/package-release.yml runs the action.
#
# A root package uses v<version>. A package in a subfolder uses <package>-v<version>, where <package> is its unscoped
# npm name. The last release is the highest tag in that namespace that HEAD contains. The bump comes from the titles of the
# first-parent commits after that tag, up to <ref> (default HEAD), that change a package input: package.json, a README,
# a LICENSE, main, or a files entry. The --title counts when the diff from <ref> to HEAD changes a package input.
# A package with a build script counts every file in its folder as an input, because the files it ships are built
# from them; each pack of such a tree runs npm install, then the build script, before npm pack.
# A merge-commit title is the PR title. The same titles make the GitHub Release body.
#   A leading plan ref (P<n>, P<n>.<m> or #<n>, then a space) is ignored before the title is classified.
#   Before 1.0.0: a title with ! before its colon, or a feat title, bumps the minor. Any other title bumps the patch.
#   From 1.0.0: ! bumps the major; else feat bumps the minor; else patch.
#   No verb makes 1.0.0: that is a deliberate choice. With no tag, the next version is 0.1.0.
# "unchanged": npm pack of the tree at the last tag and of the tree at HEAD, each with the last version, unpack to the
# same files. Then next prints "unchanged since <tag>", and publish publishes nothing and exits 0.
#
# publish is safe to run again after a failure at any step:
#   1. If the last tag has no package version on the registry, publish that version from the tagged tree.
#      If the last tag has no GitHub Release, write the Release.
#   2. Work out the next version. If it is unchanged, stop with exit 0.
#   3. Push the package's tag on HEAD. If the push fails, exit 1 and publish nothing.
#   4. Publish the tree at HEAD with the version written in, then write the GitHub Release.
# A run that fails at step 4 leaves the tag, and step 1 of the next run publishes it. A tag never moves.
# Each publish packs a copy of the tree from git, so the working copy stays at "version": "0.0.0" and nothing is committed.
# npm view decides that a version is absent only on E404. Any other error exits 1 and names the error.
#
# Exit 0 ok, 1 a fault or an error (one line each on stderr), 2 usage.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCOPE="@digio-nz"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "release: $*" >&2; exit 1; }

# pkg <field> <file>: print a field of the package.json: name, version, private (true or false), files (the count of
# entries, or "none" when it is not a non-empty list), repository (the URL, from the string or the object form) or
# inputs (the paths that npm can pack, one each line: each files entry that is not a negation, and main).
# pkg set <file> <version>: write the version into the package.json.
# shellcheck disable=SC2016
pkg_js='const fs = require("fs");
const [field, file, value] = process.argv.slice(1);
const p = JSON.parse(fs.readFileSync(file, "utf8"));
if (field === "set") { p.version = value; fs.writeFileSync(file, JSON.stringify(p, null, 2) + "\n"); process.exit(0); }
const r = p.repository;
const out = {
  name: p.name, version: p.version, private: p.private === true,
  files: Array.isArray(p.files) && p.files.length > 0 ? p.files.length : "none",
  build: p.scripts && typeof p.scripts.build === "string" ? "yes" : "no",
  repository: typeof r === "string" ? r : r && r.url,
  inputs: [...(Array.isArray(p.files) ? p.files : []), ...(typeof p.main === "string" ? [p.main] : [])]
    .filter((f) => typeof f === "string" && f !== "" && !f.startsWith("!"))
    .map((f) => f.replace(/^\.\//, "").replace(/\/+$/, "")).join("\n"),
}[field];
process.stdout.write(out === undefined || out === null ? "" : String(out));'
pkg() { node -e "$pkg_js" "$@"; }

# repo_of <url>: the owner/name of a GitHub repository URL in any of npm's forms, in lower case.
repo_of() {
  local u
  u="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  u="${u#git+}"; u="${u#https://}"; u="${u#http://}"; u="${u#ssh://}"; u="${u#git://}"
  u="${u#git@}"; u="${u#github:}"; u="${u#github.com/}"; u="${u#github.com:}"
  u="${u%/}"; u="${u%.git}"
  printf '%s' "$u"
}

need_repo() { [ -n "${GITHUB_REPOSITORY:-}" ] || die "GITHUB_REPOSITORY is not set; it names the repo as owner/name"; }
# An external package source supplies inputs and tree verbs; its assembled manifest stays outside the checkout.
PACKAGE_MANIFEST="${PACKAGE_MANIFEST:-package.json}"
need_pkg() { [ -f "$PACKAGE_MANIFEST" ] || die "no package.json in $(pwd)"; }

# check: print each fault of ./package.json on stderr; exit 1 when there is one.
check() {
  need_pkg; need_repo
  local name version url faults=0
  name="$(pkg name "$PACKAGE_MANIFEST")"
  version="$(pkg version "$PACKAGE_MANIFEST")"
  url="$(pkg repository "$PACKAGE_MANIFEST")"
  fault() { echo "fault: $*" >&2; faults=$((faults + 1)); }
  case "$name" in "$SCOPE"/?*) ;; *) fault "name '$name' is outside the $SCOPE scope" ;; esac
  [ "$(pkg private "$PACKAGE_MANIFEST")" = false ] || fault '"private": true stops npm publish; remove private'
  [ "$(pkg files "$PACKAGE_MANIFEST")" != none ] || fault 'no files list: files names the folders that the tarball holds'
  if [ -z "$url" ]; then
    fault "no repository URL; it must be https://github.com/$GITHUB_REPOSITORY"
  elif [ "$(repo_of "$url")" != "$(repo_of "$GITHUB_REPOSITORY")" ]; then
    fault "repository URL $url is another repo than https://github.com/$GITHUB_REPOSITORY"
  fi
  [ "$version" = 0.0.0 ] || fault "version is '$version'; the committed version is 0.0.0, and the release writes the real one"
  [ "$faults" = 0 ] || return 1
  echo "ok: $name"
}

# semver_tags <ref>: the tags in this package's namespace that <ref> contains, highest first.
semver_tags() {
  local tag version
  if [ -n "${1:-}" ]; then git tag --merged "$1" --list "$TAG_PREFIX*" --sort=-v:refname
  else git tag --list "$TAG_PREFIX*" --sort=-v:refname; fi |
    while IFS= read -r tag; do
      version="${tag#"$TAG_PREFIX"}"
      [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$tag"
    done
}
last_tag() { semver_tags "$1" | awk 'NR == 1'; }
version_of_tag() { printf '%s' "${1#"$TAG_PREFIX"}"; }
tag_for() { printf '%s%s' "$TAG_PREFIX" "$1"; }
# tag_before <tag>: the highest semver tag that <tag> contains, other than itself.
tag_before() { semver_tags "$1" | awk -v t="$1" '$0 != t' | awk 'NR == 1'; }

# inputs: set INPUTS to the pathspecs of the files that npm can pack from this folder: package.json, any README and
# LICENSE or LICENCE in any case, and each files entry and main of ./package.json. A merge that changes none of them
# changes no released file, so its title decides nothing. With a build script, every file in the folder is an input.
inputs() {
  local f declared
  if [ -n "${PACKAGE_SOURCE_SCRIPT:-}" ]; then
    declared="$(bash "$PACKAGE_SOURCE_SCRIPT" inputs)" || die "package source inputs failed"
    INPUTS=()
    while IFS= read -r f; do [ -z "$f" ] || INPUTS+=("$f"); done <<<"$declared"
    [ "${#INPUTS[@]}" -gt 0 ] || die "package source has no inputs"
    return
  fi
  if [ "$(pkg build "$PACKAGE_MANIFEST")" = yes ]; then INPUTS=(.); return 0; fi
  INPUTS=(package.json ':(icase)readme*' ':(icase)licen[cs]e*')
  # The last path has no newline after it, so read returns 1 with that path still in f.
  while IFS= read -r f || [ -n "$f" ]; do [ -z "$f" ] || INPUTS+=("$f"); done < <(pkg inputs "$PACKAGE_MANIFEST")
}

# titles <from tag or ""> <ref>: the titles of the first-parent commits after the tag, up to the ref, that change a
# package input, oldest first.
titles() {
  if [ -n "$1" ]; then git log --first-parent --reverse --format=%s "$1..$2" -- "${INPUTS[@]}"
  else git log --first-parent --reverse --format=%s "$2" -- "${INPUTS[@]}"; fi
}

# touches <from> <to>: exit 0 when the diff between the two commits changes a package input.
touches() { ! git diff --quiet "$1" "$2" -- "${INPUTS[@]}"; }

# bump_of <major> <title>: major, minor or patch. A leading plan ref (P<n>, P<n>.<m> or #<n>, then a space) is ignored.
bump_of() {
  local breaking='^[A-Za-z]+(\([^)]*\))?!:' feat='^feat(\([^)]*\))?:' ref='^(P[0-9]+(\.[0-9]+)?|#[0-9]+) +' title="$2"
  [[ "$title" =~ $ref ]] && title="${title:${#BASH_REMATCH[0]}}"
  if [[ "$title" =~ $breaking ]]; then [ "$1" = 0 ] && echo minor || echo major
  elif [[ "$title" =~ $feat ]]; then echo minor
  else echo patch; fi
}

# pack_tree <commit> <version> <dir>: unpack into <dir>/package the npm pack of the package's tree at <commit>,
# with that version written in. <dir>/tree keeps the tree. A tree with a build script is installed and built first.
pack_tree() {
  local archive_path="${PACKAGE_PREFIX%/}" tree="$3/tree"
  mkdir -p "$3/tree" "$3/tgz"
  if [ -n "${PACKAGE_SOURCE_SCRIPT:-}" ]; then
    tree="$3/tree/${PACKAGE_PREFIX%/}"
    bash "$PACKAGE_SOURCE_SCRIPT" tree "$1" "$tree" || die "package source at $1 failed"
  elif [ -n "$PACKAGE_PREFIX" ]; then
    git -C "$REPO_ROOT" archive --format=tar "$1" "$archive_path" | tar -xf - -C "$3/tree" || die "git archive of $1 failed"
    tree="$3/tree/$archive_path"
  else
    git -C "$REPO_ROOT" archive --format=tar "$1" | tar -xf - -C "$3/tree" || die "git archive of $1 failed"
  fi
  [ -f "$tree/package.json" ] || die "the tree at $1 has no ${PACKAGE_PREFIX}package.json"
  pkg set "$tree/package.json" "$2"
  if [ "$(pkg build "$tree/package.json")" = yes ]; then
    (cd "$tree" && npm install --ignore-scripts --no-audit --no-fund --silent && npm run --silent build) \
      || die "the build of the tree at $1 failed"
  fi
  (cd "$tree" && npm pack --ignore-scripts --silent --pack-destination "$3/tgz" >/dev/null) || die "npm pack of the tree at $1 failed"
  tar -xzf "$3/tgz/"*.tgz -C "$3" || die "the npm pack tarball of $1 did not unpack"
}

# plan [--title <t>] [--base <ref>]: set LAST (the last version, or empty), NEXT (empty when unchanged) and write the
# deciding titles, one "<bump>  <title>" line each, to $work/titles.
plan() {
  local title="" base=HEAD tag maj min pat bump t rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) [ $# -ge 2 ] || usage; title="$2"; shift 2 ;;
      --base) [ $# -ge 2 ] || usage; base="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  git rev-parse -q --verify "$base^{commit}" >/dev/null || die "no commit $base"
  tag="$(last_tag HEAD)"
  LAST="$(version_of_tag "$tag")"; NEXT=""
  : > "$work/titles"
  if [ -z "$tag" ]; then NEXT=0.1.0; return 0; fi
  rc=0
  pack_tree "$tag" "$LAST" "$work/at-tag"
  pack_tree HEAD "$LAST" "$work/at-head"
  diff -r "$work/at-tag/package" "$work/at-head/package" >/dev/null || rc=$?
  [ "$rc" -le 1 ] || die "diff of the two packs failed"
  [ "$rc" = 1 ] || return 0
  # A pull request's own title counts only when the pull request changes a package input.
  if [ -n "$title" ] && ! touches "$base" HEAD; then title=""; fi
  IFS=. read -r maj min pat <<<"$LAST"
  local level=patch
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    bump="$(bump_of "$maj" "$t")"
    printf '%s  %s\n' "$bump" "$t" >> "$work/titles"
    case "$bump" in major) level=major ;; minor) [ "$level" = major ] || level=minor ;; esac
  done < <(titles "$tag" "$base"; [ -z "$title" ] || printf '%s\n' "$title")
  case "$level" in
    major) NEXT="$((maj + 1)).0.0" ;;
    minor) NEXT="$maj.$((min + 1)).0" ;;
    *) NEXT="$maj.$min.$((pat + 1))" ;;
  esac
}

# show_plan: print the plan as next prints it.
show_plan() {
  if [ -z "$NEXT" ]; then echo "unchanged since $(tag_for "$LAST")"
  elif [ -z "$LAST" ]; then echo "$NEXT"; echo "  first release: HEAD contains no ${TAG_PREFIX}<major>.<minor>.<patch> tag"
  elif [ ! -s "$work/titles" ]; then echo "$NEXT"; echo "  from $(tag_for "$LAST"): the package changed, and no title changed a package input, so a patch"
  else echo "$NEXT"; echo "  from $(tag_for "$LAST"), by the titles that changed the package:"; sed 's/^/  /' "$work/titles"; fi
}

# registry_has <name> <version>: print yes or no. Only E404 means no; any other error exits 1 and names it.
registry_has() {
  local out rc=0 code
  out="$(npm view "$1@$2" version 2>"$work/npm-view.err")" || rc=$?
  if [ "$rc" = 0 ]; then
    [ "$out" = "$2" ] || die "npm view $1@$2 printed '$out', not $2"
    echo yes; return 0
  fi
  code="$(sed -n 's/.*code \(E[0-9A-Z]*\).*/\1/p' "$work/npm-view.err" | awk 'NR == 1')"
  [ "$code" = E404 ] && { echo no; return 0; }
  die "npm view $1@$2 failed with ${code:-no error code}: $(awk 'NF { print; exit }' "$work/npm-view.err")"
}

# has_release <tag>: exit 0 when the GitHub Release exists, 1 when gh says it is not found; any other error exits 1.
has_release() {
  local rc=0
  gh release view "$1" --repo "$GITHUB_REPOSITORY" --json tagName >/dev/null 2>"$work/gh-view.err" || rc=$?
  [ "$rc" = 0 ] && return 0
  grep -qi 'release not found' "$work/gh-view.err" && return 1
  die "gh release view $1 failed: $(awk 'NF { print; exit }' "$work/gh-view.err")"
}

# write_release <tag>: write the GitHub Release of the tag, its body the titles since the tag before it.
write_release() {
  local before
  before="$(tag_before "$1")"
  titles "$before" "$1" | sed 's/^/- /' > "$work/notes-$1.md"
  gh release create "$1" --repo "$GITHUB_REPOSITORY" --verify-tag --title "$1" --notes-file "$work/notes-$1.md" >/dev/null \
    || die "gh release create $1 failed"
  echo "released: $1"
}

# publish_tree <commit> <version>: npm publish the package's tree at <commit>, with the version written in.
publish_tree() {
  local dir="$work/publish-$2" tree
  pack_tree "$1" "$2" "$dir"
  tree="$dir/tree"
  [ -z "$PACKAGE_PREFIX" ] || tree="$tree/${PACKAGE_PREFIX%/}"
  (cd "$tree" && npm publish --ignore-scripts) || die "npm publish of $NAME@$2 failed"
  echo "published: $NAME@$2"
}

publish() {
  check >/dev/null
  local highest have last_tag_name next_tag
  highest="$(semver_tags "" | awk 'NR == 1')"
  # 1. Finish the last release, if a run before failed part way.
  plan
  last_tag_name="$(tag_for "$LAST")"
  if [ -n "$highest" ] && [ "$highest" != "$last_tag_name" ]; then
    die "the tag $highest is not in HEAD, whose last tag is ${LAST:+$last_tag_name}${LAST:-none}: HEAD is behind the release line, so nothing is published"
  fi
  if [ -n "$LAST" ]; then
    have="$(registry_has "$NAME" "$LAST")"
    [ "$have" = yes ] || publish_tree "$last_tag_name" "$LAST"
    has_release "$last_tag_name" || write_release "$last_tag_name"
  fi
  # 2. The next version.
  if [ -z "$NEXT" ]; then show_plan; return 0; fi
  show_plan
  # 3. The tag. It goes first, so a failed push publishes nothing.
  next_tag="$(tag_for "$NEXT")"
  git tag "$next_tag" HEAD || die "the tag $next_tag exists here already"
  if ! git push origin "refs/tags/$next_tag"; then
    git tag -d "$next_tag" >/dev/null
    die "the push of the tag $next_tag failed; nothing published"
  fi
  echo "tagged: $next_tag on $(git rev-parse --short HEAD)"
  # 4. The package, then the Release.
  publish_tree "$next_tag" "$NEXT"
  write_release "$next_tag"
}

[ $# -ge 1 ] || usage
verb="$1"; shift
case "$verb" in
  test) [ $# = 0 ] || usage; exec bash "$here/release-selftest.sh" ;;
  check) [ $# = 0 ] || usage; check; exit 0 ;;
  next|publish) ;;
  *) usage ;;
esac
git rev-parse --git-dir >/dev/null 2>&1 || die "$(pwd) is not in a git repository"
need_pkg
NAME="$(pkg name "$PACKAGE_MANIFEST")"
PACKAGE_PREFIX="$(git rev-parse --show-prefix)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
if [ -n "$PACKAGE_PREFIX" ]; then TAG_PREFIX="${NAME##*/}-v"; else TAG_PREFIX=v; fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
case "$verb" in
  next) inputs; plan "$@"; show_plan ;;
  publish) [ $# = 0 ] || usage; need_repo; inputs; publish ;;
esac
