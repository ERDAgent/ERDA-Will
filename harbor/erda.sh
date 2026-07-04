#!/usr/bin/env bash
# erda — single entry point for all Harbor-side ship operations.
# usage: erda <command> [ship] [args...]
#
#   install                                  wire up `erda` as a global shell
#                                             command (run once per machine, or
#                                             again after moving/updating the repo)
#   christen [name] [cpus] [memory] [disk]   launch a new ship
#   strongbox <init|backup|restore>          manage the local age keypair (see below)
#   board [ship]                             connect: multipass info + ssh in, deploying
#                                             the age key if needed and connecting with
#                                             the strongbox already unlocked (captain
#                                             scope: model keys + GH_TOKEN)
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
  strongbox init                            generate a new keypair + encrypt secrets
  strongbox backup <path>                   copy ship.key to a path of your choosing
  strongbox restore <path>                  copy ship.key back from a path
  board [ship]                              connect (multipass info + ssh), deploying the
                                             age key if needed and unlocking the strongbox
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

# strongbox — manage the local age keypair (strongbox/ship.key) and the
# encrypted secret bundles it decrypts. `ship.key` is host-side, permanent
# infrastructure -- it has nothing to do with any one ship instance, so
# sinking a ship never touches it and losing it is NOT recoverable by
# generating a new one (the existing keys.env.age/captain.env.age were
# encrypted to the OLD key's public half specifically). Back it up.
cmd_strongbox() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  local key_path="$REPO_ROOT/strongbox/ship.key"

  case "$sub" in
    init)
      command -v age-keygen >/dev/null 2>&1 || { echo "strongbox: 'age' isn't installed on this machine (brew install age)" >&2; exit 1; }

      if [[ -f "$key_path" ]]; then
        echo "strongbox: $key_path already exists." >&2
        echo "  Overwriting it orphans anything already encrypted with the old key" >&2
        echo "  (keys.env.age / captain.env.age would become permanently undecryptable)." >&2
        read -rp "  Type 'overwrite' to replace it anyway: " CONFIRM
        [[ "$CONFIRM" == "overwrite" ]] || { echo "cancelled." >&2; exit 1; }
      fi

      age-keygen -o "$key_path" 2>&1 | grep -v '^$' || true
      chmod 600 "$key_path"
      local recipient
      recipient="$(grep -o 'age1.*' "$key_path")"
      echo "generated $key_path"

      echo
      read -rs -p "DEEPINFRA_API_KEY (input hidden): " DEEPINFRA_API_KEY
      echo
      [[ -n "$DEEPINFRA_API_KEY" ]] || { echo "strongbox: empty value entered, aborting" >&2; exit 1; }
      printf 'DEEPINFRA_API_KEY=%s\n' "$DEEPINFRA_API_KEY" | age -r "$recipient" -o "$REPO_ROOT/strongbox/keys.env.age" -
      local keys_len
      keys_len="$(age -d -i "$key_path" "$REPO_ROOT/strongbox/keys.env.age" | wc -c | tr -d ' ')"
      echo "wrote keys.env.age (decrypts to $keys_len bytes)"

      echo
      read -rp "Also set up the captain compartment (GH_TOKEN) now? [y/N] " ADD_GH
      if [[ "$ADD_GH" =~ ^[Yy]$ ]]; then
        read -rs -p "GH_TOKEN (input hidden): " GH_TOKEN
        echo
        [[ -n "$GH_TOKEN" ]] || { echo "strongbox: empty value entered, skipping captain compartment" >&2; }
        if [[ -n "${GH_TOKEN:-}" ]]; then
          printf 'GH_TOKEN=%s\n' "$GH_TOKEN" | age -r "$recipient" -o "$REPO_ROOT/strongbox/captain.env.age" -
          local captain_len
          captain_len="$(age -d -i "$key_path" "$REPO_ROOT/strongbox/captain.env.age" | wc -c | tr -d ' ')"
          echo "wrote captain.env.age (decrypts to $captain_len bytes)"
        fi
      fi

      echo
      read -rp "Also set up the shipwright compartment (ANTHROPIC_API_KEY) now? [y/N] " ADD_CC
      if [[ "$ADD_CC" =~ ^[Yy]$ ]]; then
        read -rs -p "ANTHROPIC_API_KEY (input hidden): " ANTHROPIC_API_KEY
        echo
        [[ -n "$ANTHROPIC_API_KEY" ]] || { echo "strongbox: empty value entered, skipping shipwright compartment" >&2; }
        if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
          printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" | age -r "$recipient" -o "$REPO_ROOT/strongbox/shipwright.env.age" -
          local shipwright_len
          shipwright_len="$(age -d -i "$key_path" "$REPO_ROOT/strongbox/shipwright.env.age" | wc -c | tr -d ' ')"
          echo "wrote shipwright.env.age (decrypts to $shipwright_len bytes)"
        fi
      fi

      echo
      echo "strongbox initialized. Back up $key_path now: erda strongbox backup <path>"
      echo "(without a backup, losing this file again means repeating this whole process)"
      ;;

    backup)
      local dest="${1:-}"
      [[ -n "$dest" ]] || { echo "usage: erda strongbox backup <destination-path>" >&2; exit 1; }
      [[ -f "$key_path" ]] || { echo "strongbox: no local $key_path to back up" >&2; exit 1; }
      [[ -d "$dest" ]] && dest="$dest/ship.key"
      cp "$key_path" "$dest"
      chmod 600 "$dest" 2>/dev/null || true
      echo "backed up $key_path -> $dest"
      echo "keep this somewhere durable and private (password manager, encrypted drive, etc.) — it's the only copy outside this machine."
      ;;

    restore)
      local src="${1:-}"
      [[ -n "$src" ]] || { echo "usage: erda strongbox restore <source-path>" >&2; exit 1; }
      [[ -f "$src" ]] || { echo "strongbox: no file at $src" >&2; exit 1; }
      if [[ -f "$key_path" ]]; then
        read -rp "strongbox: $key_path already exists. Type 'overwrite' to replace it: " CONFIRM
        [[ "$CONFIRM" == "overwrite" ]] || { echo "cancelled." >&2; exit 1; }
      fi
      cp "$src" "$key_path"
      chmod 600 "$key_path"
      echo "restored $key_path from $src"
      echo "verify with: erda board <ship>"
      ;;

    *)
      echo "usage: erda strongbox <init|backup|restore> [args...]" >&2
      echo "  init                 generate a new keypair + encrypt DEEPINFRA_API_KEY (and optionally GH_TOKEN)" >&2
      echo "  backup <path>        copy ship.key to a path of your choosing" >&2
      echo "  restore <path>       copy ship.key back from a path of your choosing" >&2
      exit 1
      ;;
  esac
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

  strongbox)
    cmd_strongbox "$@"
    ;;

  board)
    # Ships get sunk and christened often enough that a separate "now unlock
    # it" step was pure friction -- boarding always deploys ship.key (if
    # missing) and connects with the strongbox already unlocked, as long as a
    # local strongbox/ship.key exists at all. Before `erda strongbox init` has
    # ever been run there's nothing to deploy, so it falls back to a plain
    # connect rather than failing hard.
    NAME="${1:-ship}"
    IP="$(ship_ip "$NAME")"
    echo "boarding '$NAME' ($IP)..."

    KEY_PATH="$REPO_ROOT/strongbox/ship.key"
    if [[ -f "$KEY_PATH" ]]; then
      KEY_PRESENT="$(ssh -i "$SSH_PRIV" -o LogLevel=ERROR eric@"$IP" 'test -f ~/.config/age/ship.key && echo yes || echo no')"
      if [[ "$KEY_PRESENT" != "yes" ]]; then
        echo "no age key on '$NAME' yet -- copying strongbox/ship.key..."
        ssh -i "$SSH_PRIV" -o LogLevel=ERROR eric@"$IP" 'mkdir -p ~/.config/age'
        scp -i "$SSH_PRIV" -o LogLevel=ERROR "$KEY_PATH" eric@"$IP":~/.config/age/ship.key
        ssh -i "$SSH_PRIV" -o LogLevel=ERROR eric@"$IP" 'chmod 600 ~/.config/age/ship.key'
      fi
      ssh -i "$SSH_PRIV" -t eric@"$IP" 'eval "$(unlock captain)"; exec bash -l'
    else
      echo "erda: no local strongbox/ship.key yet -- connecting without the strongbox unlocked (see strongbox/README.md)" >&2
      ssh -i "$SSH_PRIV" eric@"$IP"
    fi
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
