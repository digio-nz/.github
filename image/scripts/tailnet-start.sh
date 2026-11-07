#!/usr/bin/env bash
set -euo pipefail

if [ -z "${TS_AUTH_KEY:-}" ]; then
  echo "tailnet: workbench is not on the tailnet: TS_AUTH_KEY is not set"
  exit 0
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailnet join failed: the tailscale command is not installed" >&2
  exit 1
fi

# Workbenches use direct tailnet connections, so they do not accept subnet routes.
if ! sudo tailscale up \
  --ssh \
  --auth-key="$TS_AUTH_KEY" \
  --hostname="workbench-$(hostname)"; then
  echo "tailnet join failed: tailscale up returned an error" >&2
  exit 1
fi

if ! status_json="$(tailscale status --json)"; then
  echo "tailnet join failed: tailscale status returned an error" >&2
  exit 1
fi

if ! node_name="$(jq -er '.Self.DNSName // .Self.HostName' <<< "$status_json")"; then
  echo "tailnet join failed: tailscale status did not contain the node name" >&2
  exit 1
fi
if ! tags="$(jq -er '(.Self.Tags // []) | if length == 0 then "(none)" else join(", ") end' <<< "$status_json")"; then
  echo "tailnet join failed: tailscale status did not contain valid tags" >&2
  exit 1
fi
echo "tailnet: joined node $node_name with tags $tags"
