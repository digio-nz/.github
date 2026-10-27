#!/usr/bin/env bash
# Read the PR live from the API. On pull_request the number comes from the
# event and the head from the live PR. On merge_group the number comes from
# head_ref (pr-<n>-<sha>) and base/head from the merge group SHAs.
set -euo pipefail
event_name="${GITHUB_EVENT_NAME:-}"
event_path="${GITHUB_EVENT_PATH:-}"
out_dir="${RUNNER_TEMP:-/tmp}"
[ -n "$event_name" ] && [ -f "$event_path" ] || { echo "read-pr: GITHUB_EVENT_NAME and GITHUB_EVENT_PATH are required" >&2; exit 3; }

number=""
base=""
head=""
repo="${GITHUB_REPOSITORY:-}"

case "$event_name" in
  pull_request|pull_request_target)
    number="$(jq -r '.pull_request.number // empty' "$event_path")"
    [ -n "$number" ] || { echo "read-pr: no pull_request.number in the event" >&2; exit 3; }
    [ -n "$repo" ] || { echo "read-pr: GITHUB_REPOSITORY is empty" >&2; exit 3; }
    gh api "repos/${repo}/pulls/${number}" > "$out_dir/pr.json"
    base="$(jq -r '.base.sha // empty' "$out_dir/pr.json")"
    head="$(jq -r '.head.sha // empty' "$out_dir/pr.json")"
    ;;
  merge_group)
    ref="$(jq -r '.merge_group.head_ref // empty' "$event_path")"
    if [[ "$ref" =~ pr-([0-9]+)- ]]; then
      number="${BASH_REMATCH[1]}"
    else
      echo "read-pr: merge_group.head_ref '$ref' does not end in pr-<n>-<sha>" >&2
      exit 3
    fi
    base="$(jq -r '.merge_group.base_sha // empty' "$event_path")"
    head="$(jq -r '.merge_group.head_sha // empty' "$event_path")"
    [ -n "$repo" ] || { echo "read-pr: GITHUB_REPOSITORY is empty" >&2; exit 3; }
    gh api "repos/${repo}/pulls/${number}" > "$out_dir/pr.json"
    ;;
  *)
    echo "read-pr: unsupported event $event_name" >&2
    exit 3
    ;;
esac

[ -n "$base" ] && [ -n "$head" ] || { echo "read-pr: missing base or head sha" >&2; exit 3; }
jq -r '.title // ""' < "$out_dir/pr.json" > "$out_dir/pr-title.txt"
jq -r '.body // ""' < "$out_dir/pr.json" > "$out_dir/pr-body.txt"
{
  echo "number=$number"
  echo "base=$base"
  echo "head=$head"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "read-pr: PR #$number base=$base head=$head"
