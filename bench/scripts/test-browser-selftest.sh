#!/usr/bin/env bash
# Checks a running test-browser: the viewer serves its page, and the MCP server opens that page in the browser.
# Usage: test-browser-selftest.sh [viewer URL] [MCP URL]. The page that the browser opens is the viewer inside the container.
set -euo pipefail

viewer="${1:-http://127.0.0.1:6080}"
mcp="${2:-http://127.0.0.1:8931/mcp}"
inner="${TEST_BROWSER_SELFTEST_PAGE:-http://127.0.0.1:6080/vnc.html}"

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

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test-browser-selftest","version":"0"}}}'
# The MCP server starts after the viewer.
session=""
for _ in $(seq 60); do
  session="$(post -D - -o /dev/null -d "$init" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')" || true
  [ -z "$session" ] || break
  sleep 1
done
[ -n "$session" ] || fail "the MCP server at $mcp opened no session in 60 s"
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
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"; }
out="$(post -d "$(call 3 browser_start_video '{"filename":"selftest.webm"}')")" || fail "browser_start_video failed"
case "$out" in *'"isError":true'*) fail "browser_start_video returned an error: ${out:0:400}" ;; esac
post -o /dev/null -d "$(call 4 browser_navigate "{\"url\":\"$inner\"}")" || fail "browser_navigate during the video failed"
out="$(post -d "$(call 5 browser_stop_video '{}')")" || fail "browser_stop_video failed"
case "$out" in
  *'"isError":true'*) fail "browser_stop_video returned an error: ${out:0:400}" ;;
  *selftest.webm*) echo "ok: the browser recorded the video selftest.webm" ;;
  *) fail "browser_stop_video named no file selftest.webm: ${out:0:400}" ;;
esac
echo "test-browser: ok"
