#!/usr/bin/env bash
# machine-id.sh: give this container the machine id that its home keeps.
# Each image build makes a new /etc/machine-id, and a program that keys its identity on that id then
# starts as a new machine. The first start in a home saves the id, and each later start puts that id back.
# Exit 1 and name the fault when it cannot.
set -uo pipefail
keep="${MACHINE_ID_KEEP:-$HOME/.local/state/digio-workbench/machine-id}"
file="${MACHINE_ID_FILE:-/etc/machine-id}"

fail() { echo "FAIL: machine-id: $*" >&2; exit 1; }

if [ ! -s "$keep" ]; then
  [ -s "$file" ] || fail "$file is empty, so the home has no machine id to keep"
  mkdir -p "${keep%/*}" && cp "$file" "$keep" || fail "cannot write $keep"
  exit 0
fi
cmp -s "$keep" "$file" && exit 0
if [ -w "$file" ]; then cp "$keep" "$file"; else sudo -n cp "$keep" "$file" && sudo -n chmod 0444 "$file"; fi \
  || fail "cannot write $file, so this container has the machine id of its image, not of its home"
echo "machine-id: put the machine id of the home in $file"
