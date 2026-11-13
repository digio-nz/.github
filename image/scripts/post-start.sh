#!/usr/bin/env bash
# Runs at every container start: join the tailnet, check the git hooks, and refresh Michelin, skills and briefs.
# A failed hooks check or required Michelin step is reported on stderr, and the script exits 1 after running every step.
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

# Agents commit as Digby with his hidden address, because GitHub refuses a push that exposes his private one.
set_identity() { [ -n "$(git config --global "$1")" ] || git config --global "$1" "$2"; }
if ! { set_identity user.name digbycampbell && set_identity user.email 96467498+digbycampbell@users.noreply.github.com; }; then
  echo "git: cannot set the global identity" >&2; failed=1
fi

bash "$SCRIPT_DIR/git-hooks.sh" || failed=1

SKILLS_DIR="$HOME/.digio/michelin"
# The installed skills: setup owns this clone. ~/devs/digio-skills is a working clone, and a branch there must change no agent.
SKILL_REPO="${DIGIO_SKILLS_ROOT:-$HOME/.digio/skills}"
export DIGIO_MICHELIN_ROOT="$SKILLS_DIR" DIGIO_SKILLS_ROOT="$SKILL_REPO"
# The briefs reach the harnesses from this checkout; a local change or a failed pull keeps them stale, so say so.
brief_drift() {
  local behind
  [ -z "$(git -C "$SKILLS_DIR" status --porcelain)" ] \
    || echo "WARN: briefs: $SKILLS_DIR has local changes, so its pull stops; make them in ~/devs/digio-michelin through a PR, then discard them here" >&2
  behind="$(git -C "$SKILLS_DIR" rev-list --count HEAD..origin/main 2>/dev/null)"
  case "$behind" in
    0) ;;
    '') echo "WARN: briefs: cannot compare $SKILLS_DIR with origin/main" >&2 ;;
    *) echo "WARN: briefs: $SKILLS_DIR is $behind commits behind origin/main" >&2 ;;
  esac
}
[ -d "$SKILLS_DIR/.git" ] || echo "WARN: briefs: $SKILLS_DIR is missing, so no brief, skill or session export is set up; rerun post-create.sh" >&2
if [ -d "$SKILLS_DIR/.git" ]; then
  git -C "$SKILLS_DIR" pull -q --ff-only || true
  brief_drift
  if [ -d "$SKILL_REPO/.git" ]; then
    git -C "$SKILL_REPO" pull -q --ff-only || echo "digio-skills refresh failed; using the existing checkout" >&2
  else
    mkdir -p "$(dirname "$SKILL_REPO")"
    git clone -q https://github.com/digio-nz/digio-skills.git "$SKILL_REPO" \
      || { echo "digio-skills clone failed" >&2; failed=1; }
  fi

  if [ -d "$SKILL_REPO/.git" ]; then
    # Through a link, npm rewrites the lockfile's paths and the next pull refuses the dirty checkout.
    npm install --prefix "$(cd "$SKILL_REPO" && pwd -P)" --omit=dev --no-audit --no-fund --silent \
      || echo "digio-skills dependencies failed; skills without npm dependencies remain available" >&2
    link_skills() (
      set -e
      trap 'echo "skills: $step failed" >&2' ERR
      step='the skills library'
      # Through a link, skills-manager-cli writes some links with that path and some with the physical one.
      root="$(cd "$SKILL_REPO/skills" && pwd -P)"
      step='stale link removal'
      for folder in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
        mkdir -p "$folder"
        # A deploy adds links and removes none, and it refuses a name that holds a link into the working clone.
        find "$folder" -maxdepth 1 -type l \( -lname "$root/*" -o -lname '*/devs/digio-skills/skills/*' \) -delete
      done
      for agent in claude_code codex; do
        step="preset factory for $agent"
        skills-manager-cli --skills-root "$root" presets deploy factory --agent "$agent" >/dev/null
      done
      # An older image has no skills-manager-cli, so SkillPort goes only after the links are in place.
      step='SkillPort removal'
      if claude mcp get skillport >/dev/null 2>&1; then claude mcp remove --scope user skillport >/dev/null; fi
      if codex mcp get skillport >/dev/null 2>&1; then codex mcp remove skillport >/dev/null; fi
      for folder in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
        [ ! -L "$folder/skill-search" ] || rm "$folder/skill-search"
      done
    )
    link_skills
    skills_code=$?
    if [ "$skills_code" -ne 0 ]; then
      echo "skills setup failed: rerun $SCRIPT_DIR/post-start.sh" >&2
      failed=1
    fi
    bash "$SKILL_REPO/skills/install-briefs/scripts/install-briefs.sh" apply --quiet || true
    bash "$SKILL_REPO/skills/install-briefs/scripts/install-briefs.sh" apply --hook claude >/dev/null || true
    bash "$SKILL_REPO/skills/session-close/scripts/session-close.sh" apply >/dev/null || true
    history_env="${DIGIO_HISTORY_ENV:-$HOME/devs/digio-history/.env.local}"
    [ -n "${DIGIO_HISTORY_DATABASE_URL:-}" ] || [ -s "$history_env" ] \
      || echo "WARN: session export: no DIGIO_HISTORY_DATABASE_URL secret and no $history_env, so each session export fails" >&2
    bash "$SCRIPT_DIR/session-export-sweep.sh" start "$SKILL_REPO" \
      || { echo "session-export scheduler failed to start: session sweeps are not scheduled" >&2; failed=1; }
  fi
fi

exit "$failed"
