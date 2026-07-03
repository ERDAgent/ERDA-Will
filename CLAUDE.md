# Shipyard — CLAUDE.md

You are working in **Shipyard**: the bootstrap repo for Eric's portable agentic engineering environment and its ship-and-crew orchestration system. All planning is complete; read `HANDOFF.md` for current state and your next task, and `docs/agentic-engineering-plan.md` for the full design. Do not re-litigate settled decisions (listed in HANDOFF.md) without being asked.

## Vocabulary (use these terms in code, prompts, and docs)

| Term | Meaning |
|---|---|
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
| Muster | Spawn: berth + branch + tmux window + headless agent |
| Dry Dock / Home Port | `integration` branch / `main` |
| Trade Winds | DeepInfra serving GLM-5.2 (model `zai-org/GLM-5.2`) |
| Shipwrights | Claude Code (you) & Codex — system-level repair and support, not the daily sailing crew |

## Architecture in one paragraph

Environment-as-code: one `keel.yaml` (cloud-init) works on Multipass (Mac/Windows) and OVHcloud; all real setup is in `fitout.sh` so it's versioned and idempotent. The daily driver is **pi** (`@earendil-works/pi-coding-agent`) orchestrating **GLM-5.2 via DeepInfra**; OpenCode is the rigged relief vessel (anti-lock-in: all orchestration state lives in `.ship/` files + plain git, never in pi's session format). Crew agents run headless in tmux windows, one git worktree each; the Captain plans, the Quartermaster gates merges, the Purser counts tokens.

## Repo layout (target)

```
shipyard/
├── CLAUDE.md            # this file
├── HANDOFF.md           # state + next task (keep updated as you complete work)
├── keel.yaml
├── fitout.sh
├── harbor/              # host-side tooling (runs before a ship exists): christen.sh/.ps1
├── scuttlebutt/         # Fresh config.json (JSONC), theme, chartroom plugin (.ts)
├── dotfiles/tmux/       # ship.tmux.conf + deck-layout.svg (reference image)
├── strongbox/           # keys.env.age — NEVER commit plaintext keys
├── ship/
│   ├── bin/             # charter, sail, muster, unlock (bash) — deployed onto the ship
│   ├── prompts/         # captain.md, crew.md, officer prompts
│   └── plugin/          # pi extension (TypeScript)
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
