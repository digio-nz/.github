#!/usr/bin/env bash
# workbench-image: build the one workbench image in digio-nz/.github and publish it to GitHub's registry and Vercel's.
#
#   workbench-image.sh build [--tag <tag>] [--platform <p>] [--push] [--dry-run]   build here with the devcontainer CLI, so the features are baked in
#   workbench-image.sh publish [--ref <branch>] [--platform <p>] [--type release|trial] [--dry-run]
#                                                                                  run the Build image workflow and print the run URL
#   workbench-image.sh check [--tag <tag>]                                         boot a sandbox from the VCR image; print its user, home and tools
#   workbench-image.sh layers --tag <tag>                                          each compressed layer of the linux/amd64 build; VCR refuses one over 2 GB
#   workbench-image.sh status                                                      the newest tags in ghcr.io and in VCR
#   workbench-image.sh test                                                        run the offline self-test
#
# The image is image/assets/image/devcontainer.json; its tools are references/tools.tsv (scripts/tools.sh).
# Images: ghcr.io/digio-nz/workbench:<tag> and vcr.vercel.com/<team>/<project>/workbench:<tag>;
# DIGIO_SANDBOX_TEAM (default digbycampbells-projects) and DIGIO_SANDBOX_PROJECT (default digio-sandbox) name the VCR home.
# Exit 0 OK; 1 a finding: a missing tool, a layer over 2 GB; 2 bad usage; 3 an external call failed: a sandbox that does
# not start, a registry that cannot be read.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd -P)"
MICHELIN="$(cd "$DIR/../.." && pwd -P)"
CONFIG="image/assets/image/devcontainer.json"
TEAM="${DIGIO_SANDBOX_TEAM:-digbycampbells-projects}"
PROJECT="${DIGIO_SANDBOX_PROJECT:-digio-sandbox}"
GHCR="ghcr.io/digio-nz/workbench"
# VCR refuses a compressed layer over 2 GB.
LAYER_MAX=2000000000
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "workbench-image: $*" >&2; exit 2; }

tag=latest; type=release; platform=linux/amd64; push=0; dry=0; ref=main; tag_set=0
parse() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag) [ $# -ge 2 ] || usage; tag="$2"; tag_set=1; shift 2 ;;
      --type) [ $# -ge 2 ] || usage; type="$2"; shift 2 ;;
      --platform) [ $# -ge 2 ] || usage; platform="$2"; shift 2 ;;
      --ref) [ $# -ge 2 ] || usage; ref="$2"; shift 2 ;;
      --push) push=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) usage ;;
    esac
  done
}
show_or_run() { if [ "$dry" = 1 ]; then echo "would run: $*"; else echo "run: $*"; "$@"; fi; }

# The tool check that runs in the sandbox: the user, the home, then tools.sh check from the image's own copy. The
# devcontainer features delete the APT indexes after the Dockerfile, so the sandbox reads current ones first.
# shellcheck disable=SC2016 # the sandbox expands these
SANDBOX_CHECK='printf "user: %s\nhome: %s\n" "$(id -un)" "$HOME"; sudo -n apt-get update -qq >/dev/null 2>&1 || echo "apt indexes: sudo -n apt-get update failed"; /opt/digio/tools/tools.sh check --scope image --latest'

cmd_check() {
  local out rc=0 last missing behind unknown
  out="$(vercel sandbox run --scope "$TEAM" --project "$PROJECT" --image "workbench:$tag" --timeout 5m --rm -- bash -c "$SANDBOX_CHECK" 2>&1)" || rc=$?
  printf '%s\n' "$out" | grep -E '^(user|home|apt indexes): |^[a-z0-9][a-z0-9.-]* (present|missing)|^tools: ' || true
  last="$(printf '%s\n' "$out" | grep -E '^tools: [0-9]+ present, [0-9]+ missing, [0-9]+ behind, [0-9]+ latest unavailable$' | tail -n 1 || true)"
  if [ -z "$last" ]; then
    printf '%s\n' "$out" | tail -n 5 >&2
    echo "check: the sandbox did not start from workbench:$tag, or did not run the tool check (exit $rc)" >&2
    exit 3
  fi
  missing="$(printf '%s\n' "$out" | sed -n 's/^\([a-z0-9][a-z0-9.-]*\) missing$/\1/p' | paste -sd' ' -)"
  behind="$(printf '%s\n' "$out" | sed -n 's/^\([a-z0-9][a-z0-9.-]*\) present .* behind .*$/\1/p' | paste -sd' ' -)"
  unknown="$(printf '%s\n' "$out" | sed -n 's/^\([a-z0-9][a-z0-9.-]*\) present.*\(latest stable unavailable\|installed .* unavailable\).*$/\1/p' | paste -sd' ' -)"
  if [ -z "$missing" ] && [ -z "$behind" ] && [ -z "$unknown" ]; then
    if [ "$rc" -ne 0 ]; then
      echo "check: workbench:$tag tool check failed (exit $rc)" >&2
      exit 1
    fi
    echo "check: workbench:$tag has every tool at latest stable"
    return
  fi
  [ -z "$missing" ] || echo "check: workbench:$tag is missing: $missing" >&2
  [ -z "$behind" ] || echo "check: workbench:$tag is behind: $behind" >&2
  [ -z "$unknown" ] || { echo "check: workbench:$tag could not verify latest stable for: $unknown" >&2; exit 3; }
  exit 1
}

# The compressed layers of the linux/amd64 build: "layer <digest> <bytes>". An index names the platform's manifest.
cmd_layers() {
  local raw digest layers big=0 d size
  [ "$tag_set" = 1 ] || die "layers needs --tag <tag>"
  raw="$(docker buildx imagetools inspect --raw "$GHCR:$tag")" || { echo "layers: cannot read $GHCR:$tag" >&2; exit 3; }
  if jq -e '.manifests' >/dev/null 2>&1 <<<"$raw"; then
    digest="$(jq -r '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest // empty' <<<"$raw")"
    [ -n "$digest" ] || { echo "layers: $GHCR:$tag has no linux/amd64 build" >&2; exit 1; }
    raw="$(docker buildx imagetools inspect --raw "$GHCR@$digest")" || { echo "layers: cannot read $GHCR@$digest" >&2; exit 3; }
  fi
  layers="$(jq -r '.layers[] | "\(.digest) \(.size)"' <<<"$raw")" || { echo "layers: $GHCR:$tag has no layer list" >&2; exit 3; }
  while read -r d size; do
    [ -n "$d" ] || continue
    if [ "$size" -gt "$LAYER_MAX" ]; then echo "layer $d $size over 2 GB"; big=$((big + 1)); else echo "layer $d $size"; fi
  done <<<"$layers"
  if [ "$big" -gt 0 ]; then echo "layers: $big layers over 2 GB; VCR refuses them" >&2; exit 1; fi
  echo "layers: $(grep -c . <<<"$layers") layers, each under 2 GB"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  test) exec bash "$DIR/workbench-image-selftest.sh" ;;
  build)
    parse "$@"
    [ -f "$MICHELIN/$CONFIG" ] || die "no $CONFIG under $MICHELIN"
    TOOLS_REFRESH="${TOOLS_REFRESH:-$(date -u +%s)}"; export TOOLS_REFRESH
    args=(npx --yes @devcontainers/cli build --workspace-folder "$MICHELIN" --config "$MICHELIN/$CONFIG" --image-name "$GHCR:$tag" --platform "$platform")
    [ "$push" = 1 ] && args+=(--push)
    if [ "$dry" = 0 ]; then
      lock_dir="$MICHELIN/image/.build"
      hooks_dir="$lock_dir/michelin-hooks"
      [ ! -e "$hooks_dir" ] || die "$hooks_dir already exists"
      mkdir -p "$lock_dir"
      # Bake the live hooks tree into the image (secret-guard + committed shims). Fail closed if the guard is missing.
      cp -a "$MICHELIN/hooks" "$hooks_dir" \
        || { rm -rf "$hooks_dir"; rmdir "$lock_dir" 2>/dev/null || true; die "cannot stage hooks into $hooks_dir"; }
      [ -r "$hooks_dir/pre-push/secret-guard.sh" ] && [ -x "$hooks_dir/shims/pre-push" ] \
        || { rm -rf "$hooks_dir"; rmdir "$lock_dir" 2>/dev/null || true; die "staged hooks lack secret-guard or pre-push shim"; }
      trap 'rm -rf "$hooks_dir"; rmdir "$lock_dir" 2>/dev/null || true' EXIT
    fi
    show_or_run "${args[@]}"
    echo "image: $GHCR:$tag"
    ;;
  publish)
    platform=linux/amd64,linux/arm64; parse "$@"
    case "$type" in release | trial) ;; *) die "type must be release or trial, got '$type'" ;; esac
    # The workflow publishes the linux/amd64 build to VCR, so each run builds it.
    case "$platform" in linux/amd64 | linux/amd64,linux/arm64) ;; *) die "platform must be linux/amd64 or linux/amd64,linux/arm64, got '$platform'" ;; esac
    [ "$ref" = main ] || [ "$type" = trial ] || echo "note: a $type run from $ref is a trial; only main moves latest" >&2
    args=(gh workflow run build-image.yml --repo digio-nz/.github --ref "$ref")
    [ "$dry" = 1 ] && { echo "would run: ${args[*]} -f platforms=$platform -f type=$type"; exit 0; }
    "${args[@]}" -f "platforms=$platform" -f "type=$type" >/dev/null || exit 3
    sleep 3
    url="$(gh run list --repo digio-nz/.github --workflow build-image.yml --limit 1 --json url --jq '.[0].url')" || exit 3
    echo "run: $url"
    ;;
  check) parse "$@"; cmd_check ;;
  layers) parse "$@"; cmd_layers ;;
  status)
    [ $# -eq 0 ] || usage
    echo "ghcr: $(gh api "orgs/digio-nz/packages/container/workbench/versions?per_page=3" --jq '[.[] | .metadata.container.tags[]] | join(" ")' 2>/dev/null || echo 'unreadable (needs read:packages)')"
    echo "vcr: $(vercel vcr inspect workbench --project "$PROJECT" --scope "$TEAM" 2>/dev/null | grep -iE 'tag|ready|status' | tr '\n' ' ' || echo 'no repository yet')"
    ;;
  *) usage ;;
esac
