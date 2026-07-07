#!/usr/bin/env bash
# fitout — idempotent provisioning: turns a bare Ubuntu 24.04 hull into a working ship.
# usage: ./fitout.sh   (run as the ship's user, not root; sudo is invoked where needed)
set -euo pipefail

SHIPYARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$(dpkg --print-architecture)"   # amd64 | arm64 — matches release asset naming below

log() { printf '[fitout] %s\n' "$1"; }

# --- apt basics ---
log "apt packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  build-essential ripgrep fd-find fzf jq unzip curl age htop tmux git

# fd-find's binary is `fdfind` on Debian/Ubuntu (name clash with another package).
# Also symlinked into /usr/local/bin (same rationale as the agent CLIs below):
# ~/.local/bin is only added to PATH by ~/.profile, which login shells source
# and non-login ones (plain `ssh host 'fd ...'`, muster's crew windows) don't.
mkdir -p "$HOME/.local/bin"
if [[ ! -e "$HOME/.local/bin/fd" ]] && command -v fdfind >/dev/null 2>&1; then
  ln -s "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi
command -v fdfind >/dev/null 2>&1 && sudo ln -sfn "$(command -v fdfind)" /usr/local/bin/fd

# --- git: worktree-friendly defaults ---
git config --global rerere.enabled true
git config --global fetch.prune true

# --- crew git identity: the ERDAgentic account, kept separate from the operator's own ---
# charter's own bootstrap commit already sidesteps identity with an explicit
# -c user.name=shipyard, but crew agents commit via plain `git commit`, which
# fails with "Author identity unknown" on a fresh ship with no global identity
# set at all -- found during x86_64 validation (HANDOFF.md §4g), flagged there
# rather than fixed blind. Setting it here, unconditionally, is safe: it's the
# ship's own persona (matches the ERDAgent GitHub account `gh auth status`
# already authenticates as), separate from whatever identity the operator uses
# for their own manual commits on the ship. Override with your own
# `git config --global user.name/email` if you want something else.
git config --global user.name "ERDAgent"
git config --global user.email "agentic@ericrose.dev"

# --- fnm + Node LTS ---
# mirrors fnm's own install-dir selection (install.sh): ~/.fnm if it already
# exists, else $XDG_DATA_HOME/fnm, else ~/.local/share/fnm on Linux.
if [[ -d "$HOME/.fnm" ]]; then
  FNM_DIR="$HOME/.fnm"
elif [[ -n "${XDG_DATA_HOME:-}" ]]; then
  FNM_DIR="$XDG_DATA_HOME/fnm"
else
  FNM_DIR="$HOME/.local/share/fnm"
fi
if [[ ! -x "$FNM_DIR/fnm" ]]; then
  log "installing fnm"
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
fi
export PATH="$FNM_DIR:$PATH"
eval "$(fnm env --shell bash)"

if ! fnm list 2>/dev/null | grep -q 'v[0-9]'; then
  log "installing Node LTS"
  fnm install --lts
fi
NODE_LTS="$(fnm list | grep -o 'v[0-9][0-9.]*' | sort -V | tail -1)"
fnm default "$NODE_LTS" >/dev/null
fnm use "$NODE_LTS" >/dev/null

# --- the Scuttlebutt: Fresh editor, latest release .deb for this arch ---
if ! command -v fresh >/dev/null 2>&1; then
  log "installing Fresh ($ARCH .deb)"
  DEB_URL="$(curl -fsSL https://api.github.com/repos/sinelaw/fresh/releases/latest \
    | jq -r --arg a "$ARCH" '.assets[] | select(.name | test("^fresh-editor_.*_" + $a + "\\.deb$")) | .browser_download_url')"
  [[ -n "$DEB_URL" ]] || { echo "fitout: no Fresh .deb found for arch $ARCH" >&2; exit 1; }
  TMP_DEB="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$TMP_DEB" "$DEB_URL"
  sudo dpkg -i "$TMP_DEB" || sudo apt-get install -y -qq -f
  rm -f "$TMP_DEB"
fi
git config --global core.editor "fresh --wait"

# scuttlebutt/ (Fresh config.json, theme, chartroom plugin) symlinked into ~/.config/fresh
mkdir -p "$HOME/.config"
if [[ -d "$SHIPYARD_DIR/scuttlebutt" ]]; then
  if [[ -e "$HOME/.config/fresh" && ! -L "$HOME/.config/fresh" ]]; then
    log "warning: ~/.config/fresh exists and isn't a symlink — leaving it alone"
  else
    ln -sfn "$SHIPYARD_DIR/scuttlebutt" "$HOME/.config/fresh"
  fi
fi

# dotfiles/tmux/ship.tmux.conf → ~/.tmux.conf (deck behavior/looks)
ln -sfn "$SHIPYARD_DIR/dotfiles/tmux/ship.tmux.conf" "$HOME/.tmux.conf"

# ship/bin/* on PATH everywhere (same /usr/local/bin rationale as the agent
# CLIs above): muster's crew windows call `unlock` by name, and charter/sail/
# muster themselves should be callable without the full repo path.
for bin in charter sail muster unlock captain telescope pick-model cost-proxy pi-monitor purser-totals quartermaster bosun; do
  sudo ln -sfn "$SHIPYARD_DIR/ship/bin/$bin" "/usr/local/bin/$bin"
done

# ship/pi/models.json → ~/.pi/agent/models.json (wires pi's DeepInfra/GLM-5.2 provider)
mkdir -p "$HOME/.pi/agent"
if [[ -e "$HOME/.pi/agent/models.json" && ! -L "$HOME/.pi/agent/models.json" ]]; then
  log "warning: ~/.pi/agent/models.json exists and isn't a symlink — leaving it alone"
else
  ln -sfn "$SHIPYARD_DIR/ship/pi/models.json" "$HOME/.pi/agent/models.json"
fi

# ship/plugin/ → ~/.pi/agent/extensions/shipyard (Phase 4: /mission, /muster,
# /harbor, /debrief -- global, not per-charter, so it's active in every
# charter's bridge window with no per-charter setup, same rationale as
# models.json above)
mkdir -p "$HOME/.pi/agent/extensions"
if [[ -e "$HOME/.pi/agent/extensions/shipyard" && ! -L "$HOME/.pi/agent/extensions/shipyard" ]]; then
  log "warning: ~/.pi/agent/extensions/shipyard exists and isn't a symlink — leaving it alone"
else
  ln -sfn "$SHIPYARD_DIR/ship/plugin" "$HOME/.pi/agent/extensions/shipyard"
fi

# --- Layer 2: the agent CLIs ---
install_npm_global() {
  local bin="$1" pkg="$2"; shift 2
  if command -v "$bin" >/dev/null 2>&1; then
    log "$bin: already installed"
    return
  fi
  log "npm i -g $pkg $*"
  npm i -g "$@" "$pkg"
}
install_npm_global claude @anthropic-ai/claude-code
install_npm_global codex @openai/codex
install_npm_global pi @earendil-works/pi-coding-agent --ignore-scripts

if ! command -v opencode >/dev/null 2>&1; then
  log "installing OpenCode"
  curl -fsSL https://opencode.ai/install | bash
fi
export PATH="$HOME/.opencode/bin:$PATH"

# --- GitHub CLI: the ship's hands on GitHub (push, PRs) as ERDAgent ---
# Auth is deliberately NOT `gh auth login` state on disk: gh reads $GH_TOKEN
# from the environment, and GH_TOKEN lives in the strongbox's CAPTAIN
# compartment (captain.env.age), loaded only by `unlock captain` — the bridge
# and integration contexts. Crew windows load crew scope (keys.env.age) and
# never see push credentials: "crew never push" (D10) is a capability
# boundary here, not just a line in crew.md. See strongbox/README.md for the
# fine-grained-PAT scoping and encryption steps (operator-side, one time).
if ! command -v gh >/dev/null 2>&1; then
  log "installing GitHub CLI"
  sudo install -dm755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod 644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq gh
fi
# git pushes over HTTPS authenticate through gh's credential helper, which
# supplies $GH_TOKEN when present (and cleanly fails auth when it isn't —
# i.e. in any crew context). Equivalent to `gh auth setup-git`, minus that
# command's requirement to already be authenticated at fitout time.
git config --global "credential.https://github.com.helper" '!gh auth git-credential'
git config --global "credential.https://gist.github.com.helper" '!gh auth git-credential'

# --- headless browser for UI verification (Playwright + Chromium) ---
# Real Captain feedback after the first live mission (a Vue app): install/
# test/lint/build all green doesn't confirm a UI actually renders correctly
# -- that voyage relied on Eric manually port-forwarding and eyeballing it.
# --with-deps installs the system libraries Chromium needs (sudo, apt) plus
# the browser itself, so any charter's crew can `npx playwright screenshot`
# a dev server and have the report include a PNG instead of just green CI.
if ! command -v playwright >/dev/null 2>&1; then
  log "installing Playwright + headless Chromium"
  npm i -g playwright --ignore-scripts
  npx playwright install --with-deps chromium
fi

# Symlink the agent CLIs into /usr/local/bin, which is on every shell's PATH
# regardless of login/interactive status. Neither ~/.bashrc (interactive-only)
# nor /etc/profile.d (login-only, below) covers everything that has to find
# these headlessly: `ssh ship 'pi ...'` is non-login by default, and muster's
# crew windows exec .crew-run.sh directly with no shell-rc sourcing at all.
# Target the fnm-managed Node version's real install dir, not `command -v`'s
# result — that resolves through fnm's per-shell "multishell" symlink, which
# is torn down when the shell exits, so a symlink to it would go stale.
FNM_BIN="$FNM_DIR/node-versions/$NODE_LTS/installation/bin"
for bin in node npm npx claude codex pi playwright; do
  [[ -x "$FNM_BIN/$bin" ]] && sudo ln -sfn "$FNM_BIN/$bin" "/usr/local/bin/$bin"
done
[[ -x "$HOME/.opencode/bin/opencode" ]] && sudo ln -sfn "$HOME/.opencode/bin/opencode" /usr/local/bin/opencode

# fnm itself (for interactive Node-version switching) still needs a login
# shell's PATH — /usr/local/bin above only covers the fixed set of CLIs.
# /etc/profile.d/* is sourced by every user's login shell on the ship, not
# just eric's -- `multipass shell` logs in as the default `ubuntu` user, and
# without the -x guard below, ubuntu's login hit a bare "fnm: command not
# found" (found by actually running `multipass shell ship`, not from reading
# this script). $FNM_DIR only ever exists for eric (fnm is installed to
# eric's home, once, by this script), so any other user should just silently
# skip fnm activation rather than error.
sudo tee /etc/profile.d/shipyard.sh > /dev/null <<EOF
#!/bin/sh
if [ -n "\$BASH_VERSION" ] && [ -x "$FNM_DIR/fnm" ]; then
  export PATH="$FNM_DIR:\$PATH"
  eval "\$(fnm env --shell bash)"
fi
EOF
sudo chmod 644 /etc/profile.d/shipyard.sh

# --- the strongbox: decrypt each compartment if the age key is already on this ship ---
# Three compartments (D15, extended for the shipwright pane): crew
# (keys.env.age), captain (captain.env.age, added with GitHub access), and
# shipwright (shipwright.env.age, ANTHROPIC_API_KEY) verify independently so a
# missing/bad compartment never blocks the others from working.
CREW_BOX="$SHIPYARD_DIR/strongbox/keys.env.age"
CAPTAIN_BOX="$SHIPYARD_DIR/strongbox/captain.env.age"
SHIPWRIGHT_BOX="$SHIPYARD_DIR/strongbox/shipwright.env.age"
AGE_KEY="$HOME/.config/age/ship.key"
if [[ -f "$AGE_KEY" ]]; then
  if [[ -f "$CREW_BOX" ]]; then
    log "strongbox: verifying crew compartment decrypt"
    age -d -i "$AGE_KEY" "$CREW_BOX" >/dev/null
    log "strongbox: crew OK — load into a shell with: eval \"\$(unlock)\""
  else
    log "strongbox: crew compartment not present yet — skipping"
  fi
  if [[ -f "$CAPTAIN_BOX" ]]; then
    log "strongbox: verifying captain compartment decrypt"
    age -d -i "$AGE_KEY" "$CAPTAIN_BOX" >/dev/null
    log "strongbox: captain OK — load into a shell with: eval \"\$(unlock captain)\""
  else
    log "strongbox: captain compartment not present yet — skipping"
  fi
  if [[ -f "$SHIPWRIGHT_BOX" ]]; then
    log "strongbox: verifying shipwright compartment decrypt"
    age -d -i "$AGE_KEY" "$SHIPWRIGHT_BOX" >/dev/null
    log "strongbox: shipwright OK — load into a shell with: eval \"\$(unlock shipwright)\""
  else
    log "strongbox: shipwright compartment not present yet — skipping"
  fi
else
  log "strongbox: no age key at $AGE_KEY yet — skipping (drop your key there, then 'eval \"\$(unlock)\"', 'eval \"\$(unlock captain)\"', or 'eval \"\$(unlock shipwright)\"')"
fi

log "fitout complete"
for bin in pi opencode claude codex fresh gh tmux jq rg fd fzf age playwright; do
  printf '  %-8s %s\n' "$bin" "$(command -v "$bin" 2>/dev/null || echo 'NOT FOUND')"
done
