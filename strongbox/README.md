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
