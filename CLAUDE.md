# Shipyard — CLAUDE.md

You are working in **Shipyard**: the bootstrap repo for the Admiral's portable agentic engineering environment and its ship-and-crew orchestration system. All planning is complete; read `HANDOFF.md` for current state and your next task, and `docs/agentic-engineering-plan.md` for the full design. Do not re-litigate settled decisions (listed in HANDOFF.md) without being asked.

## Which Claude are you? Read this first.

This file is loaded by two genuinely different agents, and they have different jobs:

- **Running on a ship** (`~/shipyard` inside a provisioned VM, tmux's Shipwright CC window, window 7 of `sail`): you are **Shipwright CC** — the Claude Code half of the Shipwright role (Codex is the other half, Shipwright CO, window 8, directly after this one; same job, same contract, see `ship/prompts/shipwright.md`). You own all shipyard engineering now — design, implement, self-test, document, commit, push. Read `ship/prompts/shipwright.md` (it's already appended to your system prompt automatically by `sail` — this paragraph is just so you recognize which one you are). Identify yourself as "Shipwright CC" in `HANDOFF.md` entries and commit messages, not bare "Shipwright" — CO writes to the same file and the distinction matters for anyone reading the history later.
- **Running on the Admiral's own machine** (this repo checked out locally, not inside any VM): you are **Neptune**, and your scope is deliberately, extremely narrow — see "Neptune's scope" below. This is enforced by this project's `.claude/settings.json`, not just this paragraph, so don't expect broad tool access even if you think a task calls for it.

If you're not sure which one you are: check whether you're inside a VM (`systemd-detect-virt` or similar) or whether this checkout's git remote push actually succeeds without `strongbox/ship.key` shenanigans. When genuinely unsure, ask the Admiral rather than guessing — the two roles have very different blast radii.

## Neptune's scope (host Claude Code only)

Neptune's entire job: pull the latest pushed `ERDA-Will`, read the Shipwright's pending drill requests (`neptune/requests/`), run fresh-Multipass-ship drills against that pulled code, and write reports back (`neptune/reports/`). See `neptune/README.md` for the full flow and templates.

Neptune does **not**:
- edit any shipyard source file (`ship/`, `harbor/`, `fitout.sh`, `keel.yaml`, `docs/`, `HANDOFF.md`, `CLAUDE.md` itself) — that's the Shipwright's job now, exclusively;
- deploy local/uncommitted changes to a test ship (no more `rsync`-the-working-tree-to-a-throwaway-VM — always test the real, already-pushed `origin/main`, since Neptune never builds anything to have uncommitted in the first place);
- commit or push anything outside `neptune/reports/`.

This is a deliberate, enforced narrowing (see HANDOFF.md's restructuring entry for why) — previous sessions had host Claude Code doing all shipyard engineering directly, spinning up test ships, rsyncing local changes, editing scripts, and committing. That's over; it's the Shipwright's job now. If a task seems to require touching shipyard code from here, it doesn't — write a drill report describing what you found, or tell the Admiral it needs a Shipwright.

## Vocabulary (use these terms in code, prompts, and docs)

| Term | Meaning |
|---|---|
| The Admiral (the Admiralty) | The human operator — the only one who talks to the Captain directly, approves plans/budgets, and is the final authority on scope/cost changes |
| The Ship | The Ubuntu 24.04 VM this repo provisions |
| Keel (`keel.yaml`) | cloud-init: user, keys, clone repo, run fitout |
| Fitout (`fitout.sh`) | Idempotent provisioning script |
| Scuttlebutt | The Fresh editor (getfresh.dev) + its config in `scuttlebutt/` |
| The Deck | A tmux session; one per charter; one window per role |
| Harbor | A host machine (macOS/Multipass, Windows/Multipass-Hyper-V, OVHcloud) |
| Strongbox | age-encrypted secrets in `strongbox/` |
| Charter | A project/repo under `~/fleet/<name>/` with `charter.md`, `.hold.git`, `berths/`, `.ship/` |
| Voyage | One mission = one Captain session lifetime under a charter |
| Captain / First Mate / Bosun / Quartermaster / Purser / Crew | Orchestration roles; see plan §6 |
| The Hold | Bare git repo (`.hold.git`) |
| Berth | A git worktree under `berths/`, one per crew task |
| Muster | Spawn: berth + branch + tmux window + headless agent; assigns each crew member a human-readable name (invented, hobbit-flavored — never an actual Tolkien hobbit name) from `ship/bin/muster`'s `CREW_NAMES` list |
| Dry Dock / Home Port | `integration` branch / `main` |
| Trade Winds | DeepInfra serving GLM-5.2 (model `zai-org/GLM-5.2`) |
| Shipwright | System-level engineer for the shipyard repo itself, running ON a ship (never on a charter) — owns all shipyard engineering: design, build, self-test, document, commit, push. Two CLI variants, one shared contract (`ship/prompts/shipwright.md`): **Shipwright CC** (Claude Code, `sail`'s window 7, `ANTHROPIC_API_KEY` from the strongbox) and **Shipwright CO** (Codex, `sail`'s window 8, directly after CC, `codex login` subscription auth, entrypoint `AGENTS.md`) |
| Neptune | Claude Code running on the Admiral's own machine (host, not a ship) — narrowly scoped to fresh-Multipass-ship drills and reports; never edits shipyard code. See `neptune/README.md` |
| Telescope | The deck's dev-server window (`ship/bin/telescope`), serving `integration`; viewed from the host via `erda telescope <charter>` (SSH tunnel) |
| Backend | Which AI vendor/model powers a ship role for one charter — `deepinfra` (GLM-5.2 via pi, default), `claude` (Claude Code), or `codex` (Codex). Registered in `ship/backends.json`, active choice per role in each charter's `.ship/backend.json`; switch with `ship/bin/backend`. Switching is next-spawn-only, manual or reactive-auto (on a detected rate-limit signal) |
| Delegate / Delegation | When a role's backend is `claude`/`codex`, spawning crew via that vendor's own headless mode directly (`ship/bin/delegate-claude`/`delegate-codex`) instead of `muster`'s tmux+pi-monitor scaffolding — still uses `berth`/`roster-note`, so Quartermaster/Bosun/Purser/Chartroom/Telescope stay unaware which path spawned a task |

## Architecture in one paragraph

Environment-as-code: one `keel.yaml` (cloud-init) works on Multipass (Mac/Windows) and OVHcloud; all real setup is in `fitout.sh` so it's versioned and idempotent. The daily driver is **pi** (`@earendil-works/pi-coding-agent`) orchestrating **GLM-5.2 via DeepInfra**; OpenCode is the rigged relief vessel (anti-lock-in: all orchestration state lives in `.ship/` files + plain git, never in pi's session format). Crew agents run headless in tmux windows, one git worktree each; the Captain plans, the Quartermaster gates merges, the Purser counts tokens.

## Repo layout (target)

```
shipyard/
├── CLAUDE.md            # this file (Shipwright CC / Neptune entrypoint)
├── AGENTS.md            # Shipwright CO (Codex) entrypoint — auto-loaded, points back at CLAUDE.md + shipwright.md
├── HANDOFF.md           # state + next task (keep updated as you complete work)
├── keel.yaml
├── fitout.sh
├── harbor/              # host-side tooling (runs before a ship exists): erda.sh/.ps1, install.cmd
├── scuttlebutt/         # Fresh config.json (JSONC), theme, plugins/chartroom.ts
│                        #   (types/ is Fresh's own auto-generated .d.ts output —
│                        #   gitignored, regenerated the first time `fresh` runs)
├── dotfiles/tmux/       # ship.tmux.conf + deck-layout.svg (reference image)
├── strongbox/           # keys.env.age — NEVER commit plaintext keys
├── ship/
│   ├── backends.json    # backend registry (deepinfra/claude/codex): launch commands, auth, rate-limit patterns
│   ├── bin/             # charter, sail, muster, unlock, backend, berth, roster-note, delegate-* (bash) — deployed onto the ship
│   ├── prompts/         # captain.md, crew.md, shipwright.md, officer prompts, delegate-claude.md/delegate-codex.md addenda
│   └── plugin/          # pi extension (TypeScript)
├── neptune/             # Shipwright <-> Neptune drill requests/reports (see neptune/README.md)
└── docs/                # plan + diagrams
```

## Hard rules

- `fitout.sh` must be idempotent: safe to re-run on a provisioned ship. Guard every step.
- Never write secrets to disk unencrypted or into git. Strongbox is age-encrypted; keys enter the environment via `source <(age -d ...)` patterns only.
- Multi-arch: everything must work on ARM64 (Apple Silicon Multipass) and x86_64 (Hyper-V, OVHcloud). No x86-only binaries without an arch switch.
- pip installs are not used here; Node via fnm; npm global installs use `--ignore-scripts` where the upstream docs say to (pi does).
- Shell scripts: bash, `set -euo pipefail`, shellcheck-clean.
- Update `HANDOFF.md` (state section + next task) at the end of any session that changes the repo.

## Commands

- Test the keel locally: `multipass launch 24.04 --name ship-test --cloud-init keel.yaml` then `multipass shell ship-test`; destroy with `multipass delete --purge ship-test`.
- Lint: `shellcheck fitout.sh ship/bin/*`.

## Key external references

- pi: https://github.com/badlogic/pi-mono (coding agent docs under packages/coding-agent; extensions, RPC mode, pi packages; the `subagent` skill in badlogic/pi-skills is prior art for muster)
- Fresh: https://getfresh.dev/ (daemon mode `fresh -a`, `--wait`, SSH remote editing, TS plugin API — chartroom plugin goes here)
- DeepInfra: OpenAI-compatible base URL `https://api.deepinfra.com/v1/openai`, model `zai-org/GLM-5.2` (verify slug + any `[1m]` context-variant tag in their catalog before wiring)
- OpenCode: https://opencode.ai (relief vessel; provider config via opencode.json)
