#!/usr/bin/env bash
# nix-setup.sh installs the image's nix into an empty store, changes nothing in a store that holds it, and fails loudly.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'chmod -R u+w "$TEST_DIR"; rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A fixture release: the store path of nix with a nix-store that records its input, and one more store path.
name=aaaa-nix-1.0
rel="$TEST_DIR/rel/nix-1.0-fixture"
mkdir -p "$rel/store/$name/bin" "$rel/store/bbbb-lib-1.0" "$TEST_DIR/image"
printf '#!/usr/bin/env bash\n[ "$*" = --load-db ] || exit 2\ncat > "%s/loaded"\n' "$TEST_DIR" > "$rel/store/$name/bin/nix-store"
printf '#!/usr/bin/env bash\necho fixture\n' > "$rel/store/$name/bin/nix"
chmod +x "$rel/store/$name/bin/nix-store" "$rel/store/$name/bin/nix"
echo lib > "$rel/store/bbbb-lib-1.0/file"
echo reginfo-fixture > "$rel/.reginfo"
tar -cJf "$TEST_DIR/image/nix.tar.xz" -C "$TEST_DIR/rel" nix-1.0-fixture
echo "/nix/store/$name" > "$TEST_DIR/image/store-path"
setup() { NIX_IMAGE_DIR="$TEST_DIR/image" NIX_DIR="$1" bash "$DIR/nix-setup.sh" 2>&1; }

store="$TEST_DIR/nix"; mkdir "$store"
out="$(setup "$store")" || fail "an empty store: $out"
[ "$out" = "nix: installed $name in $store" ] || fail "an empty store: the script said: $out"
[ -x "$store/store/$name/bin/nix" ] && [ -r "$store/store/bbbb-lib-1.0/file" ] || fail "the store paths of the release are not in the store"
[ ! -w "$store/store/$name" ] && [ ! -w "$store/store/bbbb-lib-1.0/file" ] || fail "a store path can be written"
[ "$(cat "$TEST_DIR/loaded")" = reginfo-fixture ] || fail "nix-store did not get the paths to register"
[ "$(readlink "$store/var/nix/gcroots/workbench-nix")" = "/nix/store/$name" ] || fail "no garbage collector root names nix"
[ -z "$(find "$store" -maxdepth 1 -name '.unpack.*')" ] || fail "the unpack folder stays in the store"

rm "$TEST_DIR/loaded"
out="$(setup "$store")" || fail "a store that holds nix: $out"
[ -z "$out" ] && [ ! -e "$TEST_DIR/loaded" ] || fail "the script changed a store that holds the pinned nix: $out"

# A volume from an older image: another nix and its root. The pinned nix goes beside it.
old="$TEST_DIR/old"; mkdir -p "$old/store/cccc-nix-0.9/bin" "$old/var/nix/gcroots"
ln -s /nix/store/cccc-nix-0.9 "$old/var/nix/gcroots/workbench-nix"
out="$(setup "$old")" || fail "a store with an older nix: $out"
[ "$(readlink "$old/var/nix/gcroots/workbench-nix")" = "/nix/store/$name" ] && [ -d "$old/store/cccc-nix-0.9" ] \
  || fail "the script did not install the pinned nix beside the older one"

mkdir "$TEST_DIR/bin"; printf '#!/bin/sh\nexit 1\n' > "$TEST_DIR/bin/sudo"; chmod +x "$TEST_DIR/bin/sudo"
out="$(PATH="$TEST_DIR/bin:$PATH" setup "$TEST_DIR/missing")" && fail "a missing store that sudo cannot make: exit 0"
grep -q "^FAIL: nix: .* cannot write $TEST_DIR/missing" <<<"$out" || fail "a missing store: the script said: $out"

rm "$TEST_DIR/image/store-path"
out="$(setup "$store")" && fail "an image with no store-path: exit 0"
grep -q "^FAIL: nix: $TEST_DIR/image/store-path is missing" <<<"$out" || fail "no store-path: the script said: $out"

echo "/nix/store/dddd-nix-2.0" > "$TEST_DIR/image/store-path"
out="$(setup "$store")" && fail "a tarball without the pinned path: exit 0"
grep -q "^FAIL: nix: .* holds no dddd-nix-2.0" <<<"$out" || fail "a wrong tarball: the script said: $out"
[ -z "$(find "$store" -maxdepth 1 -name '.unpack.*')" ] || fail "a failed install leaves the unpack folder"

echo "nix setup self-test passed: an empty store gets the pinned nix and its root, a store that holds it stays as it is, an older nix stays beside the new one, and each fault exits 1 with its name"
