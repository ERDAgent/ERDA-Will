#!/usr/bin/env bash
# erda — command-line entry point for Harbor-side ship operations.
# usage: erda <command> [ship] [args...]
#
#   christen [name] [cpus] [memory] [disk]   launch a new ship (see christen.sh)
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
# [ship] defaults to "ship" everywhere it's optional, matching christen's own default.
#
# Note: `erda sail` (start a stopped VM, this script) and `ship/bin/sail <charter>`
# (open the tmux deck, runs ON the ship) share a name but never actually collide --
# different sides of the SSH connection -- worth knowing so "sail" isn't confusing
# when you're used to the other one.
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
  [[ -n "$ip" ]] || { echo "erda: couldn't get an IP for '$name' -- is it running? (erda sail $name)" >&2; exit 1; }
  echo "$ip"
}

usage() {
  cat >&2 <<'USAGE'
usage: erda <command> [ship] [args...]
  christen [name] [cpus] [memory] [disk]   launch a new ship
  board [ship]                             connect (multipass info + ssh)
  open lockbox [ship]                      deploy the age key if needed, connect unlocked
  anchor [ship]                            stop
  force-anchor [ship]                      stop --force
  sail [ship]                              start
  resail [ship]                            restart
  suspend [ship]                           suspend
  view [ship]                              list (no ship) / info <ship>
  sink [ship]                              delete --purge (asks to confirm; -y/--force skips)
[ship] defaults to "ship" everywhere it's optional.
USAGE
}

CMD="${1:-}"
[[ $# -gt 0 ]] && shift

case "$CMD" in
  christen)
    exec "$SCRIPT_DIR/christen.sh" "$@"
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
