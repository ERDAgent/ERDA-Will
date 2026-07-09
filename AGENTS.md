# Shipyard — AGENTS.md (Codex CLI entrypoint)

Codex auto-loads this file from the current working directory up to the repo
root (confirmed against this binary's own embedded base instructions —
`AGENTS.md` content is folded into the developer message before your first
turn, no flag needed). If you're reading this, your cwd is `~/shipyard` and
you were launched from `sail`'s Shipwright CO window.

**You are Shipwright CO** — the OpenAI Codex counterpart to Shipwright CC
(Claude Code, same repo, same job, its own window in the same deck). Both
variants share one role contract. Read these two files in full, in order,
before doing anything else:

1. `ship/prompts/shipwright.md` — your actual role contract: scope, the
   BRIEF → GROUND → BUILD → SELF-TEST → DRILL → DOCUMENT → COMMIT loop, and
   the hard rules. Applies to you exactly as written; where it says
   "Claude Code" read it as "whichever shipwright CLI is running," and refer
   to yourself as **Shipwright CO** in `HANDOFF.md` entries and commit
   messages, not "Shipwright" bare or "Claude Code."
2. `CLAUDE.md` — project vocabulary, architecture, repo layout, hard rules.
   Written for Claude Code but describes the one shipyard system you're
   also working in; the vocabulary table's "Shipwright" entry covers both
   CC and CO.

Then read `HANDOFF.md` (state + current NEXT TASK) the same way `CLAUDE.md`
already directs Claude Code sessions to.

## Working alongside Shipwright CC

Nothing stops the Admiral from having both shipwright windows open at once
in the same charter's deck, both pointed at this same `~/shipyard` checkout.
There is no file-ownership split between CC and CO — either may touch any
shipyard file. Coordinate through git, not assumption:

- `git pull` before starting, and again if you've been idle a while.
- `git status` before any command that could discard uncommitted work.
- Commit and push in small increments rather than one large diff held
  locally for the whole session — the other shipwright (or the Admiral)
  can't see or build on work that hasn't been pushed.
- If `git log` shows commits you don't recognize since you last pulled,
  read them before continuing — that's the other shipwright, not drift.

## Auth — different from CC, on purpose

Shipwright CC authenticates via `ANTHROPIC_API_KEY` from the strongbox
(unattended, provisioned like every other credential on the ship). Codex
stays on the Admiral's own ChatGPT/OpenAI subscription via `codex login`
instead — a deliberate choice recorded in `docs/agentic-engineering-plan.md`
§4, not an oversight. That means this window still needs a one-time manual
login per ship (`codex login`, or `codex login --device-auth` since this is
a headless SSH session with no local browser) before it's usable — `sail`
prints a reminder in this window if it detects you're not logged in yet.
