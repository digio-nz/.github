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
# repo's. What varies per repo — which directories are user-facing, and where
# its user docs live — is passed in by the workflow from Actions variables.
#
#   user-docs <base> <head> <pr-body-file> <docs-dir> [ui-dir...]
#     A diff touching the UI dirs either touches the user-docs dir, or the PR
#     body declares `user-docs: none — <reason>`. An empty docs dir or no UI
#     dir warns that the repo does not set DISCIPLINE_DOCS_DIR or
#     DISCIPLINE_UI_DIRS. The one UI dir `none` passes: the repo has no UI. The same-PR docs rule was
#     designed as an executable edge and shipped as optional prose in a
#     "delete the rest" block — an opinion nothing runs, which is exactly what
#     a gate must not be. The declaration is the fail-closed-but-cheap shape:
#     deviation stays legal and stays LEGIBLE.
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
#     The waiver, same shape as user-docs: a PR body line
#     `append-only: licensed — <reason>` (a plain hyphen works too; the rule
#     is the reason, not the typography) permits the change for that one PR,
#     deletions included, so a genuine one-off repair stays possible with a
#     stated reason. The reason names WHO licensed it.
#
#   pr-title <title>
#     The PR title matches the conventional-commit shape the fleet's merged
#     history uses (`type(scope): description` or `type: description`,
#     lowercase type, non-empty description). A `P<n>` or `#<n>` prefix is
#     refused. SHAPE only, never an enumerated type vocabulary a legitimate
#     new type (`revert`, `style`, ...) could fall outside of.
#
#   closing-keyword <pr-body-file> <branch> [author]
#     The body, outside HTML comments, has a closing keyword (`Closes #<n>`,
#     `Fixes`, `Resolves`, or the cross-repo `owner/name#<n>` form). Or the
#     title is a `chore` title and the body has the line `No issue: <reason>`.
#     `is_exempt_pr` exempts a genuine Dependabot PR (see below).
#
# closing-keyword (and Dependabot exemptions on pr-title) share
# `is_exempt_pr`, which recognises one provenance:
#   - a head branch starting `dependabot/` AND a PR author login of
#     `dependabot[bot]` is a dependency-bump PR with no issue to carry a
#     keyword. BOTH conditions are required — a human-authored
#     branch merely named `dependabot/...` is not exempt — because the
#     branch name alone is attacker- or author-controlled and proves nothing
#     on its own.
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
#
#   migrations <base> <head>
#     Each new drizzle migration has a 14-digit timestamp prefix, and the diff
#     changes no migration that is on the base.
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
# append-only, user-docs, plus the actionlint and selftest steps in
# discipline.yml — keep running on a Dependabot PR, which can still get those
# wrong.
#
# user-docs warns and passes: each finding is a `::warning::` annotation and a
# line in the job summary, and the gate exits 0.
#
# Exit: 0 pass · 1 violation · 3 could not determine (always failing, never a
# silent pass — an unreadable diff is the case where skipping is dangerous).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

die3() { echo "::error::$*" >&2; exit 3; }

warn_pass() {
  local gate="$1" finding="$2"
  echo "::warning title=${gate}::${finding}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- '- %s: %s\n' "$gate" "$finding" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
}

# One provenance has no work item to carry a closing keyword:
# a genuine Dependabot PR (head branch starting `dependabot/` AND author login
# `dependabot[bot]` — BOTH required, so a human branch merely named
# `dependabot/...` still fails). closing-keyword exempts through this one
# predicate rather than re-deriving the check; a gate whose content that PR
# could still get wrong (pr-title, actionlint, append-only, user-docs) keeps
# running on it.
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
  user-docs)
    [ "$#" -ge 4 ] || die3 "usage: gates.sh user-docs <base> <head> <pr-body-file> <docs-dir> [ui-dir...]"
    BASE="$1"; HEAD="$2"; BODY="$3"; DOCS="$4"; shift 4
    [ -n "$BASE" ] && [ -n "$HEAD" ] || die3 "usage: gates.sh user-docs <base> <head> <pr-body-file> <docs-dir> [ui-dir...]"
    if [ "$*" = none ]; then echo "user-docs: DISCIPLINE_UI_DIRS is none, so the repo has no UI dirs. OK."; exit 0; fi
    missing=()
    [ "$#" -gt 0 ] || missing+=(DISCIPLINE_UI_DIRS)
    [ -n "$DOCS" ] || missing+=(DISCIPLINE_DOCS_DIR)
    if [ "${#missing[@]}" -gt 0 ]; then
      warn_pass user-docs "the repo does not set the Actions variable ${missing[*]}, so this gate cannot check that a UI change ships its docs. Set DISCIPLINE_UI_DIRS and DISCIPLINE_DOCS_DIR, or set DISCIPLINE_UI_DIRS to none."
    fi
    changed="$(git diff --name-only "$BASE...$HEAD" 2>/dev/null)" \
      || die3 "could not diff $BASE...$HEAD — failing closed rather than passing"
    # Here-strings, not `printf | grep -q`: grep -q exits on its first match,
    # and once the list outgrows a pipe buffer printf dies of SIGPIPE and
    # pipefail reports 141 for a match.
    touched_ui=false
    for d in "$@"; do
      grep -q "^${d%/}/" <<<"$changed" && touched_ui=true
    done
    if [ "$touched_ui" != true ]; then echo "user-docs: no UI dirs touched."; exit 0; fi
    if grep -q "^${DOCS%/}/" <<<"$changed"; then
      echo "user-docs: UI and user docs both touched. OK."; exit 0
    fi
    # An em dash OR a plain hyphen: the rule is the reason, not the typography.
    if [ -f "$BODY" ] && grep -qE '^[[:space:]]*user-docs:[[:space:]]*none[[:space:]]*[—-][[:space:]]*\S' "$BODY"; then
      echo "user-docs: UI touched, no docs, and the PR body declares why. OK."; exit 0
    fi
    warn_pass user-docs "this diff touches the UI dirs ($*) but not $DOCS. Update the user docs in this PR, or put a line 'user-docs: none — <reason>' in the PR body."
    ;;

  append-only)
    BASE="${1:-}"; HEAD="${2:-}"; BODY="${3:-}"
    if [ -n "$BASE" ] && [ -n "$HEAD" ]; then
      :
    else
      die3 "usage: discipline-gates.sh append-only <base> <head> [pr-body-file]"
    fi

    # The waiver: a licensed one-PR exception, declared in the PR body with a
    # reason. An em dash OR a plain hyphen, as with user-docs.
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

  closing-keyword)
    BODY="${1:-}"; BRANCH="${2:-}"; AUTHOR="${3:-}"
    if [ -n "$BODY" ] && [ -n "$BRANCH" ]; then
      :
    else
      die3 "usage: discipline-gates.sh closing-keyword <pr-body-file> <branch> [author]"
    fi
    [ -f "$BODY" ] || die3 "no such PR-body file: $BODY"

    # HTML comments, code blocks and code spans close nothing on GitHub; the
    # template's own guidance once held a `Closes #<n>` example that passed
    # this gate for a body naming no issue. An unterminated comment or code
    # block hides to the end, as GitHub renders it.
    body_text="$(perl -0777 -pe 's/<!--.*?(?:-->|\z)//gs; s/^ {0,3}(`{3,}|~{3,}).*?(?:^ {0,3}\1[^\n]*$|\z)//gms; s/(`+)(?!`).+?(?<!`)\1(?!`)//gs' "$BODY")"
    if grep -qiE '\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#|#)[0-9]+' <<<"$body_text"; then
      echo "closing-keyword: body carries a closing keyword. OK."; exit 0
    fi
    if is_exempt_pr "$BRANCH" "$AUTHOR"; then
      echo "closing-keyword: $(exempt_pr_reason "$BRANCH") OK."; exit 0
    fi
    title="${PR_TITLE:-}"
    [ -n "$title" ] || title="$(cat "${RUNNER_TEMP:-}/pr-title.txt" 2>/dev/null || true)"
    chore_re='^chore(\(|:|!)'
    if [[ "$title" =~ $chore_re ]] && grep -qE '^No issue:[[:space:]]+\S' <<<"$body_text"; then
      echo "closing-keyword: chore title with a No issue line. OK."; exit 0
    fi
    echo "::error::closing-keyword: no closing keyword in the PR body. Add \`Closes #<n>\`, or a chore title with the line \`No issue: <reason>\`." >&2
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
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        package.json|*/package.json) ;;
        *) continue ;;
      esac
      diff="$(git diff -U0 "$BASE...$HEAD" -- "$f" 2>/dev/null)" \
        || die3 "could not diff $f in $BASE...$HEAD — failing closed rather than passing"
      if printf '%s\n' "$diff" | grep -qE '^[+-].*"version"[[:space:]]*:'; then
        echo "::error::no-hand-version: $f changes a \"version\" field. Version files are generated." >&2
        exit 1
      fi
    done <<<"$manifests"
    echo "no-hand-version: no hand-edited version or changelog. OK."
    exit 0
    ;;

  migrations)
    BASE="${1:-}"; HEAD="${2:-}"
    [ -n "$BASE" ] && [ -n "$HEAD" ] || die3 "usage: gates.sh migrations <base> <head>"
    status="$(git diff --name-status --no-renames "$BASE...$HEAD" 2>/dev/null)" \
      || die3 "could not diff $BASE...$HEAD — failing closed rather than passing"
    violations=""
    note() { violations="$violations
  - $1"; }
    while IFS=$'\t' read -r st f rest; do
      [ -n "${f:-}" ] || continue
      # Michelin's SQL samples are test inputs, not applied database records.
      case "${GITHUB_REPOSITORY:-}:$f" in
        digio-nz/digio-michelin:*/assets/fixture/drizzle/*.sql) continue ;;
      esac
      case "$f" in
        drizzle/*.sql|*/drizzle/*.sql) ;;
        *) continue ;;
      esac
      case "$st" in
        A*)
          basef="$(basename "$f")"
          ts_re='^[0-9]{14}_'
          if [[ ! "$basef" =~ $ts_re ]]; then
            note "$f — a new migration needs a 14-digit timestamp prefix"
          fi
          ;;
        *)
          note "$f — a migration that is on the base is never rewritten"
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
    node --experimental-strip-types "${DIGIO_SKILLS_ROOT:-$HOME/.digio/skills}/skills/pr-labeller/scripts/pr-labeller.ts" "${label_args[@]}"
    ;;

  *) die3 "usage: gates.sh [user-docs|append-only|pr-title|closing-keyword|pr-labels-apply|exempt-pr|no-hand-version|migrations|no-secret|actionlint|actionlint-install] ..." ;;
esac
