#!/usr/bin/env bash
# Joins the tailnet as workbench-<hostname>. The key is TS_AUTH_KEY, or the 1Password item of a workbench with a service account.
# A node that is joined already needs no key: a container that keeps /var/lib/tailscale keeps its node.
set -euo pipefail

KEY_REF="op://workbench/TS_AUTH_KEY_WORKBENCH/credential"
OP_TOKEN_FILE="$HOME/.config/digio/op-workbench"
TUN_DEV="${TAILNET_START_TUN:-/dev/net/tun}"

if [ -z "${TS_AUTH_KEY:-}" ] && [ ! -r "$OP_TOKEN_FILE" ]; then
  echo "tailnet: workbench is not on the tailnet: TS_AUTH_KEY is not set"
  exit 0
fi

for tool in tailscale jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "tailnet join failed: the $tool command is not installed" >&2
    exit 1
  fi
done

# Prints the state of the daemon, or nothing when no daemon answers.
backend() { tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true; }

# A node that a person removed from the tailnet stays in the state Running, and it is not online.
online() { [ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState == "Running" and .Self.Online' 2>/dev/null)" = true ]; }

# A daemon needs some seconds after its start, and after a join, before its node is online.
wait_online() {
  for _ in $(seq 1 "${TAILNET_START_TRIES:-30}"); do
    case "$(backend)" in NeedsLogin | NeedsMachineAuth | Stopped) return 1 ;; esac
    if online; then return 0; fi
    sleep 0.5
  done
  return 1
}

# A dev container tool starts the daemon of the Tailscale feature. A plain container run does not.
if [ -z "$(backend)" ]; then
  tun=()
  # Without the TUN device, the daemon keeps the network in its own process. It still serves pages and Tailscale SSH.
  [ -e "$TUN_DEV" ] || tun=(--tun=userspace-networking)
  # setsid keeps the daemon when the start script ends.
  sudo sh -c 'mkdir -p /var/lib/tailscale /var/run/tailscale && setsid "$@" >>/var/log/tailscaled.log 2>&1 </dev/null &' sh \
    tailscaled --statedir=/var/lib/tailscale --socket=/var/run/tailscale/tailscaled.sock "${tun[@]}"
fi
# An auth key that has expired fails `tailscale up`, also for a node that is joined. So a joined node gets no key.
if ! wait_online; then
  if [ -z "$(backend)" ]; then
    echo "tailnet join failed: tailscaled did not start; see /var/log/tailscaled.log" >&2
    exit 1
  fi
  key="${TS_AUTH_KEY:-}"
  if [ -z "$key" ] && ! key="$(op read "$KEY_REF")"; then
    echo "tailnet join failed: op did not read $KEY_REF" >&2
    exit 1
  fi
  # Workbenches use direct tailnet connections, so they do not accept subnet routes.
  if ! sudo tailscale up \
    --ssh \
    --auth-key="$key" \
    --hostname="workbench-$(hostname)"; then
    echo "tailnet join failed: tailscale up returned an error" >&2
    exit 1
  fi
  if ! wait_online; then
    echo "tailnet join failed: the node is not online after tailscale up" >&2
    exit 1
  fi
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
