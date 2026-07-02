# Work order: <TASK-ID> — <short title>

## Objective
One paragraph: what exists when this is done.

## Scope — files you may touch
- path/one
- path/two
(Everything else is out of scope. No-touch paths in .charter.md apply absolutely.)

## Acceptance criteria
- [ ] criterion (verifiable)
- [ ] tests: `<command>` exits 0

## Budget
- max turns: 25 · max output tokens: 60000 · thinking: High

## SOS conditions
Raise SOS (report status: SOS, then exit) if: criteria conflict, scope is
insufficient, or required paths are out of scope.
