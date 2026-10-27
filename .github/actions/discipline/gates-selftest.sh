#!/usr/bin/env bash
# Prove every gate in gates.sh both ways. Network-free: scratch git repos, no API.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
gates="$here/gates.sh"
pass=0
fail=0

# run <expected-exit> <label> -- <gate args...>
run() {
  local want="$1" label="$2" out got
  shift 3   # drop the literal --
  out="$(bash "$gates" "$@" 2>&1)"; got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok   $label"; pass=$((pass + 1))
  else
    echo "FAIL $label — expected exit $want, got $got:"
    printf '%s\n' "$out" | awk '{ print "       " $0 }'
    fail=$((fail + 1))
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A repository with an ADR corpus, so base..head diffs are real.
repo="$work/repo"
mkdir -p "$repo/docs/adr" "$repo/src/components" "$repo/src/help/content"
git -C "$repo" init -q
git -C "$repo" config user.email gate@example.com
git -C "$repo" config user.name "gate fixture"
cat > "$repo/docs/adr/20260101-a-decision.md" <<'MD'
# A decision

Status: Accepted

Body text that is history.
MD
cat > "$repo/docs/adr/README.md" <<'MD'
# ADRs

| 0007 | [A decision](20260101-a-decision.md) |
MD
echo "ui" > "$repo/src/components/Thing.tsx"
echo "docs" > "$repo/src/help/content/thing.mdx"
mkdir -p "$repo/drizzle/meta"
printf 'CREATE TABLE a (id int);\n' > "$repo/drizzle/0000_first.sql"
printf 'CREATE TABLE b (id int);\n' > "$repo/drizzle/0001_second.sql"
printf '{"id":"snap-0"}\n' > "$repo/drizzle/meta/0000_snapshot.json"
printf '{"id":"snap-1"}\n' > "$repo/drizzle/meta/0001_snapshot.json"
cat > "$repo/drizzle/meta/_journal.json" <<'JSON'
{
  "version": "7",
  "dialect": "postgresql",
  "entries": [
    { "idx": 0, "version": "7", "when": 1000, "tag": "0000_first", "breakpoints": true },
    { "idx": 1, "version": "7", "when": 2000, "tag": "0001_second", "breakpoints": true }
  ]
}
JSON
# A migrations tree below the repo root, as digio-invoices keeps one at
# lib/db/drizzle/: the rule follows drizzle's layout, not one fixed path.
mkdir -p "$repo/lib/db/drizzle/meta"
printf 'CREATE TABLE n (id int);\n' > "$repo/lib/db/drizzle/0000_nested.sql"
printf '{"id":"snap-n"}\n' > "$repo/lib/db/drizzle/meta/0000_snapshot.json"
cat > "$repo/lib/db/drizzle/meta/_journal.json" <<'JSON'
{
  "version": "7",
  "dialect": "postgresql",
  "entries": [
    { "idx": 0, "version": "7", "when": 1000, "tag": "0000_nested", "breakpoints": true }
  ]
}
JSON
git -C "$repo" add -A >/dev/null
git -C "$repo" commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"

commit_head() {   # commit_head <message>; sets $head
  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit -qm "$1"
  head="$(git -C "$repo" rev-parse HEAD)"
}
reset_to_base() { git -C "$repo" reset -q --hard "$base"; }
# Portable in-place edit: BSD and GNU sed disagree on `sed -i` syntax.
sedi() {
  local script="$1" file="$2" tmp="$2.sedi"
  if ! sed "$script" "$file" > "$tmp"; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "$file"
}

printf 'no declaration here\n' > "$work/body-plain.txt"
printf 'user-docs: none - the change is server-side only\n' > "$work/body-hyphen.txt"
printf 'user-docs: none — the change is server-side only\n' > "$work/body-emdash.txt"
printf 'user-docs: none -\n' > "$work/body-noreason-dash.txt"
printf 'user-docs: none\n' > "$work/body-noreason-bare.txt"
printf 'Closes #41\n' > "$work/body-closes.txt"
printf '<!-- e.g. Closes #123 -->\nCloses #\n' > "$work/body-comment-only.txt"
printf '<!-- e.g. Closes #123 -->\nCloses #41\n<!-- unterminated\n' > "$work/body-comment-and-real.txt"
printf 'It merged with `Closes #80` in its body.\n\n```\nFixes #81\n```\n' > "$work/body-code-only.txt"
printf 'Quotes `Closes #80`.\n\nCloses #41\n' > "$work/body-code-and-real.txt"
printf 'append-only: licensed — Digio, a licensed consistency sweep\n' > "$work/body-licensed.txt"
printf 'append-only: licensed -\n' > "$work/body-licensed-noreason.txt"

cd "$repo" || exit 1

# ── user-docs ────────────────────────────────────────────────────────
echo "ui changed" >> src/components/Thing.tsx; commit_head "ui only"
run 0 "user-docs: UI touched, no docs, no declaration" -- user-docs "$base" "$head" "$work/body-plain.txt" src/help/content src/components
run 0 "user-docs: the declaration with a hyphen is accepted" -- user-docs "$base" "$head" "$work/body-hyphen.txt" src/help/content src/components
run 0 "user-docs: the declaration with an em dash is accepted" -- user-docs "$base" "$head" "$work/body-emdash.txt" src/help/content src/components
run 0 "user-docs: a declaration with no reason after the dash warns" -- user-docs "$base" "$head" "$work/body-noreason-dash.txt" src/help/content src/components
run 0 "user-docs: a declaration with no dash and no reason warns" -- user-docs "$base" "$head" "$work/body-noreason-bare.txt" src/help/content src/components
reset_to_base

# A repo that sets neither variable gets a visible warning, not a silent skip.
echo "ui changed" >> src/components/Thing.tsx; commit_head "ui with no variables"
docs_case() {   # docs_case <missing variable names> <docs-dir> [ui-dir...]
  local names="$1"; shift
  summary="$work/summary.md"; : > "$summary"
  out="$(GITHUB_STEP_SUMMARY="$summary" bash "$gates" user-docs "$base" "$head" "$work/body-plain.txt" "$@" 2>&1)"; got=$?
  if [ "$got" -eq 0 ] && printf '%s\n' "$out" | grep -q "::warning title=user-docs::.*$names" && grep -q "$names" "$summary"; then
    echo "ok   user-docs: a repo without $names warns and passes"; pass=$((pass + 1))
  else
    echo "FAIL user-docs: a repo without $names warns and passes (exit $got)"; fail=$((fail + 1))
    printf '%s\n' "$out" | awk '{ print "       " $0 }'
  fi
}
docs_case "DISCIPLINE_UI_DIRS DISCIPLINE_DOCS_DIR" ""
docs_case "DISCIPLINE_UI_DIRS" src/help/content
docs_case "DISCIPLINE_DOCS_DIR" "" src/components
out="$(bash "$gates" user-docs "$base" "$head" "$work/body-plain.txt" "" none 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! printf '%s\n' "$out" | grep -q '::warning'; then
  echo "ok   user-docs: DISCIPLINE_UI_DIRS none passes with no warning"; pass=$((pass + 1))
else
  echo "FAIL user-docs: DISCIPLINE_UI_DIRS none passes with no warning (exit $got)"; fail=$((fail + 1))
  printf '%s\n' "$out" | awk '{ print "       " $0 }'
fi
reset_to_base

echo "ui changed" >> src/components/Thing.tsx; echo "docs changed" >> src/help/content/thing.mdx; commit_head "ui and docs"
run 0 "user-docs: UI and docs both touched" -- user-docs "$base" "$head" "$work/body-plain.txt" src/help/content src/components
reset_to_base

# More changed paths than a pipe holds (64 KB): a `printf | grep -q` matcher
# under pipefail returns 141 once grep exits on its first match, and the gate
# once read that as "no UI dirs touched". The bulk sorts after the UI file.
echo "ui changed" >> src/components/Thing.tsx
mkdir -p vendor/generated-client-with-a-deliberately-long-directory-name
for i in $(seq 1 3000); do
  : > "vendor/generated-client-with-a-deliberately-long-directory-name/generated-module-$i.ts"
done
commit_head "ui plus a large generated diff"
run 0 "user-docs: UI touched in a diff larger than a pipe buffer, no docs" -- user-docs "$base" "$head" "$work/body-plain.txt" src/help/content src/components
echo "docs changed" >> src/help/content/thing.mdx; commit_head "and the docs"
run 0 "user-docs: UI and docs both touched in a diff larger than a pipe buffer" -- user-docs "$base" "$head" "$work/body-plain.txt" src/help/content src/components
reset_to_base

echo "server" > server.ts; commit_head "no ui"
run 0 "user-docs: no UI directory touched" -- user-docs "$base" "$head" "$work/body-plain.txt" src/help/content src/components
run 3 "user-docs: an unreadable range fails closed" -- user-docs deadbeef "$head" "$work/body-plain.txt" src/help/content src/components
reset_to_base

# ── append-only ──────────────────────────────────────────────────────
echo "an extra paragraph" >> docs/adr/20260101-a-decision.md; commit_head "edit an accepted ADR"
run 1 "append-only: an accepted ADR's body edited" -- append-only "$base" "$head"
reset_to_base

sedi 's/^Status: Accepted/Status: Superseded by 20260202-another.md/' docs/adr/20260101-a-decision.md || exit 1; commit_head "status line only"
run 0 "append-only: the Status line is the one permitted edit" -- append-only "$base" "$head"
reset_to_base

git rm -q docs/adr/20260101-a-decision.md; commit_head "delete an ADR"
run 1 "append-only: an accepted ADR deleted" -- append-only "$base" "$head"
reset_to_base

cp docs/adr/20260101-a-decision.md docs/adr/20260303-new.md; commit_head "add an ADR"
run 0 "append-only: adding a record is how the log grows" -- append-only "$base" "$head"
reset_to_base

echo "| 0009 | x |" >> docs/adr/README.md; commit_head "index edit"
run 0 "append-only: the derived index is not a decision" -- append-only "$base" "$head"
reset_to_base

echo "an extra paragraph" >> docs/adr/20260101-a-decision.md; commit_head "licensed body edit"
run 0 "append-only: a body edit under the licensed waiver" -- append-only "$base" "$head" "$work/body-licensed.txt"
reset_to_base

echo "an extra paragraph" >> docs/adr/20260101-a-decision.md; commit_head "licensed body edit, no reason"
run 1 "append-only: a waiver with no reason is no waiver" -- append-only "$base" "$head" "$work/body-licensed-noreason.txt"
reset_to_base

git rm -q docs/adr/20260101-a-decision.md; commit_head "delete an ADR under waiver"
run 1 "append-only: a deletion is never waived" -- append-only "$base" "$head" "$work/body-licensed.txt"
reset_to_base

# OKF frontmatter added to an ADR is not a body edit; the check reads the
# diff hunks by line number. he-mobility PR #84 prepended a block to 22 ADRs.
okf_block=$'---\ntype: ADR\ngenerated: { by: process:digio-crew, at: 2026-10-03T23:19:24Z }\n---\n\n'
adr=docs/adr/20260101-a-decision.md
{ printf '%s' "$okf_block"; cat "$adr"; } > "$adr.new" && mv "$adr.new" "$adr"; commit_head "prepend OKF frontmatter"
run 0 "append-only: a complete frontmatter block prepended to an ADR with none" -- append-only "$base" "$head"
reset_to_base

{ printf -- '---\ntype: ADR\n---\n'; cat "$adr"; } > "$adr.new" && mv "$adr.new" "$adr"; commit_head "prepend frontmatter, no blank line"
run 0 "append-only: a prepended block with no blank line after it" -- append-only "$base" "$head"
reset_to_base

{ printf '%s' "$okf_block"; cat "$adr"; } > "$adr.new" && mv "$adr.new" "$adr"
sedi 's/^Body text that is history./Body text, rewritten./' "$adr" || exit 1; commit_head "prepend frontmatter and edit the body"
run 1 "append-only: a frontmatter prepend plus one body line changed" -- append-only "$base" "$head"
fm_out="$(bash "$gates" append-only "$base" "$head" 2>&1)"
if [[ "$fm_out" == *"$adr — body edited. Only the Status line may change after acceptance"* ]]; then
  echo "ok   append-only: a frontmatter prepend with a body edit keeps the body-edited message"; pass=$((pass + 1))
else
  echo "FAIL append-only: a frontmatter prepend with a body edit keeps the body-edited message: $fm_out"; fail=$((fail + 1))
fi
reset_to_base

{ printf '%s' "$okf_block"; cat "$adr"; echo "an extra paragraph"; } > "$adr.new" && mv "$adr.new" "$adr"; commit_head "prepend frontmatter and append a line"
run 1 "append-only: a frontmatter prepend plus a line added after the block" -- append-only "$base" "$head"
reset_to_base

{ printf '%s' "$okf_block"; sedi 's/^Status: Accepted/Status: Superseded by 20260202-another.md/' "$adr" && cat "$adr"; } > "$adr.new" && mv "$adr.new" "$adr"; commit_head "prepend frontmatter and change the status"
run 0 "append-only: a frontmatter prepend plus the Status line" -- append-only "$base" "$head"
reset_to_base

# A block that reuses an old line as its fence takes body text into the
# frontmatter: lines 1..K are not all added, so it is an edit.
printf '# A decision\n\nStatus: Accepted\n\n---\n\nBody text that is history.\n' > docs/adr/20260404-rule.md; commit_head "an ADR with a horizontal rule"
rule_base="$head"
{ printf -- '---\ntype: ADR\n'; cat docs/adr/20260404-rule.md; } > rule.new && mv rule.new docs/adr/20260404-rule.md; commit_head "a block closed by the old rule"
run 1 "append-only: a prepended block closed by an old body line" -- append-only "$rule_base" "$head"
reset_to_base

# An ADR that already has frontmatter may gain keys inside the block.
{ printf -- '---\ntitle: A decision\nsidebar_position: 2\n---\n\n'; cat "$adr"; } > "$adr.new" && mv "$adr.new" "$adr"; commit_head "an ADR with frontmatter"
fm_base="$head"
awk '{ print } /^sidebar_position: 2$/ { print "type: ADR"; print "generated: { by: process:claude, at: 2026-10-03T23:19:24Z }" }' "$adr" > "$adr.new" && mv "$adr.new" "$adr"; commit_head "add keys to the block"
run 0 "append-only: keys added inside an existing frontmatter block" -- append-only "$fm_base" "$head"
git -C "$repo" reset -q --hard "$fm_base"

sedi '/^sidebar_position: 2$/d' "$adr" || exit 1; commit_head "remove a frontmatter key"
run 1 "append-only: a frontmatter key removed" -- append-only "$fm_base" "$head"
git -C "$repo" reset -q --hard "$fm_base"

sedi 's/^sidebar_position: 2$/sidebar_position: 3/' "$adr" || exit 1; commit_head "change a frontmatter value"
run 1 "append-only: a frontmatter value changed" -- append-only "$fm_base" "$head"
git -C "$repo" reset -q --hard "$fm_base"

{ printf -- '---\ntype: ADR\n---\n\n'; cat "$adr"; } > "$adr.new" && mv "$adr.new" "$adr"; commit_head "a second block on top of the first"
run 1 "append-only: a new block prepended above an existing one" -- append-only "$fm_base" "$head"
reset_to_base

# ── append-only: applied drizzle migrations ──────────────────────────
mig_msg="an applied migration is never rewritten"
journal=drizzle/meta/_journal.json

echo "ALTER TABLE a ADD c int;" >> drizzle/0000_first.sql; commit_head "edit an applied migration"
run 1 "append-only: an applied migration edited" -- append-only "$base" "$head"
run 0 "append-only: an applied migration edited under the licensed waiver" -- append-only "$base" "$head" "$work/body-licensed.txt"
run 1 "append-only: a migration edit with a no-reason waiver" -- append-only "$base" "$head" "$work/body-licensed-noreason.txt"
mig_out="$(bash "$gates" append-only "$base" "$head" 2>&1)"
if printf '%s\n' "$mig_out" | grep -q "drizzle/0000_first.sql.*$mig_msg; add a new migration instead"; then
  echo "ok   append-only: the migration violation names the file and the rule"; pass=$((pass + 1))
else
  echo "FAIL append-only: the migration violation names the file and the rule"; fail=$((fail + 1))
fi
reset_to_base

git rm -q drizzle/0001_second.sql; commit_head "delete an applied migration"
run 1 "append-only: an applied migration deleted" -- append-only "$base" "$head"
run 0 "append-only: an applied migration deleted under the licensed waiver" -- append-only "$base" "$head" "$work/body-licensed.txt"
reset_to_base

git mv drizzle/0001_second.sql drizzle/0002_second.sql; commit_head "renumber an applied migration"
run 1 "append-only: an applied migration renamed" -- append-only "$base" "$head"
reset_to_base

echo '{"id":"snap-0-edited"}' > drizzle/meta/0000_snapshot.json; commit_head "edit an applied snapshot"
run 1 "append-only: an applied snapshot edited" -- append-only "$base" "$head"
reset_to_base

git rm -q drizzle/meta/0001_snapshot.json; commit_head "delete an applied snapshot"
run 1 "append-only: an applied snapshot deleted" -- append-only "$base" "$head"
reset_to_base

sedi 's/"when": 2000/"when": 2500/' "$journal" || exit 1; commit_head "change a journal entry"
run 1 "append-only: a journal entry changed" -- append-only "$base" "$head"
run 0 "append-only: a journal entry changed under the licensed waiver" -- append-only "$base" "$head" "$work/body-licensed.txt"
reset_to_base

sedi 's/0001_second/0001_renamed/' "$journal" || exit 1; commit_head "retag a journal entry"
run 1 "append-only: a journal entry retagged" -- append-only "$base" "$head"
reset_to_base

jq '.entries |= .[:1]' "$journal" > "$journal.tmp" && mv "$journal.tmp" "$journal"; commit_head "remove a journal entry"
run 1 "append-only: a journal entry removed" -- append-only "$base" "$head"
reset_to_base

jq '.entries |= reverse' "$journal" > "$journal.tmp" && mv "$journal.tmp" "$journal"; commit_head "reorder the journal"
run 1 "append-only: the journal reordered" -- append-only "$base" "$head"
reset_to_base

git rm -q "$journal"; commit_head "delete the journal"
run 1 "append-only: the journal deleted" -- append-only "$base" "$head"
reset_to_base

printf '{ not json\n' > "$journal"; commit_head "corrupt the journal"
run 1 "append-only: an unreadable journal is a violation, not a pass" -- append-only "$base" "$head"
reset_to_base

printf 'CREATE TABLE c (id int);\n' > drizzle/0002_third.sql
echo '{"id":"snap-2"}' > drizzle/meta/0002_snapshot.json
jq '.entries += [{"idx":2,"version":"7","when":3000,"tag":"0002_third","breakpoints":true}]' "$journal" > "$journal.tmp" && mv "$journal.tmp" "$journal"
commit_head "add a migration, snapshot and journal entry"
run 0 "append-only: a new migration, snapshot and journal entry is legal" -- append-only "$base" "$head"
reset_to_base

nested=lib/db/drizzle
echo "ALTER TABLE n ADD c int;" >> "$nested/0000_nested.sql"; commit_head "edit a nested applied migration"
run 1 "append-only: a nested applied migration edited" -- append-only "$base" "$head"
reset_to_base

echo '{"id":"snap-n-edited"}' > "$nested/meta/0000_snapshot.json"; commit_head "edit a nested applied snapshot"
run 1 "append-only: a nested applied snapshot edited" -- append-only "$base" "$head"
reset_to_base

sedi 's/"when": 1000/"when": 1500/' "$nested/meta/_journal.json" || exit 1; commit_head "change a nested journal entry"
run 1 "append-only: a nested journal entry changed" -- append-only "$base" "$head"
reset_to_base

printf 'CREATE TABLE o (id int);\n' > "$nested/0001_more.sql"
jq '.entries += [{"idx":1,"version":"7","when":2000,"tag":"0001_more","breakpoints":true}]' "$nested/meta/_journal.json" > "$nested/meta/_journal.json.tmp" && mv "$nested/meta/_journal.json.tmp" "$nested/meta/_journal.json"
commit_head "add a nested migration and journal entry"
run 0 "append-only: a new nested migration and journal entry is legal" -- append-only "$base" "$head"
reset_to_base

# ── pr-title ─────────────────────────────────────────────────────────
run 0 "pr-title: type(scope): description" -- pr-title "fix(board): stop minting labels"
run 0 "pr-title: type: description" -- pr-title "docs: name the enforcement"
run 0 "pr-title: feat(api): add x" -- pr-title "feat(api): add x"
run 0 "pr-title: feat!: drop x" -- pr-title "feat!: drop x"
run 1 "pr-title: no type prefix" -- pr-title "Stop minting labels"
run 1 "pr-title: no description" -- pr-title "fix:"
run 1 "pr-title: a Phase ref before the type" -- pr-title "P2.3 feat: add x"
run 1 "pr-title: a Plan ref before the type" -- pr-title "P56 docs: record the release decision"
run 1 "pr-title: an issue ref before the type" -- pr-title "#1602 fix(board): stop minting labels"
run 0 "pr-title: Dependabot is exempt" -- pr-title "Bump x" "dependabot[bot]" dependabot/npm/x

# ── exempt-pr (the one provenance predicate, for callers outside this file)
run 1 "exempt-pr: process-deploy is not exempt" -- exempt-pr process-deploy someone
run 0 "exempt-pr: a genuine Dependabot PR is exempt" -- exempt-pr dependabot/npm_and_yarn/vite-8 "dependabot[bot]"
run 1 "exempt-pr: a human branch named dependabot/ is not" -- exempt-pr dependabot/npm_and_yarn/vite-8 digbycampbell
run 1 "exempt-pr: process-deploy-foo is not" -- exempt-pr process-deploy-foo someone
run 1 "exempt-pr: an issue branch is not" -- exempt-pr fm-issue-41 digbycampbell
run 3 "exempt-pr: no branch is a usage error" -- exempt-pr

# ── closing-keyword ──────────────────────────────────────────────────
printf 'No issue: a templates deploy\n' > "$work/body-no-issue.txt"
run 0 "closing-keyword: a keyword in the body" -- closing-keyword "$work/body-closes.txt" my-branch
run 1 "closing-keyword: a keyword only inside an HTML comment" -- closing-keyword "$work/body-comment-only.txt" my-branch
run 0 "closing-keyword: a real keyword beside a commented example" -- closing-keyword "$work/body-comment-and-real.txt" my-branch
run 1 "closing-keyword: a keyword only inside code" -- closing-keyword "$work/body-code-only.txt" my-branch
run 0 "closing-keyword: a real keyword beside a quoted one" -- closing-keyword "$work/body-code-and-real.txt" my-branch
PR_TITLE="chore: x" run 0 "closing-keyword: a chore title with No issue" -- closing-keyword "$work/body-no-issue.txt" chore-farm
PR_TITLE="fix: x" run 1 "closing-keyword: a fix title with No issue" -- closing-keyword "$work/body-no-issue.txt" my-branch
mkdir -p "$work/rt"
printf '%s\n' 'chore(docs): a live PR title' > "$work/rt/pr-title.txt"
PR_TITLE="fix: x" RUNNER_TEMP="$work/rt" run 1 "closing-keyword: a fix title with No issue ignores RUNNER_TEMP title" -- closing-keyword "$work/body-no-issue.txt" my-branch
printf '%s\n' '<!--' 'No issue: hidden' '-->' > "$work/body-no-issue-comment.txt"
PR_TITLE="chore: x" run 1 "closing-keyword: No issue only inside an HTML comment" -- closing-keyword "$work/body-no-issue-comment.txt" chore-farm
unset PR_TITLE
run 1 "closing-keyword: neither" -- closing-keyword "$work/body-plain.txt" my-branch
run 1 "closing-keyword: process-deploy is not exempt" -- closing-keyword "$work/body-plain.txt" process-deploy
run 0 "closing-keyword: a Dependabot branch with the Dependabot author is exempt" -- closing-keyword "$work/body-plain.txt" dependabot/npm/x "dependabot[bot]"
run 1 "closing-keyword: a Dependabot branch with a human author is NOT exempt" -- closing-keyword "$work/body-plain.txt" dependabot/npm/x some-human
run 3 "closing-keyword: no body file at all fails closed" -- closing-keyword "$work/absent.txt" my-branch

mkdir -p "$work/label-bin"
cat > "$work/label-bin/node" <<'NODE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$LABEL_ARGS"
NODE
chmod +x "$work/label-bin/node"
PATH="$work/label-bin:$PATH" LABEL_ARGS="$work/label-args" run 0 "pr-labels-apply uses the complete local diff" -- pr-labels-apply o/r 7 base-ref head-ref
if [ "$(tail -n 4 "$work/label-args")" = "$(printf '%s\n' --base base-ref --head head-ref)" ]; then
  echo "ok   pr-labels-apply forwards both refs to the labeller"; pass=$((pass + 1))
else
  echo "FAIL pr-labels-apply lost the local diff refs"; fail=$((fail + 1))
fi

# ── no-hand-version ──────────────────────────────────────────────────
printf '{"name":"x","version":"1.0.0"}\n' > package.json
git add package.json && git commit -qm 'package'
pkg_base="$(git rev-parse HEAD)"
printf '{"name":"x","version":"1.0.1"}\n' > package.json
commit_head "bump version"
run 1 "no-hand-version: a version field change" -- no-hand-version "$pkg_base" "$head"
out="$(bash "$gates" no-hand-version "$pkg_base" "$head" 2>&1)" || true
if printf '%s\n' "$out" | grep -q 'package.json'; then
  echo "ok   no-hand-version: names the file"; pass=$((pass + 1))
else
  echo "FAIL no-hand-version: names the file"; fail=$((fail + 1))
fi
git reset -q --hard "$pkg_base"
git rm -q package.json
commit_head "remove the package"
run 0 "no-hand-version: removing a package does not edit a version" -- no-hand-version "$pkg_base" "$head"
git reset -q --hard "$pkg_base"
printf '# changelog\n' > CHANGELOG.md
commit_head "changelog"
run 1 "no-hand-version: CHANGELOG.md changed" -- no-hand-version "$pkg_base" "$head"
reset_to_base

# ── migrations ───────────────────────────────────────────────────────
printf 'CREATE TABLE x (id int);\n' > drizzle/0007_add_x.sql
commit_head "untimestamped migration"
run 1 "migrations: a new 0007_ file" -- migrations "$base" "$head"
out="$(bash "$gates" migrations "$base" "$head" 2>&1)" || true
if printf '%s\n' "$out" | grep -q 'drizzle/0007_add_x.sql'; then
  echo "ok   migrations: names the file"; pass=$((pass + 1))
else
  echo "FAIL migrations: names the file"; fail=$((fail + 1))
fi
reset_to_base

printf 'CREATE TABLE x (id int);\n' > drizzle/20261014141322_add_x.sql
commit_head "timestamped migration"
run 0 "migrations: a 14-digit timestamp prefix" -- migrations "$base" "$head"
reset_to_base

echo "ALTER TABLE a ADD c int;" >> drizzle/0000_first.sql; commit_head "edit applied"
run 1 "migrations: a migration on the base edited" -- migrations "$base" "$head"
reset_to_base

reset_to_base
mkdir -p sample/assets/fixture/drizzle
printf 'CREATE TABLE sample (id int);\n' > sample/assets/fixture/drizzle/0001_init.sql
commit_head "SQL fixture"
fixture_base="$head"
git rm -q sample/assets/fixture/drizzle/0001_init.sql
commit_head "move the SQL fixture"
GITHUB_REPOSITORY=digio-nz/digio-michelin run 0 "migrations: factory SQL fixtures are not applied records" -- migrations "$fixture_base" "$head"
GITHUB_REPOSITORY=example/product run 1 "migrations: a product cannot claim the factory fixture exception" -- migrations "$fixture_base" "$head"
reset_to_base

# ── no-secret ────────────────────────────────────────────────────────
# Assemble the URI at runtime so this file does not hold a credential-shaped string.
pw='abcdefghij'
printf 'url = postgres://user:%s@host/db\n' "$pw" > secret.env
git add secret.env && git commit -qm 'credential'
secret_head="$(git rev-parse HEAD)"
run 1 "no-secret: a commit that adds a credential-shaped value" -- no-secret "$base" "$secret_head"
out="$(bash "$gates" no-secret "$base" "$secret_head" 2>&1)" || true
if printf '%s\n' "$out" | grep -q "$secret_head"; then
  echo "ok   no-secret: names the commit"; pass=$((pass + 1))
else
  echo "FAIL no-secret: names the commit"; fail=$((fail + 1))
fi
reset_to_base

# ── actionlint ───────────────────────────────────────────────────────
mkdir -p .github/workflows
printf '%s\n' 'name: Good' 'on: push' 'jobs:' '  ok:' '    runs-on: ubuntu-latest' \
  '    steps:' '      - run: echo ok' > .github/workflows/ok.yml
commit_head "valid workflow"
run 0 "actionlint: a valid workflow" -- actionlint .github/workflows
reset_to_base

mkdir -p .github/workflows
printf '%s\n' 'name: [' > .github/workflows/bad.yml
commit_head "broken workflow"
out="$(bash "$gates" actionlint .github/workflows 2>&1)" || true
if printf '%s\n' "$out" | grep -q 'bad.yml' && printf '%s\n' "$out" | grep -q 'syntax fault'; then
  echo "ok   actionlint: a syntax fault names the file"; pass=$((pass + 1))
else
  echo "FAIL actionlint: a syntax fault names the file"; fail=$((fail + 1))
  printf '%s\n' "$out" | awk '{ print "       " $0 }'
fi
run 1 "actionlint: a workflow with a syntax fault" -- actionlint .github/workflows
reset_to_base

# actionlint-install against a stub curl: the releases are local fixture files.
rel="$work/releases"; stub="$work/stub-curl"; mkdir -p "$rel" "$stub"
cat > "$stub/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -H) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
case "$url" in
  */releases/latest) [ -n "${STUB_LATEST:-}" ] || exit 22; printf '{"tag_name": "%s"}\n' "$STUB_LATEST" ;;
  */releases/download/*) [ -f "$STUB_RELEASES/${url##*/}" ] || exit 22; cp "$STUB_RELEASES/${url##*/}" "$out" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$stub/curl"
case "$(uname -s)" in Darwin) los=darwin ;; *) los=linux ;; esac
case "$(uname -m)" in aarch64|arm64) larch=arm64 ;; *) larch=amd64 ;; esac
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
release() {   # release <version> <checksum-or-empty>: a tarball and its checksums file
  local v="$1" asset="actionlint_${1}_${los}_${larch}.tar.gz" d
  d="$(mktemp -d "$work/rel.XXXX")"
  printf '#!/bin/sh\necho actionlint %s\n' "$v" > "$d/actionlint"; chmod +x "$d/actionlint"
  tar -czf "$rel/$asset" -C "$d" actionlint
  printf '%s  %s\n' "${2:-$(sha_of "$rel/$asset")}" "$asset" > "$rel/actionlint_${v}_checksums.txt"
}
install_case() {   # install_case <want-exit> <label> <latest-tag-or-empty> <grep pattern> [no-binary]
  local dest; dest="$(mktemp -d "$work/install.XXXX")/bin"
  out="$(PATH="$stub:$PATH" STUB_RELEASES="$rel" STUB_LATEST="$3" bash "$gates" actionlint-install "$dest" 2>&1)"; got=$?
  local installed=yes
  [ -x "$dest/actionlint" ] || installed=no-binary
  if [ "$got" -eq "$1" ] && printf '%s\n' "$out" | grep -q -- "$4" && [ "$installed" = "${5:-yes}" ]; then
    echo "ok   $2"; pass=$((pass + 1))
  else
    echo "FAIL $2 (exit $got)"; fail=$((fail + 1))
    printf '%s\n' "$out" | awk '{ print "       " $0 }'
  fi
}
release 9.9.9
install_case 0 "actionlint-install: the latest release with a good checksum" v9.9.9 "installed v9.9.9, checksum verified"
install_case 3 "actionlint-install: no latest tag fails and installs nothing" "" "cannot read the latest release" no-binary
release 9.9.8 "$(printf '0%.0s' $(seq 64))"
install_case 3 "actionlint-install: a checksum mismatch fails and installs nothing" v9.9.8 "does not match the checksums file" no-binary
release 9.9.7; : > "$rel/actionlint_9.9.7_checksums.txt"
install_case 3 "actionlint-install: a checksums file without the asset fails" v9.9.7 "does not match the checksums file" no-binary
install_case 3 "actionlint-install: a release that cannot download fails" v0.0.1 "cannot download v0.0.1" no-binary

# ── warning annotations ──────────────────────────────────────────────
echo "ui changed" >> src/components/Thing.tsx; commit_head "ui only for warning"
summary="$work/summary.md"; : > "$summary"
out="$(GITHUB_STEP_SUMMARY="$summary" bash "$gates" user-docs "$base" "$head" "$work/body-plain.txt" src/help/content src/components 2>&1)" || true
if printf '%s\n' "$out" | grep -q '::warning title=user-docs::' && grep -q 'user-docs:' "$summary"; then
  echo "ok   user-docs: warning and summary line"; pass=$((pass + 1))
else
  echo "FAIL user-docs: warning and summary line"; fail=$((fail + 1))
  printf '%s\n' "$out"
fi
reset_to_base

# ── read-pr merge_group ──────────────────────────────────────────────
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/bin/sh
echo '{"number":41,"title":"feat: x","body":"Closes #1","base":{"sha":"b"},"head":{"sha":"h"}}'
STUB
chmod +x "$work/bin/gh"
cat > "$work/merge-group.json" <<'JSON'
{
  "merge_group": {
    "head_ref": "gh-readonly-queue/main/pr-41-deadbeef",
    "base_sha": "aa11111111111111111111111111111111111111",
    "head_sha": "bb22222222222222222222222222222222222222"
  }
}
JSON
read_out="$(
  PATH="$work/bin:$PATH" \
  GITHUB_EVENT_NAME=merge_group \
  GITHUB_EVENT_PATH="$work/merge-group.json" \
  GITHUB_REPOSITORY=o/r \
  RUNNER_TEMP="$work" \
  GITHUB_OUTPUT="$work/read-pr.out" \
  bash "$here/read-pr/read-pr.sh" 2>&1
)" || true
if grep -qx 'number=41' "$work/read-pr.out" \
  && grep -qx 'base=aa11111111111111111111111111111111111111' "$work/read-pr.out" \
  && grep -qx 'head=bb22222222222222222222222222222222222222' "$work/read-pr.out"; then
  echo "ok   read-pr: merge_group head_ref yields number 41 and the group SHAs"; pass=$((pass + 1))
else
  echo "FAIL read-pr: merge_group head_ref yields number 41 and the group SHAs"; fail=$((fail + 1))
  printf '%s\n' "$read_out"
  cat "$work/read-pr.out" 2>/dev/null || true
fi

# ── selftest of discipline.yml runner ────────────────────────────────
wf="$work/discipline.yml"
cat > "$wf" <<'YML'
name: Discipline
on: { pull_request: {}, merge_group: {} }
jobs:
  discipline:
    name: Discipline
    runs-on: ${{ vars.PROCESS_RUNNER }}
    steps: [{ run: true }]
YML
if bash "$here/selftest-workflow.sh" "$wf" >/dev/null 2>&1; then
  echo "FAIL selftest: PROCESS_RUNNER must fail"; fail=$((fail + 1))
else
  out="$(bash "$here/selftest-workflow.sh" "$wf" 2>&1)" || true
  if printf '%s\n' "$out" | grep -q 'runs-on'; then
    echo "ok   selftest: PROCESS_RUNNER names runs-on"; pass=$((pass + 1))
  else
    echo "FAIL selftest: PROCESS_RUNNER names runs-on"; fail=$((fail + 1))
  fi
fi

cat > "$wf" <<'YML'
name: Discipline
on: push
jobs:
  discipline:
    runs-on: [self-hosted, macOS, ARM64]
    steps: [{ run: true }]
YML
if bash "$here/selftest-workflow.sh" "$wf" >/dev/null 2>&1; then
  echo "FAIL selftest: a list runs-on must fail"; fail=$((fail + 1))
else
  echo "ok   selftest: a list runs-on fails"; pass=$((pass + 1))
fi

cat > "$wf" <<'YML'
name: Discipline
on: push
jobs:
  discipline:
    runs-on: ${{ vars.SOME_RUNNER }}
    steps: [{ run: true }]
YML
if bash "$here/selftest-workflow.sh" "$wf" >/dev/null 2>&1; then
  echo "FAIL selftest: an expression runs-on must fail"; fail=$((fail + 1))
else
  echo "ok   selftest: an expression runs-on fails"; pass=$((pass + 1))
fi

cat > "$wf" <<'YML'
name: Discipline
on: push
jobs:
  discipline:
    runs-on: ubuntu-latest
    steps: [{ run: true }]
YML
if bash "$here/selftest-workflow.sh" "$wf" >/dev/null 2>&1; then
  echo "FAIL selftest: no job on the Mac mini must fail"; fail=$((fail + 1))
else
  out="$(bash "$here/selftest-workflow.sh" "$wf" 2>&1)" || true
  if printf '%s\n' "$out" | grep -q 'Mac mini'; then
    echo "ok   selftest: no job on the Mac mini fails"; pass=$((pass + 1))
  else
    echo "FAIL selftest: no job on the Mac mini names the Mac mini"; fail=$((fail + 1))
  fi
fi

cat > "$wf" <<'YML'
name: Discipline
on: push
jobs:
  discipline:
    runs-on: [self-hosted, digio-orchestration, macos-arm64]
    steps: [{ run: true }]
YML
if bash "$here/selftest-workflow.sh" "$wf" >/dev/null 2>&1; then
  echo "FAIL selftest: macos-arm64 in the Mini labels must fail"; fail=$((fail + 1))
else
  echo "ok   selftest: macos-arm64 in the Mini labels fails"; pass=$((pass + 1))
fi

cat > "$wf" <<'YML'
name: Discipline
on: push
jobs:
  discipline:
    runs-on: [self-hosted, digio-orchestration]
    steps: [{ run: true }]
  labels:
    runs-on: ${{ vars.PROCESS_HOSTED_RUNNER || 'ubuntu-latest' }}
    steps: [{ run: true }]
  other:
    runs-on: ubuntu-latest # a comment
    steps: [{ run: true }]
YML
if bash "$here/selftest-workflow.sh" "$wf" >/dev/null 2>&1; then
  echo "ok   selftest: the Mini, ubuntu-latest and the hosted toggle pass"; pass=$((pass + 1))
else
  echo "FAIL selftest: the Mini, ubuntu-latest and the hosted toggle must pass"; fail=$((fail + 1))
fi

if bash "$here/selftest-workflow.sh" "$work/missing.yml" >/dev/null 2>&1; then
  echo "FAIL selftest: a missing workflow must fail"; fail=$((fail + 1))
else
  echo "ok   selftest: a missing workflow fails"; pass=$((pass + 1))
fi

f="$here/pr-labels-apply/action.yml"
if grep -Fq 'actions/create-github-app-token@v3' "$f" \
  && grep -Fq 'app-id: ${{ inputs.reader-app-id }}' "$f" \
  && grep -Fq 'READER_TOKEN: ${{ steps.reader.outputs.token }}' "$f" \
  && grep -Fq 'GH_TOKEN: ${{ github.token }}' "$f" \
  && ! grep -Fq 'vars.READER_APP_ID' "$f" \
  && ! grep -Fq 'secrets.READER_APP_PRIVATE_KEY' "$f"; then
  echo "ok   pr-labels-apply mints a digio-reader token and keeps github.token"; pass=$((pass + 1))
else
  echo "FAIL pr-labels-apply mints a digio-reader token and keeps github.token"; fail=$((fail + 1))
fi
wf_disc="$here/../../workflows/discipline.yml"
if grep -Fq 'reader-app-id: ${{ vars.READER_APP_ID }}' "$wf_disc" \
  && grep -Fq 'reader-app-private-key: ${{ secrets.READER_APP_PRIVATE_KEY }}' "$wf_disc"; then
  echo "ok   Discipline workflow passes the reader App credentials into the actions"; pass=$((pass + 1))
else
  echo "FAIL Discipline workflow passes the reader App credentials into the actions"; fail=$((fail + 1))
fi

if grep -Fq '.github/actions/discipline/gates-selftest.sh' "$here/gates.sh" \
  && ! grep -Fq 'optionally led by the delivered' "$here/gates.sh" \
  && ! grep -Fq 'head branch of exactly `process-deploy`' "$here/gates.sh"; then
  echo "ok   gates.sh header names the live self-test and the current exemptions"; pass=$((pass + 1))
else
  echo "FAIL gates.sh header names the live self-test and the current exemptions"; fail=$((fail + 1))
fi

# ── action input defaults ────────────────────────────────────────────
# defaults_case <want-exit> <label> <input name or empty>: the action.yml on stdin
defaults_case() {
  cat > "$work/action-case.yml"
  out="$(python3 -I "$here/action-defaults.py" "$work/action-case.yml" 2>&1)"; got=$?
  if [ "$got" -eq "$1" ] && { [ -z "$3" ] || printf '%s\n' "$out" | grep -qF "action-case.yml: inputs.$3.default"; }; then
    echo "ok   action-defaults: $2"; pass=$((pass + 1))
  else
    echo "FAIL action-defaults: $2 (exit $got)"; fail=$((fail + 1))
    printf '%s\n' "$out" | awk '{ print "       " $0 }'
  fi
}
defaults_case 1 "a vars default fails and names the input" app-id <<'YML'
name: bad
inputs:
  app-id:
    required: false
    default: ${{ vars.READER_APP_ID }}
YML
defaults_case 1 "a secrets default fails and names the input" key <<'YML'
name: bad
inputs:
  key:
    default: ${{ secrets.READER_APP_PRIVATE_KEY }}
YML
defaults_case 1 "a vars default in brackets fails" app-id <<'YML'
name: bad
inputs:
  app-id:
    default: ${{ vars['READER_APP_ID'] }}
YML
defaults_case 1 "a secrets default in brackets fails" key <<'YML'
name: bad
inputs:
  key:
    default: "${{ secrets [ 'READER_APP_PRIVATE_KEY' ] }}"
YML
defaults_case 1 "a whole-context default fails" all <<'YML'
name: bad
inputs:
  all:
    default: ${{ toJSON(secrets) }}
YML
defaults_case 1 "a block-scalar default fails" app-id <<'YML'
name: bad
inputs:
  app-id:
    default: >-
      ${{ vars.READER_APP_ID }}
    required: false
YML
defaults_case 1 "a folded expression over several lines fails" key <<'YML'
name: bad
inputs:
  key:
    default: >-
      ${{
      vars['KEY']
      }}
YML
defaults_case 1 "a quoted default key fails" key <<'YML'
name: bad
inputs:
  key:
    "default": ${{ secrets.KEY }}
YML
defaults_case 1 "a quoted inputs key fails" key <<'YML'
name: bad
"inputs":
  key:
    default: ${{ secrets.KEY }}
YML
defaults_case 1 "a flow mapping fails" key <<'YML'
name: bad
inputs: { key: { default: "${{ secrets.KEY }}" } }
YML
defaults_case 1 "a default that reads github fails too" token <<'YML'
name: bad
inputs:
  token:
    default: ${{ github.token }}
YML
defaults_case 1 "a duplicate default key fails" "" <<'YML'
name: bad
inputs:
  key:
    default: ${{ secrets.KEY }}
    default: ""
YML
defaults_case 2 "a file that is not YAML fails" "" <<'YML'
inputs: [
YML
defaults_case 0 "a description that names vars or secrets passes" "" <<'YML'
name: good
inputs:
  app-id:
    description: Pass ${{ vars.READER_APP_ID }} or ${{ secrets['KEY'] }} from the workflow.
    default: ""
runs:
  using: composite
  steps:
    - shell: bash
      env:
        V: ${{ inputs.app-id }}
      run: echo "$V"
YML
defaults_case 0 "an inline comment after the default passes" "" <<'YML'
name: good
inputs:
  key:
    default: "" # Pass ${{ secrets.KEY }} from the workflow.
YML

# check-discipline.yml must run the guard on a change to any action.
cd_wf="$here/../../workflows/check-discipline.yml"
if awk '/^on:/ { on = 1 } on && /^[^[:space:]#]/ && !/^on:/ { on = 0 } on' "$cd_wf" | grep -Eq '^[[:space:]]+- "?\.github/actions/\*\*"?[[:space:]]*$'; then
  echo "ok   check-discipline.yml runs on each change under .github/actions/"; pass=$((pass + 1))
else
  echo "FAIL check-discipline.yml runs on each change under .github/actions/"; fail=$((fail + 1))
fi

actions=()
while IFS= read -r -d '' file; do actions+=("$file"); done < <(find "$here/.." -name action.yml -print0)
if out="$(python3 -I "$here/action-defaults.py" "${actions[@]}" 2>&1)"; then
  echo "ok   action-defaults: no michelin action input reads vars or secrets"; pass=$((pass + 1))
else
  echo "FAIL action-defaults: no michelin action input reads vars or secrets"; fail=$((fail + 1))
  printf '%s\n' "$out" | awk '{ print "       " $0 }'
fi

echo
echo "discipline-gates selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
