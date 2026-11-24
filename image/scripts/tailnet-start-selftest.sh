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

# The start of the daemon is the one `sudo sh` call. The stub records it, and the daemon then answers as a node that is not joined.
cat > "$TEST_DIR/bin/sudo" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = sh ]; then
  printf '%s\n' "$*" >> "$DAEMON_CALLS"
  echo NeedsLogin > "$BACKEND_STATE"
  exit 0
fi
exec "$@"
STUB

# Prints a key for the reference of the workbench key only.
cat > "$TEST_DIR/bin/op" <<'STUB'
#!/usr/bin/env bash
if [ "${OP_FAIL:-0}" != 1 ] && [ "$*" = "read op://workbench/TS_AUTH_KEY_WORKBENCH/credential" ]; then
  echo selftest-op-key
  exit 0
fi
echo "stub op error: $*" >&2
exit 1
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
  echo Running > "$BACKEND_STATE"
  exit 0
fi

# No state file stands for no daemon.
if [ "$1" = status ] && [ "$2" = --json ]; then
  [ -s "$BACKEND_STATE" ] || exit 1
  printf '{"BackendState":"%s","Self":{"DNSName":"workbench-selftest.example.ts.net.","Tags":["tag:sandbox"]}}\n' "$(cat "$BACKEND_STATE")"
  exit 0
fi

echo "unexpected tailscale call: $*" >&2
exit 99
STUB

chmod +x "$TEST_DIR/bin/sudo" "$TEST_DIR/bin/op" "$TEST_DIR/bin/hostname" "$TEST_DIR/bin/tailscale"
export PATH="$TEST_DIR/bin:$PATH"
export TAILSCALE_CALLS="$TEST_DIR/calls" DAEMON_CALLS="$TEST_DIR/daemon-calls" BACKEND_STATE="$TEST_DIR/backend-state"
# This home has no service account file, so only TS_AUTH_KEY gives a key.
export HOME="$TEST_DIR/home"
mkdir -p "$HOME"
: > "$TAILSCALE_CALLS"; : > "$DAEMON_CALLS"

missing_output="$(env -u TS_AUTH_KEY bash "$SCRIPT" 2>&1)" || fail "a missing key must not fail container startup"
grep -Fq "workbench is not on the tailnet: TS_AUTH_KEY is not set" <<< "$missing_output" || fail "a missing key was not reported"
[ ! -s "$DAEMON_CALLS" ] || fail "a container with no key started a daemon"

echo NeedsLogin > "$BACKEND_STATE"
if failure_output="$(TS_AUTH_KEY=selftest-auth-key TAILSCALE_UP_FAIL=1 bash "$SCRIPT" 2>&1)"; then
  fail "tailscale up failure returned success"
fi
grep -Fq "stub tailscale up error" <<< "$failure_output" || fail "tailscale did not print its failure"
grep -Fq "tailnet join failed" <<< "$failure_output" || fail "the join failure was not reported"

# post-start.sh fails when no git hooksPath is in effect. The image names its baked hooks in the system gitconfig; this file stands in for it.
git config --file "$TEST_DIR/system.gitconfig" core.hooksPath "$(cd "$DIR/../../hooks/shims" && pwd -P)"
# This home has no content clone, so the start exits non-zero at the content steps. A line of those steps shows that the start went past the tailnet failure.
git config --file "$TEST_DIR/home/.gitconfig" url."file://$TEST_DIR/no-remote/".insteadOf https://github.com/
start_output="$(GIT_CONFIG_SYSTEM="$TEST_DIR/system.gitconfig" GIT_CONFIG_GLOBAL="$TEST_DIR/home/.gitconfig" TS_AUTH_KEY=selftest-auth-key TAILSCALE_UP_FAIL=1 bash "$DIR/post-start.sh" 2>&1)" || true
grep -Fq "tailnet: setup failed; container startup will continue" <<< "$start_output" || fail "container startup did not report the tolerated failure"
grep -Fq "FAIL: install-briefs: $TEST_DIR/home/.digio/michelin is missing" <<< "$start_output" || fail "a tailnet failure blocked container startup: $start_output"

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
[ ! -s "$DAEMON_CALLS" ] || fail "a container with a daemon started a second daemon"

# A node that is joined: no key reaches tailscale, because a key that has expired fails the command.
: > "$TAILSCALE_CALLS"
joined_output="$(TS_AUTH_KEY=selftest-expired-key bash "$SCRIPT" 2>&1)" || fail "a joined node failed the start: $joined_output"
[ ! -s "$TAILSCALE_CALLS" ] || fail "a joined node ran tailscale up: $(cat "$TAILSCALE_CALLS")"
grep -Fq "joined node workbench-selftest.example.ts.net. with tags tag:sandbox" <<< "$joined_output" || fail "a joined node was not reported"

# A plain container run: no daemon and no TUN device.
rm -f "$BACKEND_STATE"
: > "$TAILSCALE_CALLS"
TS_AUTH_KEY=selftest-auth-key TAILNET_START_TUN="$TEST_DIR/no-tun" bash "$SCRIPT" >/dev/null 2>&1 || fail "a join with no daemon failed"
grep -Fq "tailscaled --statedir=/var/lib/tailscale" "$DAEMON_CALLS" || fail "no daemon was started: $(cat "$DAEMON_CALLS")"
grep -Fq -- "--tun=userspace-networking" "$DAEMON_CALLS" || fail "the daemon did not use userspace networking with no TUN device"
grep -Fq -- '--auth-key=selftest-auth-key' "$TAILSCALE_CALLS" || fail "the node did not join after the daemon started"

rm -f "$BACKEND_STATE"
: > "$DAEMON_CALLS"
touch "$TEST_DIR/tun"
TS_AUTH_KEY=selftest-auth-key TAILNET_START_TUN="$TEST_DIR/tun" bash "$SCRIPT" >/dev/null 2>&1 || fail "a join with a TUN device failed"
if grep -Fq -- "--tun=userspace-networking" "$DAEMON_CALLS"; then
  fail "the daemon used userspace networking with a TUN device"
fi

# A workbench with a 1Password service account: the key comes from the item of the workbench.
mkdir -p "$HOME/.config/digio"
echo selftest-token > "$HOME/.config/digio/op-workbench"
echo NeedsLogin > "$BACKEND_STATE"
: > "$TAILSCALE_CALLS"
env -u TS_AUTH_KEY bash "$SCRIPT" >/dev/null 2>&1 || fail "a join with the 1Password key failed"
grep -Fq -- '--auth-key=selftest-op-key' "$TAILSCALE_CALLS" || fail "tailscale up did not use the key that op read: $(cat "$TAILSCALE_CALLS")"

echo NeedsLogin > "$BACKEND_STATE"
: > "$TAILSCALE_CALLS"
if op_output="$(env -u TS_AUTH_KEY OP_FAIL=1 bash "$SCRIPT" 2>&1)"; then
  fail "a failed read of the key returned success"
fi
grep -Fq "tailnet join failed: op did not read op://workbench/TS_AUTH_KEY_WORKBENCH/credential" <<< "$op_output" || fail "the failed read was not reported: $op_output"
[ ! -s "$TAILSCALE_CALLS" ] || fail "tailscale up ran with no key"

echo "tailnet start self-test passed"
