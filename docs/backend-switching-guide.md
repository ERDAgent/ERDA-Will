# Switching backends: a plain-language guide

Each model/agent backend powering a role is that role's **Trade Wind**. You
have three available Trade Winds for any ship role (Captain, Crew, First Mate,
Quartermaster): **DeepInfra/GLM-5.2** (the default), **Claude
Code** (your Anthropic subscription or an API key), or **Codex** (your
ChatGPT/OpenAI subscription). This is per-charter, per-role, and switchable
any time. This guide is the short version — see `strongbox/README.md`'s
"Backend-switching" section and `ship/backends.json`/`ship/bin/backend` for
the full mechanism.

The Chartroom dashboard's **Trade Winds** section shows the current setting
for every role in that charter. Treat it as the at-a-glance source of truth;
GLM-5.2 is one Trade Wind, not a synonym for the analogy itself. Claude Code
and Codex choose their model through their respective CLI defaults, so the
section says "default model" rather than claiming a model version the ship
does not explicitly pin.

## The one thing to know before anything else

**Switching does not affect a window that's already running.** If a Captain
session is mid-conversation on GLM-5.2, changing its backend setting doesn't
touch it — the window has to be restarted to pick up the new backend. This
is deliberate: there's no way to transplant an in-progress conversation from
one model to another mid-stream, so the system doesn't pretend to.

## Step 1 — check what's ready to use, right now

Two commands, one on each side:

```
# On the ship, in any window:
backend doctor

# On your own machine (harbor/), no ship needed:
erda doctor
```

`backend doctor` tells you whether each backend can actually authenticate
*right now* — it does a real (free) check, not just "is there a file here."
Typical first-run output, before you've set anything up:

```
backend doctor: checking auth for each registered backend...
  FAIL  claude: no CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY in captain.env.age (see docs/backend-switching-guide.md)
  OK    codex: logged in
  OK    deepinfra: DEEPINFRA_API_KEY live
```

Add a charter name to also see what each role is currently set to:

```
backend doctor my-charter
```

```
charter 'my-charter' -- active backend per role:
  captain        deepinfra
  crew           deepinfra
  first-mate     deepinfra
  quartermaster  deepinfra
```

`erda doctor` (host-side) checks the same credentials from the strongbox's
point of view — useful if something looks wrong and you want to know
whether the problem is a bad key vs. a ship-side issue. It can't see Codex's
login state though (that lives only on the ship, under `~/.codex`) —
`backend doctor` is the only place that shows the full picture.

## Step 2 — one-time setup per backend (skip whichever you don't need)

**Codex** — nothing to do if `backend doctor` already says `OK`. Otherwise,
from the Shipwright CO window (or any ship window):

```
codex login                    # opens a browser; needs a local browser
codex login --device-auth      # headless-friendly: prints a URL + code
```

One-time per ship, not per charter — covers every charter's Codex-backed
roles.

**Claude Code** — needs a credential in the strongbox's `captain`
compartment. Preferred option, rides your subscription instead of
pay-per-token billing:

```
claude setup-token
```

This opens an interactive OAuth flow and prints a long-lived token. Encrypt
it into `captain.env.age` (from `harbor/`, on your own machine):

```
bash -c 'read -rs -p "CLAUDE_CODE_OAUTH_TOKEN: " T; echo; printf "CLAUDE_CODE_OAUTH_TOKEN=%s\n" "$T" \
  | age -r "$(grep -o "age1.*" strongbox/ship.key)" -o strongbox/captain.env.age -'
```

If `captain.env.age` already has `GH_TOKEN` in it (it almost certainly
does), decrypt first, keep both lines, then re-encrypt — see
`strongbox/README.md` for the exact merge steps. Commit the result, then
confirm on the ship:

```
erda doctor        # host-side: confirms it decrypts
backend doctor     # ship-side: confirms Anthropic actually accepts it
```

(A note on that last check: `CLAUDE_CODE_OAUTH_TOKEN` itself can't be
live-verified against a public endpoint — there's no confirmed API surface
for it, unlike a plain `ANTHROPIC_API_KEY`. `backend doctor` will say
`~OK ... not live-verifiable` for it, which just means "present, we'll find
out for sure on first real use" rather than "confirmed working." If you'd
rather have a fully live-checked credential, use `ANTHROPIC_API_KEY`
instead — same setup, pay-per-token billing, but `backend doctor` gives it a
real thumbs-up or thumbs-down.)

**DeepInfra** — already set up if you're reading this from a working ship;
nothing to do.

## Step 3 — actually switch a role's backend

```
backend <charter-name> <role> <backend-name>
```

Example: put a charter's Captain on Claude:

```
backend my-charter captain claude
```

This does three things: writes the change, immediately runs the same live
check `backend doctor` uses (so you find out *now* if auth isn't ready, not
later when the window fails to start), and tells you how to restart:

```
backend: my-charter/captain now claude (was deepinfra)
backend: verifying claude auth...
  ~OK   claude: CLAUDE_CODE_OAUTH_TOKEN present -- not live-verifiable (no confirmed probe endpoint for this token type); a real Bridge/crew turn will surface an auth failure immediately if it's bad
note: the Bridge window (0) is running under 'deepinfra' until restarted:
  tmux kill-window -t ship-my-charter:0 && sail my-charter
```

Run that `tmux kill-window && sail` line and the Bridge window comes back up
as a real Claude Code session.

For Crew/First Mate/Quartermaster, same command shape (`backend my-charter
crew codex`, etc.) — no window to restart, it just takes effect the next
time that role is spawned (next `muster`, next First Mate/Quartermaster
invocation).

**Want to put the whole charter on one backend?** Use `all` instead of a
role name:

```
backend my-charter all claude
```

This sets all four roles in one call, runs the auth check once, and prints
every role's restart/next-invocation note.

## Checking current state without changing anything

```
backend <charter-name>              # all four roles at once
backend <charter-name> <role>       # just one
backend --list                      # every registered backend + its label
```

## Automatic fallback on rate limits

If a Claude- or Codex-backed Captain or Crew task hits a real rate limit
mid-run, the system detects it and flips that role back to `deepinfra` for
the *next* spawn on its own — you don't have to notice and switch manually.
This is reactive only (there's no way to see remaining subscription quota
ahead of time for either vendor), and it never touches a window that's
already running.

## If something doesn't add up

Run both doctors and read what they say — they're built to name the exact
broken thing (missing key, expired credential, wrong file) rather than a
generic failure. If a switch's live check fails but you're confident the
credential is actually fine (e.g. a transient network blip), the switch
still went through — just re-run `backend doctor` once things settle, or
retry the restart.
