#!/usr/bin/env bash
# Offline self-test of test-agent-start.sh, with stubs for the skills checkout, the Michelin checkout and curl.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$DIR/test-agent-start.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/skills/lib" "$TEST_DIR/michelin/scripts"
cat > "$TEST_DIR/skills/lib/skill-links.sh" <<'STUB'
echo "links $*" >> "$CALLS"
[ "$2" != no-such-preset ]
STUB
cat > "$TEST_DIR/michelin/scripts/install-briefs.sh" <<'STUB'
echo "briefs $*" >> "$CALLS"
STUB
cat > "$TEST_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS"
[ "${CURL_FAIL:-0}" != 1 ]
STUB
chmod +x "$TEST_DIR/bin/curl"

export PATH="$TEST_DIR/bin:$PATH" CALLS="$TEST_DIR/calls"
export TEST_AGENT_SKILLS_ROOT="$TEST_DIR/skills" TEST_AGENT_MICHELIN_ROOT="$TEST_DIR/michelin" TEST_AGENT_MCP_TRIES=1
# A workbench names a file in BASH_ENV that sets a token in each bash.
unset BASH_ENV GH_TOKEN GITHUB_TOKEN NODE_AUTH_TOKEN OP_SERVICE_ACCOUNT_TOKEN VERCEL_TOKEN TS_AUTH_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY TEST_AGENT_PRESET

# refused <text of the failure> <variable assignment>...: the start exits non-zero with the text, and runs no command.
refused() {
  local want="$1" out
  shift
  : > "$CALLS"
  if out="$(env "$@" bash "$SCRIPT" echo started 2>&1)"; then fail "the start passed with $*: $out"; fi
  grep -Fq "FAIL: test-agent: $want" <<< "$out" || fail "with $*, the start did not report '$want': $out"
  if grep -Fxq started <<< "$out"; then fail "with $*, the start ran the command"; fi
}

refused "TEST_AGENT_PRESET is not set" ANTHROPIC_API_KEY=selftest
[ ! -s "$CALLS" ] || fail "a start with no preset did work: $(cat "$CALLS")"
refused "no model credential" TEST_AGENT_PRESET=test
for name in GH_TOKEN GITHUB_TOKEN NODE_AUTH_TOKEN OP_SERVICE_ACCOUNT_TOKEN VERCEL_TOKEN TS_AUTH_KEY; do
  refused "$name is set" TEST_AGENT_PRESET=test ANTHROPIC_API_KEY=selftest "$name=selftest"
  [ ! -s "$CALLS" ] || fail "a start with $name did work: $(cat "$CALLS")"
done
refused "no digio-skills checkout" TEST_AGENT_PRESET=test ANTHROPIC_API_KEY=selftest TEST_AGENT_SKILLS_ROOT="$TEST_DIR/none"
refused "no digio-michelin checkout" TEST_AGENT_PRESET=test ANTHROPIC_API_KEY=selftest TEST_AGENT_MICHELIN_ROOT="$TEST_DIR/none"
refused "the skills of the preset no-such-preset are not linked" TEST_AGENT_PRESET=no-such-preset ANTHROPIC_API_KEY=selftest
refused "the MCP server of test-browser at http://test-browser:8931/mcp did not answer" TEST_AGENT_PRESET=test ANTHROPIC_API_KEY=selftest CURL_FAIL=1

: > "$CALLS"
out="$(TEST_AGENT_PRESET=test CLAUDE_CODE_OAUTH_TOKEN=selftest bash "$SCRIPT" echo started 2>&1)" || fail "a valid start failed: $out"
grep -Fxq started <<< "$out" || fail "a valid start did not run the command: $out"
grep -Fxq "links apply test claude_code" "$CALLS" || fail "the start did not link the preset for Claude Code: $(cat "$CALLS")"
grep -Fxq "briefs apply --quiet" "$CALLS" || fail "the start did not write the brief: $(cat "$CALLS")"
grep -Fq "curl " "$CALLS" || fail "the start did not check the MCP server"

echo "test-agent start self-test passed"
