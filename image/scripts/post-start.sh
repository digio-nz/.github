#!/usr/bin/env bash
# Runs at every container start: join the tailnet, and refresh Michelin, skills and briefs.
# A failed required Michelin step is reported on stderr, and the script exits 1 after running every step.
# A tailnet failure is reported but does not fail the start.
set -uo pipefail
failed=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! bash "$SCRIPT_DIR/tailnet-start.sh"; then
  # A tailnet failure must be visible, but it must not prevent the dev container from starting.
  echo "tailnet: setup failed; container startup will continue" >&2
fi

# A rebuild keeps only /workspaces, so ~/devs links to /workspaces/devs: repos keep the machines' ~/devs paths and survive it.
# Codespaces clones the codespace's own repo to /workspaces/<repo>, so devs links to it too.
link_devs() {
  local devs="$HOME/devs" root="${DIGIO_WORKSPACES:-/workspaces}" target entry own="${CODESPACE_VSCODE_FOLDER:-}"
  [ -d "$root" ] || return 0
  target="$root/devs"
  mkdir -p "$target" || return 1
  if [ -L "$devs" ]; then
    case "$(readlink "$devs")" in
      "$target") ;;
      "$root") rm "$devs" || return 1 ;;
      *) echo "devs: $devs links to $(readlink "$devs"), not $target; fix it by hand" >&2; return 1 ;;
    esac
  fi
  if [ -d "$devs" ] && [ ! -L "$devs" ]; then
    for entry in "$devs"/* "$devs"/.[!.]*; do
      [ -e "$entry" ] || continue
      [ ! -e "$target/${entry##*/}" ] || { echo "devs: $target/${entry##*/} exists; move $entry by hand" >&2; return 1; }
    done
    for entry in "$devs"/* "$devs"/.[!.]*; do [ -e "$entry" ] && { mv "$entry" "$target/" || return 1; }; done
    rmdir "$devs" || return 1
  fi
  [ -L "$devs" ] || { ln -s "$target" "$devs" && echo "devs: $devs links to $target"; } || return 1
  if [ -n "$own" ] && [ -d "$own" ] && [ "$(dirname "$own")" = "$root" ] && [ ! -e "$target/${own##*/}" ]; then
    ln -s "$own" "$target/${own##*/}" && echo "devs: $target/${own##*/} links to $own"
  fi
}
link_devs || { echo "devs: ~/devs is not linked to the kept workspace disk" >&2; failed=1; }

# A rebuild clears ~/.ssh, so a Codespace reaches GitHub over HTTPS with its own token, also for git@github.com: URLs.
if [ -n "${CODESPACES:-}" ]; then
  git config --global url."https://github.com/".insteadOf "git@github.com:" \
    || { echo "git: cannot route git@github.com: URLs over HTTPS" >&2; failed=1; }
fi

# A Codespace keeps the HumanLayer and Codex logins on the kept disk, so a rebuild keeps them. Sign out to cut access.
# A rebuild's fresh folder moves aside when the kept one already holds state.
keep_logins() {
  local root="${DIGIO_WORKSPACES:-/workspaces}" store pair path name src dst entry
  [ -n "${CODESPACES:-}" ] && [ -d "$root" ] || return 0
  store="$root/.home"
  mkdir -p "$store" && chmod 700 "$store" || return 1
  for pair in .humanlayer/riptide:humanlayer-riptide .codex:codex; do
    path="${pair%%:*}" name="${pair##*:}" src="$HOME/${pair%%:*}" dst="$store/${pair##*:}"
    [ "$(readlink "$src" 2>/dev/null)" = "$dst" ] && continue
    [ -L "$src" ] && { echo "logins: $src links to $(readlink "$src"), not $dst; fix it by hand" >&2; return 1; }
    mkdir -p "$dst" && chmod 700 "$dst" || return 1
    if [ -d "$src" ]; then
      if [ -n "$(ls -A "$dst")" ]; then
        mv "$src" "$store/replaced-$name-$(date +%Y%m%dT%H%M%S)" || return 1
      else
        for entry in "$src"/* "$src"/.[!.]*; do [ -e "$entry" ] && { mv "$entry" "$dst/" || return 1; }; done
        rmdir "$src" || return 1
      fi
    fi
    if ! mkdir -p "$(dirname "$src")" || ! ln -s "$dst" "$src"; then return 1; fi
    echo "logins: ~/$path links to $dst"
  done
}
keep_logins || { echo "logins: the HumanLayer and Codex logins are not on the kept disk" >&2; failed=1; }

SKILLS_DIR="$HOME/.digio/michelin"
SKILL_REPO="${DIGIO_SKILLS_ROOT:-$HOME/devs/digio-skills}"
export DIGIO_MICHELIN_ROOT="$SKILLS_DIR" DIGIO_SKILLS_ROOT="$SKILL_REPO"
if [ -d "$SKILLS_DIR/.git" ]; then
  git -C "$SKILLS_DIR" pull -q --ff-only || true
  if [ -d "$SKILL_REPO/.git" ]; then
    git -C "$SKILL_REPO" pull -q --ff-only || echo "digio-skills refresh failed; using the existing checkout" >&2
  else
    mkdir -p "$(dirname "$SKILL_REPO")"
    git clone -q https://github.com/digio-nz/digio-skills.git "$SKILL_REPO" \
      || { echo "digio-skills clone failed" >&2; failed=1; }
  fi

  if [ -d "$SKILL_REPO/.git" ]; then
    # Through the ~/devs link, npm rewrites the lockfile's paths and the next pull refuses the dirty checkout.
    npm install --prefix "$(cd "$SKILL_REPO" && pwd -P)" --omit=dev --no-audit --no-fund --silent \
      || echo "digio-skills dependencies failed; skills without npm dependencies remain available" >&2
    configure_skillport() (
      set -e
      trap 'echo "SkillPort: $step failed" >&2' ERR
      skills="$SKILL_REPO"
      mcp="${DIGIO_SKILLPORT_MCP:-/opt/digio/skillport-venv/bin/skillport-mcp}"
      cli="${DIGIO_SKILLPORT_CLI:-${mcp%-mcp}}"
      categories="$(awk -F '\t' '$1 == "workbench" { print $2 }' "$skills/consumers.tsv")"
      [ -n "$categories" ] || { echo 'SkillPort: unknown consumer workbench' >&2; exit 1; }
      step='SkillPort installation'
      "$mcp" --help >/dev/null
      # The importer needs the venv's python: the system python3 has no yaml module.
      "${mcp%/*}/python" "$skills/lib/skillport-sets.py" "$skills" "$cli"
      step='SkillPort validation workbench'
      "$cli" validate "$skills/skills"
      entry_env=(
        "SKILLPORT_SKILLS_DIR=$skills/skills"
        "SKILLPORT_DB_PATH=$HOME/.skillport/workbench/skills.lancedb"
        "SKILLPORT_ENABLED_CATEGORIES=$categories"
        'SKILLPORT_ENABLED_SKILLS='
        'SKILLPORT_ENABLED_NAMESPACES='
        'SKILLPORT_CORE_SKILLS_MODE=auto'
        'SKILLPORT_EMBEDDING_PROVIDER=none'
        'SKILLPORT_SEARCH_LIMIT=100'
      )
      claude_env=() codex_env=()
      for value in "${entry_env[@]}"; do
        claude_env+=(-e "$value")
        codex_env+=(--env "$value")
      done
      step='SkillPort native links workbench'
      for folder in "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex/skills" "$HOME/.pi/agent/skills" "$HOME/.grok/skills"; do
        for link in "$folder"/*; do
          [ -L "$link" ] && [ "${link##*/}" != skill-search ] || continue
          target="$(readlink "$link")"
          case "$target" in "$skills/skills/"*|"$HOME/.digio/skill-sets/"*|/opt/skills/*|*/node_modules/*-axi/skills/*) rm "$link" ;; esac
        done
      done
      for folder in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills" "$HOME/.agents/skills"; do
        mkdir -p "$folder"
        if [ -e "$folder/skill-search" ] && [ ! -L "$folder/skill-search" ]; then
          echo "SkillPort: $folder/skill-search is not a link" >&2; exit 1
        fi
        ln -sfn "$skills/skills/skill-search" "$folder/skill-search"
      done
      step='SkillPort configuration workbench'
      claude mcp remove --scope user skillport >/dev/null 2>&1 || true
      claude mcp add --scope user skillport "${claude_env[@]}" -- "$mcp"
      codex mcp remove skillport >/dev/null 2>&1 || true
      codex mcp add skillport "${codex_env[@]}" -- "$mcp"
      claude mcp get skillport >/dev/null
      codex mcp get skillport --json >/dev/null
    )
    configure_skillport
    skillport_code=$?
    if [ "$skillport_code" -ne 0 ]; then
      echo "SkillPort setup failed: rerun $SCRIPT_DIR/post-start.sh" >&2
      failed=1
    fi
    bash "$SKILL_REPO/skills/install-briefs/scripts/install-briefs.sh" apply --quiet || true
    bash "$SKILL_REPO/skills/install-briefs/scripts/install-briefs.sh" apply --hook claude >/dev/null || true
    bash "$SKILL_REPO/skills/session-close/scripts/session-close.sh" apply >/dev/null || true
    [ -n "${DIGIO_HISTORY_DATABASE_URL:-}" ] || echo "session export: set the DIGIO_HISTORY_DATABASE_URL secret, or each session export fails"
    bash "$SCRIPT_DIR/session-export-sweep.sh" start "$SKILL_REPO" \
      || { echo "session-export scheduler failed to start: session sweeps are not scheduled" >&2; failed=1; }
  fi
fi

exit "$failed"
