#!/usr/bin/env bash
# Confirm the commit range the gates read is present in this checkout.
set -euo pipefail
base="${1:-}"
head="${2:-}"
[ -n "$base" ] && [ -n "$head" ] || { echo "fetch-range: usage: fetch-range.sh <base> <head>" >&2; exit 3; }
git cat-file -e "$base^{commit}" 2>/dev/null || { echo "fetch-range: missing base $base" >&2; exit 3; }
git cat-file -e "$head^{commit}" 2>/dev/null || { echo "fetch-range: missing head $head" >&2; exit 3; }
git merge-base "$base" "$head" >/dev/null || { echo "fetch-range: no merge base for $base and $head" >&2; exit 3; }
echo "fetch-range: $base..$head is present"
exit 0
