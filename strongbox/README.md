# The Strongbox

Encrypted secrets for the ship. Only `keys.env.age` is ever committed — never plaintext.

## Setup (once, on your trusted machine)
    age-keygen -o ship.key                    # keep ship.key OUT of git
    cat > keys.env <<KEYS
    DEEPINFRA_API_KEY=...
    ANTHROPIC_API_KEY=...
    OPENAI_API_KEY=...
    KEYS
    age -r "$(grep -o 'age1.*' ship.key)" -o keys.env.age keys.env
    shred -u keys.env

## Per new ship (the one manual step)
    mkdir -p ~/.config/age && scp ship.key <ship>:~/.config/age/ship.key
    eval "$(unlock)"          # or: set -a; source <(unlock); set +a

`fitout.sh` calls unlock automatically when the key is present, and skips
gracefully when it isn't (so the keel never blocks on secrets).

## Compartments (added with GitHub access)

| File | Scope | Contents | Who loads it |
|---|---|---|---|
| `keys.env.age` | crew | Model keys only (`DEEPINFRA_API_KEY`) | Every agent context: `eval "$(unlock)"` — muster's crew windows do this |
| `captain.env.age` | captain | Push/publish credentials (`GH_TOKEN`) | Bridge + integration only: `eval "$(unlock captain)"` — sail's bridge window does this |

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
3. **Encrypt** (note the `bash -c` wrapper — zsh's `read -p` means something
   entirely different; this exact mistake silently encrypted an empty value
   once already, see HANDOFF §4f):

       bash -c 'read -rs -p "GH_TOKEN: " T; echo; printf "GH_TOKEN=%s\n" "$T" \
         | age -r "$(grep -o "age1.*" ship.key)" -o captain.env.age -'

4. **Verify a non-empty value, not just presence** (also a §4f lesson):

       age -d -i ship.key captain.env.age | wc -c    # must be > 10

5. Commit `captain.env.age`. On the ship: `eval "$(unlock captain)" && gh auth status`
   should report ERDAgent.
