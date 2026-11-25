#!/usr/bin/env bash
# Starts the test bench: a display, a viewer for a person and a Playwright MCP server for an agent.
set -euo pipefail

display="${BENCH_DISPLAY:-:1}"
geometry="${BENCH_GEOMETRY:-1440x900}"
view_port="${BENCH_VIEW_PORT:-6080}"
mcp_port="${BENCH_MCP_PORT:-8931}"
data="${BENCH_DATA:-$HOME/bench}"
novnc="${BENCH_NOVNC_DIR:-/usr/share/novnc}"

fail() {
  echo "bench-start: $*" >&2
  exit 1
}

for tool in Xvnc openbox websockify playwright-mcp; do
  command -v "$tool" >/dev/null || fail "missing tool: $tool"
done
[ -f "$novnc/vnc.html" ] || fail "missing viewer page: $novnc/vnc.html"

mkdir -p "$data/profile" "$data/output"
vnc_port=$((5900 + ${display#:}))
declare -A names

# The viewer has no password. Only the tailnet serve and the bench network reach these ports.
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
[ -n "${BENCH_MCP_ALLOWED_HOSTS:-}" ] && mcp_args+=(--allowed-hosts "$BENCH_MCP_ALLOWED_HOSTS")
[ -n "${BENCH_ALLOWED_ORIGINS:-}" ] && mcp_args+=(--allowed-origins "$BENCH_ALLOWED_ORIGINS")
[ -n "${BENCH_SECRETS_FILE:-}" ] && mcp_args+=(--secrets "$BENCH_SECRETS_FILE")
[ "${BENCH_NO_SANDBOX:-}" = 1 ] && mcp_args+=(--no-sandbox)

DISPLAY="$display" playwright-mcp "${mcp_args[@]}" &
names[$!]="playwright-mcp"

echo "bench-start: viewer on port $view_port (/vnc.html?autoconnect=1&resize=scale), MCP on port $mcp_port (/mcp)"

trap 'kill "${!names[@]}" 2>/dev/null || true' EXIT
dead=0
wait -n -p dead "${!names[@]}" || true
fail "${names[$dead]:-a process} stopped; the bench stops with it"
