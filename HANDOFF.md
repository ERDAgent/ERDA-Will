# HANDOFF — Shipyard project

**From:** planning session on claude.ai (June–July 2026, Claude Fable 5)
**To:** Claude Code, working in this repo
**Status:** Planning complete. Phase 0 item 1 done (shellcheck-clean, hardened, regression-drilled — see §4c). Next task: `fitout.sh` + `keel.yaml` + real-VM validation (items 2–4 below).

Claude.ai chats cannot be resumed as Claude Code sessions — this file and `docs/agentic-engineering-plan.md` ARE the session transfer. Read the plan in full once before writing anything.

---

## 1. What this project is

A portable Linux dev environment (VM bootable identically on macOS, Windows, and OVHcloud via one cloud-init) hosting a multi-agent orchestration system modeled on a ship's crew: Eric talks to a Captain agent; the Captain decomposes missions into work orders; crew agents execute in parallel, each in its own git worktree and tmux window; officer roles (review, dispatch, cost) gate the results. Primary model: GLM-5.2 via DeepInfra, orchestrated by pi.

## 2. Decisions already made — do not reopen unprompted

| # | Decision | Rationale (short) |
|---|---|---|
| D1 | Environment-as-code via Multipass + cloud-init, not VM images | ARM64/x86_64 split makes images non-portable; one keel.yaml covers Mac, Windows (Hyper-V backend), OVHcloud |
| D2 | VPS provider: OVHcloud | Eric's choice; Public Cloud instances take cloud-init natively (OpenStack). Legacy VPS line = fallback to manual `fitout.sh` |
| D3 | Editor: Fresh (getfresh.dev), named "the Scuttlebutt" | Zero-config, daemon mode, SSH remote editing, --wait for $EDITOR, TS plugins (chartroom plugin), built-in git review. Replaces earlier Neovim/NvChad idea |
| D4 | Orchestration host: pi primary, OpenCode as relief vessel | pi's tmux-spawn philosophy + RPC mode + minimal system prompt (cache-friendly). Anti-lock-in: all state in `.ship/` files + git, host adapter is thin |
| D5 | Model: GLM-5.2 via DeepInfra (`zai-org/GLM-5.2`), thinking=High default, Max on escalation only | Top open-weights model (AA index 51), 1M ctx, cheapest via DeepInfra; verbose reasoning (~43K out tokens/task) → hard per-order budgets |
| D6 | Claude Code + Codex = shipwrights only | System-level repair/support; not the daily crew (cost + separation of concerns) |
| D7 | tmux: one session ("deck") per charter, one window per role | Eric is a visual person; window layout = org chart; officer windows exist from day one as dashboards, become agents in Phase 5 |
| D8 | Projects = charters under `~/fleet/<name>/`; one Captain per charter, never across; parallel projects = parallel decks | Context purity, prompt-cache economics, per-client cost attribution, blast radius |
| D9 | No Commodore (captain-of-captains) | Premature; Eric is the Admiralty; revisit only if cross-deck context copying becomes frequent |
| D10 | Git: bare hold + berths (worktrees), branches `crew/<task-id>-<slug>`, crew never merge, Quartermaster gates dry dock (`integration`) → home port (`main`) | Parallel-agent collision avoidance; decompose by file ownership |
| D11 | Naming: full nautical vocabulary is load-bearing (see CLAUDE.md table) | Self-documenting system; Eric explicitly wants it leaned into |

## 3. Facts verified during planning (with as-of dates)

- GLM-5.2 (June 16, 2026): 753B/40B MoE, MIT, 1M ctx, ~128–131K max output, thinking High/Max only; DeepInfra pricing observed $0.95–1.40/M in, $3.00–4.40/M out, cached in ≈$0.21–0.26/M; leading open-weights on AA Intelligence Index (51), Terminal-Bench 2.1 ≈78–81. Very verbose (≈43K output tokens/task on AA evals).
- pi (pi.dev / badlogic/pi-mono): no built-in sub-agents by design ("spawn pi instances via tmux"), extensions API, modes: interactive / -p / --mode json / --mode rpc; packages installable from npm/git; `pi install git:...`. Install: `npm i -g --ignore-scripts @earendil-works/pi-coding-agent`.
- Fresh (getfresh.dev, June 2026): daemon mode (`fresh -a name`), hot exit, `--wait`, SSH remote editing w/ reconnect + patch-only saves, split-panel git review w/ hunk staging, TS plugins in sandboxed QuickJS (`registerCommand`, `editor.on`, `spawnProcess`), .deb releases + install script. Sends anonymous telemetry by default — disable with `check_for_updates: false` in config (Eric-friendly default: off).
- OpenCode: provider-agnostic, native subagents, TS plugins; ecosystem prior art: `opencode-orchestrator` (Commander/Planner/Worker/Reviewer mission loop), `oh-my-opencode`, `opencode-worktree`.
- Claude Code sessions: local, per project directory, `--continue`/`--resume`; claude.ai web chats are not importable.

## 4. Deliverables produced so far (all in `docs/`)

- `agentic-engineering-plan.md` — master plan, v3 (sections: goals, manifest, VM strategy, tooling, Trade Winds wiring, orchestration §6 incl. deck layout §6.4 and charters/fleet §6.5, worktrees, pi-vs-OpenCode, phases, guardrails, open questions)
- `shipyard-architecture.mermaid` — full-system component graph
- `fleet-charters-voyages.mermaid` — charters/voyages/decks conceptual graph
- `deck-layout.svg` — tmux window-per-role reference image (final home: `dotfiles/tmux/deck-layout.svg`)

## 4b. Drafted & container-tested in the planning session (July 1, 2026)

These exist in this repo and passed an end-to-end drill in an Ubuntu 24.04 container
(charter → sail → 3 concurrent stub crews → dry-dock merges → ff to main → berth prune):

- `dotfiles/tmux/ship.tmux.conf` — deck behavior/looks (windows created by sail)
- `ship/bin/charter` — register a repo as a charter (bare hold, home-port berth, charter.md, .ship bus)
- `ship/bin/sail` — open/attach deck, windows 0–6 per role, dashboards for bosun/quartermaster/purser; `SHIP_NO_ATTACH=1` for CI; `SHIP_GLYPHS=0` for plain names
- `ship/bin/muster` — berth + branch + crew window + headless agent (`SHIP_AGENT` overrides `pi -p`); roster + event log
- `ship/bin/unlock`, `strongbox/README.md` — age secrets flow
- `ship/prompts/{captain,crew,order-template}.md` — role contracts

Bugs found and FIXED during the drill (regression-test these):
1. Berth scaffolding (`.order.md`, `.charter.md`, `.crew-run.sh`) was committable via
   `git add -A`, causing add/add conflicts at dry dock → now written to the worktree's
   `info/exclude`.
2. Concurrent crews raced on `roster.json` (last-write-wins) → roster updates now
   flock-guarded via `.ship/.roster.lock`. Verified with 3 simultaneous crews.

NOT yet done for these scripts: shellcheck (unavailable in the drill container), real
pi instead of the stub agent, UTF-8 glyph window names on a real terminal, macOS/BSD
differences if any script ever runs host-side (they shouldn't — ship-side only).

## 4c. Phase 0 item 1 done (July 1, 2026) — shellcheck, hardening, regression drill

`shipyard-handoff.zip` (the claude.ai → Claude Code transfer artifact) was extracted
into this repo this session; it's now tracked source, not a bundle.

- `shellcheck -x` on `ship/bin/{charter,sail,muster,unlock}`: clean, no findings.
- Manual hardening (shellcheck doesn't catch these): `charter`'s `NAME`, `sail`'s
  `NAME`, and `muster`'s `NAME`/`TASK` flow unquoted into a single-quoted `bash -lc '...'`
  tmux command string (sail) and a heredoc-generated `.crew-run.sh` (muster) — a name
  containing a quote or `$(...)` would break out. Added
  `^[A-Za-z0-9][A-Za-z0-9_-]*$` validation on all four input points before any of that
  interpolation happens.
- Regression drill (no Multipass/Docker/Podman on this host — ran locally on macOS
  instead, with `tmux`, `flock`, `jq`, `watch` installed via `brew`; system bash 3.2
  was sufficient, no bash4+ features in use): charter → sail (all 7 windows 0–6 alive)
  → 3 concurrent `muster` calls with a stub agent → crew commits → dry-dock
  (`integration`) merges → fast-forward `main` → berth prune. Both original bugs
  confirmed still fixed: `roster.json` stayed valid JSON with all 3 entries and
  correct final `status: done` under concurrency; `git add -A` in each berth staged
  only the crew's real file, never `.order.md`/`.charter.md`/`.crew-run.sh`.
- **New bug found and fixed**: `git rev-parse --git-path info/exclude` resolves to
  the *shared* `.hold.git/info/exclude`, not a per-worktree file (worktrees don't get
  their own `info/exclude`). So every `muster` call was appending the same 3 lines
  again, unboundedly, over a charter's life. Fixed with a `grep -qxF` idempotency
  guard before the append; verified 3 concurrent musters now produce exactly one copy
  of each line.
- `date -Is` (GNU-only) fails on macOS's BSD `date`, leaving `roster.json`'s
  `started` field empty during this local drill — expected and out of scope, since
  the real ship is Ubuntu/GNU coreutils (see "ship-side only" note above).
- Still not done: UTF-8 glyph window names on a real terminal (ran with
  `SHIP_GLYPHS=0` locally), real `pi` instead of a stub agent, and validating on an
  actual Ubuntu ship — all deferred to item 4 below, which needs Multipass.

## 5. NEXT TASK — remaining Phase 0

Where to run: **on the host OS (Mac or Windows), in this repo** — Phase 0's acceptance
test is launching fresh VMs from keel.yaml via Multipass and destroying them, which is
only possible from OUTSIDE the ship. Once a ship provisions cleanly twice in a row,
move aboard (install Claude Code on the ship) and work as shipwright from there for
everything after — Phase 2 onward assumes you live on the ship.

Multipass is not yet installed on this host — available via `brew install --cask
multipass` (confirmed present in brew's cask catalog, not yet installed).

Build, in this order, with acceptance criteria:

1. ~~**shellcheck + harden the drafted scripts** in `ship/bin/` and regression-test the two fixed bugs above. AC: shellcheck clean; 3-concurrent-crew drill passes with a stub agent.~~ **DONE — see §4c.**
2. **`fitout.sh`** — idempotent bash (`set -euo pipefail`). Installs: apt basics (build-essential, ripgrep, fd-find, fzf, jq, unzip, curl, age, htop, tmux, git), fnm + Node LTS, Fresh (latest release .deb by arch; set `git config --global core.editor "fresh --wait"`; telemetry off), Claude Code, Codex CLI, OpenCode, pi (`--ignore-scripts`), symlinks `scuttlebutt/` → `~/.config/fresh/` and `dotfiles/tmux/ship.tmux.conf` → `~/.tmux.conf`, decrypts strongbox if age key present (skip gracefully if not). AC: runs clean twice in a row on fresh Ubuntu 24.04 ARM64 and x86_64.
3. **`keel.yaml`** — cloud-init: user `eric` w/ ssh key + sudo, git install, clone this repo to `~/shipyard`, run `fitout.sh` as the user, log to `/var/log/fitout.log`. AC: `multipass launch 24.04 --cloud-init keel.yaml` yields a ship where `pi --version`, `opencode --version`, `claude --version`, `codex --version`, `fresh --version` all succeed.
4. **Validate the drafted deck on a real ship**: `sail` matches `docs/deck-layout.svg`, glyphs render, two decks concurrently, muster drill with REAL pi against a scratch charter. AC: plan Phase 3 manual drill passes on-ship.

Defer: pi extension, officer agents, DeepInfra wiring test (Phase 2), chartroom Fresh plugin.

## 6. Open questions (decide during Phase 3 drills, not now)

1. Crew revision loops: fresh agent per revision vs resumed session — start fresh-per-revision.
2. Long missions on the VPS ship: does the Bosun become a daemon that pages Eric? (Forced by Phase 6.)
3. Real task-size ceiling for GLM-5.2 reliability.
4. Whether Quartermaster reviews ever route to a stronger model via pi's multi-provider support.
5. Exact DeepInfra model slug / `[1m]` variant — verify at Phase 2 wiring time.

## 7. Session log

- v1: initial plan (VM strategy, tooling, orchestration, worktrees, phases).
- v2: OVHcloud; skeuomorphic naming pass (manifest); pi-primary decision; Purser added.
- v3: Fresh editor confirmed (Scuttlebutt); window-per-role deck; charters/voyages/fleet model (§6.5); deck-layout.svg + fleet mermaid produced; this handoff created.
- v4 (Claude Code, July 1, 2026): extracted `shipyard-handoff.zip` into the repo; Phase 0 item 1 (shellcheck + hardening + regression drill) done — see §4c.
