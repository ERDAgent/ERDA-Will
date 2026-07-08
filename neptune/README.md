# Neptune — the drydock-verification channel

Async, git-mediated communication between the **Shipwright** (runs on a real
ship, `~/shipyard`, owns all shipyard engineering — see
`ship/prompts/shipwright.md`) and **Neptune** (runs on the Admiral's own machine,
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
2. The Admiral tells Neptune to check for pending requests (no automatic trigger —
   Shipwright and Neptune are on different machines with no live channel
   between them other than this repo).
3. Neptune identifies pending requests: a request file with no matching
   `neptune/reports/<ID>.report.md` yet. Pulls the **current pushed
   `origin/main`** (never a local/dirty tree — Neptune doesn't build
   anything, so there's nothing local to test), christens a fresh Multipass
   ship, runs the drill, sinks the ship, writes
   `neptune/reports/<ID>.report.md` (template below), commits, pushes.
4. Shipwright reads the report on its next `git pull`.

## Neptune's permission lockdown lives on the Admiral's machine only

`.claude/settings.json` is tracked, so `keel.yaml`'s clone ships whatever's in
it onto every ship — a checked-in deny-list meant for Neptune alone ends up
blocking the Shipwright on its own ship too (found live, July 7 2026: it
denied the Shipwright's `Edit`/`Write` tools *and* Bash file redirects
outright, no prompt, on paths well outside `neptune/`). Fix: the tracked
`.claude/settings.json` only keeps guardrails that are safe to apply
everywhere (force-push, rsync); Neptune's actual narrow scope
(`Edit`/`Write` limited to `neptune/reports/**`) lives in an **untracked**
`~/shipyard/.claude/settings.local.json` on the Admiral's host machine, which
`.gitignore` now excludes so it can never round-trip onto a ship. Claude Code
merges `settings.local.json` over `settings.json`, so this is where any
future Neptune-only restriction belongs — never in the tracked file.

Put this in `~/shipyard/.claude/settings.local.json` on the host (not on any
ship):

```json
{
  "permissions": {
    "allow": [
      "Read",
      "Edit(neptune/reports/**)",
      "Write(neptune/reports/**)",
      "Bash(git pull*)",
      "Bash(git fetch*)",
      "Bash(git status*)",
      "Bash(git log*)",
      "Bash(git diff*)",
      "Bash(git add neptune/reports/*)",
      "Bash(git commit*)",
      "Bash(git push*)",
      "Bash(multipass *)",
      "Bash(ssh *)",
      "Bash(scp *)",
      "Bash(curl *)"
    ],
    "deny": [
      "Edit(.claude/**)",
      "Edit(CLAUDE.md)",
      "Edit(HANDOFF.md)",
      "Edit(.gitignore)",
      "Edit(keel.yaml)",
      "Edit(fitout.sh)",
      "Edit(docs/**)",
      "Edit(dotfiles/**)",
      "Edit(harbor/**)",
      "Edit(scuttlebutt/**)",
      "Edit(ship/**)",
      "Edit(strongbox/**)",
      "Edit(neptune/README.md)",
      "Edit(neptune/requests/**)",
      "Write(.claude/**)",
      "Write(CLAUDE.md)",
      "Write(HANDOFF.md)",
      "Write(.gitignore)",
      "Write(keel.yaml)",
      "Write(fitout.sh)",
      "Write(docs/**)",
      "Write(dotfiles/**)",
      "Write(harbor/**)",
      "Write(scuttlebutt/**)",
      "Write(ship/**)",
      "Write(strongbox/**)",
      "Write(neptune/README.md)",
      "Write(neptune/requests/**)",
      "Bash(rsync*)",
      "Bash(git push --force*)",
      "Bash(git push -f*)",
      "Bash(git push*--force*)"
    ]
  }
}
```

Not yet verified live (same caveat as before, just relocated): confirm a
fresh Neptune session on the host actually gets blocked outside
`neptune/reports/**` with this file in place.

## ID convention

`N-001`, `N-002`, ... — sequential, matching crew's `T-NNN` task-id style but
in Neptune's own namespace so the two never collide.

## Templates

See `neptune/requests/TEMPLATE.md` and `neptune/reports/TEMPLATE.md`.
