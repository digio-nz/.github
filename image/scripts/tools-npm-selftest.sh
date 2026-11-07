#!/usr/bin/env bash
# shellcheck disable=SC2015 # Each failed assertion calls fail, which exits.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$tmp/bin"
cat > "$tmp/bin/npm" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1" in
  --version) echo "${NPM_VERSION:-12.2.1}" ;;
  view) echo 1.2.3 ;;
  install)
    printf '%s\n' "$*" >> "$FIXTURE/npm.log"
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in --prefix) prefix="$2"; shift ;; esac
      spec="$1"; shift
    done
    package="${spec%@*}"
    dest="$prefix/lib/node_modules/$package"
    mkdir -p "$dest/bin" "$prefix/bin"
    printf '{"version":"1.2.3"}\n' > "$dest/package.json"
    if [ "$package" = '@anthropic-ai/claude-code' ]; then
      printf 'echo "native binary not installed" >&2\nexit 1\n' > "$dest/bin/claude.exe"
      cat > "$dest/install.cjs" <<'JS'
const fs = require('fs');
fs.appendFileSync(process.env.FIXTURE + '/repair.log', 'repair\n');
if (process.env.REPAIR_MODE === 'error') process.exit(1);
if (process.env.REPAIR_MODE !== 'noop') {
  fs.copyFileSync(__dirname + '/native', __dirname + '/bin/claude.exe');
}
JS
      if [ "${REPAIR_MODE:-}" != missing ]; then
        printf '#!/bin/sh\n[ "$1" = --version ] || exit 9\necho 1.2.3\n' > "$dest/native"
      fi
      [ ! -f "$dest/native" ] || chmod +x "$dest/native"
      chmod +x "$dest/bin/claude.exe"
      ln -sf "$dest/bin/claude.exe" "$prefix/bin/claude"
    elif [ "$package" = '@humanlayer/cli' ]; then
      rmdir "$prefix/bin" 2>/dev/null || true
      native="@humanlayer/cli-$(node -p 'process.platform + "-" + process.arch')"
      printf '{"name":"@humanlayer/cli","version":"1.2.3","optionalDependencies":{"%s":"1.2.3"}}\n' "$native" > "$dest/package.json"
      native_dir="$dest/node_modules/$native"
      mkdir -p "$native_dir/bin"
      printf '{"name":"%s","version":"%s"}\n' "$native" "${HL_PACKAGE_VERSION:-1.2.3}" > "$native_dir/package.json"
      if [ "${HL_PACKAGE_MISSING:-0}" != 1 ]; then
        cp "$FIXTURE/humanlayer" "$native_dir/bin/humanlayer"
        chmod +x "$native_dir/bin/humanlayer"
      fi
      if [ "${HL_UNMANAGED_LAUNCHER:-0}" = 1 ]; then
        mkdir -p "$prefix/bin"
        printf '#!/bin/sh\nexit 1\n' > "$prefix/bin/humanlayer"
        chmod +x "$prefix/bin/humanlayer"
      fi
    else
      printf '#!/bin/sh\n[ "$1" = -V ] || exit 9\n[ "${GENERIC_FAIL:-}" != 1 ] || exit 1\necho 1.2.3\n' > "$prefix/bin/other"
      chmod +x "$prefix/bin/other"
    fi ;;
  *) exit 9 ;;
esac
STUB
chmod +x "$tmp/bin/npm"
export FIXTURE="$tmp" PATH="$tmp/bin:$PATH"
printf 'claude\tclaude\tnpm\t@anthropic-ai/claude-code\tlatest\t--version\tall\nother\tother\tnpm\tother-pkg\tlatest\t-V\tall\n' > "$tmp/tools.tsv"
run() {
  rc=0
  out="$(bash "$DIR/tools.sh" --list "$tmp/tools.tsv" apply --prefix "$tmp/prefix" --sources npm 2>&1)" || rc=$?
}
run
[ "$rc" = 0 ] && [ -f "$tmp/repair.log" ] && "$tmp/prefix/bin/claude" --version >/dev/null \
  || fail "Claude placeholder was not repaired: exit $rc $out"
grep -q -- '--allow-scripts=@anthropic-ai/claude-code' "$tmp/npm.log" || fail 'npm 12 did not approve Claude postinstall'
grep -q -- '--allow-scripts=other-pkg' "$tmp/npm.log" || fail 'npm 12 did not approve the other package'
grep -q '^installed other ' <<<"$out" || fail "the declared -V probe did not pass: $out"
for mode in missing error noop; do
  rm -rf "$tmp/prefix"
  export REPAIR_MODE="$mode"
  run
  [ "$rc" = 1 ] && grep -q 'install failed: claude' <<<"$out" && ! grep -q '^installed claude ' <<<"$out" \
    && grep -q '^installed other ' <<<"$out" || fail "Claude repair $mode reported success or stopped other rows: exit $rc $out"
done
unset REPAIR_MODE
rm -rf "$tmp/prefix"
export GENERIC_FAIL=1
run
[ "$rc" = 1 ] && grep -q 'install failed: other.*other -V' <<<"$out" && ! grep -q '^installed other ' <<<"$out" \
  || fail "failed generic probe reported success: exit $rc $out"
unset GENERIC_FAIL
rm -rf "$tmp/prefix"
: > "$tmp/npm.log"
export NPM_VERSION=11.15.0
run
[ "$rc" = 0 ] && ! grep -q -- '--allow-scripts' "$tmp/npm.log" || fail "npm 11 received an unsupported option: exit $rc $out"
printf '#!/bin/sh\nexit 1\n' > "$tmp/prefix/bin/other"
run
[ "$rc" = 0 ] && grep -q '^installed other ' <<<"$out" || fail "a broken current package was skipped: exit $rc $out"
echo 'ok: npm script approval, Claude repair, failed probes, and current-package recovery'

cat > "$tmp/humanlayer" <<'STUB'
#!/bin/sh
[ "${HL_BROKEN:-0}" != 1 ] || exit 1
if [ "$1" = --version ]; then echo 1.2.0; exit 0; fi
[ "${HUMANLAYER_DISABLE_SELF_UPDATE:-}" = 1 ] || exit 9
path="$*"; path="${path% --help}"
printf 'Usage: humanlayer %s [options]\n' "$path"
printf '%s\n' '--launch-token' '--no-self-update' '--host-id' '--working-directory' '--cascade-to-sessions'
STUB
printf 'humanlayer\thumanlayer\tnpm\t@humanlayer/cli\tlatest\t--version\tall\n' > "$tmp/tools.tsv"
rm -rf "$tmp/prefix"
run
[ "$rc" = 0 ] && "$tmp/prefix/bin/humanlayer" --version >/dev/null \
  || fail "HumanLayer metadata-only wrapper left no command: exit $rc $out"
out="$(PATH="$tmp/prefix/bin:$PATH" bash "$DIR/tools.sh" --list "$tmp/tools.tsv" check --latest 2>&1)" \
  || fail "HumanLayer platform metadata check failed: $out"
grep -qx 'humanlayer present 1.2.3' <<<"$out" || fail "HumanLayer used binary version instead of platform metadata: $out"
: > "$tmp/npm.log"
run
[ "$rc" = 0 ] && [ ! -s "$tmp/npm.log" ] || fail "HumanLayer repeated install was not idempotent: $out"
rm "$tmp/prefix/bin/humanlayer"
run
[ "$rc" = 0 ] && "$tmp/prefix/bin/humanlayer" --version >/dev/null \
  || fail "HumanLayer did not repair a missing link with packages installed: $out"
for mode in missing mismatch broken unmanaged; do
  rm -rf "$tmp/prefix"
  export HL_PACKAGE_MISSING=0 HL_PACKAGE_VERSION=1.2.3 HL_BROKEN=0 HL_UNMANAGED_LAUNCHER=0
  case "$mode" in
    missing) HL_PACKAGE_MISSING=1 ;;
    mismatch) HL_PACKAGE_VERSION=1.2.2 ;;
    broken) HL_BROKEN=1 ;;
    unmanaged) HL_UNMANAGED_LAUNCHER=1 ;;
  esac
  run
  [ "$rc" = 1 ] && grep -q 'install failed: humanlayer' <<<"$out" && ! grep -q '^installed humanlayer' <<<"$out" \
    || fail "HumanLayer $mode repair did not fail by name: exit $rc $out"
  if [ "$mode" = unmanaged ]; then
    [ ! -L "$tmp/prefix/bin/humanlayer" ] && grep -q '^exit 1$' "$tmp/prefix/bin/humanlayer" \
      || fail 'HumanLayer repair replaced an unmanaged launcher'
  fi
done
echo 'ok: HumanLayer platform launcher repair, metadata version, rerun and failure paths'
