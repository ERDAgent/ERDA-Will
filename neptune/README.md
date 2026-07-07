# Neptune — the drydock-verification channel

Async, git-mediated communication between the **Shipwright** (runs on a real
ship, `~/shipyard`, owns all shipyard engineering — see
`ship/prompts/shipwright.md`) and **Neptune** (runs on Eric's own machine,
narrowly scoped to provisioning-fresh-ship-from-scratch verification — see
`CLAUDE.md`'s Neptune section).

Why this exists: the Shipwright can self-test almost everything on its own
already-provisioned ship, but it cannot provision a genuinely *fresh* one
(no nested Multipass inside a VM) — and first-boot/`fitout.sh`-ordering bugs
have repeatedly only surfaced on a truly clean ship, never on one that was
already set up (see `HANDOFF.md` §4y/§4z for concrete examples: a `sudo bash`
vs `su - eric` PATH bug that passed every self-test but broke `node`
resolution on a fresh boot). Neptune exists to close exactly that gap,
without giving host-side Claude Code write access to the shipyard codebase
itself.

## Flow

1. Shipwright writes `neptune/requests/<ID>-<slug>.md` (template below),
   commits, pushes.
2. Eric tells Neptune to check for pending requests (no automatic trigger —
   Shipwright and Neptune are on different machines with no live channel
   between them other than this repo).
3. Neptune identifies pending requests: a request file with no matching
   `neptune/reports/<ID>.report.md` yet. Pulls the **current pushed
   `origin/main`** (never a local/dirty tree — Neptune doesn't build
   anything, so there's nothing local to test), christens a fresh Multipass
   ship, runs the drill, sinks the ship, writes
   `neptune/reports/<ID>.report.md` (template below), commits, pushes.
4. Shipwright reads the report on its next `git pull`.

## ID convention

`N-001`, `N-002`, ... — sequential, matching crew's `T-NNN` task-id style but
in Neptune's own namespace so the two never collide.

## Templates

See `neptune/requests/TEMPLATE.md` and `neptune/reports/TEMPLATE.md`.
