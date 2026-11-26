#!/usr/bin/env bash
# machine-id.sh saves the id of the first start, puts it back when an image brings another, and fails loudly.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'chmod -R u+w "$TEST_DIR"; rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A stub sudo that refuses, so the test never changes a file of the machine that runs it.
mkdir "$TEST_DIR/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_DIR/bin/sudo"
chmod +x "$TEST_DIR/bin/sudo"
keep="$TEST_DIR/home/state/machine-id"
file="$TEST_DIR/etc-machine-id"
run() { PATH="$TEST_DIR/bin:$PATH" MACHINE_ID_KEEP="$keep" MACHINE_ID_FILE="$file" bash "$DIR/machine-id.sh" 2>&1; }

echo first-image > "$file"
out="$(run)" || fail "a first start: $out"
[ -z "$out" ] && [ "$(cat "$keep")" = first-image ] || fail "a first start did not save the id: $out"

out="$(run)" || fail "a start with the same id: $out"
[ -z "$out" ] || fail "a start with the same id said: $out"

echo second-image > "$file"
out="$(run)" || fail "a start on a new image: $out"
[ "$(cat "$file")" = first-image ] || fail "a start on a new image kept the id of the image"
[ "$out" = "machine-id: put the machine id of the home in $file" ] || fail "a start on a new image said: $out"

echo third-image > "$file"; chmod a-w "$file"
if out="$(run)"; then fail "a file that the user cannot write passed: $out"; fi
case "$out" in "FAIL: machine-id: cannot write $file,"*) ;; *) fail "a file that the user cannot write: the script said: $out" ;; esac
chmod u+w "$file"

rm "$keep"; : > "$file"
if out="$(run)"; then fail "an empty id passed: $out"; fi
case "$out" in "FAIL: machine-id: $file is empty,"*) ;; *) fail "an empty id: the script said: $out" ;; esac
echo "machine-id-selftest: ok"
