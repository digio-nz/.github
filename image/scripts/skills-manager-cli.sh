#!/usr/bin/env bash
# skills-manager-cli.sh install --prefix <dir> | check
# Installs the Skills Manager CLI (https://github.com/xingkongliang/skills-manager) at one pinned release, and refuses a
# download whose SHA-256 is not the one below. digio-skills lib/skills-install.sh drives it to install each agent's skills.
#   install  put the pinned CLI at <dir>/bin/skills-manager-cli; a no-op when that copy already reports the version.
#   check    FAIL when the CLI on the PATH is missing or reports another version.
# The release is pinned because the CLI writes into each agent's skills folder. To move it, change VERSION and both
# checksums together, from the release's asset digests.
# Exit 0 in step, 1 on a FAIL line, 2 on bad usage.
set -uo pipefail
VERSION=1.44.0
sha_for() {
  case "$1" in
    Linux-x64) echo 3be08b67e1ca1b035e948848242412ed7ff5b592a3c82cfb9e3728eede8b2a6a ;;
    Linux-arm64) echo 02d89fffb94a0b5b9b55bfb7165d7c58bd45ae284e7ea579be01b144eca91c66 ;;
    *) return 1 ;;
  esac
}
usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
fail() { echo "FAIL: skills-manager-cli: $*"; exit 1; }
reports() { "$1" --version 2>/dev/null | grep -qx "skills-manager-cli $VERSION"; }

case "${1:-}" in
  install)
    [ $# -eq 3 ] && [ "$2" = --prefix ] && [ -n "$3" ] || usage
    target="$3/bin/skills-manager-cli"
    if [ -x "$target" ] && reports "$target"; then echo "skills-manager-cli current $VERSION"; exit 0; fi
    case "$(uname -m)" in x86_64 | amd64) asset=Linux-x64 ;; aarch64 | arm64) asset=Linux-arm64 ;; *) asset="" ;; esac
    [ "$(uname -s)" = Linux ] && [ -n "$asset" ] || fail "no pinned build for $(uname -sm)"
    want="$(sha_for "$asset")"
    tmp="$(mktemp)" || fail "cannot make a temporary file"
    trap 'rm -f "$tmp"' EXIT
    url="https://github.com/xingkongliang/skills-manager/releases/download/v$VERSION/skills-manager-cli-$asset"
    curl -fsSL --retry 3 -o "$tmp" "$url" || fail "cannot download $url"
    got="$(sha256sum "$tmp" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || fail "$url has SHA-256 $got, not $want"
    { mkdir -p "$3/bin" && install -m 0755 "$tmp" "$target"; } || fail "cannot write $target"
    reports "$target" || fail "$target does not report version $VERSION"
    echo "installed skills-manager-cli $VERSION" ;;
  check)
    [ $# -eq 1 ] || usage
    cli="$(command -v skills-manager-cli)" || fail "not on the PATH"
    reports "$cli" || fail "$cli reports $("$cli" --version 2>&1 | head -n1), not $VERSION"
    echo "skills-manager-cli present $VERSION" ;;
  *) usage ;;
esac
