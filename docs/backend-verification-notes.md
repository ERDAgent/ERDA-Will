# Backend-switching verification spike — findings

Verified live on this ship (`claude` 2.1.205, `codex-cli` 0.144.0, both
installed via `fitout.sh`) before writing any registry launch command, per
this project's "ground the design in facts" rule. The multi-agent-tooling
research done during planning was web-search-based and partially wrong on
specifics (confirmed accurate: `--bg`/`-w` exist; NOT independently
confirmed: exact Codex `[agents]` config surface — see below); this document
supersedes that research wherever they disagree.

## Claude Code (`claude --help`, `claude auth --help`, `claude agents --help`)

- `--bg, --background` — real flag: start the session as a background agent,
  return immediately, manage via `claude agents`.
- `-w, --worktree [name]` — real flag: create a new git worktree for this
  session. No flag to point it at a worktree `berth`/`muster` already
  created, and no documented output telling a caller exactly where it put
  the worktree — **not used by delegate-claude** for this reason; `berth
  create` (plain `git worktree add`) remains the one thing that creates the
  worktree, regardless of backend, so Quartermaster keeps finding it the
  same way every time. `--bg`/`-w` stay available as a possible future
  enhancement, not required for v1.
- `claude agents --json` — lists active background sessions as JSON, scriptable.
- Headless/scriptable surface already proven by Shipwright CC and reused
  as-is: `-p/--print`, `--append-system-prompt <text>` (inline text, not a
  path — already known), `--output-format {text,json,stream-json}`,
  `--model`, `--effort`, `--allowedTools`/`--disallowedTools`,
  `--permission-mode`, `--max-budget-usd`, `--json-schema`,
  `--no-session-persistence`, `--fallback-model` (built-in same-provider
  model fallback on overload, only with `--print` — orthogonal to this
  feature's cross-*backend* fallback, not a substitute for it).
- **Auth — two real options, not one:**
  - `ANTHROPIC_API_KEY` — pay-per-token API billing. Already wired for
    Shipwright CC (D17), lives in `shipwright.env.age`.
  - `CLAUDE_CODE_OAUTH_TOKEN` — a **long-lived, subscription-backed** token
    minted once via `claude setup-token` (confirmed by grepping the shipped
    binary's own strings: `"Long-lived tokens (from \`claude setup-token\`
    or CLAUDE_CODE_OAUTH_TOKEN) are limited to inference-only for security
    reasons."`). This is the credential that actually rides the Admiral's
    Claude subscription instead of metered billing — the whole point of
    this feature — so it's the **preferred** auth for backend=`claude`
    roles, with `ANTHROPIC_API_KEY` as a documented fallback for anyone who'd
    rather pay per token. `claude setup-token` opens an interactive OAuth
    flow — completing it is a one-time manual step for the Admiral (same
    category as `codex login`), not something this spike could complete
    without real account credentials.
  - **Unverified, flagged for a live follow-up**: whether `CLAUDE_CODE_OAUTH_TOKEN`
    auth is compatible with `--bg`/`-w` (moot for v1 since delegate-claude
    doesn't use them) or with any restricted permission mode Quartermaster/
    First Mate might want. Not a blocker since v1's `-p` headless path is
    the same mechanism already proven for Shipwright CC.
- **Rate-limit signal text — confirmed from the shipped binary's own
  embedded strings** (not guessed): `"usage limit reached"`, `"rate
  limited"`, `"credit balance too low"`, `"overloaded"`, `"529"`, `"401"`.
  Also confirmed a structured `rate_limits` object exists in some API/status
  surface with `five_hour`/`seven_day` fields (Claude.ai subscription usage
  windows) — not wired into anything this spike touched, noted for a
  possible future proactive-check enhancement, out of scope for the
  reactive-only design already decided.
- **Session logs — confirmed on-disk, independent of the TUI screen**: every
  session writes a JSONL transcript to
  `~/.claude/projects/<cwd-with-slashes-as-dashes>/<session-id>.jsonl` (this
  very session's own transcript file is one). `backend-watch` can tail this
  real file directly — no `script`-captured-pty fallback needed for Claude.

## Codex (`codex --help`, `codex exec --help`)

- `codex exec [PROMPT]` — confirmed mature, synchronous, scriptable:
  `--json` (JSONL event stream), `--output-schema <file>`, `-C/--cd <dir>`,
  `-o/--output-last-message <file>`, `-c key=value` (dotted-path TOML
  overrides), `--sandbox`, `codex exec resume`. Reads stdin as the prompt if
  none given as an argument.
- No dedicated system-prompt flag in `--help` (confirmed absent, matching
  the existing Shipwright CO comment) — **AGENTS.md-in-cwd remains the
  mechanism**, same as Shipwright CO already uses: `delegate-codex` writes
  `crew.md`'s content to `$BERTH/AGENTS.md` before running `codex exec`
  from inside the berth.
- **No `[agents]`/Subagents CLI surface found** in `codex --help`/`codex
  exec --help` for this installed version (0.144.0) — the web-research
  claim of a native `max_threads`/`max_depth` Subagents config was **not
  independently confirmed** here (may be config-file-only, or a
  newer/different version/product surface than what's installed). Doesn't
  block anything: `delegate-codex`'s design never depended on it — `berth
  create` handles worktree isolation, `codex exec` handles the headless run,
  both already proven.
- Auth — confirmed subscription-based, already working on this ship
  (`codex login status` → "Logged in using ChatGPT"). `--with-api-key`/
  `--with-access-token` (stdin-piped) exist as alternatives but aren't used —
  matches the existing, deliberate "Codex stays on subscription login"
  decision.
- **Rate-limit signal text — confirmed from the shipped binary's own
  strings**: a literal check `"429" in msg or "rate limit" in msg or "too
  many requests" in msg` — lowercase substring matching on exactly these
  three phrases.
- **Session logs — confirmed on-disk**: `~/.codex/sessions/YYYY/MM/DD/
  rollout-<timestamp>-<uuid>.jsonl`, plus a lighter `~/.codex/history.jsonl`
  (prompt text only). `backend-watch` tails the rollout file directly, same
  as Claude — no pty capture needed for either backend.

## Live-tested finding (during build, not the original spike): bubblewrap
## sandbox is broken for `--sandbox workspace-write` on this ship

A real `delegate-codex` run against a trivial write-a-report order failed
with `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted` --
Codex's bundled `bubblewrap` sandbox helper can't set up its network
namespace inside this ship's own VM (nested virtualization capability
restriction, not a shipyard bug; `apt`'s own `bubblewrap` package isn't
installed either, and a system copy likely hits the same kernel-capability
wall). `--sandbox read-only` was tested separately and works fine (no
network-namespace setup needed for read-only mode) -- the failure is
specific to `workspace-write`'s sandboxing, i.e. exactly crew's case.

Resolution: crew's `codex exec` launch command uses
`--dangerously-bypass-approvals-and-sandbox` instead of
`--sandbox workspace-write --add-dir <bus>`. This matches the trust level
already accepted for `claude`'s crew launch (`--permission-mode
bypassPermissions`) and for `pi`'s crew launch (no sandboxing at all,
today's default) -- crew already operates inside an isolated git worktree
berth as its trust boundary regardless of backend, and Quartermaster gates
the *result* afterward rather than any backend policing individual actions
during the run. Not a new risk class introduced by this feature. First
Mate/Quartermaster's review commands stay on `--sandbox read-only` (no
writes needed, confirmed working) -- only crew's write-needing case hits
this at all.

If a future ship environment supports bubblewrap's network sandboxing
properly (e.g. a Multipass/OVHcloud host without this nested-virt
restriction), revisit whether `--sandbox workspace-write --add-dir` is
preferable to the full bypass -- flagged here rather than assumed away.

## Net effect on the registry / delegate capsules

- Both `delegate-claude` and `delegate-codex` are plain, synchronous,
  foreground headless calls (`claude -p ...` / `codex exec ...`) run from
  inside a `berth`-created worktree — the "preferred" shape from the plan,
  not the async/vendor-native-subagent fallback. No stretch-goal path
  needed for v1.
- `backend-watch` tails a real on-disk log file for both backends — no
  `script`-captured pty needed in either case.
- `rate_limit_patterns` in `ship/backends.json`:
  - `claude`: `["usage limit reached", "rate limited", "credit balance too low", "overloaded"]`
  - `codex`: `["429", "rate limit", "too many requests"]`
- Auth: `claude` backend tries `CLAUDE_CODE_OAUTH_TOKEN` first (subscription,
  preferred), falls back to `ANTHROPIC_API_KEY` (pay-per-token) if the
  former isn't set; `codex` backend uses `codex login status`, unchanged
  from Shipwright CO's existing idiom.
