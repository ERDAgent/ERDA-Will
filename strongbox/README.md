# The Strongbox

Encrypted secrets for the ship. `keys.env.age`/`captain.env.age` are committed
(encrypted); `ship.key` (the private half) is gitignored and lives only on your
trusted machine.

**`ship.key` is host-side, permanent infrastructure — it has nothing to do with
any one ship.** Sinking a ship never touches it. Losing it is *not* recoverable
by generating a new one: the committed `.env.age` files were encrypted to the
old key's public half specifically, so a fresh key can't decrypt them — you'd
need to re-mint every secret from scratch (see the incident this rationale
comes from: HANDOFF §4q). **Back it up the moment you create it.**

## Setup (once, on your trusted machine)

The easy way — `erda strongbox init` generates the keypair, prompts for
`DEEPINFRA_API_KEY` (hidden input), optionally sets up the captain compartment
(`GH_TOKEN`) and the shipwright compartment (`ANTHROPIC_API_KEY`), encrypts
each, and verifies every one decrypts to a non-empty value:

    erda strongbox init

By hand, if you want to see every step:
    age-keygen -o ship.key                    # keep ship.key OUT of git
    cat > keys.env <<KEYS
    DEEPINFRA_API_KEY=...
    KEYS
    age -r "$(grep -o 'age1.*' ship.key)" -o keys.env.age keys.env
    shred -u keys.env

## Checking credential health: `erda doctor`

Run `erda doctor` any time you want to know whether the strongbox is actually
usable — no ship needed. It decrypts each compartment present and makes a
real live call to the credential's own API (DeepInfra, `gh auth status`,
Anthropic), rather than treating "decrypts to something non-empty" as good
enough. `christen` and `board` both run it automatically first and refuse to
proceed if it fails. A `.env.age` file that decrypts fine but whose value is
dead upstream (expired/revoked) is a real, silent failure mode this is
built specifically to catch — see HANDOFF §4v for the incident that proved
it: a Windows-only CRLF encoding bug baked a stray `\r` into a still-valid
GitHub PAT, which decrypted to a plausible value and passed every host-side
tool's own check (including an early version of `doctor` itself), yet was
rejected by GitHub as invalid the moment a real Ubuntu ship's plain `bash`
decrypted it. Fixed in `erda.ps1`'s `strongbox init`; `doctor` also checks
for this specific contamination directly.

## Back it up (do this now, not after you lose it)

    erda strongbox backup <path>       # copy ship.key somewhere durable and
                                        # private — a password manager's file
                                        # attachment, an encrypted drive, etc.
                                        # Your choice of destination; erda
                                        # doesn't assume or require any
                                        # particular cloud/vault provider.
    erda strongbox restore <path>      # copy it back, on this machine or a
                                        # replacement one

## Per new ship (the one manual step)
    mkdir -p ~/.config/age && scp ship.key <ship>:~/.config/age/ship.key
    eval "$(unlock)"          # or: set -a; source <(unlock); set +a

(`erda board <ship>` does this deploy-if-missing step for you automatically, every
time you connect, then connects with the strongbox already unlocked.)

`fitout.sh` calls unlock automatically when the key is present, and skips
gracefully when it isn't (so the keel never blocks on secrets).

**A ship's own checkout can go stale relative to the strongbox.** The
`.env.age` files travel with the git repo, not with `ship.key` — if you
regenerate the keypair (e.g. after losing the old one), any ship that already
cloned the repo before that point still has the *old* encrypted bundles on
disk, encrypted to the *old* key. `unlock`/`unlock captain` will fail with
`age: error: no identity matched any of the recipients` until that ship's
checkout is updated (`git pull` inside its clone, once the new `.env.age`
files are committed and pushed) to match the new key.

## Compartments (added with GitHub access)

| File | Scope | Contents | Who loads it |
|---|---|---|---|
| `keys.env.age` | crew | Model keys only (`DEEPINFRA_API_KEY`) | Every agent context: `eval "$(unlock)"` — muster's crew windows do this |
| `captain.env.age` | captain | Push/publish credentials (`GH_TOKEN`), plus (optional — see below) `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY` for a Claude-backed Captain | Bridge + integration only: `eval "$(unlock captain)"` — sail's bridge window does this automatically, and `charter` does too (quietly, before its gh-auth check) so a bare `captain charter` works from any shell once `ship.key` is deployed |
| `shipwright.env.age` | shipwright | System-level Claude Code credential (`ANTHROPIC_API_KEY`) | Shipwright window only: `eval "$(unlock shipwright)"` — sail's shipwright window does this automatically. Superset of captain scope (also gets `GH_TOKEN`), since this pane pushes system-level changes to ERDA-Will itself |

Crew agents must never hold push credentials — "crew never push" is enforced
by this split, not just by crew.md's prose. Never move GH_TOKEN into
keys.env.age "for convenience." Model/inference keys (`DEEPINFRA_API_KEY`,
and now optionally `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY` for a
Claude-backed Captain) are a different axis than push credentials — see
"Backend-switching" below for why the latter now *can* live in
`captain.env.age` too, deliberately narrower than crew scope: only a
Claude-backed charter Captain and `delegate-claude` (which inherits that
Captain's own environment) get it in v1 — crew's own `keys.env.age` is
untouched, so a Claude-backed *crew* task via `muster` directly still has no
key and fails loudly rather than silently, until a separate explicit
decision extends crew scope too.

## GH_TOKEN — creating the captain compartment (operator, one time)

1. **Mint a fine-grained PAT on the ERDAgent GitHub account**
   (Settings → Developer settings → Fine-grained personal access tokens):
   - Repository access: **Only select repositories** — just the charter repos.
   - Permissions: **Contents: Read and write.** Add **Pull requests: Read and
     write** only if the Captain will open PRs. Add **Workflows** only if crews
     will ever edit `.github/workflows/` (pushes touching those files fail
     without it). Nothing else.
   - Set an expiry. Rotation = repeat step 3 with the new token.
2. **Give ERDAgent write access** to each charter repo that isn't already
   under the ERDAgent account/org (repo → Settings → Collaborators).

**Separate, broader scope needed for `captain charter`'s auto-create-repo
feature.** The PAT above (Contents R/W on specific repos) is enough for
pushing to charters that already exist, but **cannot create new repos** —
verified directly: `gh repo create` with that scope returns `Resource not
accessible by personal access token (createRepository)`. Repo creation is an
account-level action, not scoped to a pre-existing repo, so it needs a
*different* fine-grained PAT shape: **Repository access: All repositories**,
plus **Administration: Read and write**. This is a meaningfully bigger grant
than the minimal push-only scope above — deliberate tradeoff, not an
oversight, so mint it as a conscious choice rather than just widening the
existing token "to make the error go away." Without it, `captain charter`
with no `git-url` falls back to a local-only charter automatically, with a
clear message explaining why — not a hard failure.
3. **Encrypt** (note the `bash -c` wrapper — zsh's `read -p` means something
   entirely different; this exact mistake silently encrypted an empty value
   once already, see HANDOFF §4f):

       bash -c 'read -rs -p "GH_TOKEN: " T; echo; printf "GH_TOKEN=%s\n" "$T" \
         | age -r "$(grep -o "age1.*" ship.key)" -o captain.env.age -'

4. **Verify a non-empty value, not just presence** (also a §4f lesson):

       age -d -i ship.key captain.env.age | wc -c    # must be > 10

5. Commit `captain.env.age`. On the ship: `eval "$(unlock captain)" && gh auth status`
   should report ERDAgent.

## ANTHROPIC_API_KEY — creating the shipwright compartment (operator, one time)

Powers the **Shipwright CC** tmux window (`sail`'s window 7): a real Claude
Code instance, on the ship, scoped to system-level work on ERDA-Will itself —
not charter work. Chosen over Claude Code's interactive `/login`
(subscription) flow specifically so this pane can be provisioned the same
unattended way as every other credential here, at the cost of pay-per-token
API billing on this key rather than riding your existing subscription.

1. **Mint an API key** at [console.anthropic.com](https://console.anthropic.com)
   (Settings → API Keys). No fine-grained scoping like GitHub's PATs — it's a
   single capability, budget/usage limits are the only real lever.
2. **Encrypt** (same `bash -c` wrapper, same reason as GH_TOKEN above):

       bash -c 'read -rs -p "ANTHROPIC_API_KEY: " T; echo; printf "ANTHROPIC_API_KEY=%s\n" "$T" \
         | age -r "$(grep -o "age1.*" ship.key)" -o shipwright.env.age -'

3. **Verify a non-empty value, not just presence:**

       age -d -i ship.key shipwright.env.age | wc -c    # must be > 10

4. Commit `shipwright.env.age`. On the ship: `eval "$(unlock shipwright)" && claude --version`
   should run without a `/login` prompt.

## Shipwright CO (Codex) — no strongbox compartment, by design

The **Shipwright CO** window (`sail`'s window 8, `codex`) is the OpenAI
counterpart to Shipwright CC above, but deliberately does *not* get its own
strongbox compartment or API key — per `docs/agentic-engineering-plan.md`
§4, Codex stays on the Admiral's own ChatGPT/OpenAI subscription via
`codex login` rather than pay-per-token API billing. That's a one-time
manual step per ship (this compartment's whole point is to avoid exactly
that kind of manual step, so don't "fix" this by minting an `OPENAI_API_KEY`
compartment without checking with the Admiral first — it would change the
billing model, not just the plumbing):

    codex login                    # opens a browser flow; needs a local browser
    codex login --device-auth      # headless-friendly: prints a URL + code instead

Run whichever fits from inside the Shipwright CO window itself (it loads
`unlock shipwright` for `GH_TOKEN` same as CC, so push access is already
covered — `codex login` only needs to happen once per ship, not per
charter/deck, since credentials land under `~/.codex`, outside any one
charter). `sail` prints a reminder in this window if `codex login status`
comes back logged-out.

This same one-time `codex login` also covers any **charter** Captain/crew
task whose backend is set to `codex` (see "Backend-switching" below) — auth
lives under `~/.codex`, not the strongbox, so it doesn't matter which role
or charter is asking.

## Backend-switching (`ship/backends.json` / `.ship/backend.json`) — Claude auth for a charter Captain (operator, one time, optional)

Lets the Admiral pick which backend (DeepInfra/GLM-5.2, Claude Code, or
Codex) powers a charter's Captain/Crew/First Mate/Quartermaster roles — see
`ship/bin/backend` and `docs/backend-verification-notes.md`. Codex needs
nothing beyond the `codex login` above. **Claude needs a key in the
`captain` compartment** (a Claude-backed Captain, and `delegate-claude`
which inherits that Captain's own already-`unlock captain`'d environment,
both read from here — crew's own `keys.env.age` is deliberately untouched,
see the note above the compartment table).

Two options, prefer the first:

1. **`CLAUDE_CODE_OAUTH_TOKEN` (preferred — rides your Claude subscription,
   not pay-per-token)**: run `claude setup-token` (opens an interactive
   OAuth flow; confirmed via the shipped binary's own strings that this
   token is deliberately "limited to inference-only," which is exactly the
   headless-crew-work use case here), then encrypt whatever it gives you
   the same way as `GH_TOKEN` above:

       bash -c 'read -rs -p "CLAUDE_CODE_OAUTH_TOKEN: " T; echo; printf "CLAUDE_CODE_OAUTH_TOKEN=%s\n" "$T" \
         | age -r "$(grep -o "age1.*" ship.key)" -o captain.env.age -'

   (If `captain.env.age` already exists with `GH_TOKEN` in it, decrypt it
   first, append the new line, then re-encrypt — same caution as any
   multi-value compartment: verify the merged plaintext has *both* values
   before overwriting the committed file.)

2. **`ANTHROPIC_API_KEY` (fallback — pay-per-token, same key type Shipwright
   CC already uses)**: same steps as the shipwright compartment section
   above, just written into `captain.env.age` instead of
   `shipwright.env.age`.

`backend_auth_setup` (in `ship/bin/backend-lib.sh`) tries
`CLAUDE_CODE_OAUTH_TOKEN` first, falls back to `ANTHROPIC_API_KEY`, and
prints which one it's using — verify with: `backend <charter> captain
claude` then restart the bridge window and watch its startup line.
