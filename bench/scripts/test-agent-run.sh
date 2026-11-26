#!/usr/bin/env bash
# test-agent-run.sh: run full browser tests on the bench for some hours, one person and one round at a time, and keep each record.
#
#   test-agent-run.sh <product> <address> <hours> [<feature to skip>]
#
# Run it on the host of the bench, with docker and jq. Each run is one Claude Code session in test-agent.
# RESULTS is the folder of the records, by default ~/test-bench/results/<product>-<UTC time>.
# ROUNDS stops the runs after that many rounds, before the hours end.
# Exit 0 when each run gave a report, 1 when a run failed, 2 on bad usage.
set -uo pipefail

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
fail() { echo "FAIL: test-agent-run: $*" >&2; exit 1; }

[ $# -ge 3 ] && [ $# -le 4 ] || usage
product="$1" address="$2" hours="$3" skip="${4:-}"
[[ "$hours" =~ ^[1-9][0-9]?$ ]] || { echo "test-agent-run: hours must be a number from 1 to 99, not '$hours'" >&2; exit 2; }
rounds="${ROUNDS:-0}"
[[ "$rounds" =~ ^[0-9]+$ ]] || { echo "test-agent-run: ROUNDS must be a number, not '$rounds'" >&2; exit 2; }
agent="${TEST_AGENT_CONTAINER:-test-bench-test-agent-1}"
browser="${TEST_BROWSER_CONTAINER:-test-bench-test-browser-1}"
skill="/home/vscode/.claude/skills/browser-test/scripts/browser-test.sh"
results="${RESULTS:-$HOME/test-bench/results/$product-$(date -u +%Y%m%dT%H%MZ)}"
# A failed run is often a usage limit of the model, so the next run waits.
pause="${TEST_AGENT_RUN_PAUSE:-300}"

command -v jq >/dev/null || fail "no jq on this host"
for container in "$agent" "$browser"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = true ] || fail "$container is not running; start the bench first"
done
in_agent() { docker exec -u vscode "$agent" "$@"; }
in_agent bash "$skill" host "$product" "$address" || fail "the plan of $product refuses $address"
people="$(in_agent bash "$skill" people "$product")" || fail "browser-test.sh people $product failed"
mkdir -p "$results" || fail "cannot make $results"
index="$results/index.md"
printf '# %s at %s\n\nStarted %s, for %s hours.%s\n\n| Round | Person | Started | Exit | First line of the report |\n| --- | --- | --- | --- | --- |\n' \
  "$product" "$address" "$(date -u +%FT%TZ)" "$hours" "${skip:+ Skips: $skip.}" > "$index"
echo "test-agent-run: records in $results"

end=$(( $(date +%s) + hours * 3600 ))
failed=0 round=1 in_a_row=0
while [ "$(date +%s)" -lt "$end" ] && { [ "$rounds" -eq 0 ] || [ "$round" -le "$rounds" ]; }; do
  while IFS= read -r person; do
    [ "$(date +%s)" -lt "$end" ] || break
    name="$(printf 'r%02d-%s' "$round" "${person%%@*}")"
    task="Use the browser-test skill. Do a full run of $product at $address for the person $person, round $round."
    [ -z "$skip" ] || task="$task Skip the feature: $skip."
    started="$(date -u +%FT%TZ)"
    echo "test-agent-run: $started $name"
    in_agent claude -p --output-format stream-json --verbose "$task" < /dev/null > "$results/$name.jsonl" 2> "$results/$name.err"
    code=$?
    jq -rs '[.[] | select(.type == "result")] | last | .result // empty' "$results/$name.jsonl" > "$results/$name.md" 2>/dev/null
    first="$(grep -m 1 . "$results/$name.md" | tr '|' '/' | cut -c 1-160)"
    printf '| %s | %s | %s | %s | %s |\n' "$round" "$person" "$started" "$code" "${first:-no report}" >> "$index"
    if [ "$code" -ne 0 ] || [ -z "$first" ]; then
      failed=$((failed + 1)) in_a_row=$((in_a_row + 1))
      echo "FAIL: test-agent-run: $name exited $code${first:+ after its report}${first:- with no report}; see $results/$name.err" >&2
      [ "$in_a_row" -lt 3 ] || { echo "FAIL: test-agent-run: three runs in a row failed, so the runs stop" >&2; break 2; }
      sleep "$pause"
    else
      in_a_row=0
    fi
  done <<<"$people"
  round=$((round + 1))
done

docker cp "$browser:/home/browser/data/output" "$results/browser-output" >/dev/null \
  || { echo "FAIL: test-agent-run: cannot copy the output of $browser" >&2; failed=$((failed + 1)); }
echo "test-agent-run: $((round - 1)) rounds; $failed failed runs; index at $index"
[ "$failed" -eq 0 ]
