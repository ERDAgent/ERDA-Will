# The Ship & Crew — System Overview

What this project actually is, who (or what) does what, and how the pieces talk to
each other. For *how to operate it* see `docs/vm-cheatsheet.md` (the VM) and
`docs/captain-cheatsheet.md` (talking to the Captain) — this doc is the map, not the
manual.

## The one-paragraph model

One **Ship** (a Linux VM) hosts many **Charters** (projects). Each charter has one
**Captain** — the only role you ever talk to — which turns your intent into a **mission**,
breaks it into **work orders**, and delegates each order to a disposable **crew** agent
working alone in its own git worktree and branch. A layer of **Officers** (First Mate,
Bosun, Quartermaster, Purser) sits between Captain and crew to handle QA, dispatch,
review, and cost — today they're mostly dashboards you read yourself; the design lets
them become real agents later without changing anything else. Everything coordinates
through plain files (`.ship/`), not a chat log or a database, so any of this is
inspectable and resumable by hand.

## Chain of command

```
You (the Admiralty)
   │  the only human touchpoint — one interactive conversation, on the bridge
   ▼
CAPTAIN                 — interprets intent, owns the mission, reports back
   │  decomposes the mission into work orders
   ▼
OFFICERS  (First Mate · Bosun · Quartermaster · Purser)
   │  QA, dispatch, review, cost — see status table below for what's real today
   ▼
CREW  (1..N, running in parallel)
   └─ each: own tmux window, own git worktree, own branch, exactly one work order
```

Two roles run outside this chain entirely: **Shipwrights** (Claude Code, Codex) —
system-level repair and support for the ship/scripts themselves, not daily project
work — and **you**, who never touches crew or officers directly. The hierarchy is
*elastic*: for a small mission the Captain just performs officer duties itself rather
than ceremonially routing through four dashboards. Don't build the third tier before
the second one hurts.

## The roles

### You — the Admiralty
The only human in the loop, and the only one who talks to the Captain directly.
You state intent, approve plans and budgets before any tokens burn, and are the final
authority on anything a mission's scope or cost changes. Multiple charters running at
once just means multiple Captains, each on its own deck (tmux session) — you're the
one thing that spans all of them (the "Fleet Board").

### Captain — the mission owner
Real, working today (`ship/prompts/captain.md`, wired into every bridge window by
`sail`). One per charter, really one per *voyage* (mission) — never shared across
projects, deliberately, for context purity and cost attribution. Its loop:

1. **BRIEF** — you state intent; it asks only what changes the plan.
2. **PLAN** — writes `.ship/mission.md` and one work order per task, decomposed so no
   two concurrent orders touch the same files. Shows you the plan and cost. **Stops
   and waits for your approval** — no exceptions.
3. **MUSTER** — runs `muster <charter> <task-id> <order-file>` per approved order
   (performing the Bosun's dispatch function itself, today).
4. **WATCH** — polls `.ship/roster.json` and `.ship/reports/`. A crew SOS comes back
   to the Captain, not to you, unless it changes scope or cost.
5. **REVIEW** — inspects each finished branch's diff against its order's acceptance
   criteria itself (performing the Quartermaster's review function, today). Accepts,
   or rejects with feedback to a **fresh** crew agent (never resumes a rejected one).
6. **INTEGRATE** — merges accepted branches into `integration` (dry dock), runs the
   full test suite, fast-forwards `main` (home port), removes berths, logs everything.
7. **DEBRIEF** — summarizes to you: shipped, blocked, cost.

**Phase 4 plugin (`ship/plugin/`, real, working today)**: a pi extension, symlinked
globally by `fitout.sh` into every ship (`~/.pi/agent/extensions/shipyard`), so it's
active in every charter's bridge window automatically. Adds four slash commands
mapping onto the loop above: `/mission <goal>` (PLAN — hands the goal to the Captain's
own planning conversation via `sendUserMessage`, after ensuring `.ship/orders/`
exists; the extension doesn't do any planning itself), `/muster <task-id>
[order-file]` (MUSTER — a pure, deterministic wrapper around `ship/bin/muster`, no LLM
turn at all; auto-resolves the order file from `.ship/orders/` if omitted), `/harbor
[task-id]` (WATCH — reads `.ship/roster.json` + reports directly and shows them,
interactively picking a task if none is given; also pure, no LLM turn), and `/debrief`
(DEBRIEF — reads the real roster, recent commits, and `log/ledger.tsv` deterministically,
then hands those facts to the Captain to narrate; the summary's numbers are always
real, never re-derived or guessed by the model). The split is deliberate: anything
that's just files and one subprocess call (`/muster`, `/harbor`) never touches the LLM;
anything that's inherently a language task (planning, narrating) still goes through the
Captain's own judgment, just grounded in facts the extension gathered first.

Hard rules it operates under: never merge to `main` without dry-dock tests passing,
never exceed a mission budget without asking, never touch (or let an order touch) a
charter's no-touch paths, and — the one crew members don't have — **never write
production code itself**. If it starts editing app files directly instead of writing
an order, that's a real deviation from the contract, not a variant of "efficient."

### First Mate — planning QA
**Not yet an active agent** (Phase 5). Today it's window 2 on the deck, a note
reminding you to review `mission.md` yourself before approving a muster. Designed
eventually to critique the Captain's decomposition before you see it — a second pair
of eyes on scope/budget/file-ownership conflicts, not a second Captain.

### Bosun — dispatch
**Not yet an active agent.** Today it's window 3, a live `roster.json` + last-8-events
view refreshing every 5 seconds — a dashboard, not a decision-maker. The Captain
performs the actual dispatch function itself (step 3, MUSTER, above) by directly
invoking `muster`. Designed eventually to own spawning/monitoring/restarting stuck
crew agents as its own process, so the Captain doesn't have to babysit turn limits.

### Quartermaster — review & merge gate
**Not yet an active agent.** Today it's window 4, a live view of hold branches and
recent commits — read-only. The Captain performs the actual review/merge-gating
function itself (step 5–6, REVIEW/INTEGRATE, above). Designed eventually to be the
one place diffs get reviewed and dry-dock tests run before anything reaches `main` —
possibly on a different (stronger) model than the crew's, per an open HANDOFF
question, not yet decided.

### Purser — cost
**Not yet an active agent, but cost tracking is real now, not an estimate.** pi's own
notion of "cost" is computed from a local price table (`ship/pi/models.json`'s `cost`
fields) — a guess against numbers we maintain, not what DeepInfra actually billed.
Instead, `ship/bin/cost-proxy` sits in front of DeepInfra (every window's pi points its
`deepinfra` provider `baseUrl` at it) and logs the real `usage.estimated_cost` DeepInfra
returns on every call — forcing `stream_options.include_usage` on streamed requests,
since OpenAI-compatible streaming omits usage otherwise — to `log/ledger.tsv`, tagged by
role/charter/crew-name/task via `X-Ship-*` headers (interpolated per-window from each
window's own `SHIP_ROLE`/`SHIP_CHARTER`/`SHIP_NAME`/`SHIP_TASK` exports). `ship/bin/unlock`
starts the proxy on demand (127.0.0.1:8790, ship-wide, one instance serves every
charter's deck) if it isn't already running. Window 5 (`purser-totals`) shows a running
total — overall and by role — plus the last 10 calls. The per-order turn/token budget in
each work order (`ship/prompts/order-template.md`) remains the only thing that actually
*caps* spend; the ledger only reports it. Still not an active agent: tallying per-mission
totals and flagging budget breaches is Phase 5+.

### Crew — the ones who actually write code
Real, working today (`ship/prompts/crew.md`, wired by `muster`). Spawned fresh per
work order, one at a time, one order each, in its own git worktree (a "berth") on its
own branch (`crew/<task-id>-<slug>`). Its loop: read the order and the charter's
standing rules fully, implement *only* what's in scope, prove it with the order's own
test commands, commit with clear messages, write a structured report to an exact path
the order specifies, exit. Hard limits: never merge, push, switch branches, or leave
its berth; never touch no-touch paths or anything in `.ship/` besides its own report.

The prime directive is **SOS over improvisation**: if the order's acceptance criteria
can't be met, or it would need to touch out-of-scope paths, it stops and reports SOS
rather than guessing — "a wrong guess merged costs more than an aborted task." Crew
never resumes after rejection; a reviewer's feedback always spawns a brand-new crew
agent against the same order, so there's no drift between what was reviewed and what a
"fixed" version might silently become.

Each crew member also gets a human-readable name (`muster` picks one at random from an
invented, hobbit-flavored pool — deliberately not any actual Tolkien hobbit name — that
avoids colliding with any other currently-active crew member in the same charter). The
tmux window shows the name (e.g. "⚒Clover"); the roster (Bosun's window) shows name,
task, status, and branch together, so "Clover" and "T-014" are always one glance apart.

The window itself now shows real activity, not just a blank pane until the task ends:
crew run with `pi --mode json` (not `-p`) piped through `ship/bin/pi-monitor`, which
prints each turn's thinking (truncated to the last ~3000 chars — recent reasoning, not
the full transcript), tool calls, and tool results live as they happen. This is a
display change only — reasoning is already generated (and paid for) by `--thinking
high` regardless of whether anything prints it, so there's no added cost or model-side
work, just a formatter reading pi's own event stream.

### Shipwrights — Claude Code, Codex
System-level repair and support for the ship/scripts themselves (this repo,
`fitout.sh`, `ship/bin/*`) — not daily project work, and not part of the charter/crew
system at all. Used for exactly the kind of work that produced this document. Claude
Code gets its own tmux window (`sail`'s window 7, "shipwright") in every charter's
deck for reachability — one tmux-switch away no matter which charter you're
working — but its cwd is always `~/shipyard`, never the charter, and it loads its own
strongbox compartment (`ANTHROPIC_API_KEY`, see `strongbox/README.md`), not the
charter's model keys.

### Preview — the dev server window
Not an agent role, but the same "window in every deck" pattern: `sail`'s window 8
runs the charter's dev server (`npm run dev` or equivalent, from `charter.md`'s
"## Dev server" section) against the `integration` branch — crew's merged, reviewed
work, kept fresh by the Captain's INTEGRATE step. Eric views it from the host via
`erda preview <charter>`, an SSH tunnel — no external service, and the dev server
itself never needs to bind anything but `localhost` on the ship.

## How they interact: the mission lifecycle

The seven Captain steps above (BRIEF → PLAN → MUSTER → WATCH → REVIEW → INTEGRATE →
DEBRIEF) *are* the interaction model — there's no separate "system" choreography
beyond what the Captain's own loop already describes. What makes it actually work with
multiple independent agents running concurrently is that none of them talk to each
other directly — they read and write a shared set of files, described next.

## The shared substrate: `.ship/`

No chat log, no shared memory — every interaction between Captain and crew happens
through plain files, per charter:

```
.ship/
├── mission.md              # current mission statement (Captain writes, keeps current)
├── orders/T-014-*.md       # one work order per task — the contract going out
├── reports/T-014.report.md # crew writes on completion or SOS — the contract coming back
├── roster.json             # live crew: task id, branch, window, status (flock-guarded)
└── log/
    ├── events.log           # append-only: muster/crew-done/crew-failed, tab-separated
    └── ledger.tsv           # real per-call DeepInfra cost, written by cost-proxy
```

This is deliberate, not incidental: because everything's a file, any of this is
inspectable by hand (`cat .ship/mission.md`), the Bosun/Quartermaster/Purser
dashboards can exist today as plain `watch`/`tail` commands with zero agent behind
them, and a crew agent crashing mid-task leaves a diagnosable trail instead of a lost
conversation.

## The physical model: one deck, one window per role

Because you're a visual person, the org chart above *is* the tmux layout — one window
per role, permanently numbered, whether that role is currently an LLM, a script, or
just a live view of its own artifacts:

| # | Window | Role | Real agent today? |
|---|--------|------|---|
| 0 | ⚓ bridge | Captain | **Yes** |
| 1 | 🗺 chartroom | (mission/orders/reports, live in Fresh) | n/a — it's a viewer |
| 2 | 🧭 first-mate | First Mate | No — dashboard/reminder only |
| 3 | 📣 bosun | Bosun | No — dashboard only; Captain dispatches itself |
| 4 | ⚖ quartermaster | Quartermaster | No — dashboard only; Captain reviews/merges itself |
| 5 | 🪙 purser | Purser | No — dashboard, but the numbers are real (cost-proxy logs actual DeepInfra cost) |
| 6 | ⚙ engine-room | (system monitor) | n/a — it's `htop` |
| 7+ | ⚒ crew-T### | Crew | **Yes**, one window per active task, auto-created/closed by `muster` |

One session (`ship-<charter>`) per active charter — parallel projects are parallel
decks, each fully staffed the same way, switchable instantly via tmux's session
picker. Your visual habits don't change as officers go from dashboard to real agent
underneath them.

## The concurrency mechanism: Hold & Berths

Crew agents run in parallel without colliding because of how git is structured per
charter, not because of any coordination logic:

- **The Hold** (`.hold.git`) — one bare repo per charter, the actual source of truth.
- **Berths** (`berths/<task-id>`) — one git worktree per crew task, checked out on its
  own `crew/<task-id>-<slug>` branch. A crew agent physically cannot affect another
  crew agent's files; they don't share a working directory.
- **`home-port`** — a standing berth checked out on `main`, for browsing/manual work
  (and, since a recent fix, where the Captain itself now actually starts).
- **Dry dock** (`integration` branch) and **home port** (`main`) — accepted crew
  branches merge to `integration` first, get the full test suite, then fast-forward
  to `main`. Crew never merges anything themselves.

Combined with the Captain's own rule that no two concurrent orders touch the same
files, this is what makes "spawn N crew agents at once" safe rather than a merge-
conflict generator by construction, not by review discipline.

## Scaling: Charters & the Fleet

One ship carries many charters — provisioning a new VM per project would mean
patching N machines for zero benefit, since the environment itself (agents, editor,
tmux, keys) is project-agnostic. Each charter under `~/fleet/<name>/` is fully
self-contained (its own hold, berths, and `.ship/` bus), so charters never share
state, and a Captain that can only see one hold can only merge into one hold. There's
deliberately no "Captain of captains" — you are the coordination layer across
projects, by design, revisited only if cross-project context-copying becomes a
recurring pain in practice.

## What's real vs. what's designed

Worth stating plainly, since the design doc (`docs/agentic-engineering-plan.md`) and
the current implementation aren't the same document: **Captain and Crew are real,
working, verified end-to-end** (a genuine mission has run start-to-finish against a
real model). **First Mate, Bosun, Quartermaster, and Purser are dashboards today, not
agents** — the Captain absorbs all four of those functions itself for now, which the
design explicitly allows ("elastic hierarchy... don't build three tiers before two
tiers hurts"). Nothing about talking to the Captain today is provisional or a demo —
the officer layer activating later (Phase 5) changes *who* does review/dispatch/cost,
not whether the mission loop works.
