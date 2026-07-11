#!/usr/bin/env bash
# erda — single entry point for all Harbor-side ship operations.
# usage: erda <command> [ship] [args...]
#
#   install                                  wire up `erda` as a global shell
#                                             command (run once per machine, or
#                                             again after moving/updating the repo)
#   christen [name] [cpus] [memory] [disk]   launch a new ship
#   strongbox <init|backup|restore>          manage the local age keypair (see below)
#   doctor                                   host-side credential health check (no ship
#                                             needed) -- also runs automatically before
#                                             christen/board, which refuse to proceed if
#                                             it fails
#   board [ship]                             connect: multipass info + ssh in, deploying
#                                             the age key if needed and connecting with
#                                             the strongbox already unlocked (captain
#                                             scope: model keys + GH_TOKEN)
#   telescope <charter> [ship] [port]        SSH-tunnel to a charter's dev server
#                                             (integration branch); port read from
#                                             charter.md if not given
#   anchor [ship|all]                        multipass stop
#   force-anchor [ship|all]                  multipass stop --force
#   sail [ship|all]                          multipass start
#   resail [ship|all]                        multipass restart
#   suspend [ship|all]                       multipass suspend
#   view [ship]                              multipass list (no ship) / info <ship>
#   sink [ship|all]                          multipass delete --purge
#                                             (asks to confirm; -y/--force skips)
#
# [ship] defaults to "ship" everywhere it's optional. Pass "all" to
# anchor/force-anchor/sail/resail/suspend/sink to apply the same operation to
# every ship multipass knows about, instead of just one.
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

# every ship multipass currently knows about, one name per line -- backs the
# "all" fleet-wide variant of anchor/force-anchor/sail/resail/suspend/sink,
# not just what's currently running (e.g. `erda sail all` should start
# stopped ships too).
all_ship_names() {
  "$MULTIPASS" list --format csv 2>/dev/null | tail -n +2 | cut -d, -f1
}

# run_fleetwide <multipass-subcommand> [extra args after the name...]
# Applies one multipass subcommand to every known ship in turn. Best-effort:
# one ship failing (e.g. already stopped) doesn't stop the rest, but the
# overall exit status reflects whether anything failed.
run_fleetwide() {
  local subcmd="$1"; shift
  local extra=("$@")
  local names=()
  mapfile -t names < <(all_ship_names)
  if [[ "${#names[@]}" -eq 0 ]]; then
    echo "erda: no ships found (multipass list is empty)" >&2
    return 0
  fi
  local n failed=0
  for n in "${names[@]}"; do
    echo "-- $subcmd $n ${extra[*]:-} --"
    if ! "$MULTIPASS" "$subcmd" "$n" "${extra[@]}"; then
      echo "erda: $subcmd $n failed" >&2
      failed=1
    fi
  done
  return "$failed"
}

usage() {
  cat >&2 <<'USAGE'
usage: erda <command> [ship] [args...]
  install                                   wire up `erda` as a global command (run once)
  christen [name] [cpus] [memory] [disk]    launch a new ship
  strongbox init                            generate a new keypair + encrypt secrets
  strongbox backup <path>                   copy ship.key to a path of your choosing
  strongbox restore <path>                  copy ship.key back from a path
  doctor                                    host-side credential health check (no ship
                                             needed); christen/board also run this first
                                             and refuse to proceed if it fails
  board [ship]                              connect (multipass info + ssh), deploying the
                                             age key if needed and unlocking the strongbox
  telescope <charter> [ship] [port]         SSH-tunnel to a charter's dev server (port
                                             read from charter.md if not given)
  anchor [ship|all]                         stop
  force-anchor [ship|all]                   stop --force
  sail [ship|all]                           start
  resail [ship|all]                         restart
  suspend [ship|all]                        suspend
  view [ship]                               list (no ship) / info <ship>
  sink [ship|all]                           delete --purge (asks to confirm; -y/--force skips)
[ship] defaults to "ship" everywhere it's optional. Pass "all" to
anchor/force-anchor/sail/resail/suspend/sink to apply it to every ship
multipass knows about.
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

# doctor — host-side credential health check, no ship needed. Distinguishes
# the three states an operator actually cares about (no key at all / a key
# that can't decrypt the committed .env.age files / a key that decrypts fine
# but the credential inside has gone bad upstream) instead of letting all
# three surface identically, deep inside charter's or muster's own silent
# fallback. That collapse is real, not hypothetical: an expired/revoked
# GH_TOKEN decrypts to a perfectly valid-looking 94-byte string and produces
# the exact same "gh not authenticated" fallback message a missing token
# does -- only a live call to GitHub itself tells them apart.
#
# DEEPINFRA_API_KEY and GH_TOKEN are treated differently on purpose:
# keys.env.age is required baseline (nothing works without a model key), but
# captain.env.age/shipwright.env.age are optional compartments -- not having
# them at all is a legitimate "local-only, no push" choice charter already
# supports gracefully. Only a compartment that EXISTS but is broken fails
# doctor; one that was never provisioned is silently skipped.
cmd_doctor() {
  local key_path="$REPO_ROOT/strongbox/ship.key"
  local ok=1

  command -v age >/dev/null 2>&1 || {
    echo "doctor: 'age' isn't installed on this machine (brew install age / winget install --id FiloSottile.age)" >&2
    return 1
  }

  if [[ ! -f "$key_path" ]]; then
    echo "doctor: NO KEY -- $key_path doesn't exist yet. Run: erda strongbox init" >&2
    return 1
  fi

  local keys_age="$REPO_ROOT/strongbox/keys.env.age"
  if [[ ! -f "$keys_age" ]]; then
    echo "doctor: NO KEY -- $keys_age doesn't exist yet. Run: erda strongbox init" >&2
    return 1
  fi

  local keys_plain
  if ! keys_plain="$(age -d -i "$key_path" "$keys_age" 2>/dev/null)"; then
    echo "doctor: WRONG KEY -- $key_path can't decrypt $keys_age (stale/regenerated ship.key? see strongbox/README.md's stale-checkout note)" >&2
    return 1
  fi
  # Raw byte check, not on $keys_plain: bash's own "$(...)" capture (used
  # just above) already strips a trailing \r along with the \n, same as
  # PowerShell's pipeline does -- so it would silently launder away exactly
  # the corruption this is trying to catch. Only a check against the
  # untouched byte stream still sees it.
  if age -d -i "$key_path" "$keys_age" 2>/dev/null | grep -qU $'\r'; then
    echo "doctor: $keys_age has a Windows CRLF baked into its plaintext (a stray carriage return) -- likely encrypted via a PowerShell 'string | age' pipe before that was fixed. Re-encrypt via 'erda strongbox init'; it silently 'looks' fine from Windows tools but breaks on a real Linux ship" >&2
    ok=0
  fi
  local deepinfra_key
  deepinfra_key="$(printf '%s\n' "$keys_plain" | sed -n 's/^DEEPINFRA_API_KEY=//p')"
  if [[ -z "$deepinfra_key" ]]; then
    echo "doctor: keys.env.age decrypts but DEEPINFRA_API_KEY is empty -- re-run erda strongbox init" >&2
    ok=0
  elif ! command -v curl >/dev/null 2>&1; then
    echo "doctor: 'curl' isn't installed -- can't live-check DEEPINFRA_API_KEY, only that it decrypts" >&2
  else
    local di_code
    di_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $deepinfra_key" https://api.deepinfra.com/v1/openai/models || echo 000)"
    if [[ "$di_code" != "200" ]]; then
      echo "doctor: DEEPINFRA_API_KEY decrypts fine but DeepInfra rejected it (HTTP $di_code) -- mint a new key and re-encrypt keys.env.age" >&2
      ok=0
    else
      echo "doctor: DEEPINFRA_API_KEY OK"
    fi
  fi

  local captain_age="$REPO_ROOT/strongbox/captain.env.age"
  if [[ -f "$captain_age" ]]; then
    local captain_plain
    if ! captain_plain="$(age -d -i "$key_path" "$captain_age" 2>/dev/null)"; then
      echo "doctor: WRONG KEY -- $key_path can't decrypt $captain_age" >&2
      ok=0
    elif age -d -i "$key_path" "$captain_age" 2>/dev/null | grep -qU $'\r'; then
      echo "doctor: $captain_age has a Windows CRLF baked into its plaintext (a stray carriage return) -- likely encrypted via a PowerShell 'string | age' pipe before that was fixed. Re-encrypt via 'erda strongbox init'; it silently 'looks' fine from Windows tools but breaks on a real Linux ship" >&2
      ok=0
    else
      local gh_token
      gh_token="$(printf '%s\n' "$captain_plain" | sed -n 's/^GH_TOKEN=//p')"
      if [[ -z "$gh_token" ]]; then
        echo "doctor: captain.env.age decrypts but GH_TOKEN is empty -- re-encrypt captain.env.age" >&2
        ok=0
      elif ! command -v gh >/dev/null 2>&1; then
        echo "doctor: 'gh' isn't installed on this machine -- can't live-check GH_TOKEN, only that it decrypts" >&2
      elif ! GH_TOKEN="$gh_token" gh auth status >/dev/null 2>&1; then
        echo "doctor: GH_TOKEN decrypts fine but GitHub rejected it (expired/revoked?) -- mint a new fine-grained PAT (Repository access: All repositories, Administration: Read and write) and re-encrypt captain.env.age, see strongbox/README.md" >&2
        ok=0
      else
        echo "doctor: GH_TOKEN OK"
      fi

      # Backend-switching (see ship/backends.json / docs/backend-switching-guide.md)
      # can put CLAUDE_CODE_OAUTH_TOKEN and/or ANTHROPIC_API_KEY in this same
      # file, independent of GH_TOKEN above -- optional, not having either yet
      # is a legitimate "still on deepinfra/codex" state, not a failure.
      local claude_oauth claude_apikey
      claude_oauth="$(printf '%s\n' "$captain_plain" | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p')"
      claude_apikey="$(printf '%s\n' "$captain_plain" | sed -n 's/^ANTHROPIC_API_KEY=//p')"
      if [[ -n "$claude_oauth" ]]; then
        # Live-tested directly against api.anthropic.com/v1/models while building
        # this check: a bogus ANTHROPIC_API_KEY gets a real 401 there, but that
        # endpoint has no confirmed relationship to CLAUDE_CODE_OAUTH_TOKEN's own
        # auth flow -- and `claude --version`/`claude auth status` were both
        # live-tested and confirmed to report success even for a bogus or absent
        # credential, so neither substitutes for a real check. Presence is
        # reported honestly instead of guessing at an unverified probe.
        echo "doctor: captain.env.age has CLAUDE_CODE_OAUTH_TOKEN (present -- not live-verifiable via a direct API probe; a charter Captain's first real turn under backend=claude will surface an auth failure immediately if it's bad)"
      elif [[ -n "$claude_apikey" ]]; then
        if ! command -v curl >/dev/null 2>&1; then
          echo "doctor: 'curl' isn't installed -- can't live-check captain.env.age's ANTHROPIC_API_KEY, only that it decrypts" >&2
        else
          local cc_code
          cc_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "x-api-key: $claude_apikey" -H "anthropic-version: 2023-06-01" https://api.anthropic.com/v1/models || echo 000)"
          if [[ "$cc_code" != "200" ]]; then
            echo "doctor: captain.env.age's ANTHROPIC_API_KEY decrypts fine but Anthropic rejected it (HTTP $cc_code) -- mint a new key, see strongbox/README.md's Backend-switching section" >&2
            ok=0
          else
            echo "doctor: captain.env.age's ANTHROPIC_API_KEY OK (charter Captain can use backend=claude)"
          fi
        fi
      fi
    fi
  fi

  local shipwright_age="$REPO_ROOT/strongbox/shipwright.env.age"
  if [[ -f "$shipwright_age" ]]; then
    local shipwright_plain
    if ! shipwright_plain="$(age -d -i "$key_path" "$shipwright_age" 2>/dev/null)"; then
      echo "doctor: WRONG KEY -- $key_path can't decrypt $shipwright_age" >&2
      ok=0
    elif age -d -i "$key_path" "$shipwright_age" 2>/dev/null | grep -qU $'\r'; then
      echo "doctor: $shipwright_age has a Windows CRLF baked into its plaintext (a stray carriage return) -- likely encrypted via a PowerShell 'string | age' pipe before that was fixed. Re-encrypt via 'erda strongbox init'; it silently 'looks' fine from Windows tools but breaks on a real Linux ship" >&2
      ok=0
    else
      local anthropic_key
      anthropic_key="$(printf '%s\n' "$shipwright_plain" | sed -n 's/^ANTHROPIC_API_KEY=//p')"
      if [[ -z "$anthropic_key" ]]; then
        echo "doctor: shipwright.env.age decrypts but ANTHROPIC_API_KEY is empty" >&2
        ok=0
      elif ! command -v curl >/dev/null 2>&1; then
        echo "doctor: 'curl' isn't installed -- can't live-check ANTHROPIC_API_KEY, only that it decrypts" >&2
      else
        local an_code
        an_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "x-api-key: $anthropic_key" -H "anthropic-version: 2023-06-01" https://api.anthropic.com/v1/models || echo 000)"
        if [[ "$an_code" != "200" ]]; then
          echo "doctor: ANTHROPIC_API_KEY decrypts fine but Anthropic rejected it (HTTP $an_code)" >&2
          ok=0
        else
          echo "doctor: ANTHROPIC_API_KEY OK"
        fi
      fi
    fi
  fi

  [[ "$ok" -eq 1 ]]
}

CMD="${1:-}"
[[ $# -gt 0 ]] && shift

case "$CMD" in
  install)
    cmd_install "$@"
    ;;

  christen)
    cmd_doctor || { echo "christen: fix the strongbox issues above first (see 'erda doctor')" >&2; exit 1; }
    cmd_christen "$@"
    ;;

  strongbox)
    cmd_strongbox "$@"
    ;;

  doctor)
    cmd_doctor && echo "doctor: all checks passed"
    ;;

  board)
    cmd_doctor || { echo "board: fix the strongbox issues above first (see 'erda doctor')" >&2; exit 1; }
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

  telescope)
    # SSH port-forward to a charter's dev server (see ship/bin/telescope,
    # sail's "telescope" window) -- never a raw exposed port, so the dev
    # server only ever needs to bind localhost on the ship itself.
    NAME="${1:-}"
    [[ -n "$NAME" ]] || { echo "usage: erda telescope <charter> [ship] [port]" >&2; exit 1; }
    shift
    SHIP_NAME="${1:-ship}"
    [[ $# -gt 0 ]] && shift
    PORT="${1:-}"
    IP="$(ship_ip "$SHIP_NAME")"

    echo "ensuring the deck is up for '$NAME' on '$SHIP_NAME' ($IP)..."
    ssh -i "$SSH_PRIV" -o LogLevel=ERROR eric@"$IP" "SHIP_NO_ATTACH=1 sail $NAME"

    if [[ -z "$PORT" ]]; then
      PORT="$(ssh -i "$SSH_PRIV" -o LogLevel=ERROR eric@"$IP" "sed -n '/^## Dev server/,/^## /{/^- port:/s/^- port: *//p}' ~/fleet/$NAME/charter.md 2>/dev/null | head -1")"
      case "$PORT" in
        \(*|"")
          echo "erda: no port configured in ~/fleet/$NAME/charter.md's '## Dev server' section (and none given as an argument)" >&2
          echo "  fill it in, or run: erda telescope $NAME $SHIP_NAME <port>" >&2
          exit 1
          ;;
      esac
    fi

    echo "tunneling localhost:$PORT -> $SHIP_NAME:$PORT ..."
    echo "open: http://localhost:$PORT"
    echo "(Ctrl+C to close the tunnel)"
    ssh -i "$SSH_PRIV" -N -L "$PORT:localhost:$PORT" eric@"$IP"
    ;;

  anchor)
    NAME="${1:-ship}"
    if [[ "$NAME" == "all" ]]; then run_fleetwide stop; else "$MULTIPASS" stop "$NAME"; fi
    ;;
  force-anchor)
    NAME="${1:-ship}"
    if [[ "$NAME" == "all" ]]; then run_fleetwide stop --force; else "$MULTIPASS" stop "$NAME" --force; fi
    ;;
  sail)
    NAME="${1:-ship}"
    if [[ "$NAME" == "all" ]]; then run_fleetwide start; else "$MULTIPASS" start "$NAME"; fi
    ;;
  resail)
    NAME="${1:-ship}"
    if [[ "$NAME" == "all" ]]; then run_fleetwide restart; else "$MULTIPASS" restart "$NAME"; fi
    ;;
  suspend)
    NAME="${1:-ship}"
    if [[ "$NAME" == "all" ]]; then run_fleetwide suspend; else "$MULTIPASS" suspend "$NAME"; fi
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
    if [[ "$NAME" == "all" ]]; then
      mapfile -t ALL_NAMES < <(all_ship_names)
      if [[ "${#ALL_NAMES[@]}" -eq 0 ]]; then
        echo "erda: no ships found (multipass list is empty)"
        exit 0
      fi
      if [[ "$FORCE" -ne 1 ]]; then
        echo "This will permanently destroy ALL ships and everything on them:"
        printf '  %s\n' "${ALL_NAMES[@]}"
        read -rp "Type 'all' to confirm: " CONFIRM
        [[ "$CONFIRM" == "all" ]] || { echo "cancelled."; exit 1; }
      fi
      FAILED=0
      for N in "${ALL_NAMES[@]}"; do
        echo "-- sink $N --"
        "$MULTIPASS" delete "$N" --purge || { echo "erda: delete $N failed" >&2; FAILED=1; }
      done
      exit "$FAILED"
    fi
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
