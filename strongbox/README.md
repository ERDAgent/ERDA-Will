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
(`GH_TOKEN`), encrypts both, and verifies each decrypts to a non-empty value:

    erda strongbox init

By hand, if you want to see every step:
    age-keygen -o ship.key                    # keep ship.key OUT of git
    cat > keys.env <<KEYS
    DEEPINFRA_API_KEY=...
    KEYS
    age -r "$(grep -o 'age1.*' ship.key)" -o keys.env.age keys.env
    shred -u keys.env

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
| `captain.env.age` | captain | Push/publish credentials (`GH_TOKEN`) | Bridge + integration only: `eval "$(unlock captain)"` — sail's bridge window does this automatically, and `charter` does too (quietly, before its gh-auth check) so a bare `captain charter` works from any shell once `ship.key` is deployed |

Crew agents must never hold push credentials — "crew never push" is enforced
by this split, not just by crew.md's prose. Never move GH_TOKEN into
keys.env.age "for convenience."

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
