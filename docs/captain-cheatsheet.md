# Talking to the Captain — cheatsheet

You (Eric, the Admiralty) only ever talk to the Captain — never to crew directly. The
Captain plans, delegates, gates, and reports; it never writes production code itself.
This is a conversational guide to that relationship: what to say, when, and what to
expect back. For getting the ship itself running, see `docs/vm-cheatsheet.md`.

Grounded in `ship/prompts/captain.md` (the Captain's actual role contract) and a real
verified session (2026-07-02) — not just the design doc.

## Getting to the Captain

```bash
captain charter <name> [git-url] [--local]   # once, for a brand-new project
captain work <name>                          # opens the deck; window 0 ("bridge") is the Captain
```

`captain charter` with no `git-url`: creates (or reuses, if it already exists) a
private GitHub repo under the ERDAgent account and clones that — needs `gh`
authenticated with repo-*creation* permission, broader than the default push-only PAT
scope (see `strongbox/README.md`); falls back to a local-only charter with a clear
message if that's not set up. Pass `--local` to skip GitHub entirely on purpose. Give
an explicit `git-url` to charter an existing repo instead, same as before.

`captain work <name>` on a project you've already chartered just reattaches to the
same deck — same Captain conversation, same mission, same everything, picking up
where you left off (tmux sessions persist across SSH disconnects; they only die if
the ship itself restarts or you explicitly `tmux kill-session`).

(`captain charter`/`captain work` are friendly aliases for the underlying `charter`/
`sail` commands — those still work directly too, same behavior, if you ever need
them.)

The bridge auto-launches `pi` as the Captain — no login needed, no manual model flags.
If it ever comes up as a plain, un-briefed coding assistant instead (introduces itself
generically, doesn't mention charters/orders/muster), something's wrong with the
launch, not the conversation — check `docs/vm-cheatsheet.md` §3 (strongbox) first.

## Starting a brand-new project

1. `captain charter <name> [git-url] [--local]` creates a `charter.md` template
   (stack/conventions, test commands, no-touch paths, notes — all blank placeholders)
   and an empty `.ship/mission.md`.
2. `captain work <name>` — the Captain reads `charter.md` on its own before anything
   else.
3. Tell it what you want, e.g.:
   > "This is a Next.js app, tests run with `npm test`, never touch `deploy/` or
   > `.env*`. I want a dark-mode toggle added to the settings page."

   You can also just describe the project and ask it to draft `charter.md` for you —
   it'll ask back for whatever's missing (stack, test command, no-touch paths) rather
   than guess.

## Working on an existing project

`captain work <name>` and just talk — no ceremony. Good openers:
> "Pick up where we left off — what's the state of things?"
> "New ask: <describe it>."

The Captain re-reads `charter.md` and `.ship/mission.md` itself; you don't need to
re-explain standing context it already wrote down.

## The BRIEF → PLAN → approval gate

This is the one step that's a hard stop, by design (`captain.md`: "WAIT for approval
before any muster"). After you state intent, the Captain:
- writes `.ship/mission.md` (the overall plan) and one work order per task under
  `.ship/orders/` (scope, acceptance criteria, budget — see
  `ship/prompts/order-template.md` for the exact shape)
- decomposes so no two concurrent orders touch the same files (parallel-safe by
  construction)
- presents the plan with an estimated cost and **stops**

It will not muster anything until you explicitly say so. Useful phrasings:
> "Show me the plan first." / "What's this going to cost?"
> "Approved — go ahead." / "Muster T-001 only, hold the rest."
> "Change T-002's scope to exclude the API layer, then muster."

If you never approve, nothing runs — that's the intended failure mode, not a bug.

**Shortcut**: `/mission <goal>` does the same BRIEF→PLAN kickoff as typing it out in
plain English — it just saves you re-explaining the mission.md/order-template.md
convention every time. Same approval gate applies either way; `/mission` still stops
and waits.

## While crew is working

The Captain runs `muster <charter> <task-id> <order-file>` itself (you don't need to
type this by hand once you've approved) and then **watches** — polling
`.ship/roster.json` and `.ship/reports/`. A crew SOS (stuck, scope conflict, can't
meet acceptance criteria) comes back to the Captain, not to you, *unless* it changes
the mission's scope or cost — then it surfaces to you.

You can just ask:
> "Status?" / "How's T-002 doing?" / "Anything stuck?"

and the Captain checks the real files and answers — it's not guessing from memory of
what it mustered. Or type `/harbor` yourself — a pure file read (roster.json +
reports), no LLM turn, same data the Captain would check, just without spending a
turn to ask for it. `/muster <task-id>` is the same idea for the MUSTER step itself:
the Captain already runs `muster` on your approval, but you can also invoke it
directly if you want to re-run one order without a full conversational round trip.

## Reviewing finished work

For each `done` report, the Captain inspects the actual diff on that crew branch
against the order's acceptance criteria — accept, or reject with written feedback (a
**fresh** crew agent respawns with that feedback; rejected work is never silently
patched by resuming the old one). You can steer this:
> "Let me see the diff before you decide." / "Reject T-003 — it touched a file outside
> scope, redo with feedback: <specifics>."

Or just let it run and ask for the outcome:
> "What landed and what got rejected?"

## Checking status without asking the Captain

The other 6 deck windows are live dashboards — switch to them directly
(`ctrl-b <number>` in tmux, or `tmux select-window -t ship-<name>:<n>`) instead of
interrupting the Captain's context if you just want a quick look:

| # | Window | Shows | Check it directly when... |
|---|--------|-------|---------------------------|
| 1 | 🗺 chartroom | `mission.md`/orders/reports, live in Fresh (or a `watch` fallback) | you want to read the actual plan/order text, not a summary |
| 2 | 🧭 first-mate | placeholder dashboard — **not yet an active agent** (Phase 5); currently just a note to manually review `mission.md` yourself before approving | you want a second pair of eyes and it isn't you |
| 3 | 📣 bosun | `roster.json` + last 8 events, auto-refreshing every 5s | "is anything still running, right now" |
| 4 | ⚖ quartermaster | git branches + last 10 commits across the whole hold | "what's actually landed on `main`/`integration`" |
| 5 | 🪙 purser | running total + last 10 calls from `log/ledger.tsv`, real DeepInfra cost (`usage.estimated_cost`) logged by `cost-proxy` — not pi's own local-price-table guess | you want to know what a mission is actually costing, right now |
| 6 | ⚙ engine-room | `htop`/`top` on the ship itself | the ship feels slow and you want to know if it's actually loaded |

## Ending a mission / DEBRIEF

> "Debrief." / "Wrap up and report." (or type `/debrief` directly)

The Captain summarizes: shipped, blocked, and the real cost so far — `/debrief`
(and the plain-English version) both read `log/ledger.tsv` and the roster directly
before narrating, so the number is always the real DeepInfra total, never a guess.
Merging to `main` happens as part of its own INTEGRATE step (dry-dock tests on
`integration` → fast-forward `main` → remove berths) — `captain.md` doesn't gate that
specific step on your approval the way it gates muster, only mission-level
scope/budget changes require asking. If you want an explicit checkpoint before
anything touches `main`, say so up front:
> "Don't fast-forward main without telling me first."

## Hard boundaries (so you know what's a bug, not a feature)

Per `captain.md`, the Captain should never:
- merge to `main` without dry-dock tests passing
- exceed a mission budget without asking
- touch (or let an order touch) a "No-touch" path from `charter.md`
- write production code itself — if it starts directly editing app files instead of
  writing an order and mustering crew, that's a real deviation, call it out

## Quick reference: things to literally say

- *"Here's what I want: `<describe it>`."* — starts a BRIEF
- *"What's the plan?"* / *"Show me the mission."* — re-surface current `mission.md`
- *"Approved, muster it."* / *"Go ahead with T-003, hold the others."* — the approval gate
- *"Status?"* / *"How's T-002 doing?"* — WATCH
- *"Reject T-003, redo with: `<feedback>`."* — REVIEW
- *"Debrief."* / *"Wrap up and report."* — DEBRIEF
- *"Cap this mission at `<budget>`."* / *"Use xhigh thinking for T-004, it's tricky."* — per-mission/per-order overrides

Or skip the conversation for the mechanical steps: `/mission <goal>`, `/muster
<task-id>`, `/harbor [task-id]`, `/debrief` — see `ship/plugin/index.ts`. `/muster`
and `/harbor` never spend a model turn; `/mission` and `/debrief` still go through the
Captain's own judgment, just grounded in real files/ledger data gathered first.
