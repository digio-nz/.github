#!/usr/bin/env bash
# nix-setup.sh: put the image's pinned nix into /nix, as the user who runs it. The image build runs it, and so does each
# start, because a volume at /nix can be empty or can hold the nix of an older image.
# It changes nothing when the store holds the pinned nix. Exit 1 and name the fault when it cannot install.
# NIX_IMAGE_DIR holds nix.tar.xz, the release that the Dockerfile pins, and store-path, the store path of nix in it.
set -uo pipefail
image="${NIX_IMAGE_DIR:-/opt/digio/nix}"
dir="${NIX_DIR:-/nix}"

fail() { echo "FAIL: nix: $*" >&2; exit 1; }

want="$(cat "$image/store-path" 2>/dev/null)" || fail "$image/store-path is missing, so this image holds no nix"
name="${want##*/}"
[ -n "$name" ] || fail "$image/store-path is empty"
root="$dir/var/nix/gcroots/workbench-nix"
if [ -x "$dir/store/$name/bin/nix" ] && [ "$(readlink "$root" 2>/dev/null)" = "$want" ]; then exit 0; fi

# An older container has no /nix, and Docker makes a new volume as root when the image has no folder for it.
if [ ! -w "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then sudo -n install -d -o "$(id -u)" -g "$(id -g)" "$dir" 2>/dev/null; fi
{ [ -d "$dir" ] && [ -w "$dir" ]; } || fail "$(id -un) cannot write $dir; give that folder to $(id -un)"

unpack="$(mktemp -d "$dir/.unpack.XXXXXX")" || fail "cannot make a folder in $dir"
# A store path is read-only, and a folder can move or go only when its owner can write it.
trap 'chmod -R u+w "$unpack" 2>/dev/null; rm -rf "$unpack"' EXIT
tar -xJf "$image/nix.tar.xz" -C "$unpack" --strip-components=1 || fail "cannot unpack $image/nix.tar.xz"
[ -x "$unpack/store/$name/bin/nix-store" ] || fail "$image/nix.tar.xz holds no $name"
mkdir -p "$dir/store" "${root%/*}" || fail "cannot make $dir/store"
for path in "$unpack"/store/*; do
  dest="$dir/store/${path##*/}"
  [ -e "$dest" ] && continue
  { chmod -R a-w "$path" && chmod u+w "$path" && mv "$path" "$dest" && chmod a-w "$dest"; } || fail "cannot install ${path##*/}"
done
"$dir/store/$name/bin/nix-store" --load-db < "$unpack/.reginfo" \
  || fail "nix-store cannot register the paths of $image/nix.tar.xz"
ln -sfn "$want" "$root" || fail "cannot write $root"
echo "nix: installed $name in $dir"
