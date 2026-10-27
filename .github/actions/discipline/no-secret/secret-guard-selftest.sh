#!/usr/bin/env bash
# Offline proof for pre-push/secret-guard.sh: real pre-push ref lists against
# scratch repositories. Credentials are refused with the value redacted,
# placeholders and removals pass, new refs scan from the empty tree, deletions
# are skipped, a credential plus a binary file is refused,
# ++ and +++ hunk content is scanned, a NUL before a credential on the same added
# line is refused even when awk truncates at NUL, invalid UTF-8 bytes under a
# UTF-8 locale pass when they hold no credential and still block one, awk, tr,
# the added-line read, grep, and each mktemp fail closed, and a guard whose
# pattern matches nothing fails these cases.
#
# Fixture credentials are assembled at run time so this file never matches the
# guard's own pattern; the factory must be able to push itself.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd -P)"
HOOK="$(cd "$(dirname "$0")" && pwd -P)/secret-guard.sh"
# A user locale is often UTF-8. BSD tr then rejects a byte such as 0xff.
# Every guard run inherits this locale so the tests match that case.
utf8_locale=C.UTF-8
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passes=0 failures=0
pass() { printf 'ok: %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

zero=0000000000000000000000000000000000000000
pw='Zx9Qw3Er7Ty1' # twelve alphanumerics
uri="postgres://app:${pw}@host/db"
tok='Ab3dEf7hJk'
npg="npg_${tok}"
placeholder='postgres://user:password@localhost/db'

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email selftest@example.com
git -C "$repo" config user.name selftest
# commit <file> <content>: prints the new commit sha.
commit() {
  printf '%s\n' "$2" > "$repo/$1"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "set $1"
  git -C "$repo" rev-parse HEAD
}

base=$(commit README.md 'scratch')
with_uri=$(git -C "$repo" checkout -q -b uri "$base" && commit env.txt "DATABASE_URL=$uri")
with_npg=$(git -C "$repo" checkout -q -b npg "$base" && commit env.txt "PGPASSWORD=$npg")
with_placeholder=$(git -C "$repo" checkout -q -b placeholder "$base" && commit env.txt "DATABASE_URL=$placeholder")
removed=$(git -C "$repo" checkout -q -b removed "$with_uri" && commit env.txt 'DATABASE_URL=from-the-secret-manager')
later=$(git -C "$repo" checkout -q -b later "$with_uri" && commit notes.txt 'harmless')
excluded=$(git -C "$repo" checkout -q -b excluded "$base" && mkdir -p "$repo/.githooks" && commit .githooks/pre-push "# $uri")
# A credential added in one commit and deleted in the next: the tip's tree is clean, the pushed history is not.
deleted=$(git -C "$repo" checkout -q -b deleted "$with_uri" && commit env.txt 'DATABASE_URL=from-the-secret-manager')
# The same through a merge: the side branch adds and deletes it, then merges into a clean branch.
git -C "$repo" checkout -q -b side "$deleted" && commit side.txt 'side work' >/dev/null
merged=$(git -C "$repo" checkout -q -b merged "$base" && commit main.txt 'main work' >/dev/null && git -C "$repo" merge -q --no-edit side >/dev/null && git -C "$repo" rev-parse HEAD)
# A side branch that leaves no lasting change: it adds the credential, removes the file, and merges with --no-ff.
# The merge's tree equals its first parent's, so a path-limited log simplifies the side branch away.
git -C "$repo" checkout -q -b vanish "$base"; printf 'DATABASE_URL=%s\n' "$uri" > "$repo/vanish.env"
git -C "$repo" add -A; git -C "$repo" commit -q -m add; git -C "$repo" rm -q vanish.env; git -C "$repo" commit -q -m remove
vanished=$(git -C "$repo" checkout -q -b vanished "$base" && git -C "$repo" merge -q --no-ff --no-edit vanish >/dev/null && git -C "$repo" rev-parse HEAD)
# A credential line and a file with NUL bytes in one push: GNU grep otherwise treats the
# diff as binary, prints only "binary file matches", and the guard exits 0.
git -C "$repo" checkout -q -b with-bin "$base"
printf 'PGPASSWORD=%s\n' "$npg" > "$repo/env.txt"
printf 'a\0b' > "$repo/blob.bin"
git -C "$repo" add -A
git -C "$repo" commit -q -m 'credential and binary'
with_bin=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q -b bin-only "$base"
printf 'a\0b' > "$repo/blob.bin"
git -C "$repo" add -A
git -C "$repo" commit -q -m 'binary only'
bin_only=$(git -C "$repo" rev-parse HEAD)
# An added file line that starts with ++ becomes +++ in the diff, which a
# prefix header filter dropped, so a credential on that line escaped the scan.
git -C "$repo" checkout -q -b plusplus "$base"
printf '++PGPASSWORD=%s\n' "$npg" > "$repo/odd.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m 'plusplus credential'
plusplus=$(git -C "$repo" rev-parse HEAD)
# Two pluses and a space: the hunk line is "+++ PGPASSWORD=", which looks like
# a unified-diff file header if the scan uses prefixes instead of diff structure.
git -C "$repo" checkout -q -b plusplus-space "$base"
printf '++ PGPASSWORD=%s\n' "$npg" > "$repo/odd.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m 'plusplus space credential'
plusplus_space=$(git -C "$repo" rev-parse HEAD)
# A hunk that holds a +++ content line and a credential on another line.
git -C "$repo" checkout -q -b hunk-triple "$base"
printf 'hello\n++ PGPASSWORD=%s\n+++ b/looks-like-a-header\n' "$npg" > "$repo/odd.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m 'hunk triple credential'
hunk_triple=$(git -C "$repo" rev-parse HEAD)
# One True Awk prints only the bytes before the first NUL in a record, so a
# credential after a NUL on the same added line would skip the scan.
git -C "$repo" checkout -q -b nul-before "$base"
printf 'prefix\0PGPASSWORD=%s\n' "$npg" > "$repo/fixture.bin"
git -C "$repo" add -A
git -C "$repo" commit -q -m 'nul before credential'
nul_before=$(git -C "$repo" rev-parse HEAD)
# BSD tr under UTF-8 rejects a byte such as 0xff ("Illegal byte sequence").
# A harmless file must pass; a credential beside it must still be refused.
git -C "$repo" checkout -q -b bin-invalid "$base"
printf 'a\377b\0c\n' > "$repo/blob.bin"
git -C "$repo" add -A
git -C "$repo" commit -q -m 'invalid utf8 binary only'
bin_invalid=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q -b with-invalid "$base"
printf 'PGPASSWORD=%s\n' "$npg" > "$repo/env.txt"
printf 'a\377b\0c\n' > "$repo/blob.bin"
git -C "$repo" add -A
git -C "$repo" commit -q -m 'credential and invalid utf8 binary'
with_invalid=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q main
unknown=0123456789abcdef0123456789abcdef01234567

# run <hook> <ref list>: sets rc and err from the guard run inside the repo.
run() {
  err=$(
    export LC_ALL="$utf8_locale"
    cd "$repo" || exit 1
    printf '%s\n' "$2" | sh "$1" origin git@example.com:o/r.git 2>&1 >/dev/null
  )
  rc=$?
}
line() { printf 'refs/heads/%s %s refs/heads/%s %s\n' "$1" "$2" "$1" "$3"; }

# The cases a guard must refuse, run against the real guard and, at the end,
# against a mutant whose pattern matches nothing. refused <hook> counts misses.
refused() {
  local hook="$1" missed=0
  run "$hook" "$(line uri "$with_uri" "$base")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  run "$hook" "$(line npg "$with_npg" "$base")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  run "$hook" "$(line uri "$later" "$zero")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  run "$hook" "$(line uri "$later" "$unknown")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  run "$hook" "$(line deleted "$deleted" "$base")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  run "$hook" "$(line with-bin "$with_bin" "$base")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  run "$hook" "$(line plusplus "$plusplus" "$base")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  run "$hook" "$(line plusplus-space "$plusplus_space" "$base")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  run "$hook" "$(line hunk-triple "$hunk_triple" "$base")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  run "$hook" "$(line nul-before "$nul_before" "$base")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  run "$hook" "$(line with-invalid "$with_invalid" "$base")"
  [ "$rc" -eq 1 ] || missed=$((missed + 1))
  return "$missed"
}

run "$HOOK" "$(line uri "$with_uri" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'DATABASE_URL=postgres://app:<redacted>@host/db' <<<"$err" && ! grep -qF "$pw" <<<"$err"; then
  pass "a URI with a twelve-character password is refused and the password redacted"
else fail "URI credential: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line npg "$with_npg" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'PGPASSWORD=npg_<redacted>' <<<"$err" && ! grep -qF "$tok" <<<"$err"; then
  pass "an npg_ token is refused and the token redacted"
else fail "npg_ token: rc=$rc err=[$err]"; fi

if grep -qF 'refs/heads/npg' <<<"$err" && grep -qF 'git push --no-verify' <<<"$err"; then
  pass "the refusal names the ref and the --no-verify exception"
else fail "refusal text: err=[$err]"; fi

run "$HOOK" "$(line with-bin "$with_bin" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'PGPASSWORD=npg_<redacted>' <<<"$err" && ! grep -qF "$tok" <<<"$err" && ! grep -qi 'binary file' <<<"$err"; then
  pass "a credential plus a binary file in one push is refused and the line named"
else fail "credential plus binary: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line bin-only "$bin_only" "$base")"
if [ "$rc" -eq 0 ] && [ -z "$err" ]; then
  pass "a binary file with no credential passes"
else fail "binary only: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line bin-invalid "$bin_invalid" "$base")"
if [ "$rc" -eq 0 ] && [ -z "$err" ]; then
  pass "a binary file with invalid UTF-8 bytes and no credential passes"
else fail "invalid-byte binary only: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line with-invalid "$with_invalid" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'PGPASSWORD=npg_<redacted>' <<<"$err" && ! grep -qF "$tok" <<<"$err" && ! grep -qi 'binary file' <<<"$err"; then
  pass "a credential plus invalid UTF-8 bytes is refused and the line named"
else fail "credential plus invalid bytes: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line plusplus "$plusplus" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'PGPASSWORD=npg_<redacted>' <<<"$err" && ! grep -qF "$tok" <<<"$err"; then
  pass "an added line that starts with ++ and a credential is refused and the line named"
else fail "plusplus header bypass: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line plusplus-space "$plusplus_space" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'PGPASSWORD=npg_<redacted>' <<<"$err" && ! grep -qF "$tok" <<<"$err"; then
  pass "an added line ++ PGPASSWORD= is refused and the line named"
else fail "plusplus space bypass: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line hunk-triple "$hunk_triple" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'PGPASSWORD=npg_<redacted>' <<<"$err" && ! grep -qF "$tok" <<<"$err"; then
  pass "a +++ content line inside a hunk does not hide a credential"
else fail "hunk triple plus: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line nul-before "$nul_before" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'PGPASSWORD=npg_<redacted>' <<<"$err" && ! grep -qF "$tok" <<<"$err"; then
  pass "a NUL immediately before a credential on the same added line is refused"
else fail "nul before credential: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line placeholder "$with_placeholder" "$base")"
if [ "$rc" -eq 0 ] && [ -z "$err" ]; then pass "a placeholder password passes"; else fail "placeholder: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line uri "$removed" "$with_uri")"
if [ "$rc" -eq 0 ]; then pass "removing a credential line passes"; else fail "removal: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line uri "$later" "$with_uri")"
if [ "$rc" -eq 0 ]; then pass "an existing ref scans only what the push adds"; else fail "incremental: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line uri "$later" "$zero")"
if [ "$rc" -eq 1 ] && grep -qF '<redacted>' <<<"$err"; then
  pass "a new ref scans from the empty tree and finds a credential in an earlier commit"
else fail "new ref: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line uri "$later" "$unknown")"
if [ "$rc" -eq 1 ]; then pass "an unfetched remote tip scans from the empty tree"; else fail "unknown remote: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line deleted "$deleted" "$base")"
if [ "$rc" -eq 1 ] && grep -qF '<redacted>' <<<"$err"; then
  pass "a credential deleted in a later commit is refused: the push still sends the commit that adds it"
else fail "added then deleted: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line merged "$merged" "$base")"
if [ "$rc" -eq 1 ]; then pass "a credential added and deleted on a merged side branch is refused"; else fail "merge history: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line vanished "$vanished" "$base")"
if [ "$rc" -eq 1 ]; then pass "a merged side branch with no lasting change is still scanned"; else fail "vanished merge: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line deleted "$deleted" "$zero")"
if [ "$rc" -eq 1 ]; then pass "a new ref with no remote-tracking refs scans every commit it sends"; else fail "new ref, no remotes, added then deleted: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line deleted "$deleted" "$with_uri")"
if [ "$rc" -eq 0 ]; then pass "a push after the remote already has the credential commit scans only what it adds"; else fail "after remote: rc=$rc err=[$err]"; fi

remote_repo="$tmp/remote-tracking"
git clone -q "$repo" "$remote_repo" 2>/dev/null
git -C "$remote_repo" config user.email selftest@example.com
git -C "$remote_repo" config user.name selftest
git -C "$remote_repo" checkout -q -b fresh origin/deleted
printf 'more\n' > "$remote_repo/more.txt"; git -C "$remote_repo" add -A; git -C "$remote_repo" commit -q -m more
fresh_tip=$(git -C "$remote_repo" rev-parse HEAD)
err=$(cd "$remote_repo" && printf 'refs/heads/fresh %s refs/heads/fresh %s\n' "$fresh_tip" "$zero" | sh "$HOOK" origin "$repo" 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then pass "a new ref skips commits already on a remote-tracking ref"; else fail "new ref over published history: rc=$rc err=[$err]"; fi
printf 'DATABASE_URL=%s\n' "$uri" > "$remote_repo/x.txt"; git -C "$remote_repo" add -A; git -C "$remote_repo" commit -q -m add
git -C "$remote_repo" rm -q x.txt; git -C "$remote_repo" commit -q -m drop
fresh_tip=$(git -C "$remote_repo" rev-parse HEAD)
err=$(cd "$remote_repo" && printf 'refs/heads/fresh %s refs/heads/fresh %s\n' "$fresh_tip" "$zero" | sh "$HOOK" origin "$repo" 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 1 ]; then pass "a new ref scans each commit it adds over the remote-tracking refs"; else fail "new ref add then drop: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line uri "$zero" "$with_uri")"
if [ "$rc" -eq 0 ] && [ -z "$err" ]; then pass "a ref deletion is skipped"; else fail "deletion: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line uri "$with_uri" "$base")
$(line placeholder "$with_placeholder" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'refs/heads/uri' <<<"$err" && ! grep -qF 'refs/heads/placeholder' <<<"$err"; then
  pass "one credential among several refs refuses the push and names its ref"
else fail "multiple refs: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line excluded "$excluded" "$base")"
if [ "$rc" -eq 0 ]; then pass "a repo's own .githooks are not scanned"; else fail "excluded: rc=$rc err=[$err]"; fi

err=$(cd "$repo" && line npg "$with_npg" "$base" | tr -d '\n' | sh "$HOOK" 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ]; then pass "a final ref line without its newline is still scanned"; else fail "unterminated line: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line uri "$unknown" "$base")"
if [ "$rc" -eq 2 ] && grep -qF 'could not diff' <<<"$err"; then
  pass "an unreadable diff blocks the push rather than passing it"
else fail "unreadable diff: rc=$rc err=[$err]"; fi

run "$HOOK" "$(line uri "$unknown" "$base")
$(line npg "$with_npg" "$base")"
if [ "$rc" -eq 2 ] && grep -qF 'refs/heads/npg' <<<"$err"; then
  pass "an unreadable diff still exits 2 when a later ref has a hit"
else fail "unreadable then hit: rc=$rc err=[$err]"; fi

# Fail awk, tr, the added-line read, the credential grep, and each mktemp on
# PATH. Each wrapper fails only its own command. The hook must exit 2 with
# a diagnostic; a later command must still run if an earlier check is gone.
# trunc-awk keeps the bytes before the first NUL in each record, like One True
# Awk, then runs the real awk. The NUL-before-credential case must still refuse.
real_awk=$(command -v awk)
real_grep=$(command -v grep)
real_mktemp=$(command -v mktemp)
real_python=$(command -v python3)
real_tr=$(command -v tr)
if [ -z "$real_python" ]; then
  echo "FAIL: python3 is required for the truncating awk wrapper" >&2
  exit 2
fi
run_path() {
  # run_path <bindir> [ref-list]
  local refs="${2:-$(line npg "$with_npg" "$base")}"
  err=$(
    export PATH="$1:$PATH" LC_ALL="$utf8_locale"
    cd "$repo" || exit 1
    printf '%s\n' "$refs" | sh "$HOOK" origin git@example.com:o/r.git 2>&1 >/dev/null
  )
  rc=$?
}
mkdir -p "$tmp/fail-awk"
cat > "$tmp/fail-awk/awk" <<EOF
#!/bin/sh
echo 'awk: simulated I/O failure' >&2
exit 1
EOF
chmod +x "$tmp/fail-awk/awk"
run_path "$tmp/fail-awk"
if [ "$rc" -eq 2 ] && grep -q 'simulated I/O failure' <<<"$err"; then
  pass "a failure in awk blocks the push"
else fail "awk failure: rc=$rc err=[$err]"; fi

mkdir -p "$tmp/trunc-awk"
cat > "$tmp/trunc-awk/awk" <<EOF
#!/bin/sh
exec '${real_python}' - '${real_awk}' "\$@" <<'PY'
import os, subprocess, sys, tempfile
real_awk = sys.argv[1]
args = sys.argv[2:]
if not args:
    os.execv(real_awk, [real_awk])
infile = args[-1]
if os.path.isfile(infile):
    with open(infile, 'rb') as f:
        data = f.read()
    out = b'\n'.join(p.split(b'\0', 1)[0] for p in data.split(b'\n'))
    fd, stripped = tempfile.mkstemp(prefix='trunc-awk-')
    try:
        os.write(fd, out)
        os.close(fd)
        fd = None
        rc = subprocess.call([real_awk] + args[:-1] + [stripped])
    finally:
        if fd is not None:
            os.close(fd)
        try:
            os.unlink(stripped)
        except OSError:
            pass
    sys.exit(rc)
os.execv(real_awk, [real_awk] + args)
PY
EOF
chmod +x "$tmp/trunc-awk/awk"
run_path "$tmp/trunc-awk" "$(line nul-before "$nul_before" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'PGPASSWORD=npg_<redacted>' <<<"$err" && ! grep -qF "$tok" <<<"$err"; then
  pass "a NUL immediately before a credential is refused when awk truncates at NUL"
else fail "truncating awk: rc=$rc err=[$err]"; fi

mkdir -p "$tmp/fail-tr"
cat > "$tmp/fail-tr/tr" <<EOF
#!/bin/sh
if [ "\$1" = '\\000' ]; then
  echo 'tr: simulated I/O failure' >&2
  exit 1
fi
exec '${real_tr}' "\$@"
EOF
chmod +x "$tmp/fail-tr/tr"
run_path "$tmp/fail-tr"
if [ "$rc" -eq 2 ] && grep -q 'could not translate the diff' <<<"$err"; then
  pass "a failure translating NUL bytes blocks the push"
else fail "tr failure: rc=$rc err=[$err]"; fi

mkdir -p "$tmp/bsd-tr"
cat > "$tmp/bsd-tr/tr" <<EOF
#!${real_python}
import os, subprocess, sys
real_tr = '${real_tr}'
args = sys.argv[1:]
locale = os.environ.get('LC_ALL') or os.environ.get('LC_CTYPE') or os.environ.get('LANG') or ''
if locale in ('C', 'POSIX'):
    os.execv(real_tr, [real_tr] + args)
data = sys.stdin.buffer.read()
try:
    data.decode('utf-8')
except UnicodeDecodeError:
    sys.stderr.write('tr: Illegal byte sequence\\n')
    sys.exit(1)
sys.exit(subprocess.run([real_tr] + args, input=data).returncode)
EOF
chmod +x "$tmp/bsd-tr/tr"
run_path "$tmp/bsd-tr" "$(line bin-invalid "$bin_invalid" "$base")"
if [ "$rc" -eq 0 ] && [ -z "$err" ]; then
  pass "a binary file with invalid UTF-8 bytes passes when tr is BSD-like"
else fail "bsd-tr invalid-byte binary: rc=$rc err=[$err]"; fi
run_path "$tmp/bsd-tr" "$(line with-invalid "$with_invalid" "$base")"
if [ "$rc" -eq 1 ] && grep -qF 'PGPASSWORD=npg_<redacted>' <<<"$err" && ! grep -qF "$tok" <<<"$err"; then
  pass "a credential plus invalid UTF-8 bytes is refused when tr is BSD-like"
else fail "bsd-tr credential plus invalid bytes: rc=$rc err=[$err]"; fi

mkdir -p "$tmp/fail-cat"
cat > "$tmp/fail-cat/cat" <<EOF
#!/bin/sh
echo 'cat: simulated I/O failure' >&2
exit 1
EOF
chmod +x "$tmp/fail-cat/cat"
run_path "$tmp/fail-cat"
if [ "$rc" -eq 2 ] && grep -q 'could not read the added lines' <<<"$err"; then
  pass "a failure reading the added lines blocks the push"
else fail "added-line read failure: rc=$rc err=[$err]"; fi

mkdir -p "$tmp/fail-grep"
cat > "$tmp/fail-grep/grep" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    *npg_*)
      echo 'grep: simulated I/O failure' >&2
      exit 2
      ;;
  esac
done
exec '${real_grep}' "\$@"
EOF
chmod +x "$tmp/fail-grep/grep"
run_path "$tmp/fail-grep"
if [ "$rc" -eq 2 ] && grep -q 'simulated I/O failure' <<<"$err"; then
  pass "a failure in the credential grep blocks the push"
else fail "credential grep failure: rc=$rc err=[$err]"; fi

write_mktemp_nth() {
  # write_mktemp_nth <bindir> <n> <countfile>: fail only the Nth mktemp call.
  mkdir -p "$1"
  cat > "$1/mktemp" <<EOF
#!/bin/sh
c=0
if [ -f '$3' ]; then
  c=\$(cat '$3')
fi
c=\$((c + 1))
printf '%s\n' "\$c" > '$3'
if [ "\$c" -eq $2 ]; then
  echo 'mktemp: simulated failure' >&2
  exit 1
fi
exec '${real_mktemp}' "\$@"
EOF
  chmod +x "$1/mktemp"
}

write_mktemp_nth "$tmp/fail-mk1" 1 "$tmp/mktemp-count-1"
run_path "$tmp/fail-mk1"
if [ "$rc" -eq 2 ] && grep -q 'could not create a temporary file' <<<"$err"; then
  pass "a failure creating the first temporary file blocks the push"
else fail "first mktemp failure: rc=$rc err=[$err]"; fi

write_mktemp_nth "$tmp/fail-mk2" 2 "$tmp/mktemp-count-2"
run_path "$tmp/fail-mk2"
if [ "$rc" -eq 2 ] && grep -q 'could not create a temporary file' <<<"$err"; then
  pass "a failure creating the second temporary file blocks the push"
else fail "second mktemp failure: rc=$rc err=[$err]"; fi

# Diff settings that would hide added lines from a plain git diff.
git -C "$repo" config color.ui always
git -C "$repo" config diff.external true
printf 'env.txt -diff\n' > "$repo/.gitattributes"
run "$HOOK" "$(line npg "$with_npg" "$base")"
if [ "$rc" -eq 1 ]; then pass "colour, an external diff and a -diff attribute do not hide a credential"; else fail "diff config: rc=$rc err=[$err]"; fi
git -C "$repo" config --unset color.ui
git -C "$repo" config --unset diff.external
rm -f "$repo/.gitattributes"

mkdir -p "$repo/sub"
err=$(cd "$repo/sub" && line uri "$with_uri" "$base" | sh "$HOOK" 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ]; then pass "run from a subdirectory, the whole tree is scanned"; else fail "subdirectory: rc=$rc err=[$err]"; fi

sha256="$tmp/sha256"
if git init -q -b main --object-format=sha256 "$sha256" 2>/dev/null; then
  git -C "$sha256" config user.email selftest@example.com
  git -C "$sha256" config user.name selftest
  printf 'PGPASSWORD=%s\n' "$npg" > "$sha256/env.txt"
  git -C "$sha256" add -A && git -C "$sha256" commit -q -m env
  tip=$(git -C "$sha256" rev-parse HEAD)
  zero64=$(printf '%064d' 0)
  err=$(cd "$sha256" && printf 'refs/heads/main %s refs/heads/main %s\n' "$tip" "$zero64" | sh "$HOOK" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 1 ]; then pass "a new ref in a SHA-256 repo scans from its empty tree"; else fail "sha256 new ref: rc=$rc err=[$err]"; fi
  err=$(cd "$sha256" && printf '(delete) %s refs/heads/main %s\n' "$zero64" "$tip" | sh "$HOOK" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ]; then pass "a ref deletion in a SHA-256 repo is skipped"; else fail "sha256 deletion: rc=$rc err=[$err]"; fi
else
  fail "this git cannot create a SHA-256 repository"
fi

run "$HOOK" ""
if [ "$rc" -eq 0 ]; then pass "an empty ref list passes"; else fail "empty ref list: rc=$rc"; fi

if (cd "$ROOT" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$zero" | sh "$HOOK" 2>/dev/null); then
  pass "the factory's own tree passes, so the factory can push itself"
else fail "the guard refuses the factory's own tree"; fi

if refused "$HOOK"; then pass "every refusal case is refused"; else fail "the real guard missed $? refusal case(s)"; fi

mutant="$tmp/mutant.sh"
sed "s/^pattern=.*/pattern='\$^'/" "$HOOK" > "$mutant"
if cmp -s "$HOOK" "$mutant"; then
  fail "the mutation did not change the guard"
elif refused "$mutant"; then
  fail "a guard whose pattern matches nothing still passed every refusal case"
else
  pass "a guard whose pattern matches nothing fails the refusal cases"
fi

printf '\nsecret-guard selftest: %d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
