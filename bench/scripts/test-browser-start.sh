#!/usr/bin/env bash
# Starts test-browser: a display, a viewer for a person and a Playwright MCP server for an agent.
set -euo pipefail

display="${TEST_BROWSER_DISPLAY:-:1}"
geometry="${TEST_BROWSER_GEOMETRY:-1440x900}"
view_port="${TEST_BROWSER_VIEW_PORT:-6080}"
mcp_port="${TEST_BROWSER_MCP_PORT:-8931}"
data="${TEST_BROWSER_DATA:-$HOME/data}"
novnc="${TEST_BROWSER_NOVNC_DIR:-/usr/share/novnc}"

fail() {
  echo "test-browser-start: $*" >&2
  exit 1
}

for tool in Xvnc openbox websockify playwright-mcp; do
  command -v "$tool" >/dev/null || fail "missing tool: $tool"
done
[ -f "$novnc/vnc.html" ] || fail "missing viewer page: $novnc/vnc.html"

mkdir -p "$data/profile" "$data/output"
vnc_port=$((5900 + ${display#:}))
declare -A names

# The viewer has no password. Only the tailnet serve and the network of the bench reach these ports.
Xvnc "$display" -geometry "$geometry" -depth 24 -SecurityTypes None -localhost -AlwaysShared &
names[$!]="Xvnc"
for _ in $(seq 50); do
  [ -S "/tmp/.X11-unix/X${display#:}" ] && break
  sleep 0.1
done
[ -S "/tmp/.X11-unix/X${display#:}" ] || fail "display $display did not start"

DISPLAY="$display" openbox &
names[$!]="openbox"

websockify --web "$novnc" "0.0.0.0:$view_port" "127.0.0.1:$vnc_port" &
names[$!]="websockify"

mcp_args=(
  --browser chromium
  --host 0.0.0.0
  --port "$mcp_port"
  --user-data-dir "$data/profile"
  --output-dir "$data/output"
  --viewport-size "${geometry/x/,}"
  --shared-browser-context
)
[ -n "${TEST_BROWSER_MCP_ALLOWED_HOSTS:-}" ] && mcp_args+=(--allowed-hosts "$TEST_BROWSER_MCP_ALLOWED_HOSTS")
[ -n "${TEST_BROWSER_ALLOWED_ORIGINS:-}" ] && mcp_args+=(--allowed-origins "$TEST_BROWSER_ALLOWED_ORIGINS")
[ -n "${TEST_BROWSER_SECRETS_FILE:-}" ] && mcp_args+=(--secrets "$TEST_BROWSER_SECRETS_FILE")
[ "${TEST_BROWSER_NO_SANDBOX:-}" = 1 ] && mcp_args+=(--no-sandbox)

DISPLAY="$display" playwright-mcp "${mcp_args[@]}" &
names[$!]="playwright-mcp"

echo "test-browser-start: viewer on port $view_port (/vnc.html?autoconnect=1&resize=scale), MCP on port $mcp_port (/mcp)"

trap 'kill "${!names[@]}" 2>/dev/null || true' EXIT
dead=0
wait -n -p dead "${!names[@]}" || true
fail "${names[$dead]:-a process} stopped; test-browser stops with it"
