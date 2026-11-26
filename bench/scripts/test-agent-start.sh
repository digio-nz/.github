#!/usr/bin/env bash
# The command of test-agent: links the skills of one preset, writes the agent brief, checks the link to test-browser,
# then runs the command given, or waits. A test is one `claude -p` run in this container.
set -euo pipefail

skills="${TEST_AGENT_SKILLS_ROOT:-/opt/digio/skills}"
michelin="${TEST_AGENT_MICHELIN_ROOT:-/opt/digio/michelin}"
preset="${TEST_AGENT_PRESET:-}"
mcp="${TEST_AGENT_MCP_URL:-http://test-browser:8931/mcp}"
tries="${TEST_AGENT_MCP_TRIES:-60}"

fail() {
  echo "FAIL: test-agent: $*" >&2
  exit 1
}

[ -n "$preset" ] || fail "TEST_AGENT_PRESET is not set; name the skills preset of the test agent"
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ] \
  || fail "no model credential; set CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY"
# The model credential is the one credential of this container. A credential of another system gives the agent that system.
for name in GH_TOKEN GITHUB_TOKEN NODE_AUTH_TOKEN OP_SERVICE_ACCOUNT_TOKEN VERCEL_TOKEN TS_AUTH_KEY; do
  [ -z "${!name:-}" ] || fail "$name is set; the test agent holds no credential of another system"
done
[ -f "$skills/lib/skill-links.sh" ] || fail "no digio-skills checkout at $skills"
[ -f "$michelin/scripts/install-briefs.sh" ] || fail "no digio-michelin checkout at $michelin"

bash "$skills/lib/skill-links.sh" apply "$preset" claude_code || fail "the skills of the preset $preset are not linked"
bash "$michelin/scripts/install-briefs.sh" apply --quiet || fail "the agent brief is not written"

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test-agent-start","version":"0"}}}'
ready=0
for _ in $(seq "$tries"); do
  if curl -fsS -m 10 -o /dev/null -X POST "$mcp" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' -d "$init" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || fail "the MCP server of test-browser at $mcp did not answer in $tries tries"

echo "test-agent: ready; preset $preset, browser tools at $mcp"
[ "$#" -gt 0 ] || set -- sleep infinity
exec "$@"
