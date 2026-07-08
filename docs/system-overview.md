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
review, and cost — as of Phase 5, First Mate/Bosun/Quartermaster are real (Purser
remains a dashboard with real numbers behind it, see the status table below).
Everything coordinates through plain files (`.ship/`), not a chat log or a database,
so any of this is inspectable and resumable by hand.

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
*elastic*: officers are real now, but nothing forces a Captain to route every small
mission through all four of them ceremonially if a lighter touch fits. Don't build the
third tier before the second one hurts.

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
3. **MUSTER** — runs `muster <charter> <task-id> <order-file>` per approved order.
4. **WATCH** — no manual polling needed: the bridge extension tracks the mustered
   wave via `log/events.log` and wakes the Captain automatically, with every
   finished task's report already in hand, the moment the whole wave reaches a
   terminal state (see "Wave-completion watcher" below). A crew SOS surfaces as
   its own roster status (`sos`, distinct from `done`) — it comes back to the
   Captain, not to you, unless it changes scope or cost.
5. **REVIEW** — runs `/review <task-id>` (the Quartermaster) for each `done`
   task (never an `sos` one — the Quartermaster refuses those itself); it merges
   into `integration`, runs the real dry-dock tests, and judges the diff against
   the order's acceptance criteria. Accepts, or rejects with feedback to a
   **fresh** crew agent via `muster --redo <task-id>` (never resumes a rejected
   one) — REJECT also retains the crew branch's sha for salvage/cherry-picking.
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
Captain's own judgment, just grounded in facts the extension gathered first. Phase 5
added two more commands the same way: `/critique` (First Mate, wraps
`ship/bin/first-mate`) and `/review <task-id>` (Quartermaster, wraps
`ship/bin/quartermaster`).

**Wave-completion watcher (real, working today)**: the same extension also closes the
WATCH step's actual gap — captain.md always said "monitor roster.json" without ever
saying how a `pi` session, which only does anything when it gets a turn, would do that
on its own. On `session_start` (bridge only, gated on `SHIP_ROLE=captain` so it stays
inert in crew/quartermaster/first-mate's own invocations of this same globally-loaded
extension), it starts a timer that tracks mustered tasks against `log/events.log`'s
durable `muster`/`crew-done`/`crew-failed` lines — not by polling `roster.json`'s live
status field, which a real drill showed can miss fast-finishing crew entirely between
polls. The moment every task in the current wave has a terminal event, it wakes the
Captain with `pi.sendMessage(..., {triggerTurn: true})`, handing it each task's real
report content and pointing it at REVIEW — live-verified end to end: mustered crew
finish, and the Captain autonomously reads the reports, runs `/review` on each, and
proceeds, with nothing typed into that pane.

Hard rules it operates under: never merge to `main` without dry-dock tests passing,
never exceed a mission budget without asking, never touch (or let an order touch) a
charter's no-touch paths, and — the one crew members don't have — **never write
production code itself**. If it starts editing app files directly instead of writing
an order, that's a real deviation from the contract, not a variant of "efficient."

### First Mate — planning QA
**A real agent as of Phase 5** (`ship/bin/first-mate`, wrapped by the bridge's
`/critique`, window 2 shows the latest `.ship/mission-critique.md` live). A second
pair of eyes on the Captain's decomposition, run **before you see the plan** —
`captain.md`'s PLAN step now runs `/critique` itself, right after writing
`mission.md` and orders, and presents both together for your approval.

What it actually checks, same deterministic-gathering-then-LLM-judgment split as
Quartermaster: the script itself mechanically computes scope conflicts (a file
claimed by more than one order's declared "Scope — files you may touch"), no-touch
path violations (against `charter.md`'s own list), and missing budget/acceptance-
criteria fields — these are ground truth, not up for LLM interpretation. A headless,
`--no-tools` review pass (`ship/prompts/first-mate.md`) then adds qualitative
judgment on top: is the decomposition the right granularity, are budgets
proportionate, are objectives and acceptance criteria clear enough that a crew agent
won't have to guess — while being explicitly told never to contradict the mechanical
findings. In practice this qualitative pass has already caught real cross-document
inconsistencies the deterministic checks don't attempt (e.g. a work order's title
disagreeing with `mission.md`'s own decomposition line for the same task).

**Advisory only, not a gate** — this is the one deliberate difference from
Quartermaster. Nothing First Mate says blocks `/muster`; Eric (or the Captain) decides
what to do about a `STATUS: CONCERNS` critique. `captain.md` is instructed to treat a
mechanically-confirmed finding (scope conflict, no-touch violation) as a real defect
in its own decomposition to fix before presenting, not just a note to relay — those
specific findings aren't a matter of opinion.

### Bosun — dispatch watchdog
**A real watchdog as of Phase 5, v1 scope** (`ship/bin/bosun`, window 3, still under
`watch -t -n 5` — same one-shot-script + `watch` pattern as the Purser's window). The
Captain still performs the actual dispatch function itself (step 3, MUSTER, above) by
directly invoking `muster` — Bosun doesn't spawn anything.

What it does: every refresh, for each crew member still `working`, sums that task's
real turn count and real output-token usage from the same ledger the Purser already
tallies (`log/ledger.tsv`, filtered to `role=="crew"` rows for that task — one real
DeepInfra call is one ledger row is one turn, so this needed no new accounting
mechanism) and compares it against the budget declared in that task's own order
(`## Budget`'s `max turns:`/`max output tokens:` fields). The first time either is
exceeded, it logs one `bosun-flag` event and marks the task `OVER BUDGET` in the
dashboard — deduplicated per task so a long-still-breaching crew member doesn't spam
the log every 5 seconds, and cleared automatically once that task leaves `working`
(so a fresh muster of the same task ID after a redo gets flagged fresh if it breaches
again too).

**v1 is explicitly detect-and-flag only, Eric's own call**: it never kills a tmux
window, never touches git, and never re-musters anything — a wrong guess parsing an
unusual order's budget field costs nothing here (a false negative just means no
flag), but the plan's eventual "kill and restart" is real, hard-to-reverse action
against a live process, and that's a bigger step to earn than Quartermaster's
git-only mechanics needed. The Captain (or Eric) decides what to do about a flagged
task, same as any other conversational judgment call. Promoting this to
auto-restart-with-feedback is future work, once flag-only has been seen to work
correctly against real crew runs for a while.

### Quartermaster — review & merge gate
**A real agent as of Phase 5** (`ship/bin/quartermaster`, wrapped by the bridge's
`/review <task-id>`). Window 4 is unchanged (still the read-only hold/branches view) —
the Quartermaster itself runs headless, on demand, once per `done` report, not as a
standing window process. Refuses outright (no LLM call, no merge attempt) on a
`working` or `sos` roster status — an `sos` task needs the Captain's own judgment,
never a merge-gate pass.

What it actually does, in order, for one task: merges the crew's branch into
`integration` (creating that branch/worktree on first use, same lazy-create
convention `ship/bin/telescope` already uses); runs the charter's real dry-dock test
command (`charter.md`'s `## Test commands` → `- dry dock: ...` field) against the
merged result; and — only once that mechanical gate passes — hands a headless,
**tool-less** review agent (`ship/prompts/quartermaster.md`, GLM-5.2 High by default,
same model routing as crew, overridable via `SHIP_QUARTERMASTER_AGENT` for the "maybe
a stronger model" question the plan left open) the order, the crew's report, the real
diff, and the real test result — pure text in, `VERDICT: APPROVE`/`VERDICT: REJECT`
text out, nothing else. The reviewer has no filesystem or shell access at all: every
fact it needs to judge is already gathered deterministically by the script, so there's
nothing for a stray tool call to break.

A merge conflict, a failing dry-dock test, or a malformed/missing verdict are all
automatic REJECTs — never left to the LLM's discretion, mirroring the Captain's own
"never merge without dry-dock tests passing" hard rule. `charter.md`'s own test-command
fields are stripped of a leading/trailing markdown backtick pair before being run —
the template's own placeholder example used to model that anti-pattern, and a value
copying it verbatim would otherwise have `bash -c` treat the backticks as command
substitution, REJECTing clean crew work on a documentation defect rather than a real
failure. Any REJECT rolls `integration` back to its pre-merge commit (via
`git reset --hard` to a SHA captured before the merge attempt), pins the crew branch's
current tip as a salvage point (`.ship/reviews/<task-id>.review.md` and
`roster.json`'s `salvageSha` — cherry-pickable if part of the attempt was actually
correct), and writes that review; the Captain re-musters the same task with
`muster --redo <task-id>`, which replaces the prior berth/branch and appends the
review's feedback to the order automatically. Reviews for one charter are serialized
through a `flock` on `.ship/.integration.lock`, since every review shares the one
`berths/integration` worktree (the same one the telescope dev server runs against).

Still not automatic: the Captain decides *when* to call `/review` and whether to
re-muster after a REJECT — this is a gate the Captain drives, not a background
watchdog. That's Bosun's eventual job (dispatch/monitoring), not this one.

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

**Purser also tracks time now**, from sources that already existed — no new
instrumentation anywhere. Four durations, always shown first in the dashboard: **ship
uptime** (`uptime -p`), **charter age** (the charter directory's own filesystem birth
time — deliberately not `charter.md`'s mtime, which gets bumped every time it's kept
current per the Captain's own standing instruction), **voyage time** (the bridge tmux
pane's process elapsed time — a voyage *is* one Captain session lifetime under a
charter, so this is the literal definition, not an approximation), and **crew work
time** (cumulative wall-clock across every crew task ever mustered in this charter,
pairing `roster.json`'s `started` field with `log/events.log`'s `crew-done`/
`crew-failed` timestamp per task, or "now" for anything still `working`).

### Crew — the ones who actually write code
Real, working today (`ship/prompts/crew.md`, wired by `muster`). Spawned fresh per
work order, one at a time, one order each, in its own git worktree (a "berth") on its
own branch (`crew/<task-id>-<slug>`), cut from `integration` (falling back to `main`
only before any wave has ever been reviewed) so a berth mustered mid-voyage starts
from whatever's already landed, not from `main`'s pre-mission state — and, if the
integration worktree already has `node_modules`, gets it hardlink-copied in too. Its
loop: read the order and the charter's standing rules fully, implement *only* what's
in scope, prove it with the order's own test commands, commit with clear messages,
write a structured report to an exact path the order specifies, exit. Hard limits:
never merge, push, switch branches, or leave its berth; never touch no-touch paths or
anything in `.ship/` besides its own report.

The prime directive is **SOS over improvisation**: if the order's acceptance criteria
can't be met, or it would need to touch out-of-scope paths, it stops, makes the
report's first line exactly `Status: SOS`, and explains why rather than guessing — "a
wrong guess merged costs more than an aborted task." That exact first line is what
lets `muster` mark it `sos` in the roster instead of a plain `done`. Crew never
resumes after rejection; a reviewer's feedback always spawns a brand-new crew agent
(`muster --redo <task-id>`) against the same order, so there's no drift between what
was reviewed and what a "fixed" version might silently become.

Each crew member also gets a human-readable name (`muster` picks one at random from an
invented, hobbit-flavored pool — deliberately not any actual Tolkien hobbit name — that
avoids colliding with any other currently-active crew member in the same charter). The
tmux window shows the name (e.g. "👷 Clover"); the roster (Bosun's window) shows name,
task, status, and branch together, so "Clover" and "T-014" are always one glance apart.
`roster.json`'s own `window` field stores this exact, already-glyph-decorated string
(not the bare name) specifically so Chartroom's "jump to crew window" targets the real
tmux window correctly regardless of the `SHIP_GLYPHS` setting.

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

### Telescope — the dev server window
Not an agent role, but the same "window in every deck" pattern: `sail`'s window 8
runs the charter's dev server (`npm run dev` or equivalent, from `charter.md`'s
"## Dev server" section) against the `integration` branch — crew's merged, reviewed
work, kept fresh by the Captain's INTEGRATE step. Eric views it from the host via
`erda telescope <charter>`, an SSH tunnel — no external service, and the dev server
itself never needs to bind anything but `localhost` on the ship.

### Chartroom — the deck's live mission view
Not an agent role either, but the last piece of Phase 5: a real Fresh editor plugin
(`scuttlebutt/plugins/chartroom.ts`, auto-loaded from `~/.config/fresh/plugins/` —
symlinked to `scuttlebutt/` by `fitout.sh`), running in the chartroom window (`sail`'s
window 1, `fresh mission.md`, cwd = the charter's `.ship/` dir). Three things, matching
the original design: commands to open the current mission's orders and reports (Ctrl+P
→ "Chartroom: Open Order"/"Chartroom: Open Report", prompting for a task id or prefix);
flagging SOS reports (both in the listing before you pick one, and via a warning when
you open one); and jumping to a crew member's tmux window from their report — "Chartroom:
Jump to Crew Window" resolves the task directly if the active buffer is that crew
member's report, or prompts otherwise, then runs `tmux select-window` for real via
`spawnProcess`. On top of the commands, it registers a live section with Fresh's
bundled `dashboard` plugin, so `roster.json`'s status and any SOS reports are visible
at a glance without running a command at all — the "watching `.ship/` live" half of
the vocabulary entry, not just request/response.

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
| 0 | 🧑‍✈ Bridge | Captain | **Yes** |
| 1 | 🗺 Chartroom | Chartroom (Fresh plugin) | **Yes** — `scuttlebutt/plugins/chartroom.ts`: commands to open the mission/orders/reports (flagging SOS reports), jump to a crew member's tmux window (contextual from their report), and a live dashboard panel showing roster status + SOS reports |
| 2 | 🧑‍🔬 First Mate | First Mate | **Yes** — `/critique`, advisory only, wired into the Captain's own PLAN step |
| 3 | 🧑‍🔧 Bosun | Bosun | **Yes**, v1 scope — `ship/bin/bosun` detects and flags turn/token budget breaches; doesn't kill/restart yet (deliberately deferred) |
| 4 | 📋 Quartermaster | Quartermaster | **Yes** — `/review <task-id>`, real merge gate (merges into `integration`, runs the dry-dock test, judges the diff) |
| 5 | 🧑‍💼 Purser | Purser | No — dashboard, but the numbers are real (cost-proxy logs actual DeepInfra cost) |
| 6 | ⚙️ Engine Room | (system monitor) | n/a — it's `htop` |
| 7 | 🧑‍🏭 Shipwright | Shipwright | **Yes** — system-level Claude Code, scoped to `~/shipyard`, not the charter |
| 8 | 🔭 Telescope | (dev server) | n/a — runs the charter's dev server against `integration` |
| 9+ | 👷 [crew name] | Crew | **Yes**, one window per active task, auto-created/closed by `muster` |

(Window 4's own contents are still just the git-branches dashboard — the Quartermaster *agent* runs headless via `/review`, not inside that window. Same pattern for window 2 and First Mate/`/critique`, and window 3's dashboard now also reflects Bosun's real budget checks each refresh.)

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
real model, `/review` and `/critique` included). **Quartermaster, First Mate, and
Bosun are now real too, as of Phase 5** — Quartermaster gates merges into
`integration` for real; First Mate critiques the plan before the Captain shows it to
Eric, advisory only; Bosun detects and flags real budget breaches (v1 scope,
deliberately not yet killing/restarting anything). **Purser is still a dashboard, not
an agent** — but the numbers on it are real (`cost-proxy` logs actual DeepInfra
cost), and per-mission/per-role cost tallying was never gated on Purser becoming an
agent to begin with. **Chartroom is the last piece of Phase 5, and it's real too** —
a genuine Fresh plugin, not a placeholder viewer. Nothing about any of this was ever
provisional or a demo; the officer layer arriving in Phase 5 changed *who* does
review/planning-QA/dispatch, not whether the mission loop worked before they did.
