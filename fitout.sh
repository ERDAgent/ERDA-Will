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

# fd-find's binary is `fdfind` on Debian/Ubuntu (name clash with another package)
mkdir -p "$HOME/.local/bin"
if [[ ! -e "$HOME/.local/bin/fd" ]] && command -v fdfind >/dev/null 2>&1; then
  ln -s "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi

# --- git: worktree-friendly defaults ---
git config --global rerere.enabled true
git config --global fetch.prune true

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

# Symlink the agent CLIs into /usr/local/bin, which is on every shell's PATH
# regardless of login/interactive status. Neither ~/.bashrc (interactive-only)
# nor /etc/profile.d (login-only, below) covers everything that has to find
# these headlessly: `ssh ship 'pi ...'` is non-login by default, and muster's
# crew windows exec .crew-run.sh directly with no shell-rc sourcing at all.
# Target the fnm-managed Node version's real install dir, not `command -v`'s
# result — that resolves through fnm's per-shell "multishell" symlink, which
# is torn down when the shell exits, so a symlink to it would go stale.
FNM_BIN="$FNM_DIR/node-versions/$NODE_LTS/installation/bin"
for bin in node npm npx claude codex pi; do
  [[ -x "$FNM_BIN/$bin" ]] && sudo ln -sfn "$FNM_BIN/$bin" "/usr/local/bin/$bin"
done
[[ -x "$HOME/.opencode/bin/opencode" ]] && sudo ln -sfn "$HOME/.opencode/bin/opencode" /usr/local/bin/opencode

# fnm itself (for interactive Node-version switching) still needs a login
# shell's PATH — /usr/local/bin above only covers the fixed set of CLIs.
sudo tee /etc/profile.d/shipyard.sh > /dev/null <<EOF
#!/bin/sh
if [ -n "\$BASH_VERSION" ]; then
  export PATH="$FNM_DIR:\$PATH"
  eval "\$(fnm env --shell bash)"
fi
EOF
sudo chmod 644 /etc/profile.d/shipyard.sh

# --- the strongbox: decrypt if the age key is already on this ship ---
STRONGBOX="$SHIPYARD_DIR/strongbox/keys.env.age"
AGE_KEY="$HOME/.config/age/ship.key"
if [[ -f "$STRONGBOX" ]]; then
  if [[ -f "$AGE_KEY" ]]; then
    log "strongbox: verifying decrypt"
    age -d -i "$AGE_KEY" "$STRONGBOX" >/dev/null
    log "strongbox: OK — load keys into a shell with: eval \"\$(unlock)\""
  else
    log "strongbox: no age key at $AGE_KEY yet — skipping (drop your key there, then 'eval \"\$(unlock)\"')"
  fi
else
  log "strongbox: not present yet — skipping"
fi

log "fitout complete"
for bin in pi opencode claude codex fresh tmux jq rg fd fzf age; do
  printf '  %-8s %s\n' "$bin" "$(command -v "$bin" 2>/dev/null || echo 'NOT FOUND')"
done
