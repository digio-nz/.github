#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$DIR/tailnet-start.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TEST_DIR/bin"

cat > "$TEST_DIR/bin/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB

cat > "$TEST_DIR/bin/hostname" <<'STUB'
#!/usr/bin/env bash
echo selftest
STUB

cat > "$TEST_DIR/bin/tailscale" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = up ]; then
  printf '%s\n' "$*" >> "$TAILSCALE_CALLS"
  if [ "${TAILSCALE_UP_FAIL:-0}" = 1 ]; then
    echo "stub tailscale up error" >&2
    exit 42
  fi
  exit 0
fi

if [ "$1" = status ] && [ "$2" = --json ]; then
  cat <<'JSON'
{"Self":{"DNSName":"workbench-selftest.example.ts.net.","Tags":["tag:sandbox"]}}
JSON
  exit 0
fi

echo "unexpected tailscale call: $*" >&2
exit 99
STUB

chmod +x "$TEST_DIR/bin/sudo" "$TEST_DIR/bin/hostname" "$TEST_DIR/bin/tailscale"
export PATH="$TEST_DIR/bin:$PATH"
export TAILSCALE_CALLS="$TEST_DIR/calls"

missing_output="$(env -u TS_AUTH_KEY bash "$SCRIPT" 2>&1)" || fail "a missing key must not fail container startup"
grep -Fq "workbench is not on the tailnet: TS_AUTH_KEY is not set" <<< "$missing_output" || fail "a missing key was not reported"

if failure_output="$(TS_AUTH_KEY=selftest-auth-key TAILSCALE_UP_FAIL=1 bash "$SCRIPT" 2>&1)"; then
  fail "tailscale up failure returned success"
fi
grep -Fq "stub tailscale up error" <<< "$failure_output" || fail "tailscale did not print its failure"
grep -Fq "tailnet join failed" <<< "$failure_output" || fail "the join failure was not reported"

mkdir -p "$TEST_DIR/home"
# post-start.sh fails when no git hooksPath is in effect. The image names its baked hooks in the system gitconfig; this file stands in for it.
git config --file "$TEST_DIR/system.gitconfig" core.hooksPath "$(cd "$DIR/../../hooks/shims" && pwd -P)"
if ! start_output="$(HOME="$TEST_DIR/home" GIT_CONFIG_SYSTEM="$TEST_DIR/system.gitconfig" GIT_CONFIG_GLOBAL="$TEST_DIR/home/.gitconfig" TS_AUTH_KEY=selftest-auth-key TAILSCALE_UP_FAIL=1 bash "$DIR/post-start.sh" 2>&1)"; then
  fail "a tailnet failure blocked container startup"
fi
grep -Fq "tailnet: setup failed; container startup will continue" <<< "$start_output" || fail "container startup did not report the tolerated failure"

: > "$TAILSCALE_CALLS"
success_output="$(TS_AUTH_KEY=selftest-auth-key bash "$SCRIPT" 2>&1)" || fail "a valid join failed"
call="$(cat "$TAILSCALE_CALLS")"
grep -Eq '(^| )--ssh( |$)' <<< "$call" || fail "tailscale up did not enable Tailscale SSH"
grep -Fq -- '--auth-key=selftest-auth-key' <<< "$call" || fail "tailscale up did not use TS_AUTH_KEY"
grep -Fq -- '--hostname=workbench-selftest' <<< "$call" || fail "tailscale up did not set the workbench hostname"
if grep -Fq -- '--advertise-tags' <<< "$call"; then
  fail "tailscale up set a tag instead of using the auth key tag"
fi
if grep -Fq -- '--accept-routes' <<< "$call"; then
  fail "tailscale up accepted subnet routes without a consumer"
fi
grep -Fq "joined node workbench-selftest.example.ts.net. with tags tag:sandbox" <<< "$success_output" || fail "the joined node and tags were not reported"

echo "tailnet start self-test passed"
