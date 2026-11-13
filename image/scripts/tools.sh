#!/usr/bin/env bash
# tools: the one list of the tools that the workbench image and the physical machines install, and the verbs that read it.
#
#   tools.sh [--list <file>] list [--scope image|all] [--source <s>]   print the rows, from the file only
#   tools.sh [--list <file>] apply --prefix <dir> --sources <s,...> [--scope image|all]
#                                                                      install each row of those sources that is missing or older
#   tools.sh [--list <file>] check [--scope image|all] [--latest]      report presence; --latest also rejects stale or unverified tools
#   tools.sh [--list <file>] lint                                      one line per fault in the list and the files that agree with it
#   tools.sh version-lt <a> <b>                                        exit 0 when version a is older than b, else 1
#   tools.sh latest-release <owner/repo>                               print the latest GitHub release's version, with no v
#
# The list is --list, else tools.tsv beside this script (the image copies both to /opt/digio/tools/), else
# ../references/tools.tsv. --scope image is every row, the default; --scope all is the rows that the machines install
# too, and a machine applies only those.
# apply installs the sources in this order: apt, nodesource, npm, installer, gh-release. It never installs a feature row:
# the devcontainer CLI installs the features from the image's devcontainer.json. apt, nodesource and op need root.
# lint reads TOOLS_DOCKERFILE and TOOLS_DEVCONTAINER; the defaults are the image's Dockerfile and devcontainer.json.
# version-lt and latest-release are the version helpers that dotfiles' bootstrap/status-output.sh calls for the
# machine-only tools, so the image and the machines compare versions one way.
# Exit 0 OK; 1 a finding: a fault, a missing or stale tool, or a failed install; 2 bad usage or a bad list; 3 freshness
# cannot be verified because a version or registry cannot be read.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# The packages that the Dockerfile installs itself, before tools.sh: no person runs them, so they are not tools.
BASE_PACKAGES="ca-certificates build-essential gnupg python3-pip python3-venv"
SOURCES="apt nodesource npm installer gh-release feature"
INSTALL_ORDER="apt nodesource npm installer gh-release"

LIST=""
if [ "${1:-}" = --list ]; then [ $# -ge 2 ] || usage; LIST="$2"; shift 2; fi
if [ -z "$LIST" ]; then
  if [ -f "$DIR/tools.tsv" ]; then LIST="$DIR/tools.tsv"; else LIST="$DIR/../references/tools.tsv"; fi
fi

has_word() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
fn_of() { printf 'install_%s' "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9\n' '_')"; }

# parse: one line per row or fault of the list. "ROW<TAB>line<TAB>tool<TAB>command<TAB>source<TAB>package<TAB>version<TAB>probe<TAB>scope"
# or "FAULT<TAB><message>". The faults are the list's own: the columns, a tool twice, the source, the scope, the version
# and its version policy.
parse() {
  [ -f "$LIST" ] || { echo "FAULT	$LIST: no such list"; return; }
  awk -F'\t' -v file="$LIST" -v sources=" $SOURCES " '
    function fault(msg) { printf "FAULT\t%s:%d: %s\n", file, NR, msg }
    /^[[:space:]]*$/ { next }
    /^#/ { next }
    {
      row = $0
      if (NF != 7) { fault("the row has " NF " columns, not 7: " row); next }
      bad = 0
      if ($1 in seen) { fault("tool " $1 " is listed twice (first at line " seen[$1] ")"); bad = 1 } else seen[$1] = NR
      if (index(sources, " " $3 " ") == 0) { fault($1 ": unknown source \"" $3 "\": " row); bad = 1 }
      if ($6 !~ /^--?[A-Za-z][A-Za-z-]*$/) { fault($1 ": invalid version probe \"" $6 "\": " row); bad = 1 }
      if ($7 != "all" && $7 != "image") { fault($1 ": unknown scope \"" $7 "\": " row); bad = 1 }
      if ($5 != "latest") { fault($1 ": version \"" $5 "\" is pinned; use latest and enforce any feature floor in a check: " row); bad = 1 }
      if (!bad) printf "ROW\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", NR, $1, $2, $3, $4, $5, $6, $7
    }' "$LIST"
}

# rows <scope> [source]: the valid rows, as the ROW lines without the ROW. A list with a fault exits 2 and names it.
ROWS=""
load() {
  local parsed
  parsed="$(parse)"
  if grep -q '^FAULT' <<<"$parsed"; then
    sed -n 's/^FAULT	/tools: bad list: /p' <<<"$parsed" >&2
    exit 2
  fi
  ROWS="$(sed -n 's/^ROW	//p' <<<"$parsed")"
}
rows() { # <scope all|image> [source]
  awk -F'\t' -v scope="$1" -v source="${2:-}" '($8 == "all" || scope == "image") && (source == "" || $4 == source)' <<<"$ROWS"
}

# The first version number in a command's output, or nothing.
version_in() { grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sed -n '1p'; }
# present_version <command> <probe>: the version that the declared probe prints; "(no version)" on a failure.
present_version() {
  local out
  if out="$("$1" "$2" </dev/null 2>&1)"; then
    out="$(version_in <<<"$out")"
    printf '%s' "${out:-(no version)}"
  else
    printf '(no version)'
  fi
}
# HumanLayer's executable version can lag its npm package version.
npm_command_version() {
  node -e '
    const fs = require("node:fs"), path = require("node:path");
    const file = path.resolve(path.dirname(fs.realpathSync(process.argv[1])), "../package.json");
    const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
    const expected = process.argv[2];
    const platform = "@humanlayer/cli-" + process.platform + "-" + process.arch;
    if ((pkg.name !== expected && !(expected === "@humanlayer/cli" && pkg.name === platform)) ||
        !/^\d+\.\d+\.\d+$/.test(pkg.version)) process.exit(1);
    process.stdout.write(pkg.version);
  ' "$(command -v "$1")" "$2" 2>/dev/null
}
apt_lists_present() {
  local lists="${TOOLS_APT_LISTS:-/var/lib/apt/lists}"
  [ -d "$lists" ] && find "$lists" -maxdepth 1 -type f -name '*Packages*' -print -quit 2>/dev/null | grep -q .
}
# The candidate version in the configured APT repository.
apt_latest() {
  local candidate
  apt_lists_present || return 3
  candidate="$(apt-cache policy "$1" 2>/dev/null | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | sed -n '1p')"
  [ -n "$candidate" ] && [ "$candidate" != "(none)" ] || return 3
  printf '%s' "$candidate"
}
# The newest stable Node release. The index lists releases from newest to oldest.
node_latest() {
  local index
  index="$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null)" || return 3
  grep -oE '"version"[[:space:]]*:[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"' <<<"$index" | sed -n '1p' | version_in
}
# ver_lt <a> <b>: a is older than b, comparing each dotted number.
ver_lt() {
  local a="${1%%[-+]*}" b="${2%%[-+]*}" x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x="${a%%.*}"; y="${b%%.*}"
    x="${x:-0}"; y="${y:-0}"
    [ "$x" -lt "$y" ] 2>/dev/null && return 0
    [ "$x" -gt "$y" ] 2>/dev/null && return 1
    case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
    case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
  done
  return 1
}
# github_repo <package>: owner/repo for a gh-release row, or for an installer served from raw.githubusercontent.com.
github_repo() {
  case "$1" in
    https://raw.githubusercontent.com/*) printf '%s' "$1" | cut -d/ -f4-5 ;;
    */*) case "$1" in *://*) return 1 ;; *) printf '%s' "$1" ;; esac ;;
    *) return 1 ;;
  esac
}
# latest_tag <owner/repo>: the tag of the latest release, from the /releases/latest redirect (no API rate limit).
latest_tag() {
  local url
  url="$(curl -fsSLI --max-time 10 -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" 2>/dev/null)" || return 3
  case "$url" in */releases/tag/*) url="${url##*/releases/tag/}"; printf '%s' "${url%%[?#/]*}" ;; *) return 3 ;; esac
}
# grok_latest <base>: the version that xAI's stable channel names; it publishes no GitHub release.
grok_latest() {
  local v
  v="$(curl -fsSL --max-time 10 "$1/stable" 2>/dev/null | tr -d '[:space:]')" || return 3
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 3
  printf '%s' "$v"
}
# latest_of <tool> <source> <package>: the latest stable version of a row, for check --latest.
latest_of() {
  local repo tag
  case "$2" in
    apt) apt_latest "$3" ;;
    nodesource) apt_latest nodejs ;;
    npm) npm view "$3" version 2>/dev/null || return 3 ;;
    installer)
      if [ "$1" = op ]; then apt_latest "$3"; return; fi
      if [ "$1" = grok ]; then grok_latest "$3"; return; fi
      repo="$(github_repo "$3")" || return 3
      tag="$(latest_tag "$repo")" || return 3
      printf '%s' "${tag#v}" ;;
    gh-release)
      repo="$(github_repo "$3")" || return 3
      tag="$(latest_tag "$repo")" || return 3
      printf '%s' "${tag#v}" ;;
    feature)
      case "$1" in
        gh) repo=cli/cli ;;
        sshd) apt_latest openssh-server; return ;;
        docker) repo=moby/moby ;;
        tailscale) repo=tailscale/tailscale ;;
        *) return 3 ;;
      esac
      tag="$(latest_tag "$repo")" || return 3
      tag="${tag#docker-v}"
      printf '%s' "${tag#v}" ;;
    *) return 3 ;;
  esac
}
# has_latest_lookup <tool> <source> <package>: whether latest_of has a lookup for the row.
has_latest_lookup() {
  case "$2" in
    apt | nodesource | npm) return 0 ;;
    gh-release) github_repo "$3" >/dev/null ;;
    installer) [ "$1" = op ] || [ "$1" = grok ] || github_repo "$3" >/dev/null ;;
    feature) case "$1" in gh | sshd | docker | tailscale) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}
# package_for <tool> <source> <package>: the Debian package that owns the installed version, when there is one.
package_for() {
  case "$2" in
    apt) printf '%s' "$3" ;;
    nodesource) printf nodejs ;;
    installer) [ "$1" = op ] && printf '%s' "$3" ;;
    feature) [ "$1" = sshd ] && printf openssh-server ;;
    *) return 1 ;;
  esac
}
# is_behind <tool> <source> <package> <shown-version> <latest-version>: 0 behind, 1 current, 3 unverified.
is_behind() {
  local deb installed
  if deb="$(package_for "$1" "$2" "$3")"; then
    command -v dpkg-query >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1 || return 3
    installed="$(dpkg-query -W -f='${Version}' "$deb" 2>/dev/null)" || return 3
    dpkg --compare-versions "$installed" lt "$5" && return 0
    return 1
  fi
  ver_lt "$4" "$5"
}

cmd_list() {
  local scope=image source=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope) [ $# -ge 2 ] || usage; scope="$2"; shift 2 ;;
      --source) [ $# -ge 2 ] || usage; source="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$scope" in image | all) ;; *) usage ;; esac
  [ -z "$source" ] || has_word "$SOURCES" "$source" || usage
  load
  rows "$scope" "$source" | cut -f2-8
}

# Generated API commands can return parent help with exit 0 for an unknown child.
check_humanlayer() {
  local command="$1" path flags help flag failed=0
  while IFS='|' read -r path flags; do
    # shellcheck disable=SC2086 # paths contain separate command words
    if ! help="$(HUMANLAYER_DISABLE_SELF_UPDATE=1 "$command" $path --help 2>&1)" \
      || ! grep -Fxq "Usage: humanlayer $path [options]" <<<"$help"; then
      echo "humanlayer present; missing capability: $path"
      failed=1; continue
    fi
    for flag in $flags; do
      if ! grep -Eq -- "^[[:space:]]*$flag([[:space:]]|$)" <<<"$help"; then
        echo "humanlayer present; missing capability: $path $flag"
        failed=1
      fi
    done
  done <<'CAPABILITIES'
daemon launch|--launch-token --no-self-update
api auth daemon launch-token create|
api sync online-hosts|
api sessions create|--host-id --working-directory
api sessions list|
api sessions interrupt|
api artifacts list|
api artifacts get|
api tasks archive|--cascade-to-sessions
api hosts delete|
CAPABILITIES
  return "$failed"
}

cmd_check() {
  local scope=image latest=0 line tool command source package version probe present=0 missing=0 behind=0 unknown=0 v newest rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope) [ $# -ge 2 ] || usage; scope="$2"; shift 2 ;;
      --latest) latest=1; shift ;;
      *) usage ;;
    esac
  done
  case "$scope" in image | all) ;; *) usage ;; esac
  load
  if [ "$latest" = 1 ] && command -v apt-cache >/dev/null 2>&1 && ! apt_lists_present; then
    echo "apt indexes: none in ${TOOLS_APT_LISTS:-/var/lib/apt/lists}; run apt-get update as root before check --latest"
  fi
  while IFS=$'\t' read -r line tool command source package version probe _; do
    [ -n "$tool" ] || continue
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "$tool missing"; missing=$((missing + 1)); continue
    fi
    present=$((present + 1))
    v="$(present_version "$command" "$probe")"
    if [ "$tool" = humanlayer ] && ! check_humanlayer "$command"; then
      echo "humanlayer present $v behind required capabilities"; behind=$((behind + 1)); continue
    fi
    if [ "$latest" = 1 ]; then
      if [ "$v" = "(no version)" ]; then
        echo "$tool present; installed version unavailable from $command $probe"; unknown=$((unknown + 1)); continue
      fi
      if [ "$tool" = humanlayer ]; then
        if ! v="$(npm_command_version "$command" "$package")"; then
          echo "humanlayer present; installed npm package version unavailable"; unknown=$((unknown + 1)); continue
        fi
      fi
      if ! newest="$(latest_of "$tool" "$source" "$package")" || [ -z "$newest" ]; then
        echo "$tool present $v; latest stable unavailable"; unknown=$((unknown + 1)); continue
      fi
      if is_behind "$tool" "$source" "$package" "$v" "$newest"; then
        echo "$tool present $v behind $newest"; behind=$((behind + 1)); continue
      else
        rc=$?
        if [ "$rc" = 3 ]; then echo "$tool present $v; installed package version unavailable"; unknown=$((unknown + 1)); continue; fi
      fi
    fi
    echo "$tool present $v"
  done < <(rows "$scope")
  echo "tools: $present present, $missing missing, $behind behind, $unknown latest unavailable"
  [ "$unknown" -eq 0 ] || return 3
  [ "$missing" -eq 0 ] && [ "$behind" -eq 0 ]
}

# --- apply --------------------------------------------------------------------------------------------------------------

PREFIX="" STATUS=0 SCOPE=image
worse() { [ "$1" -gt "$STATUS" ] && STATUS="$1"; return 0; }
need_root() { [ "$(id -u)" = 0 ] || { echo "$1: needs root to install $2" >&2; worse 1; return 1; }; }

apply_apt() {
  local line tool command source package version lists="${TOOLS_APT_LISTS:-/var/lib/apt/lists}" installed candidate pkgs="" names="" unknown=""
  [ -n "$(rows "$SCOPE" apt)" ] || { echo "apt: no rows"; return 0; }
  need_root apt "the apt rows" || return 0
  if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    echo "apt: cannot refresh the package indexes; no apt row was changed" >&2; worse 3; return 0
  fi
  # A row is installed when its command is missing, dpkg does not own its package, or the candidate is newer.
  while IFS=$'\t' read -r line tool command source package version probe _; do
    [ -n "$tool" ] || continue
    if command -v "$command" >/dev/null 2>&1 && installed="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null)"; then
      if ! candidate="$(apt_latest "$package")"; then unknown="$unknown $tool"; continue; fi
      dpkg --compare-versions "$installed" lt "$candidate" || continue
    fi
    pkgs="$pkgs $package"; names="$names $tool"
  done < <(rows "$SCOPE" apt)
  [ -z "$unknown" ] || { echo "apt: no candidate version for:$unknown" >&2; worse 3; }
  if [ -z "$pkgs" ]; then rm -rf "${lists:?}"/*; echo "apt: every row current"; return 0; fi
  # shellcheck disable=SC2086 # one word for each package
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $pkgs >/dev/null; then
    rm -rf "${lists:?}"/*
    echo "apt: installed$names"
  else
    rm -rf "${lists:?}"/*
    echo "apt: install failed:$names" >&2; worse 1; return 0
  fi
  # Debian names the fd binary fdfind, because another package has fd.
  if has_word "$names" fd && ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
    mkdir -p "$PREFIX/bin" && ln -sf "$(command -v fdfind)" "$PREFIX/bin/fd" && echo "apt: linked fd to fdfind"
  fi
}

apply_nodesource() {
  local line tool command source package version have want script
  while IFS=$'\t' read -r line tool command source package version probe _; do
    [ -n "$tool" ] || continue
    if ! want="$(node_latest)" || [ -z "$want" ]; then
      echo "nodesource: cannot read the latest stable Node release; $tool was not changed" >&2
      worse 3; continue
    fi
    have="$(node --version 2>/dev/null | version_in)"
    if [ -n "$have" ] && ! ver_lt "$have" "$want"; then echo "$tool current $have"; continue; fi
    need_root nodesource "$tool $package" || continue
    script="$(curl -fsSL "https://deb.nodesource.com/setup_$package")" || { echo "nodesource: cannot reach the setup script for $package; $tool is missing" >&2; worse 3; continue; }
    if bash -c "$script" >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends nodejs >/dev/null; then
      rm -rf /var/lib/apt/lists/*
      echo "installed $tool $(node --version 2>/dev/null | version_in)"
    else
      echo "install failed: $tool $package" >&2; worse 1
    fi
  done < <(rows "$SCOPE" nodesource)
}

# The version of an npm package installed under the prefix, from its package.json; nothing when it is not there.
npm_installed() {
  local f="$PREFIX/lib/node_modules/$1/package.json"
  # The first "version" key, so a package.json on one line or on many reads the same.
  [ -f "$f" ] && grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/'
}

repair_humanlayer_launcher() {
  node - "$PREFIX" <<'JS'
const fs = require('node:fs'), path = require('node:path');
try {
  const prefix = fs.realpathSync(process.argv[2]);
  const wrapperDir = path.join(prefix, 'lib/node_modules/@humanlayer/cli');
  const wrapper = JSON.parse(fs.readFileSync(path.join(wrapperDir, 'package.json'), 'utf8'));
  const name = `@humanlayer/cli-${process.platform}-${process.arch}`;
  if (wrapper.name !== '@humanlayer/cli' || wrapper.optionalDependencies?.[name] !== wrapper.version) {
    throw new Error(`no matching optional dependency ${name}`);
  }
  const manifest = require.resolve(`${name}/package.json`, {paths: [wrapperDir]});
  const pkg = JSON.parse(fs.readFileSync(manifest, 'utf8'));
  if (pkg.name !== name || pkg.version !== wrapper.version) throw new Error(`mismatched package ${name}`);
  const binary = path.join(path.dirname(manifest), 'bin/humanlayer');
  fs.accessSync(binary, fs.constants.X_OK);
  const launcher = path.join(prefix, 'bin/humanlayer');
  fs.mkdirSync(path.dirname(launcher), {recursive: true});
  let existing;
  try { existing = fs.lstatSync(launcher); } catch (err) { if (err.code !== 'ENOENT') throw err; }
  if (existing) {
    if (!existing.isSymbolicLink()) throw new Error(`refusing to replace non-symlink ${launcher}`);
    fs.unlinkSync(launcher);
  }
  fs.symlinkSync(path.relative(path.dirname(launcher), binary), launcher);
} catch (err) {
  console.error(`humanlayer launcher repair: ${err.message}`);
  process.exit(1);
}
JS
}

apply_npm() {
  local line tool command source package version have want probe npm_version output script_arg
  command -v npm >/dev/null 2>&1 || { echo "npm: not on the PATH; apply nodesource first" >&2; worse 1; return 0; }
  npm_version="$(npm --version)" || { echo "npm: cannot read its version" >&2; worse 1; return 0; }
  while IFS=$'\t' read -r line tool command source package version probe _; do
    [ -n "$tool" ] || continue
    have="$(npm_installed "$package")"
    # A package with no executable of its row is not installed: npm reinstalls it, and a lookup that fails names it missing.
    if [ -n "$have" ] && [ ! -x "$PREFIX/bin/$command" ]; then
      echo "repair: $tool $have has no $command in $PREFIX/bin; reinstalling"
      have=""
    elif [ -n "$have" ] && ! "$PREFIX/bin/$command" "$probe" </dev/null >/dev/null 2>&1; then
      echo "repair: $tool $have failed $command $probe; reinstalling"
      have=""
    fi
    if [ "$version" = latest ]; then
      if ! want="$(npm view "$package" version 2>/dev/null)" || [ -z "$want" ]; then
        if [ -n "$have" ]; then echo "$tool kept $have: the registry cannot be reached for $package"
        else echo "npm: the registry cannot be reached for $package; $tool is missing" >&2; worse 3; fi
        continue
      fi
    else
      want="$version"
    fi
    if [ -n "$have" ] && ! ver_lt "$have" "$want"; then echo "$tool current $have"; continue; fi
    script_arg=""
    # npm 12 blocks unapproved lifecycle scripts even when ignore-scripts is false.
    if ! ver_lt "$npm_version" 12.0.0; then script_arg="--allow-scripts=$package"; fi
    if npm install -g --prefix "$PREFIX" --no-audit --no-fund --loglevel=error ${script_arg:+"$script_arg"} "$package@$want" >/dev/null; then
      if [ "$package" = @humanlayer/cli ] && [ ! -x "$PREFIX/lib/node_modules/$package/bin/humanlayer" ]; then
        if ! repair_humanlayer_launcher; then
          echo "install failed: $tool $package@$want; platform launcher repair failed" >&2
          worse 1; continue
        fi
      fi
      if ! output="$("$PREFIX/bin/$command" "$probe" </dev/null 2>&1)"; then
        if [ "$package" = @anthropic-ai/claude-code ]; then
          echo "repair: $tool failed $command $probe; running install.cjs"
          if ! (cd "$PREFIX/lib/node_modules/$package" && node install.cjs); then
            echo "install failed: $tool $package@$want; install.cjs failed" >&2
            worse 1; continue
          fi
          if output="$("$PREFIX/bin/$command" "$probe" </dev/null 2>&1)"; then
            echo "installed $tool $want${have:+ (was $have)}"
            continue
          fi
        fi
        echo "install failed: $tool $package@$want; $command $probe failed: $output" >&2
        worse 1; continue
      fi
      echo "installed $tool $want${have:+ (was $have)}"
    else
      echo "install failed: $tool $package@$want" >&2; worse 1
    fi
  done < <(rows "$SCOPE" npm)
}

# want_tag <tool> <version> <owner/repo>: the release tag to install, or exit 3 when the latest cannot be read.
want_tag() {
  if [ "$2" != latest ]; then printf 'v%s' "$2"; return 0; fi
  latest_tag "$3" || { echo "$1: cannot read the latest release of $3" >&2; return 3; }
}

# install_<tool> <version> <package>: one function for each installer and gh-release row, because each takes its own options.

install_op() {
  local version="$1" package="$2" key policy arch
  [ "$version" = latest ] || { echo "op: the 1Password repository takes only the latest release, not $version" >&2; return 1; }
  [ "$package" = 1password-cli ] || { echo "op: unknown package: $package" >&2; return 1; }
  command -v op >/dev/null 2>&1 && { echo "op current $(op --version 2>/dev/null | version_in)"; return 0; }
  need_root op "$package" || return 1
  key="$(mktemp)"; policy="$(mktemp)"
  if ! curl -fsSL -o "$key" https://downloads.1password.com/linux/keys/1password.asc \
    || ! curl -fsSL -o "$policy" https://downloads.1password.com/linux/debian/debsig/1password.pol; then
    rm -f "$key" "$policy"; echo "op: cannot download the 1Password signing files" >&2; return 3
  fi
  arch="$(dpkg --print-architecture)"
  mkdir -p /etc/debsig/policies/AC2D62742012EA22 /usr/share/debsig/keyrings/AC2D62742012EA22 /usr/share/keyrings
  if ! gpg --batch --yes --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg "$key" \
    || ! install -m 0644 "$policy" /etc/debsig/policies/AC2D62742012EA22/1password.pol \
    || ! gpg --batch --yes --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg "$key" \
    || ! printf 'deb [arch=%s signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/%s stable main\n' "$arch" "$arch" > /etc/apt/sources.list.d/1password.list \
    || ! DEBIAN_FRONTEND=noninteractive apt-get update -qq \
    || ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$package" >/dev/null; then
    rm -f "$key" "$policy"; echo "install failed: op" >&2; return 1
  fi
  rm -f "$key" "$policy"; rm -rf /var/lib/apt/lists/*
  echo "installed op $(op --version 2>/dev/null | version_in)"
}

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

install_actionlint() {
  local version="$1" repo="$2" tag have os arch asset sums tmp want got
  have="$("$PREFIX/bin/actionlint" --version 2>/dev/null | version_in)"
  if ! tag="$(want_tag actionlint "$version" "$repo")"; then [ -n "$have" ] && { echo "actionlint kept $have"; return 0; }; return 3; fi
  if [ -n "$have" ] && ! ver_lt "$have" "${tag#v}"; then echo "actionlint current $have"; return 0; fi
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "actionlint: no release for $(uname -s)" >&2; return 1 ;; esac
  case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) echo "actionlint: no release for $(uname -m)" >&2; return 1 ;; esac
  asset="actionlint_${tag#v}_${os}_${arch}.tar.gz"; sums="actionlint_${tag#v}_checksums.txt"
  tmp="$(mktemp -d)"
  if ! curl -fsSL -o "$tmp/$asset" "https://github.com/$repo/releases/download/$tag/$asset" \
    || ! curl -fsSL -o "$tmp/$sums" "https://github.com/$repo/releases/download/$tag/$sums"; then
    rm -rf "$tmp"; echo "actionlint: cannot download $tag" >&2; [ -n "$have" ] && return 1; return 3
  fi
  want="$(awk -v a="$asset" '$2 == a { print $1 }' "$tmp/$sums")"
  got="$(sha256_of "$tmp/$asset")"
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    rm -rf "$tmp"; echo "actionlint: $asset does not match the release's checksums file" >&2; return 1
  fi
  mkdir -p "$PREFIX/bin"
  if tar -xzf "$tmp/$asset" -C "$tmp" actionlint && cp "$tmp/actionlint" "$PREFIX/bin/actionlint" && chmod 0755 "$PREFIX/bin/actionlint"; then
    rm -rf "$tmp"; echo "installed actionlint ${tag#v}${have:+ (was $have)}"
  else
    rm -rf "$tmp"; echo "install failed: actionlint" >&2; return 1
  fi
}

# xAI publishes no checksum for the binary, so the HTTPS download and the version probe are the only checks.
# uv's release names each archive by its Rust target and publishes a .sha256 file beside it.
# The t3 package on npm downloads this archive on first run, into a home that a rebuild clears, so the row installs the archive.
install_t3() {
  local version="$1" repo="$2" tag have os arch asset tmp want got
  have="$("$PREFIX/bin/t3" --version 2>/dev/null | version_in)"
  if ! tag="$(want_tag t3 "$version" "$repo")"; then [ -n "$have" ] && { echo "t3 kept $have"; return 0; }; return 3; fi
  if [ -n "$have" ] && ! ver_lt "$have" "${tag#v}"; then echo "t3 current $have"; return 0; fi
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "t3: no release for $(uname -s)" >&2; return 1 ;; esac
  case "$(uname -m)" in x86_64 | amd64) arch=x64 ;; aarch64 | arm64) arch=arm64 ;; *) echo "t3: no release for $(uname -m)" >&2; return 1 ;; esac
  asset="t3-${tag#v}-$os-$arch.tar.gz"
  tmp="$(mktemp -d)"
  if ! curl -fsSL -o "$tmp/$asset" "https://github.com/$repo/releases/download/$tag/$asset" \
    || ! curl -fsSL -o "$tmp/SHA256SUMS" "https://github.com/$repo/releases/download/$tag/SHA256SUMS"; then
    rm -rf "$tmp"; echo "t3: cannot download $tag" >&2; [ -n "$have" ] && return 1; return 3
  fi
  want="$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1 }' "$tmp/SHA256SUMS")"
  got="$(sha256_of "$tmp/$asset")"
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    rm -rf "$tmp"; echo "t3: $asset does not match the release's SHA256SUMS" >&2; return 1
  fi
  mkdir -p "$tmp/unpacked" "$PREFIX/bin" "$PREFIX/lib"
  if tar -xzf "$tmp/$asset" -C "$tmp/unpacked" --strip-components=1 && "$tmp/unpacked/t3" --version >/dev/null \
    && rm -rf "$PREFIX/lib/t3" && mv "$tmp/unpacked" "$PREFIX/lib/t3" && ln -sfn ../lib/t3/t3 "$PREFIX/bin/t3"; then
    rm -rf "$tmp"; echo "installed t3 ${tag#v}${have:+ (was $have)}"
  else
    rm -rf "$tmp"; echo "install failed: t3" >&2; return 1
  fi
}

install_uv() {
  local version="$1" repo="$2" tag have os arch asset tmp want got bin
  have="$("$PREFIX/bin/uv" --version 2>/dev/null | version_in)"
  if ! tag="$(want_tag uv "$version" "$repo")"; then [ -n "$have" ] && { echo "uv kept $have"; return 0; }; return 3; fi
  if [ -n "$have" ] && ! ver_lt "$have" "${tag#v}"; then echo "uv current $have"; return 0; fi
  case "$(uname -s)" in Linux) os="unknown-linux-gnu" ;; Darwin) os="apple-darwin" ;; *) echo "uv: no release for $(uname -s)" >&2; return 1 ;; esac
  case "$(uname -m)" in x86_64 | amd64) arch=x86_64 ;; aarch64 | arm64) arch=aarch64 ;; *) echo "uv: no release for $(uname -m)" >&2; return 1 ;; esac
  asset="uv-$arch-$os.tar.gz"
  tmp="$(mktemp -d)"
  if ! curl -fsSL -o "$tmp/$asset" "https://github.com/$repo/releases/download/$tag/$asset" \
    || ! curl -fsSL -o "$tmp/$asset.sha256" "https://github.com/$repo/releases/download/$tag/$asset.sha256"; then
    rm -rf "$tmp"; echo "uv: cannot download $tag" >&2; [ -n "$have" ] && return 1; return 3
  fi
  want="$(awk '{ print $1; exit }' "$tmp/$asset.sha256")"
  got="$(sha256_of "$tmp/$asset")"
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    rm -rf "$tmp"; echo "uv: $asset does not match its .sha256 file" >&2; return 1
  fi
  mkdir -p "$PREFIX/bin"
  if tar -xzf "$tmp/$asset" -C "$tmp"; then
    for bin in uv uvx; do
      if ! cp "$tmp/uv-$arch-$os/$bin" "$PREFIX/bin/$bin" || ! chmod 0755 "$PREFIX/bin/$bin"; then rm -rf "$tmp"; echo "install failed: $bin" >&2; return 1; fi
    done
    rm -rf "$tmp"; echo "installed uv ${tag#v}${have:+ (was $have)}"
  else
    rm -rf "$tmp"; echo "install failed: uv" >&2; return 1
  fi
}

install_grok() {
  local version="$1" base="$2" have want os arch tmp got
  have="$("$PREFIX/bin/grok" --version </dev/null 2>/dev/null | version_in)"
  if [ "$version" = latest ]; then
    if ! want="$(grok_latest "$base")"; then
      [ -n "$have" ] && { echo "grok kept $have: cannot read $base/stable"; return 0; }
      echo "grok: cannot read $base/stable" >&2; return 3
    fi
  else
    want="$version"
  fi
  if [ -n "$have" ] && ! ver_lt "$have" "$want"; then echo "grok current $have"; return 0; fi
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=macos ;; *) echo "grok: no build for $(uname -s)" >&2; return 1 ;; esac
  case "$(uname -m)" in x86_64 | amd64) arch=x86_64 ;; aarch64 | arm64) arch=aarch64 ;; *) echo "grok: no build for $(uname -m)" >&2; return 1 ;; esac
  tmp="$(mktemp -d)"
  if ! curl -fsSL -o "$tmp/grok.gz" "$base/grok-$want-$os-$arch.gz" || ! gzip -dc "$tmp/grok.gz" > "$tmp/grok"; then
    rm -rf "$tmp"; echo "grok: cannot download $want for $os-$arch" >&2; [ -n "$have" ] && return 1; return 3
  fi
  chmod 0755 "$tmp/grok"
  got="$("$tmp/grok" --version </dev/null 2>/dev/null | version_in)"
  if [ "$got" != "$want" ]; then
    rm -rf "$tmp"; echo "grok: the downloaded binary reports '${got:-no version}', not $want" >&2; return 1
  fi
  mkdir -p "$PREFIX/bin"
  if cp "$tmp/grok" "$PREFIX/bin/grok"; then
    rm -rf "$tmp"; echo "installed grok $want${have:+ (was $have)}"
  else
    rm -rf "$tmp"; echo "install failed: grok" >&2; return 1
  fi
}

install_no_mistakes() {
  local version="$1" installer="$2" repo have want script restart_line restart_count
  [ "$version" = latest ] || { echo "no-mistakes: the installer takes only the latest release, not $version" >&2; return 1; }
  [ "$installer" = https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh ] \
    || { echo "no-mistakes: unknown installer: $installer" >&2; return 1; }
  repo="$(github_repo "$installer")" || { echo "no-mistakes: cannot resolve the repository from $installer" >&2; return 1; }
  want="$(latest_tag "$repo")" || { echo "no-mistakes: cannot read the latest release of $repo" >&2; return 3; }
  want="${want#v}"
  have="$("$PREFIX/bin/no-mistakes" --version </dev/null 2>/dev/null | version_in)"
  if [ -n "$have" ] && ! ver_lt "$have" "$want"; then echo "no-mistakes current $have"; return 0; fi
  script="$(curl -fsSL "$installer")" || { echo "no-mistakes: cannot download $installer" >&2; return 3; }
  restart_line="\"\$BIN_PATH\" daemon restart >/dev/null"
  restart_count="$(printf '%s\n' "$script" | grep -Fxc "$restart_line")"
  [ "$restart_count" = 1 ] \
    || { echo "no-mistakes: the installer daemon restart changed; refusing to run it during an image build" >&2; return 1; }
  script="$(printf '%s\n' "$script" | grep -Fvx "$restart_line")"
  if printf '%s\n' "$script" | NO_MISTAKES_INSTALL_DIR="$PREFIX/lib/no-mistakes/bin" \
    NO_MISTAKES_LINK_DIR="$PREFIX/bin" sh; then
    have="$("$PREFIX/bin/no-mistakes" --version </dev/null 2>/dev/null | version_in)"
    [ "$have" = "$want" ] || { echo "no-mistakes: installed version '${have:-none}' is not $want" >&2; return 1; }
    echo "installed no-mistakes $have"
  else
    echo "install failed: no-mistakes" >&2
    return 1
  fi
}

apply_function_rows() { # <source>
  local line tool command source package version fn rc
  while IFS=$'\t' read -r line tool command source package version probe _; do
    [ -n "$tool" ] || continue
    fn="$(fn_of "$tool")"
    "$fn" "$version" "$package"; rc=$?
    worse "$rc"
  done < <(rows "$SCOPE" "$1")
}
apply_installer() { apply_function_rows installer; }
apply_gh-release() { apply_function_rows gh-release; }

cmd_apply() {
  local sources="" s
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) [ $# -ge 2 ] || usage; PREFIX="$2"; shift 2 ;;
      --sources) [ $# -ge 2 ] || usage; sources="$(printf '%s' "$2" | tr ',' ' ')"; shift 2 ;;
      --scope) [ $# -ge 2 ] || usage; SCOPE="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$PREFIX" ] && [ -n "$sources" ] || usage
  case "$SCOPE" in image | all) ;; *) usage ;; esac
  for s in $sources; do
    has_word "$INSTALL_ORDER" "$s" || { echo "tools: apply takes the sources $INSTALL_ORDER; not $s" >&2; exit 2; }
  done
  load
  for s in $INSTALL_ORDER; do
    if has_word "$sources" "$s"; then "apply_$s"; fi
  done
  exit "$STATUS"
}

# --- lint ---------------------------------------------------------------------------------------------------------------

# The Dockerfile's instructions, one per line with its continuation lines joined: "<first line number><TAB><text>".
instructions() {
  awk '
    function flush() { if (text != "") printf "%d\t%s\n", start, text; text = "" }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (text == "") start = NR
      cont = sub(/\\[[:space:]]*$/, "", line)
      text = text " " line
      if (!cont) flush()
    }
    END { flush() }' "$1"
}

# dockerfile_faults <Dockerfile>: each RUN that installs a tool outside tools.sh. The Dockerfile may apt-get install the
# BASE_PACKAGES only, run tools.sh apply, install the pinned Skills Manager CLI, and download the Playwright browser.
dockerfile_faults() {
  local file="$1" n text cmd pkgs p bad
  while IFS=$'\t' read -r n text; do
    case "$text" in *[[:space:]]RUN[[:space:]]*) ;; *) continue ;; esac
    bad=""
    # Each command of the RUN, split at && ; and |, so one install hides in no chain.
    while IFS= read -r cmd; do
      cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//; s/^RUN[[:space:]]*//')"
      case "$cmd" in
        *"tools.sh apply"*) ;;
        "playwright install"*) ;;
        "/opt/digio/tools/skills-manager-cli.sh install "*) ;;
        *"apt-get install"* | *"apt install"*)
          pkgs="$(printf '%s' "$cmd" | sed 's/.*install//')"
          for p in $pkgs; do
            case "$p" in -*) continue ;; esac
            has_word "$BASE_PACKAGES" "$p" || bad="$bad apt $p;"
          done ;;
        *"npm install"* | *"npm i "* | *"npm add"* | *"yarn global"* | *corepack* | *"pip install"* | *"pip3 install"* | *"gh extension install"* | *"go install"*)
          bad="$bad $cmd;" ;;
        curl* | wget* | *"install.sh"*)
          bad="$bad $cmd;" ;;
      esac
    done < <(printf '%s\n' "$text" | awk '{ gsub(/&&|;|\|/, "\n"); print }')
    [ -z "$bad" ] || echo "$file:$n: installs a tool outside tools.sh:${bad%;}"
  done < <(instructions "$file")
}

# The feature ids in a devcontainer.json: each key that names an OCI path, such as ghcr.io/devcontainers/features/sshd:1.
features_in() { grep -oE '"[a-z0-9.-]+\.[a-z]+/[^"]+"[[:space:]]*:' "$1" | sed 's/^"//; s/"[[:space:]]*:$//' | sort -u; }

cmd_lint() {
  [ $# -eq 0 ] || usage
  local dockerfile="${TOOLS_DOCKERFILE:-$DIR/../assets/image/Dockerfile}"
  local devcontainer="${TOOLS_DEVCONTAINER:-$DIR/../assets/image/devcontainer.json}"
  local parsed faults=0 line tool command source package version fn f names
  parsed="$(parse)"
  while IFS= read -r f; do [ -n "$f" ] && { echo "$f"; faults=$((faults + 1)); }; done < <(sed -n 's/^FAULT	//p' <<<"$parsed")
  ROWS="$(sed -n 's/^ROW	//p' <<<"$parsed")"
  # An installer or gh-release row needs its own install function.
  while IFS=$'\t' read -r line tool command source package version probe _; do
    [ -n "$tool" ] || continue
    has_latest_lookup "$tool" "$source" "$package" \
      || { echo "$LIST:$line: $tool: the $source row has no latest stable lookup in tools.sh"; faults=$((faults + 1)); }
    case "$source" in installer | gh-release) ;; *) continue ;; esac
    fn="$(fn_of "$tool")"
    declare -F "$fn" >/dev/null || { echo "$LIST:$line: $tool: the $source row has no $fn function in tools.sh"; faults=$((faults + 1)); }
  done <<<"$ROWS"
  # The Dockerfile installs no tool itself.
  if [ -f "$dockerfile" ]; then
    while IFS= read -r f; do [ -n "$f" ] && { echo "$f"; faults=$((faults + 1)); }; done < <(dockerfile_faults "$dockerfile")
  else
    echo "$dockerfile: no such Dockerfile"; faults=$((faults + 1))
  fi
  # Each feature row is a feature in devcontainer.json, and each feature there is a row.
  if [ -f "$devcontainer" ]; then
    names="$(features_in "$devcontainer")"
    while IFS=$'\t' read -r line tool command source package version probe _; do
      [ "$source" = feature ] || continue
      grep -Fxq "$package" <<<"$names" || { echo "$LIST:$line: $tool: the feature $package is not in $devcontainer"; faults=$((faults + 1)); }
    done <<<"$ROWS"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      awk -F'\t' -v f="$f" '$4 == "feature" && $5 == f { found = 1 } END { exit !found }' <<<"$ROWS" \
        || { echo "$devcontainer: the feature $f has no row in $LIST"; faults=$((faults + 1)); }
    done <<<"$names"
  else
    echo "$devcontainer: no such devcontainer.json"; faults=$((faults + 1))
  fi
  if [ "$faults" -gt 0 ]; then echo "lint: $faults faults"; return 1; fi
  echo "lint: ok, $(grep -c . <<<"$ROWS") rows"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  list) cmd_list "$@" ;;
  apply) cmd_apply "$@" ;;
  check) cmd_check "$@" ;;
  lint) cmd_lint "$@" ;;
  version-lt) [ $# -eq 2 ] || usage; ver_lt "$1" "$2" ;;
  latest-release)
    [ $# -eq 1 ] || usage
    tag="$(latest_tag "$1")" || exit 3
    version="$(printf '%s' "$tag" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//')"
    [ -n "$version" ] || exit 3
    printf '%s\n' "$version"
    ;;
  *) usage ;;
esac
