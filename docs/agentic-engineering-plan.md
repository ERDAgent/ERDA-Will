# Agentic Engineering Environment — Master Plan

**Project codename: Shipyard**
*A portable Linux dev VM + a ship-and-crew multi-agent orchestration system built on OpenCode/pi, GLM-5.2, and git worktrees.*

---

## 1. Goals & Design Principles

**What we're building:**

1. A Linux VM environment that spins up identically on macOS, Windows, or a VPS — headless, disposable, reproducible.
2. A full agent toolbelt: the [Fresh editor](https://getfresh.dev/) ("the Scuttlebutt," below), tmux, Claude Code, Codex CLI, OpenCode, and pi.
3. Claude Code + Codex reserved for **system-level work and support** (env repair, debugging the orchestrator itself, second opinions).
4. Primary dev workflow: **pi orchestrating GLM-5.2 instances via DeepInfra** — with OpenCode maintained as a rigged-and-ready replacement host. Anti-lock-in by design: the `.ship/` file protocol is host-agnostic, so swapping the orchestration host never strands the fleet.
5. A custom orchestration layer modeled on a **ship and crew**: you talk to the Captain; the Captain commands officers and crew; crew agents work in parallel via **git worktrees**.

**Principles:**

- **Environment as code, not as image.** A single disk image can't span Apple Silicon (ARM64) and x86_64 anyway. The unit of portability is a *bootstrap repo* (cloud-init + provision script), not a VHDX/qcow2 file. Any Ubuntu box, any arch, any host becomes The Ship in ~5 minutes.
- **Files are the message bus.** Agents coordinate through the repo and a `.ship/` directory (orders, reports, logs), not through fragile in-memory RPC. Everything is inspectable, replayable, and git-trackable.
- **tmux is the deck.** Every agent runs in a named tmux pane/window. You can always attach and watch any crew member work. (This is also pi's official answer to sub-agents: spawn instances via tmux.)
- **Worktree = workstation.** One crew agent, one worktree, one branch. No two agents ever share a working directory.
- **Cheap tokens, hard budgets.** GLM-5.2 is inexpensive per token but *extremely* verbose (reasoning-heavy). Guardrails from day one.

---

## 1.5 The Ship's Manifest — Naming Convention

Every component gets a name from the world it lives in. The metaphor isn't decoration; it's the system's vocabulary — commands, directories, and prompts all use these terms, which makes the orchestration self-documenting.

| Name | What it actually is |
|---|---|
| **The Ship** | The Ubuntu VM itself |
| **Shipyard** | The bootstrap repo that builds ships |
| **The Keel** (`keel.yaml`) | cloud-init file — the first thing laid down |
| **Fitout** (`fitout.sh`) | Idempotent provisioning script — turns a bare hull into a working vessel |
| **The Scuttlebutt** | The Fresh editor — the freshwater cask on deck where all hands gather to see what's going on |
| **The Deck** | A tmux session — where all hands work in plain view; one deck per active charter |
| **The Bridge** | Your interactive Captain window (tmux window 0) |
| **The Chartroom** | Scuttlebutt window watching `.ship/` live (window 1) |
| **A Charter** | A project/repo registered with the fleet — a standing contract of work |
| **A Voyage** | One mission run under a charter — a Captain session's lifetime |
| **The Fleet Board** | `tmux choose-session` — every active charter's deck at a glance |
| **The Engine Room** | htop / logs / cost tally window |
| **Shipwrights** | Claude Code & Codex — they repair the ship, they don't sail her |
| **The Trade Winds** | DeepInfra serving GLM-5.2 — what actually propels the voyage |
| **The Strongbox** | age-encrypted secrets |
| **A Harbor** | Any host machine (Mac, Windows box, OVHcloud) |
| **The Hold** | The bare git repo all worktrees hang off |
| **Berths** | Git worktrees — one crew member, one berth |
| **Muster** | The spawn script: berth + branch + tmux window + agent |
| **The Roster** | `roster.json` — who's aboard, where, doing what |
| **The Ship's Log** | Append-only event log |
| **Work Orders / Reports / SOS** | The task contract files in `.ship/` |
| **Dry Dock** | The `integration` branch — where merged work is tested before sailing |
| **Home Port** | `main` |

## 2. Layer 0 — The Portable VM

### Recommended: Multipass + cloud-init

[Multipass](https://canonical.com/multipass) runs headless Ubuntu VMs on macOS (QEMU, ARM-native on Apple Silicon), Windows (Hyper-V backend — fits your existing Hyper-V setup), and Linux. Crucially, it takes **cloud-init** — the same YAML that provisions an OVHcloud instance. One keel, three harbors.

```bash
# Mac or Windows — identical command
multipass launch 24.04 --name ship --cpus 4 --memory 8G --disk 40G \
  --cloud-init keel.yaml
multipass shell ship
```

```bash
# VPS — OVHcloud Public Cloud (OpenStack under the hood, full cloud-init support)
openstack server create --image "Ubuntu 24.04" --flavor b3-8 \
  --key-name eric --user-data keel.yaml ship
# or paste keel.yaml into the "cloud-init" box in the OVH Manager UI at instance creation
```

OVHcloud notes: their **Public Cloud instances** take cloud-init natively (they're OpenStack), which is the clean path. Their cheaper legacy **VPS line** has spottier cloud-init support depending on image — if you go that route, the fallback is trivial: SSH in and run `git clone … && ./fitout.sh` by hand, since the keel is deliberately thin anyway.

`keel.yaml` does the minimum: create user, install git, clone your **shipyard repo**, run `./fitout.sh`. All real setup lives in the repo so it's versioned and testable.

### Alternatives considered

| Option | Verdict |
|---|---|
| **Hyper-V image export/import** (your current workflow) | Works Windows-only; doesn't travel to Mac or VPS. Keep for Windows-local snapshots. |
| **Lima** (Mac) + Hyper-V (Win) separately | Fine, but two configs to maintain. Multipass unifies. |
| **Docker/devcontainer** | Great for the *tooling* layer, but you want a full VM (systemd, tmux servers surviving, SSH target, VPS parity). Could be a later addition for crew sandboxing. |
| **Nix/home-manager** | Most rigorous reproducibility; steeper learning curve. Reasonable Phase-2 refactor if drift becomes a problem. |

### The shipyard repo (environment-as-code)

```
shipyard/
├── keel.yaml               # cloud-init: user, ssh keys, clone + run fitout
├── fitout.sh               # idempotent: apt packages, node, agent CLIs
├── scuttlebutt/            # Fresh config.json, themes, TS plugins (Section 3)
├── dotfiles/               # tmux.conf (deck layout), shell rc, git config
├── strongbox/              # age-encrypted API keys (DeepInfra, Anthropic, OpenAI)
├── ship/                   # the orchestration system (Section 6)
│   ├── plugin/             # opencode plugin or pi extension source
│   ├── prompts/            # captain.md, officer.md, crew.md role prompts
│   └── bin/                # helper scripts: muster, spawn-crew, harbor-report
└── README.md
```

The Strongbox: encrypt `strongbox/keys.env` with [age](https://github.com/FiloSottile/age); the one manual step per new ship is dropping in your age private key. Never bake keys into the keel.

---

## 3. Layer 1 — Base Tooling

`fitout.sh` installs (idempotently):

- **System:** build-essential, ripgrep, fd, fzf, jq, unzip, curl, age, htop
- **Editor — the Scuttlebutt (Fresh):** installed via the latest release .deb in `fitout.sh` (see below)
- **tmux:** with a `ship.tmux.conf` defining the deck layout (Section 6.4)
- **Node.js:** via `fnm` (fast, no shell-startup cost) — required by all four agent CLIs
- **Git:** with worktree-friendly defaults (`rerere.enabled=true`, `fetch.prune=true`)

### The Scuttlebutt — Fresh editor

The scuttlebutt was the freshwater cask on deck where sailors gathered — fitting for [Fresh](https://getfresh.dev/), and for the place you'll gather to see what the crew is up to. Fresh is a Rust terminal editor/IDE: zero-config, VS Code/Sublime-style keybindings and mouse support, instant startup, and it stays responsive on multi-GB files. Several features are unusually well-matched to the ship:

- **Daemon mode & hot exit.** `fresh -a ship` runs a named daemon you can detach from and reattach to across disconnects, with every buffer persisted through crashes and restarts — the editor equivalent of tmux itself, and exactly right for a headless VM you SSH into.
- **`--wait` for scripted flows.** `git config --global core.editor "fresh --wait"` — set in `fitout.sh` so commits, rebases, and any orchestration script that shells out to `$EDITOR` behave.
- **Remote editing over SSH.** `fresh deploy@ovh-ship:~/fleet/...` from your Mac or Windows terminal, with background reconnection and patch-only saves — you can inspect a VPS ship's `.ship/` files without even attaching to its tmux.
- **Built-in git review.** Split-panel staged/unstaged/diff review with hunk-level staging and exportable review notes — a human-friendly console for the Quartermaster gate.
- **TypeScript plugins.** Sandboxed QuickJS plugins with `registerCommand`, event hooks (`editor.on`), and `spawnProcess`. This is where the **Chartroom plugin** lives: commands to open the current mission's orders/reports, highlight SOS reports, and jump to a crew member's tmux window from their report (via `spawnProcess("tmux", ["select-window", ...])`).

What lives in `shipyard/scuttlebutt/`: `config.json` (JSONC), a ship theme, and the Chartroom plugin's `.ts` files — symlinked into `~/.config/fresh/` by `fitout.sh`. Because Fresh is zero-config by design, this stays tiny; the Chartroom plugin is the only real carving, and building it is itself a good early mission to run *through the crew* once the orchestrator works.

## 4. Layer 2 — The Agent CLIs

| Tool | Install | Role on the ship |
|---|---|---|
| **Claude Code** | `npm i -g @anthropic-ai/claude-code` | Shipwright CC: system-level work, fixing the vessel, debugging the orchestrator, hard problems |
| **Codex CLI** | `npm i -g @openai/codex` | Shipwright CO: second shipwright / cross-check, same role contract as CC |
| **pi** | `npm i -g --ignore-scripts @earendil-works/pi-coding-agent` | **The orchestration host** — the ship's command structure runs here |
| **OpenCode** | `curl -fsSL https://opencode.ai/install \| bash` | The relief vessel: rigged, provisioned, ready to take over if pi ever becomes a liability |

Shipwrights repair the ship; they don't sail her. Both variants get their own live `sail` window in every charter's deck (`~/shipyard` cwd, never the charter) — Shipwright CC at window 7, Shipwright CO at window 8 directly after it (telescope moved to window 9 to make room, per the Admiral's request to keep the two shipwrights adjacent). Auth model differs by design: Shipwright CC uses `ANTHROPIC_API_KEY` from the Strongbox's shipwright compartment — chosen over the `/login` subscription flow so it can be provisioned unattended like every other credential here, at the cost of pay-per-token billing on that key. Shipwright CO stays on your existing OpenAI/ChatGPT subscription via `codex login` (or `codex login --device-auth` over SSH) instead — a one-time manual step per ship, not strongbox-provisioned, on purpose (see `strongbox/README.md`'s "Shipwright CO" section). Both load the shipwright strongbox compartment for `GH_TOKEN` (push credentials), so `ANTHROPIC_API_KEY` sits unused in CO's environment. pi and OpenCode are pointed at the Trade Winds (DeepInfra) via their own API key from the Strongbox. Codex has no `--append-system-prompt`-equivalent flag (confirmed against the CLI's own `--help` and its shipped binary's embedded base instructions, not assumed); it auto-loads `AGENTS.md` from the cwd up to the repo root into its developer message instead, so the repo's root `AGENTS.md` is CO's entrypoint, mirroring how `CLAUDE.md` + `ship/prompts/shipwright.md` work for CC.

## 5. Layer 3 — The Trade Winds: GLM-5.2 via DeepInfra

Current facts (verified June 2026): GLM-5.2 is Z.ai's open-weight (MIT) MoE model, 753B total / 40B active, **1M-token context**, ~128K max output, thinking levels High/Max only. It's the top open-weights model on the Artificial Analysis Intelligence Index (51) and leads open models on Terminal-Bench 2.1 (~78–81) and SWE-bench — genuinely strong for agentic coding. DeepInfra serves it at roughly **$0.95–1.40/M input, $3.00–4.40/M output**, with cached input around **$0.21–0.26/M** — and DeepInfra is consistently the cheapest blended-price provider for the GLM family.

Two things to design around:

1. **Verbosity.** GLM-5.2 averages ~43K output tokens per benchmark task (mostly reasoning). Output tokens are the expensive side. Crew prompts must demand terse final answers, and budgets must count output.
2. **Cache leverage.** Agent loops resend the same system prompt + tool defs every turn. Keep role prompts stable and front-loaded so DeepInfra's prompt caching (≈5x discount) does the heavy lifting.

### Wiring OpenCode → DeepInfra

DeepInfra exposes an OpenAI-compatible endpoint. In `opencode.json`:

```json
{
  "provider": {
    "deepinfra": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "DeepInfra",
      "options": { "baseURL": "https://api.deepinfra.com/v1/openai" },
      "models": {
        "zai-org/GLM-5.2": { "name": "GLM-5.2" }
      }
    }
  },
  "model": "deepinfra/zai-org/GLM-5.2"
}
```

with `DEEPINFRA_API_KEY` in the environment. (Verify the exact model slug against DeepInfra's catalog when you wire it — there may be a `[1m]`-context variant tag.)

### Wiring pi → DeepInfra

pi's `pi-ai` layer supports OpenAI-compatible providers; register via env vars or a tiny extension (`pi.registerProvider()` gives it a friendly name in `/login`). Same base URL, same key.

### Model routing policy

- **Captain:** GLM-5.2 thinking=High (needs judgment, not max burn)
- **Officers (review/plan):** GLM-5.2 High
- **Crew (implementation):** GLM-5.2 High; escalate a stuck task to Max rather than defaulting everyone to Max
- **Cheap chores** (commit messages, log summarization): consider a small model (e.g., a Qwen3.5 variant on DeepInfra) later — one provider, many models.

---

## 6. Layer 4 — The Ship & Crew Orchestration System

### 6.1 Chain of command

```
You (Admiralty)
   │  interactive session — the only human touchpoint
   ▼
CAPTAIN          — interprets your intent, owns the mission, reports back
   │  decomposes mission into work orders
   ▼
OFFICERS (optional layer, added in Phase 5)
   ├─ First Mate   — planning & task decomposition QA
   ├─ Bosun        — dispatch: spawns/monitors crew, restarts the stuck
   ├─ Quartermaster— repo state: reviews diffs, gates merges, runs tests
   └─ Purser       — the money: tallies token spend per order/mission,
                     flags budget breaches (mostly a script, not an LLM)
   ▼
CREW (1..N parallel agents)
   └─ each: own tmux window, own worktree, own branch, one work order
```

For small missions the Captain performs officer duties itself — the hierarchy is *elastic*. Don't build three tiers before two tiers hurts.

### 6.2 The message bus: `.ship/`

```
.ship/
├── mission.md              # current mission statement (Captain writes)
├── orders/
│   └── T-014-booking-widget-dates.md   # one work order per task
├── reports/
│   └── T-014.report.md     # crew writes on completion (or SOS)
├── log/                    # append-only event log (spawn, done, merge, fail)
└── roster.json             # live crew: task id, tmux window, worktree, branch, pid
```

A **work order** is a contract: objective, files in scope, acceptance criteria (tests to pass), branch name, token/turn budget, and "raise SOS instead of guessing" rules. A **report** is the return contract: what changed, test results, open concerns.

### 6.3 Mission lifecycle

1. **Brief** — You tell the Captain what you want.
2. **Plan** — Captain writes `mission.md`, decomposes into orders, shows you the plan. *You approve before tokens burn.*
3. **Muster** — Bosun function: for each order, create worktree + branch, spawn a crew agent headless in a tmux window:
   `opencode run "$(cat .ship/orders/T-014*.md)"` or `pi -p @order.md` inside the worktree.
4. **Work** — Crew implement, self-test, commit, write report, exit. Watchdog restarts hung agents (with turn limits).
5. **Review** — Quartermaster function: diff review + test run per branch; failed reviews go back to a fresh crew agent with feedback appended.
6. **Integrate** — Merge passing branches into `integration`, run the full suite, then fast-forward `main`. Worktrees pruned, log updated.
7. **Debrief** — Captain summarizes to you: what shipped, what's blocked, cost.

### 6.4 The deck (tmux layout) — one window per role

You're a visual person, so the layout is the org chart: **every role gets a permanent, numbered window**, whether that role is currently an LLM agent, a script, or just a live view of its artifacts. Muscle memory maps prefix+number to a role, and a glance at the status bar tells you who's busy.

```
Session: ship-<charter>          (one deck per active charter — Section 6.5)
├── 0: bridge        — Captain (your interactive pi session)
├── 1: chartroom     — Scuttlebutt on .ship/ (orders, reports, mission)
├── 2: first-mate    — plan critique agent; pre-Phase-5: mission.md open for your own review
├── 3: bosun         — dispatch console: roster.json + spawn log, watch-style
├── 4: quartermaster — review station: Fresh git-review of the branch under inspection
├── 5: purser        — live cost tally (tail of the ledger + running mission total)
├── 6: engine-room   — htop, system logs
└── 7+: crew-T###    — one window per active crew member (auto-created/-closed by muster)
```

Two details that make this sing: name windows with role glyphs in `ship.tmux.conf` (`⚓ bridge`, `🗺 chartroom`, `⚒ crew-T014`…) and use tmux `monitor-activity` + status-bar colors so a crew window flashes when its agent finishes or raises SOS. Officer windows exist from day one even though officers only become agents in Phase 5 — until then each is a dashboard for the same information, so your visual habits don't change when the roles get automated underneath them.

A rendered reference of this layout lives at `shipyard/dotfiles/tmux/deck-layout.svg`, next to `ship.tmux.conf` — the picture and the conf that produces it travel together.

`muster` (a shell script in `ship/bin/`) owns spawn: berth create → tmux window → launch agent → register in the roster. The plugin calls it; you can also call it by hand — which is exactly Phase 3.

### 6.5 Charters & the Fleet — how repos and projects fit

The mental model, in one line: **the Ship is infrastructure; a repo is a Charter; a mission is a Voyage; parallel projects are parallel decks (tmux sessions), each with its own Captain.**

**Is each project a new ship?** No. A ship per repo means provisioning, authenticating, and patching N VMs for zero benefit — the environment (agents, editor, tmux, keys) is project-agnostic by design. One ship carries many charters:

```
~/fleet/
├── royal-guest/            # a charter
│   ├── charter.md          # standing orders: repo URL, stack, conventions,
│   │                       #   test commands, paths agents may never touch
│   ├── .hold.git/          # bare repo (the hold)
│   ├── berths/             # worktrees
│   └── .ship/              # this charter's bus: mission, orders, reports, roster, log
├── meshmon/                # another charter
└── shipyard/               # the shipyard itself is a charter — the ship improves itself
```

One exception to keep in your pocket: if a client engagement ever demands hard isolation (their secrets, their compliance posture), that client gets a dedicated ship — trivially, since ships cost one `multipass launch` against the same keel.

**One captain per project, or one captain across projects?** One Captain per charter, strictly — and really one Captain per *voyage* (mission). Four reasons, in descending order of importance:

1. **Context purity.** A Captain's judgment depends on its context holding one repo's map, one mission, one set of conventions. Two projects in one session means both get reasoned about worse.
2. **Cache economics.** The Trade Winds discount (~5x on cached input) comes from stable repeated prefixes. `charter.md` + role prompt + repo map form a per-charter stable prefix; interleaving projects shreds it.
3. **Cost & blame attribution.** A per-charter `.ship/` gives the Purser clean per-client numbers — which matters the day agent-assisted work shows up on a Royal Guest invoice.
4. **Blast radius.** A Captain that can only see one hold can only merge into one hold.

**How do I run multiple projects at once, then?** Multiple Captains — which costs nothing, because a Captain is a session, not a daemon. One deck per active charter, each with the full window-per-role layout from 6.4:

```bash
sail royal-guest   # helper: tmux new -As ship-royal-guest, cd ~/fleet/royal-guest,
                   #         build the deck layout, Captain on the bridge
sail meshmon       # a second, fully-staffed deck
# prefix+s → the Fleet Board: every deck at a glance, switch instantly
```

This is the visual model scaled up: **session = project, window = role, pane = detail.** The Fleet Board (`tmux choose-session`) becomes your cross-project overview for free.

**Should there be a Commodore — a captain of captains?** Not yet, and maybe never. Cross-project orchestration sounds appealing but buys little: charters rarely share tasks, an admiral agent would mostly relay messages you'd rather see yourself, and it doubles the hardest unsolved problems (budgeting, review gating) before they're solved at one level. *You* are the Admiralty; the Fleet Board is your flag deck. Revisit only if you catch yourself repeatedly copying context between two bridges — that's the signal a real cross-charter workflow exists.

**Tasking across charters in practice:** brief each Captain on its own bridge in its own words; never route Royal Guest work through the meshmon deck "because it's open." If a task genuinely spans repos (rare — e.g., shipyard tooling change needed for a client task), it's two orders on two decks with you as the link, sequenced by hand.

---

## 7. Git Worktrees — The Hold and the Berths

```bash
# One-time per repo: lay in the hold
cd ~/fleet/royal-guest
git clone --bare git@...:royal-guest-site.git .hold.git
git -C .hold.git worktree add ../berths/home-port main

# Per task (done by muster): assign a berth
git -C .hold.git worktree add ../berths/T-014 -b crew/T-014-booking-dates main
# ... crew works, commits ...
# Quartermaster reviews, then into dry dock:
git -C berths/dry-dock merge --no-ff crew/T-014-booking-dates   # integration branch
git -C .hold.git worktree remove ../berths/T-014                # berth freed
```

Rules that keep parallel agents from colliding:

- **Decompose by file ownership.** Orders declare which paths a crew member may touch; the Captain's planner avoids overlapping scopes. Overlap → serialize those tasks instead.
- **Branch naming:** `crew/<task-id>-<slug>` — greppable, prunable.
- **Crew never merge.** Only the Quartermaster/Captain path touches dry dock (`integration`) and home port (`main`).
- **`rerere` on** so repeated conflict resolutions are remembered during integration.
- **Short-lived branches.** A work order should complete in one session; anything bigger gets split.

---

## 8. OpenCode vs pi as the Orchestration Host

Honest comparison for *your* stated goal (build the orchestration yourself):

| | **OpenCode** | **pi** |
|---|---|---|
| Sub-agents | Native (agents/subagents, task tool) | Deliberately none — you build it (tmux spawn is the blessed path) |
| Plugin surface | TypeScript plugin API + skills; rich ecosystem (`oh-my-opencode`, `opencode-worktree`, `opencode-orchestrator`, swarm plugins) | Extensions can do nearly anything (custom tools, providers, TUI, event hooks); packages installable from npm/git |
| Headless mode | `opencode run` | `-p` / `--mode json` / `--mode rpc` (RPC mode is ideal for a Bosun controlling crew programmatically) |
| Philosophy | Batteries included, provider-agnostic (75+ providers) | Minimal harness, token-efficient system prompt, "adapt pi to your workflow" |
| Risk | You fight built-in orchestration when yours differs | You build more from scratch |

**Decision (made):** **pi is the orchestration host; OpenCode is the relief vessel.** pi's RPC mode + extension API + explicit "spawn instances via tmux" philosophy is almost a description of this design, and its minimal system prompt stretches GLM-5.2's cache discount further. OpenCode stays installed, configured against the same Trade Winds provider, and gets exercised occasionally (run one mission through `opencode-orchestrator` or `oh-my-opencode` early to steal ideas about what a mature mission loop handles — stagnation escalation, review gates, session pooling). Studying `badlogic/pi-skills`' `subagent` skill is the fastest on-ramp for the pi extension.

The anti-lock-in discipline that makes the relief vessel real rather than theoretical: **all orchestration state lives in `.ship/` files and plain git, never inside pi's session format.** The pi extension is a thin adapter over `muster`, the roster, and the order/report contract — so porting to OpenCode means rewriting one adapter, not the system. Test the escape hatch once a quarter: run a small mission with the OpenCode adapter and confirm the fleet still sails.

---

## 9. Build Phases

**Phase 0 — Lay the keel (½ day).** Create the shipyard repo: `keel.yaml`, `fitout.sh`, Scuttlebutt config (Fresh + ship theme), the per-role deck layout in `ship.tmux.conf`, Strongbox. Test: fresh Multipass VM on the gaming PC reaches a working shell with all four CLIs authenticated.

**Phase 1 — Three harbors (½ day).** Same bootstrap on the Mac and on an OVHcloud Public Cloud instance. Fix arch-specific issues (ARM64 binaries on Apple Silicon). Deliverable: `multipass launch … && ssh` works identically everywhere.

**Phase 2 — Catch the trade winds (½ day).** DeepInfra provider configured in pi (primary) and OpenCode (relief). Smoke tests: single-shot code task each; confirm cache hits appear in DeepInfra's usage dashboard; record baseline cost per task.

**Phase 3 — Manual drills (1–2 days).** *No plugin yet.* You are the Captain. By hand: write two work orders, `muster` two crew agents (headless pi/opencode in worktrees, tmux windows), review, merge. This teaches you the failure modes the plugin must handle — worth more than any design doc.

**Phase 4 — Plugin v1: Captain + crew (2–4 days).** pi extension (or OpenCode plugin) adding: `/mission` (plan + orders), `/muster` (spawn), `/harbor` (status from roster + reports), `/debrief`. Crew are plain headless instances; the extension only manages files, tmux, and worktrees.

**Phase 5 — Officers & gates (ongoing).** Quartermaster review pass (separate agent reviewing each diff before merge), Bosun watchdog (turn/token limits, restart-with-feedback), then First Mate plan critique. Add per-mission cost ledger from the log.

**Phase 6 — Fleet ops.** VPS as always-on ship for long missions; kick off from your phone via SSH/tmux attach. Optional: crew inside containers for blast-radius control; a small web dashboard reading `.ship/log`.

---

## 10. Guardrails

- **Budget per order:** max turns and max output tokens in every work order; Bosun kills over-budget crew and logs it. GLM-5.2's reasoning verbosity makes this non-optional.
- **The Purser's ledger:** append per-call usage to `.ship/log`; `/debrief` totals it. Sanity check against the DeepInfra dashboard weekly.
- **Blast radius:** crew agents run as an unprivileged user, in a VM, on branches. They never get `main`, never get secrets beyond their model key, never get prod credentials (relevant when Royal Guest work runs through this).
- **SOS over improvisation:** the crew prompt's prime directive — if acceptance criteria can't be met or scope is wrong, write an SOS report and exit. A wrong guess merged is costlier than an aborted task.
- **Human gate at two points:** plan approval (before spawn) and merge-to-main (until the Quartermaster earns trust).

## 11. Open Questions (decide during Phase 3)

1. Crew feedback loops: fresh agent per revision (clean context, more tokens) vs. resumed session (cheaper, contaminated context)? Start with fresh-per-revision.
2. Does the Captain stay resident during long missions, or does the Bosun become a daemon that pages you? (VPS phase forces this.)
3. Order granularity: what task size keeps GLM-5.2 reliable? Benchmarks say it sustains long trajectories, but your Phase-3 drills will find the real ceiling.
4. When (if ever) do officers deserve a stronger model (e.g., routing Quartermaster reviews through Claude via pi's multi-provider support)?
