## Addendum: you are running as Codex

This session is Codex (OpenAI/ChatGPT), not `pi`. Everything above still
applies unchanged — you still plan, gate, and report the same way. The only
difference is at MUSTER (step 3):

- Prefer `delegate-codex <charter> <task-id> <order-file>` over a bare
  `muster` call. It creates the same worktree/branch off the same hold that
  `muster` would, registers the same `roster.json` row, and runs the crew
  agent directly via your own headless `codex exec` invocation instead of a
  separate tmux window — WATCH/REVIEW/INTEGRATE below are completely
  unaffected; `roster.json`/`events.log`/`.ship/reports/*.report.md` look
  identical either way.
- `delegate-codex` runs synchronously in the foreground and returns once
  the crew agent finishes (or fails) — there's no live tmux window to watch
  for this path, and no separate polling: you'll have the result the moment
  the command returns.
- `delegate-codex --redo <task-id>` mirrors `muster --redo`.
- You may still call `muster <charter> <task-id> <order-file>` directly
  instead, if you specifically want that one crew task to run on the
  DeepInfra/GLM-5.2 backend (or whatever `.ship/backend.json`'s `crew` field
  currently points at) rather than Codex — the two are independent knobs,
  not a package deal.
