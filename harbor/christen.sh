#!/usr/bin/env bash
# christen — launch a new ship with one command and sensible defaults
# usage: christen [name] [cpus] [memory] [disk]
#   christen                    # ship, 2 cpus, 4G memory, 20G disk
#   christen resolve            # named, defaults for the rest
#   christen resolve 4 8G 40G   # fully custom
#
# Handles the whole first-provisioning dance: substitutes your real SSH key
# into keel.yaml (never writing the substituted copy into the repo), calls
# `multipass launch`, then waits for SSH and cloud-init to actually finish
# before handing control back — so "christen" means "ready to use", not just
# "instance exists". Runs from the Harbor (your host machine), before any
# ship exists — that's why this isn't in ship/bin/*, which only exists once
# a ship is already up.
#
# Fleet naming (D16): flagships get Will-class virtue names (resolve,
# endeavour, tenacity...); skiffs use skiff-<purpose> and get purged same
# day. This script doesn't enforce either — name whatever you want.
set -euo pipefail

NAME="${1:-ship}"
CPUS="${2:-2}"
MEMORY="${3:-4G}"
DISK="${4:-20G}"

[[ "$NAME" =~ ^[A-Za-z]$ || "$NAME" =~ ^[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$ ]] || {
  echo "christen: invalid name '$NAME' (letters, digits, hyphens; must start with a letter, end alphanumeric)" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEEL_SRC="$REPO_ROOT/keel.yaml"
[[ -f "$KEEL_SRC" ]] || { echo "christen: keel.yaml not found at $KEEL_SRC" >&2; exit 1; }

SSH_PRIV="${SSH_PRIV:-$HOME/.ssh/id_ed25519}"
SSH_PUB="${SSH_PUB:-$SSH_PRIV.pub}"
[[ -f "$SSH_PUB" ]] || {
  echo "christen: no SSH public key at $SSH_PUB" >&2
  echo "  generate one first: ssh-keygen -t ed25519" >&2
  exit 1
}

TMP_KEEL="$(mktemp -t "keel-christen-XXXXXX.yaml")"
trap 'rm -f "$TMP_KEEL"' EXIT
PUBKEY="$(cat "$SSH_PUB")"
sed "s|REPLACE-ME-with-your-ssh-public-key|$PUBKEY|" "$KEEL_SRC" > "$TMP_KEEL"

# Falls back to the default Windows install path if not on PATH yet (a
# fresh terminal after winget install should have it; this only matters in
# a shell opened before that). No-op on macOS -- that path never exists
# there, and brew's install already puts multipass on PATH.
MULTIPASS="multipass"
if ! command -v multipass >/dev/null 2>&1; then
  WIN_MP="/c/Program Files/Multipass/bin/multipass.exe"
  [[ -x "$WIN_MP" ]] && MULTIPASS="$WIN_MP"
fi

echo "christening '$NAME': $CPUS cpu(s), $MEMORY memory, $DISK disk"
"$MULTIPASS" launch 24.04 \
  --name "$NAME" \
  --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK" \
  --cloud-init "$TMP_KEEL"

echo
echo -n "waiting for '$NAME' to get an IP..."
IP=""
for _ in $(seq 1 20); do
  IP="$("$MULTIPASS" info "$NAME" | awk '/IPv4/{print $2; exit}')"
  [[ -n "$IP" ]] && break
  echo -n "."
  sleep 2
done
[[ -n "$IP" ]] || { echo; echo "christen: never got an IP for '$NAME' — check: multipass info $NAME" >&2; exit 1; }
echo " $IP"

echo -n "waiting for ssh..."
SSH_OK=0
for _ in $(seq 1 40); do
  if ssh -i "$SSH_PRIV" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
       eric@"$IP" true 2>/dev/null; then
    SSH_OK=1
    break
  fi
  echo -n "."
  sleep 3
done
if [[ "$SSH_OK" -ne 1 ]]; then
  echo
  echo "christen: ssh never came up on '$NAME' ($IP) after 2 minutes — check manually:" >&2
  echo "  ssh -i $SSH_PRIV eric@$IP" >&2
  exit 1
fi
echo " up"

echo "waiting for cloud-init to finish provisioning (a couple of minutes)..."
ssh -i "$SSH_PRIV" -o StrictHostKeyChecking=accept-new eric@"$IP" 'cloud-init status --wait'

echo
echo "'$NAME' is ready: ssh -i $SSH_PRIV eric@$IP"
