#!/usr/bin/env bash
# erda — single entry point for all Harbor-side ship operations.
# usage: erda <command> [ship] [args...]
#
#   install                                  wire up `erda` as a global shell
#                                             command (run once per machine, or
#                                             again after moving/updating the repo)
#   christen [name] [cpus] [memory] [disk]   launch a new ship
#   board [ship]                             connect: multipass info + ssh in
#   open lockbox [ship]                      deploy the age key if needed, connect
#                                             with the strongbox already unlocked
#                                             (captain scope: model keys + GH_TOKEN)
#   anchor [ship]                            multipass stop
#   force-anchor [ship]                      multipass stop --force
#   sail [ship]                              multipass start
#   resail [ship]                            multipass restart
#   suspend [ship]                           multipass suspend
#   view [ship]                              multipass list (no ship) / info <ship>
#   sink [ship]                              multipass delete --purge
#                                             (asks to confirm; -y/--force skips)
#
# [ship] defaults to "ship" everywhere it's optional.
#
# Before `erda` is a shell command, run this once by its full path:
#   ./harbor/erda.sh install
# (On Windows with a fresh/Restricted execution policy, use harbor/install.cmd
# instead — it bypasses that policy just long enough to run this same install.)
#
# Note: `erda sail` (start a stopped VM, this command) and `ship/bin/sail
# <charter>` (open the tmux deck, runs ON the ship) share a name but never
# actually collide -- different sides of the SSH connection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_PRIV="${SSH_PRIV:-$HOME/.ssh/id_ed25519}"

MULTIPASS="multipass"
if ! command -v multipass >/dev/null 2>&1; then
  WIN_MP="/c/Program Files/Multipass/bin/multipass.exe"
  [[ -x "$WIN_MP" ]] && MULTIPASS="$WIN_MP"
fi

ship_ip() {
  local name="$1" ip
  ip="$("$MULTIPASS" info "$name" | awk '/IPv4/{print $2; exit}')"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "erda: couldn't get an IP for '$name' -- is it running? (erda sail $name)" >&2; exit 1; }
  echo "$ip"
}

usage() {
  cat >&2 <<'USAGE'
usage: erda <command> [ship] [args...]
  install                                   wire up `erda` as a global command (run once)
  christen [name] [cpus] [memory] [disk]    launch a new ship
  board [ship]                              connect (multipass info + ssh)
  open lockbox [ship]                       deploy the age key if needed, connect unlocked
  anchor [ship]                             stop
  force-anchor [ship]                       stop --force
  sail [ship]                               start
  resail [ship]                             restart
  suspend [ship]                            suspend
  view [ship]                               list (no ship) / info <ship>
  sink [ship]                               delete --purge (asks to confirm; -y/--force skips)
[ship] defaults to "ship" everywhere it's optional.
USAGE
}

# install — wire up `erda` as a global shell command. Shell profile changes
# are per-machine state that git can't carry across computers, so instead of
# hand-editing your profile, the setup step lives here. Idempotent: re-running
# (e.g. after moving the repo, or pulling an updated harbor/) replaces the
# previously-installed block rather than duplicating it.
cmd_install() {
  local profile_file="${SHELL_PROFILE:-}"
  if [[ -z "$profile_file" ]]; then
    case "$(basename "${SHELL:-bash}")" in
      zsh) profile_file="$HOME/.zshrc" ;;
      *)   profile_file="$HOME/.bashrc" ;;
    esac
  fi
  touch "$profile_file"

  local marker_start="# --- ERDA-Will harbor commands (managed by harbor/erda.sh install) ---"
  local marker_prefix="# --- ERDA-Will harbor commands"
  local marker_end="# --- end ERDA-Will harbor commands ---"

  # Matched by prefix, not exact text: an older install (e.g. the
  # since-merged harbor/install.sh) wrote a marker with different wording
  # after "harbor commands" -- matching only the prefix means an upgrade
  # replaces that stale block instead of leaving it duplicated alongside a
  # new one.
  if grep -qF "$marker_prefix" "$profile_file"; then
    awk -v start="$marker_prefix" -v end="$marker_end" '
      index($0, start) == 1 {skip=1; next}
      $0 == end {skip=0; next}
      !skip {print}
    ' "$profile_file" > "$profile_file.tmp"
    mv "$profile_file.tmp" "$profile_file"
    echo "updated existing erda install in $profile_file (path may have changed)"
  else
    echo "installed erda into $profile_file"
  fi

  {
    echo ""
    echo "$marker_start"
    echo "erda() { \"$SCRIPT_DIR/erda.sh\" \"\$@\"; }"
    echo "$marker_end"
  } >> "$profile_file"

  echo
  echo "Restart your terminal, or run: source $profile_file"
  echo "Then 'erda <command>' works from any directory (e.g. erda christen, erda board)."
}

# christen — launch a new ship with one command and sensible defaults.
# Handles the whole first-provisioning dance: substitutes your real SSH key
# into keel.yaml (never writing the substituted copy into the repo), calls
# `multipass launch`, then waits for SSH and cloud-init to actually finish
# before handing control back -- so "christen" means "ready to use", not just
# "instance exists".
#
# Fleet naming (D16): flagships get Will-class virtue names (resolve,
# endeavour, tenacity...); skiffs use skiff-<purpose> and get purged same
# day. This command doesn't enforce either -- name whatever you want.
cmd_christen() {
  local name="${1:-ship}" cpus="${2:-2}" memory="${3:-4G}" disk="${4:-20G}"

  [[ "$name" =~ ^[A-Za-z]$ || "$name" =~ ^[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$ ]] || {
    echo "christen: invalid name '$name' (letters, digits, hyphens; must start with a letter, end alphanumeric)" >&2
    exit 1
  }

  local keel_src="$REPO_ROOT/keel.yaml"
  [[ -f "$keel_src" ]] || { echo "christen: keel.yaml not found at $keel_src" >&2; exit 1; }

  local ssh_pub="${SSH_PUB:-$SSH_PRIV.pub}"
  [[ -f "$ssh_pub" ]] || {
    echo "christen: no SSH public key at $ssh_pub" >&2
    echo "  generate one first: ssh-keygen -t ed25519" >&2
    exit 1
  }

  local tmp_keel pubkey
  tmp_keel="$(mktemp -t "keel-christen-XXXXXX.yaml")"
  trap 'rm -f "$tmp_keel"' RETURN
  pubkey="$(cat "$ssh_pub")"
  sed "s|REPLACE-ME-with-your-ssh-public-key|$pubkey|" "$keel_src" > "$tmp_keel"

  echo "christening '$name': $cpus cpu(s), $memory memory, $disk disk"
  "$MULTIPASS" launch 24.04 \
    --name "$name" \
    --cpus "$cpus" --memory "$memory" --disk "$disk" \
    --cloud-init "$tmp_keel"

  echo
  echo -n "waiting for '$name' to get an IP..."
  local ip=""
  for _ in $(seq 1 20); do
    ip="$("$MULTIPASS" info "$name" | awk '/IPv4/{print $2; exit}')"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    ip=""
    echo -n "."
    sleep 2
  done
  [[ -n "$ip" ]] || { echo; echo "christen: never got an IP for '$name' — check: multipass info $name" >&2; exit 1; }
  echo " $ip"

  echo -n "waiting for ssh..."
  local ssh_ok=0
  for _ in $(seq 1 40); do
    if ssh -i "$SSH_PRIV" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
         eric@"$ip" true 2>/dev/null; then
      ssh_ok=1
      break
    fi
    echo -n "."
    sleep 3
  done
  if [[ "$ssh_ok" -ne 1 ]]; then
    echo
    echo "christen: ssh never came up on '$name' ($ip) after 2 minutes — check manually:" >&2
    echo "  ssh -i $SSH_PRIV eric@$ip" >&2
    exit 1
  fi
  echo " up"

  echo "waiting for cloud-init to finish provisioning (a couple of minutes)..."
  ssh -i "$SSH_PRIV" -o StrictHostKeyChecking=accept-new eric@"$ip" 'cloud-init status --wait'

  echo
  echo "'$name' is ready: ssh -i $SSH_PRIV eric@$ip"
}

CMD="${1:-}"
[[ $# -gt 0 ]] && shift

case "$CMD" in
  install)
    cmd_install "$@"
    ;;

  christen)
    cmd_christen "$@"
    ;;

  board)
    NAME="${1:-ship}"
    IP="$(ship_ip "$NAME")"
    echo "boarding '$NAME' ($IP)..."
    ssh -i "$SSH_PRIV" eric@"$IP"
    ;;

  open)
    [[ "${1:-}" == "lockbox" ]] || { echo "erda: 'open' only supports 'open lockbox [ship]'" >&2; exit 1; }
    shift
    NAME="${1:-ship}"
    IP="$(ship_ip "$NAME")"
    echo "opening the lockbox on '$NAME' ($IP)..."

    KEY_PATH="$REPO_ROOT/strongbox/ship.key"
    [[ -f "$KEY_PATH" ]] || { echo "erda: no local strongbox/ship.key -- generate/place it first (see strongbox/README.md)" >&2; exit 1; }

    KEY_PRESENT="$(ssh -i "$SSH_PRIV" -o LogLevel=ERROR eric@"$IP" 'test -f ~/.config/age/ship.key && echo yes || echo no')"
    if [[ "$KEY_PRESENT" != "yes" ]]; then
      echo "no age key on '$NAME' yet -- copying strongbox/ship.key..."
      ssh -i "$SSH_PRIV" -o LogLevel=ERROR eric@"$IP" 'mkdir -p ~/.config/age'
      scp -i "$SSH_PRIV" -o LogLevel=ERROR "$KEY_PATH" eric@"$IP":~/.config/age/ship.key
      ssh -i "$SSH_PRIV" -o LogLevel=ERROR eric@"$IP" 'chmod 600 ~/.config/age/ship.key'
    fi

    echo "connecting with the lockbox unlocked (captain scope: model keys + GH_TOKEN if present)..."
    ssh -i "$SSH_PRIV" -t eric@"$IP" 'eval "$(unlock captain)"; exec bash -l'
    ;;

  anchor)
    "$MULTIPASS" stop "${1:-ship}"
    ;;
  force-anchor)
    "$MULTIPASS" stop "${1:-ship}" --force
    ;;
  sail)
    "$MULTIPASS" start "${1:-ship}"
    ;;
  resail)
    "$MULTIPASS" restart "${1:-ship}"
    ;;
  suspend)
    "$MULTIPASS" suspend "${1:-ship}"
    ;;
  view)
    if [[ -n "${1:-}" ]]; then
      "$MULTIPASS" info "$1"
    else
      "$MULTIPASS" list
    fi
    ;;
  sink)
    NAME="${1:-ship}"
    FORCE=0
    for a in "$@"; do [[ "$a" == "-y" || "$a" == "--force" ]] && FORCE=1; done
    if [[ "$FORCE" -ne 1 ]]; then
      read -rp "This will permanently destroy '$NAME' and everything on it. Type the ship name to confirm: " CONFIRM
      [[ "$CONFIRM" == "$NAME" ]] || { echo "cancelled."; exit 1; }
    fi
    "$MULTIPASS" delete "$NAME" --purge
    ;;

  ""|-h|--help)
    usage
    exit 1
    ;;
  *)
    echo "erda: unknown command '$CMD'. Run 'erda' with no args for the command list." >&2
    exit 1
    ;;
esac
