#!/usr/bin/env bash
# install — wire up `erda` (harbor/erda.sh, the command dispatcher for all
# harbor/* operations: christen, board, open lockbox, anchor, sail, ...) as
# a global shell command, so you can type `erda <command>` from anywhere.
#
# This is the reproducibility story for "just typing erda from anywhere":
# shell profile changes are per-machine state that git can't carry across
# computers, so instead of hand-editing your profile, the setup step itself
# lives in this repo. On a fresh machine: clone the repo, run this script
# once, restart your terminal (or `source` your profile). `erda` then works
# globally, permanently, on that machine.
#
# Idempotent: re-running (e.g. after moving the repo to a new path, or
# after pulling an updated harbor/) replaces the previously-installed block
# rather than duplicating it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ERDA_PATH="$REPO_ROOT/harbor/erda.sh"
[[ -f "$ERDA_PATH" ]] || { echo "install: expected $ERDA_PATH to exist -- run this from a real ERDA-Will checkout" >&2; exit 1; }

PROFILE_FILE="${SHELL_PROFILE:-}"
if [[ -z "$PROFILE_FILE" ]]; then
  case "$(basename "${SHELL:-bash}")" in
    zsh) PROFILE_FILE="$HOME/.zshrc" ;;
    *)   PROFILE_FILE="$HOME/.bashrc" ;;
  esac
fi
touch "$PROFILE_FILE"

MARKER_START="# --- ERDA-Will harbor commands (managed by harbor/install.sh) ---"
MARKER_END="# --- end ERDA-Will harbor commands ---"

if grep -qF "$MARKER_START" "$PROFILE_FILE"; then
  # Strip the previously-installed block, then append the current one --
  # handles both a stale path (repo moved) and an update to this logic.
  awk -v start="$MARKER_START" -v end="$MARKER_END" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$PROFILE_FILE" > "$PROFILE_FILE.tmp"
  mv "$PROFILE_FILE.tmp" "$PROFILE_FILE"
  echo "updated existing erda install in $PROFILE_FILE (path may have changed)"
else
  echo "installed erda into $PROFILE_FILE"
fi

{
  echo ""
  echo "$MARKER_START"
  echo "erda() { \"$ERDA_PATH\" \"\$@\"; }"
  echo "$MARKER_END"
} >> "$PROFILE_FILE"

echo
echo "Restart your terminal, or run: source $PROFILE_FILE"
echo "Then 'erda <command>' works from any directory (e.g. erda christen, erda board)."
