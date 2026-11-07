#!/usr/bin/env bash
# Offline proof for run.sh through real pushes: a clone whose core.hooksPath points at shims/, set in the clone by
# install.sh or globally as the workbench image and Codespace do, runs every pre-push script, then the clone's own
# .git/hooks pre-push and a committed .githooks/pre-push. run.sh must never chain back into shims/, which would call
# it again without end. A missing secret-guard.sh fails closed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=../lib/host.sh
. "$ROOT/lib/host.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passes=0 failures=0
pass() { printf 'ok: %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
for v in $(env | sed -n 's/^\(GIT_CONFIG[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.name selftest; git config --global user.email selftest@example.com
git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/clone" 2>/dev/null
cd "$tmp/clone" || exit 1
pw="$(printf 'k%.0s' {1..12})"

# push <name>: a commit on its own branch; sets rc and err. A run.sh that loops is stopped after 20 seconds (rc 124).
push() {
  git checkout -q -b "$1" origin/main 2>/dev/null || git checkout -q -b "$1"
  printf '%s\n' "${2:-ok}" > "$1.txt"; git add -A; git commit -q -m "$1"
  err="$(host_timeout 20 git push -q origin "$1" 2>&1)"; rc=$?
}
git commit -q --allow-empty -m base && git push -q --no-verify origin HEAD:main

bash "$ROOT/hooks/install.sh" "$tmp/clone" >/dev/null
push clean
[ "$rc" = 0 ] && pass "a clean push through the clone's hooksPath finishes" || fail "clean push through install.sh: rc=$rc err=[$err]"
printf '#!/bin/sh\necho own >> "%s/own.log"\n' "$tmp" > .git/hooks/pre-push; chmod +x .git/hooks/pre-push
push chained
[ "$rc" = 0 ] && [ "$(cat "$tmp/own.log" 2>/dev/null)" = own ] && pass "the clone's own .git/hooks pre-push runs once after the michelin scripts" || fail "own hook: rc=$rc log=[$(cat "$tmp/own.log" 2>/dev/null)] err=[$err]"
rm -f .git/hooks/pre-push
mkdir -p .githooks
printf '#!/bin/sh\necho committed >> "%s/committed.log"\n' "$tmp" > .githooks/pre-push; chmod +x .githooks/pre-push
push committed-hook
[ "$rc" = 0 ] && [ "$(cat "$tmp/committed.log" 2>/dev/null)" = committed ] && pass "a committed .githooks/pre-push runs once after the michelin scripts" || fail "committed hook: rc=$rc log=[$(cat "$tmp/committed.log" 2>/dev/null)] err=[$err]"
rm -rf .githooks
push leaked "DATABASE_URL=postgres://app:${pw}@db/app"
[ "$rc" = 1 ] && grep -q 'BLOCKED' <<<"$err" && pass "a credential is refused through the shim" || fail "credential: rc=$rc err=[$err]"

# Fail closed: hide secret-guard.sh from a copy of the hooks tree the clone points at.
cp -a "$ROOT/hooks" "$tmp/hooks-missing"
rm -f "$tmp/hooks-missing/pre-push/secret-guard.sh"
git config --unset core.hooksPath || true
git config core.hooksPath "$tmp/hooks-missing/shims"
push missing-guard
[ "$rc" = 1 ] && grep -q 'BLOCKED: .*secret-guard.sh' <<<"$err" && pass "a missing secret-guard.sh fails closed" || fail "missing guard: rc=$rc err=[$err]"

git config --unset core.hooksPath
git config --global core.hooksPath "$ROOT/hooks/shims"
push global
[ "$rc" = 0 ] && pass "a clean push through a global hooksPath finishes" || fail "clean push through global hooksPath: rc=$rc err=[$err]"
push global-leak "DATABASE_URL=postgres://app:${pw}@db/app"
[ "$rc" = 1 ] && pass "a credential is refused through a global hooksPath" || fail "global credential: rc=$rc err=[$err]"

# install.sh --global --check against the path we just set.
out="$(bash "$ROOT/hooks/install.sh" --global --check 2>&1)"; code=$?
[ "$code" = 0 ] && grep -q "ok: global hooks -> $ROOT/hooks/shims" <<<"$out" && pass "install.sh --global --check accepts the set path" || fail "install --global --check: exit $code $out"

# install.sh refuses a repo that already has a foreign hooksPath (husky / lefthook).
git config --unset --global core.hooksPath || true
git -C "$tmp/clone" config --local core.hooksPath .husky/_
out="$(bash "$ROOT/hooks/install.sh" "$tmp/clone" 2>&1)"; code=$?
[ "$code" = 1 ] && grep -q "has core.hooksPath set to '.husky/_'" <<<"$out" && pass "install.sh refuses to overwrite a husky hooksPath" || fail "husky refuse: exit $code $out"
git -C "$tmp/clone" config --unset --local core.hooksPath

# install.sh takes over a repo that points at its own committed .githooks; run.sh still chains to them.
git -C "$tmp/clone" config --local core.hooksPath .githooks
out="$(bash "$ROOT/hooks/install.sh" "$tmp/clone" 2>&1)"; code=$?
[ "$code" = 0 ] && [ "$(git -C "$tmp/clone" config --local --get core.hooksPath)" = "$ROOT/hooks/shims" ] \
  && pass "install.sh takes over a .githooks hooksPath (run.sh chains to it)" || fail ".githooks takeover: exit $code $out"

# commit-msg: the agent-trailer strip runs, then the repo's committed commit-msg hook.
mkdir -p .githooks
printf '#!/bin/sh\ncp "$1" "%s/committed-msg"\n' "$tmp" > .githooks/commit-msg; chmod +x .githooks/commit-msg
git checkout -q -b trailer origin/main
printf 'x\n' > trailer.txt; git add trailer.txt
git commit -q -m $'trailer\n\nCo-Authored-By: Claude <x@example.invalid>\nCo-Authored-By: Ada <ada@example.com>'
msg="$(git log -1 --format=%B)"
if ! grep -qi 'co-authored-by: claude' <<<"$msg" && grep -q 'Co-Authored-By: Ada' <<<"$msg" \
  && grep -q 'Co-Authored-By: Ada' "$tmp/committed-msg" 2>/dev/null && ! grep -qi claude "$tmp/committed-msg"; then
  pass "commit-msg strips an agent trailer, keeps a human one, then runs the committed hook"
else
  fail "commit-msg: msg=[$msg] committed=[$(cat "$tmp/committed-msg" 2>/dev/null)]"
fi
rm -rf .githooks
git -C "$tmp/clone" config --unset --local core.hooksPath

# The image's system hooksPath: no local or global setting, only /etc/gitconfig (here a file).
sys="$tmp/system-gitconfig"
git config --file "$sys" core.hooksPath "$ROOT/hooks/shims"
( unset GIT_CONFIG_NOSYSTEM; export GIT_CONFIG_SYSTEM="$sys"
  push system-clean; [ "$rc" = 0 ] || exit 11
  push system-leak "DATABASE_URL=postgres://app:${pw}@db/app"; [ "$rc" = 1 ] && grep -q BLOCKED <<<"$err" || exit 12
  bash "$ROOT/hooks/install.sh" --system --check >/dev/null || exit 13 )
code=$?
[ "$code" = 0 ] && pass "a system hooksPath (the workbench image) guards a push and install.sh --system --check sees it" || fail "system hooksPath: code $code"

# Worker sandboxes pin core.hooksPath through GIT_CONFIG_* (digio-skills dispatch). That wins over the system and
# global path, so the michelin shim does not also run: the worker's own hook calls the guard once.
mkdir -p "$tmp/worker-hooks"
printf '#!/bin/sh\necho worker >> "%s/worker.log"\ncat >/dev/null\n' "$tmp" > "$tmp/worker-hooks/pre-push"; chmod +x "$tmp/worker-hooks/pre-push"
git config --global core.hooksPath "$ROOT/hooks/shims"
( export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$tmp/worker-hooks"
  push worker-pin "DATABASE_URL=postgres://app:${pw}@db/app"; [ "$rc" = 0 ] || exit 21 )
code=$?
[ "$code" = 0 ] && [ "$(cat "$tmp/worker.log" 2>/dev/null)" = worker ] \
  && pass "a GIT_CONFIG_* worker hooksPath replaces the michelin shim (no double run; the worker hook owns the guard)" \
  || fail "worker pin: code $code log=[$(cat "$tmp/worker.log" 2>/dev/null)]"
git config --unset --global core.hooksPath

# install.sh fails closed when the guard is missing.
out="$(bash "$tmp/hooks-missing/install.sh" --global 2>&1)"; code=$?
[ "$code" = 1 ] && grep -q 'missing or unreadable' <<<"$out" && pass "install.sh fails closed when secret-guard.sh is missing" || fail "install missing guard: exit $code $out"

printf '\nrun selftest: %d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
