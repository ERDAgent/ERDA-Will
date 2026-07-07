# Drill request: N-XXX — <short title>

## What changed
Commit range or short description of the shipyard change(s) to verify (e.g.
"fitout.sh's new symlink block, commits abc123..def456").

## What to verify
Concrete, checkable pass/fail items — not "make sure it works". E.g.:
- [ ] `cloud-init status --wait` exits 0 on a fresh ARM64 ship
- [ ] `fitout.sh` re-run is a true no-op (idempotent)
- [ ] `/usr/local/bin/<new-binary>` resolves over a plain non-login `ssh host 'cmd'`
- [ ] `charter` → `sail` → `muster` (real or stub agent) completes end-to-end

## Why this needs a fresh ship, not just self-testing
What's provisioning-sensitive here (first-boot ordering, a new symlink,
PATH resolution, etc.) — if it's not provisioning-sensitive, this probably
doesn't need a Neptune drill at all; self-test on your own ship instead.

## Priority
Optional — anything Eric should know about urgency/blocking.
