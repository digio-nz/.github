#!/usr/bin/env bash
# Checks a running bench: the viewer serves its page, and the MCP server opens that page in the bench browser.
# Usage: bench-selftest.sh [viewer URL] [MCP URL]. The page that the browser opens is the viewer inside the bench.
set -euo pipefail

viewer="${1:-http://127.0.0.1:6080}"
mcp="${2:-http://127.0.0.1:8931/mcp}"
inner="${BENCH_SELFTEST_PAGE:-http://127.0.0.1:6080/vnc.html}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for _ in $(seq 60); do
  curl -fsS -o /dev/null "$viewer/vnc.html" 2>/dev/null && ready=1 && break
  sleep 1
done
[ "${ready:-0}" = 1 ] || fail "the viewer at $viewer/vnc.html did not answer in 60 s"
echo "ok: the viewer serves vnc.html"

headers=(-H 'content-type: application/json' -H 'accept: application/json, text/event-stream')
post() {
  curl -fsS -m 120 -X POST "$mcp" "${headers[@]}" "$@"
}

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bench-selftest","version":"0"}}}'
session="$(post -D - -o /dev/null -d "$init" | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')" \
  || fail "the MCP server at $mcp refused initialize"
[ -n "$session" ] || fail "the MCP server at $mcp gave no session id"
headers+=(-H "mcp-session-id: $session")
post -o /dev/null -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' || fail "the MCP server refused the session"
echo "ok: the MCP server opens a session"

navigate="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_navigate\",\"arguments\":{\"url\":\"$inner\"}}}"
out="$(post -d "$navigate")" || fail "browser_navigate failed"
case "$out" in
  *'"isError":true'*) fail "browser_navigate returned an error: ${out:0:400}" ;;
  *'Page Title: noVNC'*) echo "ok: the browser opened $inner" ;;
  *) fail "the browser did not open $inner: ${out:0:400}" ;;
esac
echo "bench: ok"
