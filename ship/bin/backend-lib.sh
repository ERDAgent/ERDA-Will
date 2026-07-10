# shellcheck shell=bash
# backend-lib.sh — shared helpers for backend-registry/state lookups.
# Sourced (not executed, not on PATH) by sail, muster, quartermaster,
# first-mate, delegate-claude, delegate-codex, backend-watch, and
# ship/bin/backend itself. Each caller must set SHIPYARD_DIR before sourcing
# (all of them already resolve it via the same readlink -f idiom for their
# own purposes).
#
# Registry (ship/backends.json): one entry per backend, shipyard-owned,
# checked into git, never secret. Per-charter state (.ship/backend.json):
# role -> active backend name, defaults to "deepinfra" for any missing file
# or role key so a charter that never touches this feature behaves exactly
# as it did before this feature existed.

BACKENDS_REGISTRY="${SHIP_BACKENDS_FILE:-$SHIPYARD_DIR/ship/backends.json}"

backend_state_path() {
  # $1: charter dir
  printf '%s/.ship/backend.json' "$1"
}

backend_get() {
  # $1: charter dir, $2: role -> active backend name for that role (default: deepinfra)
  local dir="$1" role="$2" state
  state="$(backend_state_path "$dir")"
  if [[ -f "$state" ]]; then
    jq -r --arg r "$role" '.[$r] // "deepinfra"' "$state" 2>/dev/null || echo deepinfra
  else
    echo deepinfra
  fi
}

backend_names() {
  jq -r 'keys[]' "$BACKENDS_REGISTRY"
}

backend_exists() {
  # $1: backend name
  jq -e --arg b "$1" 'has($b)' "$BACKENDS_REGISTRY" >/dev/null 2>&1
}

backend_field() {
  # $1: backend name, $2: jq filter applied to that backend's object (e.g. '.label')
  backend_exists "$1" || {
    echo "backend-lib: unknown backend '$1' (known: $(backend_names | tr '\n' ' '))" >&2
    return 1
  }
  jq -r --arg b "$1" ".[\$b] | $2" "$BACKENDS_REGISTRY"
}

backend_render() {
  # $1: template string, remaining args: KEY=value pairs -> substitutes {{KEY}}
  # tokens only; anything else (bare $VAR, $(...)) passes through untouched,
  # same deliberate-literal-until-runtime convention sail/muster already use.
  local out="$1"; shift
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    out="${out//\{\{$key\}\}/$val}"
  done
  printf '%s' "$out"
}

backend_auth_setup() {
  # $1: backend name, $2: role ("captain"/"crew"/"first-mate"/"quartermaster")
  # -> a literal shell snippet (echoed, not executed) that the caller
  # splices into a generated script/heredoc, same idiom as sail's/muster's
  # existing hardcoded `unlock ...`/`codex login status` lines -- just
  # parameterized by registry lookup instead of copy-pasted.
  #
  # The role matters, not just the backend: "crew never push" (D10) is a
  # capability boundary enforced by which strongbox compartment gets loaded,
  # not just prose -- unlock captain (which also carries GH_TOKEN) must
  # only ever happen for the captain role, regardless of which backend that
  # role is running under.
  local name="$1" role="$2" auth_type
  auth_type="$(backend_field "$name" '.auth.type')"
  local scope="crew"; [[ "$role" == "captain" ]] && scope="captain"
  case "$auth_type" in
    strongbox)
      # shellcheck disable=SC2016  # single-quoted on purpose: this is a printf format string, not meant to expand here
      printf 'command -v unlock >/dev/null 2>&1 && eval "$(unlock %s)"' "$scope"
      ;;
    claude-code)
      # v1 only wires CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_API_KEY into captain
      # scope (see docs/backend-verification-notes.md + strongbox/README.md)
      # -- a non-captain role under this backend still runs (claude itself
      # gives a clear "not authenticated" error), it just won't find a key
      # until the Admiral makes the separate call to extend crew scope too.
      if [[ "$role" != "captain" ]]; then
        printf 'echo "[backend] claude: no key wired for role '\''%s'\'' in v1 -- see docs/backend-verification-notes.md"' "$role"
        return
      fi
      local prefer fallback
      prefer="$(backend_field "$name" '.auth.prefer_env')"
      fallback="$(backend_field "$name" '.auth.fallback_env')"
      # shellcheck disable=SC2016  # single-quoted on purpose: this is a printf format string, not meant to expand here
      printf 'command -v unlock >/dev/null 2>&1 && eval "$(unlock captain)"; [[ -n "${%s:-}" ]] && echo "[backend] claude: using %s (subscription)" || { [[ -n "${%s:-}" ]] && echo "[backend] claude: using %s (pay-per-token)"; }' \
        "$prefer" "$prefer" "$fallback" "$fallback"
      ;;
    subscription-login)
      local check; check="$(backend_field "$name" '.auth.check')"
      # codex needs no strongbox key at all -- only the captain role loads
      # `unlock captain` here, and only for GH_TOKEN (push/PR access), same
      # as every other backend's captain path. Crew never gets it (D10).
      if [[ "$role" == "captain" ]]; then
        # shellcheck disable=SC2016  # single-quoted on purpose: this is a printf format string, not meant to expand here
        printf 'command -v unlock >/dev/null 2>&1 && eval "$(unlock captain)"; %s >/dev/null 2>&1 || echo "[backend] %s: not logged in -- run: codex login (or: codex login --device-auth over SSH)"' \
          "$check" "$name"
      else
        printf '%s >/dev/null 2>&1 || echo "[backend] %s: not logged in -- run: codex login (or: codex login --device-auth over SSH)"' \
          "$check" "$name"
      fi
      ;;
    *)
      printf 'echo "[backend] %s: unknown auth type %s" >&2' "$name" "$auth_type"
      ;;
  esac
}

# backend_check_auth: live readiness check for one backend, run ON the ship
# (unlike erda doctor, which is host-side and can't see codex login state).
# Prints one status line, returns 0 (ready) / 1 (not ready). Dispatches on
# auth.type same as backend_auth_setup above, but actually verifies instead
# of just checking presence -- except where live verification isn't a real
# thing to check: CLAUDE_CODE_OAUTH_TOKEN has no confirmed public-API probe
# endpoint (live-tested directly against api.anthropic.com/v1/models during
# this feature's build -- a bogus ANTHROPIC_API_KEY correctly gets a live
# 401 there, but that endpoint has no documented relationship to the OAuth
# token's own auth flow, and `claude auth status`/`claude --version` were
# both live-tested and confirmed to report success even for a bogus/absent
# credential, so neither is a substitute). Presence is reported honestly as
# "not live-verifiable" rather than a guessed-at check that could silently
# rubber-stamp a bad token.
backend_check_auth() {
  local name="$1" auth_type
  backend_exists "$name" || { echo "  ??    $name: not a registered backend"; return 1; }
  auth_type="$(backend_field "$name" '.auth.type')"
  case "$auth_type" in
    strongbox)              _backend_check_auth_strongbox "$name" ;;
    claude-code)             _backend_check_auth_claude_code "$name" ;;
    subscription-login)      _backend_check_auth_subscription_login "$name" ;;
    *) echo "  ??    $name: unknown auth type '$auth_type'"; return 1 ;;
  esac
}

_backend_check_auth_strongbox() {
  local name="$1" result
  command -v unlock >/dev/null 2>&1 || { echo "  FAIL  $name: 'unlock' not found on PATH"; return 1; }
  result="$(
    eval "$(unlock crew 2>/dev/null)" 2>/dev/null
    if [[ -z "${DEEPINFRA_API_KEY:-}" ]]; then
      echo "MISSING"
    else
      curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Authorization: Bearer $DEEPINFRA_API_KEY" \
        https://api.deepinfra.com/v1/openai/models 2>/dev/null || echo 000
    fi
  )"
  case "$result" in
    MISSING)
      echo "  FAIL  $name: DEEPINFRA_API_KEY not found in the strongbox (host-side: erda strongbox init)"
      return 1 ;;
    200)
      echo "  OK    $name: DEEPINFRA_API_KEY live"
      return 0 ;;
    *)
      echo "  FAIL  $name: DeepInfra rejected the key (HTTP $result) -- mint a new one, see strongbox/README.md"
      return 1 ;;
  esac
}

_backend_check_auth_claude_code() {
  local name="$1" prefer fallback result
  prefer="$(backend_field "$name" '.auth.prefer_env')"
  fallback="$(backend_field "$name" '.auth.fallback_env')"
  command -v unlock >/dev/null 2>&1 || { echo "  FAIL  $name: 'unlock' not found on PATH"; return 1; }
  result="$(
    eval "$(unlock captain 2>/dev/null)" 2>/dev/null
    pv="${!prefer:-}"; fv="${!fallback:-}"
    if [[ -n "$pv" ]]; then
      echo "PREFER"
    elif [[ -n "$fv" ]]; then
      curl -s -o /dev/null -w 'FALLBACK:%{http_code}' --max-time 10 \
        -H "x-api-key: $fv" -H "anthropic-version: 2023-06-01" \
        https://api.anthropic.com/v1/models 2>/dev/null || echo "FALLBACK:000"
    else
      echo "MISSING"
    fi
  )"
  case "$result" in
    MISSING)
      echo "  FAIL  $name: no $prefer or $fallback in captain.env.age (see docs/backend-switching-guide.md)"
      return 1 ;;
    PREFER)
      echo "  ~OK   $name: $prefer present -- not live-verifiable (no confirmed probe endpoint for this token type); a real Bridge/crew turn will surface an auth failure immediately if it's bad"
      return 0 ;;
    FALLBACK:200)
      echo "  OK    $name: $fallback live"
      return 0 ;;
    FALLBACK:*)
      echo "  FAIL  $name: $fallback decrypts but Anthropic rejected it (HTTP ${result#FALLBACK:})"
      return 1 ;;
  esac
}

_backend_check_auth_subscription_login() {
  local name="$1" check status
  check="$(backend_field "$name" '.auth.check')"
  if status="$(eval "$check" 2>/dev/null)"; then
    echo "  OK    $name: ${status:-logged in}"
    return 0
  else
    echo "  FAIL  $name: not logged in -- run: codex login (or: codex login --device-auth over SSH)"
    return 1
  fi
}
