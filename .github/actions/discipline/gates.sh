#!/usr/bin/env bash
# gates.sh — Discipline gates for digio-nz/.github .github/actions/discipline/.
# Each composite action runs one verb. Product repos call the workflow at @main.
#
# A gate lives in a script rather than in workflow YAML because inline YAML
# cannot be run or tested anywhere but a live PR, and a gate only counts as
# executable when it is anchored to something that RUNS.
# `.github/actions/discipline/gates-selftest.sh` proves EVERY gate below in
# BOTH directions, and `.github/workflows/discipline.yml` runs that selftest
# before the gates judge anything: a gate that has stopped detecting its own
# violations then fails loudly instead of passing every PR silently. A gate
# added here is not proven by this sentence until it has cases there.
#
# Nothing in this file names a repo, a directory or a convention that is one
# repo's.
#
#   append-only <base> <head> [pr-body-file]
#     A diff does not rewrite an applied drizzle migration: an existing
#     `drizzle/*.sql` or `drizzle/meta/*_snapshot.json` is never modified,
#     deleted or renamed, and `drizzle/meta/_journal.json` may only gain
#     entries at the end (every base entry unchanged, same order). The same
#     holds for a `drizzle/` tree below the root (digio-invoices keeps one at
#     `lib/db/drizzle/`). A renumbered or reissued migration once left a
#     database ledger the tree no longer matched. New migrations, snapshots
#     and entries stay legal; a repo with no `drizzle/` is unaffected.
#
#     The waiver: a PR body line `append-only: licensed — <reason>` (a plain
#     hyphen works too; the rule is the reason, not the typography) permits
#     the change for that one PR, deletions included, so a genuine one-off
#     repair stays possible with a stated reason. The reason names WHO
#     licensed it.
#
#   pr-sections <body-file> [author] [branch]
#     The PR body has text under `## Why` and `## Decisions`. Template comments do not count.
#   pr-title <title>
#     The PR title matches the conventional-commit shape the fleet's merged
#     history uses (`type(scope): description` or `type: description`,
#     lowercase type, non-empty description). A `P<n>` or `#<n>` prefix is
#     refused. SHAPE only, never an enumerated type vocabulary a legitimate
#     new type (`revert`, `style`, ...) could fall outside of.
#
# Dependabot exemptions on pr-title share `is_exempt_pr`, which recognises
# one provenance:
#   - a head branch starting `dependabot/` AND a PR author login of
#     `dependabot[bot]` is a dependency-bump PR. BOTH conditions are
#     required — a human-authored branch merely named `dependabot/...` is
#     not exempt — because the branch name alone is attacker- or
#     author-controlled and proves nothing on its own.
#
#   exempt-pr <branch> [author]
#     Exit 0 when `is_exempt_pr` (below) says the PR is exempt, 1 when not.
#     Not a gate: the one provenance predicate, for trusted callers outside
#     this file (route-label preparation, review-gate.yml) so none of them
#     re-derives it.
#
#   pr-labels-apply <owner/name> <n>
#     `pr-labeller apply` for the PR. Not a gate: it writes the labels.
#
#   no-hand-version <base> <head>
#     The diff changes no `"version"` in a package.json and no CHANGELOG.md.
#     A package.json that is new in the diff may add one `"version": "0.0.0"`
#     line, because `release.sh check` requires that committed version.
#
#   migrations <base> <head>
#     Each new drizzle migration has a 14-digit timestamp prefix, and the diff
#     changes no migration that is on the base. A migration moved unchanged,
#     with the same file name, into another drizzle/ folder is not new.
#
#   no-secret <base> <head>
#     no-secret/secret-guard.sh passes on each commit in the range.
#
#   actionlint [dir]
#     actionlint passes on each workflow file in the dir, .github/workflows by
#     default. With no actionlint on PATH, it runs actionlint-install first.
#
#   actionlint-install <dir>
#     Installs the latest actionlint release into the dir and checks it
#     against the release's checksums file. When the latest tag cannot be
#     read, it exits 3. A checksum mismatch exits 3.
#
# The gates that judge the PR's CONTENT rather than its provenance — pr-title,
# append-only, plus the actionlint and selftest steps in discipline.yml —
# keep running on a Dependabot PR, which can still get those wrong.
#
# Exit: 0 pass · 1 violation · 3 could not determine (always failing, never a
# silent pass — an unreadable diff is the case where skipping is dangerous).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

die3() { echo "::error::$*" >&2; exit 3; }

# One provenance is exempt from pr-title shape:
# a genuine Dependabot PR (head branch starting `dependabot/` AND author login
# `dependabot[bot]` — BOTH required, so a human branch merely named
# `dependabot/...` still fails). pr-title exempts through this one predicate
# rather than re-deriving the check; a gate whose content that PR could still
# get wrong (actionlint, append-only) keeps running on it.
is_exempt_pr() {
  local branch="${1:-}" author="${2:-}"
  case "$branch" in
    dependabot/*) [ "$author" = "dependabot[bot]" ] ;;
    *) return 1 ;;
  esac
}

# The message a caller prints once is_exempt_pr has already said yes.
exempt_pr_reason() {
  echo "Dependabot PR, exempt by design."
}

cmd="${1:-}"; shift || true

case "$cmd" in
  append-only)
    BASE="${1:-}"; HEAD="${2:-}"; BODY="${3:-}"
    if [ -n "$BASE" ] && [ -n "$HEAD" ]; then
      :
    else
      die3 "usage: discipline-gates.sh append-only <base> <head> [pr-body-file]"
    fi

    # The waiver: a licensed one-PR exception, declared in the PR body with a
    # reason. An em dash OR a plain hyphen.
    licensed=false
    if [ -n "$BODY" ] && [ -f "$BODY" ] \
      && grep -qE '^[[:space:]]*append-only:[[:space:]]*licensed[[:space:]]*[—-][[:space:]]*\S' "$BODY"; then
      licensed=true
    fi
    # --no-renames deliberately: a renamed migration must appear under its OLD
    # path, or "renamed away" becomes the way to edit one.
    status="$(git diff --name-status --no-renames "$BASE...$HEAD" 2>/dev/null)" \
      || die3 "could not diff $BASE...$HEAD — failing closed rather than passing"

    violations=""
    note() { violations="$violations
  - $1"; }

    while IFS=$'\t' read -r st f rest; do
      [ -n "${f:-}" ] || continue
      case "$st" in
        A*) continue ;;   # ADDING a record is always legal — that is how the log grows
      esac

      case "$f" in
        # Applied drizzle migrations: a migration file or snapshot that exists
        # at the base may be applied somewhere, so it is never modified,
        # deleted or renamed (--no-renames shows a rename as delete + add).
        drizzle/*.sql|*/drizzle/*.sql|drizzle/meta/*_snapshot.json|*/drizzle/meta/*_snapshot.json)
          if [ "$licensed" = true ]; then
            echo "::warning::$f — applied migration changed under the PR's declared append-only license."
            continue
          fi
          note "$f — an applied migration is never rewritten; add a new migration instead."
          ;;

        # The journal may only grow: every entry at the base must be unchanged
        # at the head, in the same order.
        drizzle/meta/_journal.json|*/drizzle/meta/_journal.json)
          why=""
          case "$st" in
            D*) why="DELETED" ;;
            *)
              # `-e` so a false comparison, a jq error and unreadable JSON all
              # read as a violation rather than a pass.
              if ! jq -e -n --slurpfile b <(git show "$BASE:$f" 2>/dev/null) \
                            --slurpfile h <(git show "$HEAD:$f" 2>/dev/null) \
                   '($b[0].entries) as $x | ($h[0].entries[:($x | length)]) == $x' >/dev/null 2>&1; then
                why="an applied entry was changed, removed or reordered"
              fi
              ;;
          esac
          [ -n "$why" ] || continue
          if [ "$licensed" = true ]; then
            echo "::warning::$f — journal changed ($why) under the PR's declared append-only license."
            continue
          fi
          note "$f — $why. An applied migration is never rewritten; add a new migration instead."
          ;;
      esac
    done <<EOF
$status
EOF

    if [ -z "$violations" ]; then
      echo "append-only: no append-only record was modified. OK."
      exit 0
    fi
    echo "::error::this diff MODIFIES append-only records:$violations" >&2
    exit 1
    ;;

  pr-title)
    TITLE="${1:-}"; AUTHOR="${2:-}"; BRANCH="${3:-}"
    [ -n "$TITLE" ] || die3 "usage: gates.sh pr-title <title> [author] [branch]"
    if is_exempt_pr "${BRANCH:-}" "${AUTHOR:-}"; then
      echo "pr-title: $(exempt_pr_reason "${BRANCH:-}") OK."; exit 0
    fi
    title_re='^[a-z]+(\([a-zA-Z0-9._/-]+\))?!?: .+'
    if [[ "$TITLE" =~ $title_re ]]; then
      echo "pr-title: \"$TITLE\" matches the conventional-commit shape. OK."
      exit 0
    fi
    echo "::error::pr-title: \"$TITLE\" does not match \`type(scope): description\` or \`type: description\` (lowercase type, optional !, space after the colon). A P<n> or #<n> prefix is not allowed." >&2
    exit 1
    ;;

  pr-sections)
    BODY_FILE="${1:-}"; AUTHOR="${2:-}"; BRANCH="${3:-}"
    [ -f "$BODY_FILE" ] || die3 "usage: gates.sh pr-sections <body-file> [author] [branch]"
    if is_exempt_pr "${BRANCH:-}" "${AUTHOR:-}"; then
      echo "pr-sections: $(exempt_pr_reason "${BRANCH:-}") OK."; exit 0
    fi
    missing="$(python3 - "$BODY_FILE" <<'PY'
import re, sys
body = open(sys.argv[1], encoding="utf-8").read().replace("\r\n", "\n")
body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
parts = re.split(r"(?m)^## +(.+?)[ \t]*$", body)
sections = dict(zip(parts[1::2], parts[2::2]))
print(" ".join(s for s in ("Why", "Decisions") if not sections.get(s, "").strip()))
PY
)" || die3 "pr-sections: could not read $BODY_FILE"
    if [ -z "$missing" ]; then
      echo "pr-sections: Why and Decisions both have text. OK."
      exit 0
    fi
    echo "::error::pr-sections: the PR body needs text under these headings: $missing"
    exit 1
    ;;

  exempt-pr)
    [ -n "${1:-}" ] || die3 "usage: discipline-gates.sh exempt-pr <branch> [author]"
    if is_exempt_pr "$1" "${2:-}"; then
      echo "exempt-pr: $(exempt_pr_reason "$1")"; exit 0
    fi
    echo "exempt-pr: '$1' by '${2:-}' is not exempt."
    exit 1
    ;;

  no-hand-version)
    BASE="${1:-}"; HEAD="${2:-}"
    [ -n "$BASE" ] && [ -n "$HEAD" ] || die3 "usage: gates.sh no-hand-version <base> <head>"
    changed="$(git diff --name-only "$BASE...$HEAD" 2>/dev/null)" \
      || die3 "could not diff $BASE...$HEAD — failing closed rather than passing"
    if grep -qx 'CHANGELOG.md' <<<"$changed"; then
      echo "::error::no-hand-version: CHANGELOG.md changed. Version and changelog files are generated." >&2
      exit 1
    fi
    manifests="$(git diff --name-only --diff-filter=d "$BASE...$HEAD" 2>/dev/null)" \
      || die3 "could not list surviving manifests for $BASE...$HEAD"
    added="$(git diff --name-only --no-renames --diff-filter=A "$BASE...$HEAD" 2>/dev/null)" \
      || die3 "could not list added files for $BASE...$HEAD"
    initial_re='^\+[[:space:]]*"version"[[:space:]]*:[[:space:]]*"0\.0\.0"[[:space:]]*,?[[:space:]]*$'
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        package.json|*/package.json) ;;
        *) continue ;;
      esac
      diff="$(git diff -U0 "$BASE...$HEAD" -- "$f" 2>/dev/null)" \
        || die3 "could not diff $f in $BASE...$HEAD — failing closed rather than passing"
      initial_allowed=false
      grep -qxF -- "$f" <<<"$added" && initial_allowed=true
      while IFS= read -r line; do
        [[ "$line" =~ ^[+-].*\"version\"[[:space:]]*: ]] || continue
        if [ "$initial_allowed" = true ] && [[ "$line" =~ $initial_re ]]; then
          initial_allowed=false
          continue
        fi
        echo "::error::no-hand-version: $f changes a \"version\" field: ${line}. Version files are generated." >&2
        exit 1
      done <<<"$diff"
    done <<<"$manifests"
    echo "no-hand-version: no hand-edited version or changelog. OK."
    exit 0
    ;;

  migrations)
    BASE="${1:-}"; HEAD="${2:-}"
    [ -n "$BASE" ] && [ -n "$HEAD" ] || die3 "usage: gates.sh migrations <base> <head>"
    # 100% so that only an unchanged file pairs as a rename; an edited one
    # shows as a delete and an add.
    status="$(git diff --name-status --find-renames=100% "$BASE...$HEAD" 2>/dev/null)" \
      || die3 "could not diff $BASE...$HEAD — failing closed rather than passing"
    violations=""
    note() { violations="$violations
  - $1"; }
    is_migration() {
      # Michelin's SQL samples are test inputs, not applied database records.
      case "${GITHUB_REPOSITORY:-}:$1" in
        digio-nz/digio-michelin:*/assets/fixture/drizzle/*.sql) return 1 ;;
      esac
      case "$1" in
        drizzle/*.sql|*/drizzle/*.sql) return 0 ;;
      esac
      return 1
    }
    check_new() {
      local ts_re='^[0-9]{14}_'
      if [[ ! "$(basename "$1")" =~ $ts_re ]]; then
        note "$1 — a new migration needs a 14-digit timestamp prefix"
      fi
    }
    while IFS=$'\t' read -r st f to; do
      [ -n "${f:-}" ] || continue
      case "$st" in
        R*)
          if is_migration "$f"; then
            if is_migration "$to" && [ "$(basename "$f")" = "$(basename "$to")" ]; then
              continue
            fi
            note "$f — a migration that is on the base is never renamed or moved out of a drizzle/ folder (to $to)"
          elif is_migration "$to"; then
            check_new "$to"
          fi
          ;;
        A*)
          is_migration "$f" && check_new "$f"
          ;;
        *)
          is_migration "$f" && note "$f — a migration that is on the base is never rewritten"
          ;;
      esac
    done <<EOF
$status
EOF
    if [ -n "$violations" ]; then
      echo "::error::migrations:$violations" >&2
      exit 1
    fi
    echo "migrations: new files use a 14-digit timestamp prefix and no base migration changed. OK."
    exit 0
    ;;

  no-secret)
    BASE="${1:-}"; HEAD="${2:-}"
    [ -n "$BASE" ] && [ -n "$HEAD" ] || die3 "usage: gates.sh no-secret <base> <head>"
    guard="$HERE/no-secret/secret-guard.sh"
    [ -f "$guard" ] || die3 "no secret-guard.sh at $guard"
    commits="$(git rev-list "$BASE..$HEAD" 2>/dev/null)" \
      || die3 "could not list $BASE..$HEAD — failing closed rather than passing"
    while IFS= read -r commit; do
      [ -n "$commit" ] || continue
      parent="$(git rev-parse "${commit}^" 2>/dev/null || true)"
      [ -n "$parent" ] || parent="$(git hash-object -t tree /dev/null)"
      status=0
      out="$(printf 'refs/heads/head %s refs/heads/base %s\n' "$commit" "$parent" | sh "$guard" origin unused 2>&1)" || status=$?
      if [ "$status" -eq 1 ]; then
        echo "::error::no-secret: commit $commit adds a credential-shaped value." >&2
        printf '%s\n' "$out" >&2
        exit 1
      fi
      if [ "$status" -ne 0 ]; then
        echo "::error::no-secret: secret-guard exited $status on commit $commit." >&2
        printf '%s\n' "$out" >&2
        exit 1
      fi
    done <<<"$commits"
    echo "no-secret: no commit in the range adds a credential-shaped value. OK."
    exit 0
    ;;

  actionlint-install)
    DEST="${1:-}"
    [ -n "$DEST" ] || die3 "usage: gates.sh actionlint-install <dir>"
    mkdir -p "$DEST" || die3 "actionlint: cannot make $DEST"
    case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) die3 "actionlint: no release for $(uname -s)" ;; esac
    case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die3 "actionlint: no release for $(uname -m)" ;; esac
    token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    curl_auth=()
    [ -n "$token" ] && curl_auth=(-H "Authorization: Bearer $token" -H "X-GitHub-Api-Version: 2022-11-28")
    tag="$(curl -fsSL "${curl_auth[@]}" https://api.github.com/repos/rhysd/actionlint/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)" || true
    [ -n "$tag" ] || die3 "actionlint: cannot read the latest release"
    asset="actionlint_${tag#v}_${os}_${arch}.tar.gz"
    sums="actionlint_${tag#v}_checksums.txt"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    if ! curl -fsSL -o "$tmp/$asset" "https://github.com/rhysd/actionlint/releases/download/$tag/$asset" \
      || ! curl -fsSL -o "$tmp/$sums" "https://github.com/rhysd/actionlint/releases/download/$tag/$sums"; then
      die3 "actionlint: cannot download $tag"
    fi
    want="$(awk -v a="$asset" '$2 == a { print $1 }' "$tmp/$sums")"
    if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$tmp/$asset")"; else got="$(shasum -a 256 "$tmp/$asset")"; fi
    got="${got%% *}"
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
      die3 "actionlint: $asset does not match the checksums file of $tag"
    fi
    tar -xzf "$tmp/$asset" -C "$DEST" actionlint || die3 "actionlint: cannot unpack $asset"
    echo "actionlint: installed $tag, checksum verified."
    exit 0
    ;;

  actionlint)
    DIR="${1:-.github/workflows}"
    bin="$(command -v actionlint || true)"
    if [ -z "$bin" ]; then
      cache="${RUNNER_TEMP:-/tmp}/actionlint"
      bash "$HERE/gates.sh" actionlint-install "$cache" || exit
      bin="$cache/actionlint"
    fi
    files=()
    if [ -d "$DIR" ]; then
      while IFS= read -r -d '' file; do
        files+=("$file")
      done < <(find "$DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
    fi
    if [ "${#files[@]}" -eq 0 ]; then
      echo "actionlint: no workflow files in $DIR. OK."
      exit 0
    fi
    if ! "$bin" -color=false "${files[@]}"; then
      echo "::error::actionlint: a workflow has a syntax fault." >&2
      exit 1
    fi
    echo "actionlint: workflows parse. OK."
    exit 0
    ;;

  pr-labels-apply)
    REPO="${1:-}"; NUMBER="${2:-}"
    [ -n "$REPO" ] && [ -n "$NUMBER" ] || die3 "usage: gates.sh pr-labels-apply <owner/name> <n>"
    label_args=(apply --repo "$REPO" --pr "$NUMBER")
    if [ -n "${3:-}" ] && [ -n "${4:-}" ]; then label_args+=(--base "$3" --head "$4"); fi
    node --experimental-strip-types "${DIGIO_SKILLS_ROOT:-$HOME/.digio/skills}/archive/pr-labeller/scripts/pr-labeller.ts" "${label_args[@]}"
    ;;

  *) die3 "usage: gates.sh [append-only|pr-sections|pr-title|pr-labels-apply|exempt-pr|no-hand-version|migrations|no-secret|actionlint|actionlint-install] ..." ;;
esac
