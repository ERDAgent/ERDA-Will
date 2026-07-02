# HANDOFF — Shipyard project

**From:** planning session on claude.ai (June–July 2026, Claude Fable 5)
**To:** Claude Code, working in this repo
**Status:** Phase 0 is complete (items 1–4, see §4c, §4d, §4e). DeepInfra wiring is
also done and verified end-to-end with a real crew agent completing real work (see
§4f) — pi → GLM-5.2 via the Trade Winds is no longer the blocker. Repo is public at
https://github.com/ERDAgent/ERDA-Will (flipped from private so keel.yaml can `git
clone` over plain HTTPS with no baked-in credentials — secrets never live in git
anyway, that's what strongbox is for). Strongbox has a real, working
`DEEPINFRA_API_KEY` committed (encrypted; `strongbox/ship.key`, the private half,
stays local — see strongbox/README.md for the per-ship copy step). Next: x86_64
validation, then the pi extension / officer agents.

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

## 4d. Phase 0 items 2–3 done (July 1, 2026) — fitout.sh, keel.yaml, real Multipass validation

Multipass was missing on this host; user installed it via `brew install --cask
multipass` (needed an interactive terminal for the sudo prompt — not scriptable from
this session). Repo was pushed and flipped from private to public so `keel.yaml` can
`git clone` over plain HTTPS with no credentials baked in (user's explicit choice among
several options offered — see the private-repo tradeoff this raised).

Wrote `fitout.sh` and `keel.yaml` from the design doc's specs (§3–4 of
`agentic-engineering-plan.md`), researched the exact install mechanics that weren't
pinned down during planning (Fresh's actual repo is `github.com/sinelaw/fresh`, `.deb`
assets are named `fresh-editor_<ver>-1_<arch>.deb`; fnm's install script is at
`fnm.vercel.app/install`), and validated on a real ARM64 Ubuntu 24.04 Multipass VM
(this host is Apple Silicon — **x86_64 is still untested**, needs a Windows/Hyper-V or
OVHcloud run). Three real bugs surfaced only by actually launching a VM, not by
reading docs:

1. **fnm's actual install directory.** Assumed `~/.fnm` (from a web search that turned
   out to be stale/wrong); on a real fresh Ubuntu 24.04 image with no pre-existing
   `~/.fnm` and no `$XDG_DATA_HOME`, fnm's own installer picks `~/.local/share/fnm`.
   Fixed by mirroring the installer's own directory-selection logic instead of
   hardcoding a path — `fnm: command not found` immediately after "installing fnm"
   was the tell.
2. **PATH never reached anything outside the install shell.** This image's
   `~/.profile` doesn't source `~/.bashrc` (don't assume it does on a minimal cloud
   image), so appending PATH exports to `.bashrc` alone left `pi`/`claude`/`codex`
   unreachable from `ssh`/login shells — and critically, `muster`'s crew windows
   `exec` `.crew-run.sh` directly (§4c), which sources no shell rc file at all, so a
   per-dotfile fix wouldn't have reached the one place that matters most for the
   whole orchestration system to function. Fixed by writing PATH once to
   `/etc/profile.d/shipyard.sh`, sourced by every login shell (ssh, `multipass
   shell`), so tmux and everything it spawns inherits it by ordinary process
   inheritance — no per-tool, per-shell-type patching needed.
3. **`keel.yaml` schema validation.** Multipass's cloud-init passthrough
   re-serializes a quoted `write_files` permissions string like `'0755'` as the bare
   integer `493` — numerically identical (493 decimal *is* 0o755, so `chmod` still
   applied the right mode and the ship provisioned successfully regardless) but fails
   strict schema validation (`cloud-init status --wait` exits 2, "degraded"). Fixed by
   dropping the `permissions:` field and `chmod`-ing explicitly in `runcmd` instead,
   sidestepping the type coercion. `cloud-init status --wait` now exits 0 clean.

Final validated run (`multipass launch 24.04 --cloud-init keel.yaml`, arm64): cloud-init
exits 0; `pi --version`, `opencode --version`, `claude --version`, `codex --version`,
`fresh --version` all succeed from a fresh login shell; a second `fitout.sh` run on the
same ship completes in ~1.75s doing nothing (true idempotency, not just "didn't
crash"). Test VMs destroyed after each run (`multipass delete --purge`) — no ship left
running.

Not built this session (out of scope for items 2–3, called out for item 4 / Phase 2):
the Chartroom Fresh plugin, `scuttlebutt/` theme (only `config.json` with
`check_for_updates: false` exists — created because `fitout.sh`'s telemetry-off
requirement needed real content to symlink, not because the full scuttlebutt/ layer was
in scope), DeepInfra wiring, officer agents.

## 4e. Phase 0 item 4 done (July 1, 2026) — real-ship deck + muster drill with real pi

Launched a fresh, persistent ship (`ship-drill`, arm64 Multipass) with a real SSH key
substituted into `keel.yaml`'s `REPLACE-ME` placeholder (a scratch, uncommitted copy —
the tracked `keel.yaml` still carries the placeholder, same one-manual-step spirit as
the strongbox age key) and drove it entirely over real `ssh eric@<ship-ip>`, not
`multipass exec`, specifically to exercise the actual login/non-login shell paths a
real operator (or an automated caller) would hit.

**Found a fourth real bug, worse than the first three**: `ssh ship 'pi --version'` —
an ordinary non-login SSH command, exactly the shape `ssh host 'command'` always takes
— came back `command not found`, even after §4d's `/etc/profile.d` fix. OpenSSH runs a
supplied command through the login shell *non-login* by default; `/etc/profile.d` is
only sourced by login shells. That's the identical invocation shape to `muster`'s crew
windows, which `exec` `.crew-run.sh` directly with no shell-rc sourcing of any kind —
so the previous fix covered interactive `ssh` sessions and `bash -lc` but silently
missed the one path that actually matters for the orchestration system to run
headlessly. Root-caused and fixed by symlinking the agent CLIs into `/usr/local/bin`
(on every shell's PATH unconditionally — login or not, interactive or not), targeting
fnm's real, stable per-version install directory
(`$FNM_DIR/node-versions/$NODE_LTS/installation/bin`) rather than `command -v`'s
result, which resolves through fnm's ephemeral per-shell "multishell" symlink and goes
stale the moment that shell exits. Verified: `ssh ship 'pi --version'` (and
opencode/claude/codex) all resolve cleanly now, non-login, no tmux or login shell
involved. `/etc/profile.d/shipyard.sh` still stands, narrowed to just making `fnm`
itself usable interactively.

Drill results, all against the real ship (not simulated):
- `charter royal-guest` + `sail royal-guest` (`SHIP_NO_ATTACH=1`, driven over ssh):
  all 7 windows (0–6) alive, correct glyphs (⚓🗺🧭📣⚖🪙⚙ — real UTF-8 rendering on a
  real terminal, not the `SHIP_GLYPHS=0` workaround the macOS drill needed), and pane
  content matches intent per window: bridge shows the berth prompt, chartroom is
  running the *real Fresh editor* rendering `mission.md`, bosun's `watch` loop is live,
  quartermaster shows real `git -C .hold.git` branch/log output, engine-room is running
  real `htop`.
- Second charter (`scratch`) chartered and sailed concurrently — `ship-royal-guest`
  and `ship-scratch` coexist as two independent tmux sessions with zero collision
  (matches the Fleet Board / D8 design intent).
- Wrote two work orders by hand (`T-001` add a README, `T-002` add a `.gitignore`) on
  `scratch`, per the plan's Phase 3 description ("you are the Captain... by hand").
  `muster`'d both with the real `pi` binary (`SHIP_AGENT` unset, so the actual default
  `pi -p`) — no stub. Both crews correctly hit `pi`'s real, expected failure: `No API
  key found for the selected model` (DeepInfra wiring is explicit Phase 2 scope, not
  done yet). Confirmed this is handled exactly as designed, not just "didn't crash":
  `roster.json` shows `status: "failed"` for both tasks, `events.log` has
  `crew-failed ... rc=1` for both, and both crew worktrees are completely clean — no
  partial commits, no dirty state — since `pi` errored before any tool use. `.crew-run.sh`'s
  `set -uo pipefail` (deliberately no `-e`) did its job: let the failure be captured
  and reported rather than aborting the harness.
- Test ship destroyed after the drill (`multipass delete --purge`) — no ship left
  running, matching this session's practice throughout.

**Phase 0 is now complete.** The remaining named gaps are explicitly out of Phase 0's
scope, not overlooked: x86_64 validation (this dev machine is Apple Silicon; needs
Windows/Hyper-V or OVHcloud), DeepInfra wiring (Phase 2 — is the actual blocker for
crew agents completing real work), and the Chartroom Fresh plugin / officer agents
(Phase 5+).

## 4f. DeepInfra wiring done (July 2, 2026) — verified with a real crew agent completing real work

Resolved the model-slug open question directly against DeepInfra's live models API
(`api.deepinfra.com/v1/openai/models`), not a cached doc page: `zai-org/GLM-5.2`, no
separate `[1m]`-context variant. Pulled pi's actual `models.json`/`providers.md` docs
from source (`raw.githubusercontent.com/badlogic/pi-mono`) rather than trust a
summarizer's paraphrase of them, which materially differed on a couple of points.

Built: `ship/pi/models.json` (registers DeepInfra as an `openai-completions` provider,
GLM-5.2 with `thinkingLevelMap` restricted to high/xhigh — matching the verified fact
that this model only supports High/Max reasoning), symlinked into
`~/.pi/agent/models.json` by `fitout.sh`. `muster`'s default `AGENT_CMD` now actually
routes to it (`pi -p --provider deepinfra --model zai-org/GLM-5.2 --thinking high`,
still overridable via `SHIP_AGENT`).

Generated the ship's `age` keypair locally (`strongbox/ship.key`, gitignored) and
walked Eric through getting `DEEPINFRA_API_KEY` into the encrypted strongbox — this
took two failed attempts worth recording since they'll recur for any future secret:
1. First attempt silently encrypted an **empty** value. Root cause: Eric's login shell
   is zsh, and zsh's `read -p` flag means "read from a coprocess," not "show this
   prompt text" like bash — the `read` errored, left the variable empty, and nothing
   downstream checked. Numeric proof this even happened at all only came from checking
   decrypted byte-length, not just key presence — checking a secret's *name* decrypts
   without checking it has a non-empty *value* is not real verification.
2. Second attempt hit an `age` flag mistake on my end (`-f` means "recipients file" in
   `age`, not "force overwrite" — unrelated, invalid file-path handling error).
   Fixed both by wrapping the capture in an explicit `bash -c '...'` (shell-agnostic
   regardless of the operator's login shell) and dropping the bad flag.

Then found and fixed three more real bugs, each only surfacing by actually running a
crew agent against a real model — none were guessable from docs:

1. **422 from DeepInfra**: `messages.0 ... Input should be <ChatMessageRole.TOOL:
   'tool'>` — a deeply confusing error that has nothing to do with tool messages. Root
   cause: pi defaults to sending the system prompt with `role: "developer"` for
   reasoning-capable models (an OpenAI o1-style convention); DeepInfra's endpoint
   doesn't recognize that role, so its Pydantic message-type union match fails for
   every variant, and the reported error is just whichever variant was checked last.
   Fixed: `compat.supportsDeveloperRole: false` in `models.json` — exactly the fix
   pi's own docs describe for this class of provider, just not obvious from the error
   text alone.
2. **`muster` never actually loaded the strongbox.** `.crew-run.sh` ran the agent
   directly with no `unlock` call anywhere, so `DEEPINFRA_API_KEY` would never reach
   `pi` in a real headless crew window even with everything else correctly wired — an
   oversight that (2) below made worse: `unlock` itself wasn't even on `PATH` yet.
   Fixed: `.crew-run.sh` now calls `unlock` (no-op if absent) before invoking the
   agent; `ship/bin/*` (charter/sail/muster/unlock) are now symlinked into
   `/usr/local/bin` by `fitout.sh`, same rationale as the agent-CLI symlinks in §4e.
3. **`crew.md`'s role contract was never actually passed to `pi`.** `muster` only ever
   sent the order text as the prompt — pi had no idea it was supposed to commit or
   write a report. Fixed with `--append-system-prompt ship/prompts/crew.md`, which
   needed `muster` to resolve its own real location for the first time (`readlink -f
   "${BASH_SOURCE[0]}"`, not `dirname` alone — muster is invoked through the
   `/usr/local/bin` symlink, and `dirname` on an unresolved symlink path returns the
   wrong directory).

With all of the above fixed, the first genuinely successful crew run also surfaced a
fourth bug: `crew.md` says "write `.ship/reports/<TASK-ID>.report.md`" without saying
relative to what. pi's cwd is the berth, so — completely reasonably — it created a
stray `.ship/` *inside* the berth and wrote the report there, instead of the charter's
real bus one level up. This is a prompt-wording bug, not an agent mistake: a relative
path is inherently ambiguous once cwd differs from what the prose writer had in mind.
Fixed by having `muster` append the exact absolute report path to each order at muster
time (it already knows `$BUS` and `$TASK`), rather than trusting relative-path
inference that would also break if the berths/charter nesting ever changed.

**Final verified run**, real ship, real credentials, real model, no stubs anywhere:
`charter` → `sail` → hand-written order → `muster` → `pi`/GLM-5.2 reads the order,
writes `hello.txt` with the exact required content, commits it as `feat: add
hello.txt` (crew.md's commit-style convention, followed correctly), writes a properly
structured report to the correct path, exits 0. `roster.json` shows `status: "done"`.
Merged through the full pipeline for the first time with genuine content: dry-dock
(`integration`) merge → fast-forward `home-port` (`main`) → `hello.txt` present and
correct in the home-port checkout. Test ship destroyed after (`multipass delete
--purge`) — no ship left running.

Resolves HANDOFF open question #5 (exact DeepInfra model slug). Open question #4
(whether Quartermaster review ever routes to a stronger model) is now answerable in
principle — `models.json` supports multiple providers/models simultaneously — but not
decided; still a Phase 3 drill question, not a Phase-0/2 one.

## 4g. x86_64 validation done (July 2, 2026) — real Windows/Hyper-V ship, two more bugs found and fixed

Ran on the Windows machine Eric set aside for this (Windows 11 Pro, admin rights,
Hyper-V already enabled). Installed Multipass via `winget install --id
Canonical.Multipass` (not available before this session); confirmed `multipass get
local.driver` → `hyperv`, matching D1's intent. First `multipass launch` failed with
an image hash mismatch (`Verifying image` step) — a corrupted/partial download in
`C:\ProgramData\Multipass\cache\vault\images\`, not a repo issue; deleting that cache
subfolder and relaunching fixed it immediately.

**Methodology note confirmed from §4e, worth restating**: `multipass exec` on this
Windows/Hyper-V backend is unreliable for anything beyond trivial one-shot commands —
a `bash -lc` login-shell invocation through it hung the *client* indefinitely (`timeout
20` on the `multipass exec` call itself expired) even though the guest-side command
had already completed in-session (confirmed by wrapping the same command in a guest-
side `timeout`, which returned instantly). Root cause not pinned down (likely a
PTY/exec-channel quirk of Multipass's Hyper-V backend, not a keel/fitout bug) — not
investigated further since §4e already established the right tool for this class of
check is real `ssh eric@<ship-ip>`, which is unaffected and was used for the rest of
this drill.

Validated via SSH against a real x86_64 (amd64) Ubuntu 24.04 Multipass/Hyper-V VM,
same drill shape as §4e: `cloud-init status --wait` exits 0; all five agent CLIs
(`pi`, `opencode`, `claude`, `codex`, `fresh`) resolve over plain non-login `ssh host
'cmd'`; a second `fitout.sh` run completes in ~1.9s doing nothing (idempotent, matches
ARM64's ~1.75s); `charter` → `sail` (`SHIP_NO_ATTACH=1`) → `muster` (stub agent) →
dry-dock (`integration`) → fast-forward `main` all worked, including the info/exclude
idempotency guard and roster locking from §4c. UTF-8 glyph window names rendered
correctly (`⚓🗺🧭📣⚖🪙⚙⚒`), same as the real-terminal ARM64 run.

Two real bugs found and fixed, both from the class "only surfaces when actually
exercised, not from reading the script":

1. **`fd` unreachable from any non-login context.** `fitout.sh` symlinks `fdfind` to
   `~/.local/bin/fd`, but `~/.local/bin` only reaches PATH via `~/.profile`, which
   login shells source and non-login ones (plain `ssh host 'fd ...'`, and critically
   `muster`'s crew windows, which `exec` `.crew-run.sh` directly with no shell-rc
   sourcing at all) don't — identical shape to the agent-CLI PATH bugs in §4d/§4e,
   just never hit before because nothing had exercised `fd` specifically in a
   non-login context. Fixed the same way: also symlink `fdfind` into
   `/usr/local/bin/fd`.
2. **`muster` corrupted its own generated crew-run script when `AGENT_CMD` contained a
   literal `"`.** `$AGENT_CMD` is spliced into the `.crew-run.sh` heredoc twice: once
   raw as the actual invocation (correct and necessary — this is what lets an operator
   override `SHIP_AGENT` with a command that itself needs internal quoting), and once
   inside an already-double-quoted diagnostic `echo` line. The real default
   `AGENT_CMD` (`pi -p --provider deepinfra ...`) never contains a `"`, so this never
   surfaced in any prior drill. It surfaced immediately when this session's x86_64
   regression drill used a compound stub (`SHIP_AGENT='bash -c "echo ...; git commit
   -q -m stub"'`, deliberately close in shape to a real multi-step agent action): the
   embedded `"` prematurely closed the echo's quoting, which split the rest of that
   line into several unquoted commands (an errant `touch`/`git add`/`git commit` ran
   *from the diagnostic line*, with a garbled commit message), and the real invocation
   line then failed on "nothing to commit" — reported as `status: "failed", rc=1` for
   a completely different reason than the actual defect. Root-caused by reading the
   literal generated `.crew-run.sh` byte-for-byte, not by reasoning about muster's
   source. Fixed by rendering the diagnostic line with `printf '%s' $(printf '%q'
   "$AGENT_CMD")` instead of raw interpolation inside a quoted string; the real
   invocation line is untouched. Re-verified: stub run now reports `status: "done",
   rc=0`, single correct commit, and the diagnostic line displays the full original
   command correctly.

Both fixes committed after a manual `shellcheck -x` pass (no shellcheck on this host by
default; spun up a throwaway scratch VM just to run it, then destroyed it) — clean, no
findings on either changed file. Test VMs (`ship-x86-drill`, `shellcheck-scratch`)
destroyed after use, no ship left running, matching every prior session's practice.

**Not investigated, out of scope for this item**: git commit identity. A completely
fresh ship (and, separately, this Windows dev host) has no `git config --global
user.name/user.email` set anywhere, so a stub crew agent's `git commit` fails with
"Author identity unknown" until an operator sets one. `charter`'s own bootstrap commit
already sidesteps this with an explicit `-c user.name=shipyard -c
user.email=shipyard@local`, but crew agents commit via plain `git commit`, relying on
whatever identity the ship happens to have. Every prior drill's dev machine apparently
already had a global identity set, which is why this never surfaced before. Worth a
decision before scaling up real crew usage: does `fitout.sh` set a default identity
(and if so, what should commits from GLM-5.2 crew look like — "eric", "shipyard",
something crew/task-specific?), or is this explicitly an operator setup step to
document in `HANDOFF.md`/`charter.md`? Not decided; flagging rather than guessing at a
default.

Resolves HANDOFF §5 item 1 (x86_64 validation).

## 5. NEXT TASK — Phase 2+

Phase 0 (lay the keel) is done — see §4c, §4d, §4e. DeepInfra wiring is done — see
§4f. x86_64 validation is done — see §4g. Both ARM64 (Multipass/macOS) and x86_64
(Multipass/Windows-Hyper-V) are now confirmed working; OVHcloud (the third harbor)
has not been tried yet.

Next up, in rough priority order:

1. Move aboard: install Claude Code on a real ship and work as shipwright from
   there — Phase 2 onward assumes you live on the ship, per the original Phase 0 exit
   criterion. DeepInfra being wired removes the last blocker for this.
2. pi extension (wraps `muster` for the Captain), officer agents, Chartroom Fresh
   plugin — Phase 5+, not before the above.
3. Worth a look before scaling up real usage: two independent sessions now (§4f, §4g)
   have found a real, previously-invisible bug on the very first drill that actually
   exercised a new code path — a good reminder that `ship/prompts/*.md` (captain.md,
   order-template.md haven't been drilled with a real agent at all yet) and the
   git-identity question above (§4g) are both live risks, not resolved by inspection.
4. OVHcloud harbor (D2) is still completely untried — `keel.yaml` is written to be
   portable to it (native cloud-init, OpenStack-backed) but has only ever run under
   Multipass so far.

## 6. Open questions (decide during Phase 3 drills, not now)

1. Crew revision loops: fresh agent per revision vs resumed session — start fresh-per-revision.
2. Long missions on the VPS ship: does the Bosun become a daemon that pages Eric? (Forced by Phase 6.)
3. Real task-size ceiling for GLM-5.2 reliability.
4. Whether Quartermaster reviews ever route to a stronger model via pi's multi-provider support. (`models.json` can hold multiple providers/models at once — mechanically possible now per §4f — but not decided.)
5. ~~Exact DeepInfra model slug / `[1m]` variant — verify at Phase 2 wiring time.~~ **Resolved — see §4f: `zai-org/GLM-5.2`, no separate `[1m]` variant.**

## 7. Session log

- v1: initial plan (VM strategy, tooling, orchestration, worktrees, phases).
- v2: OVHcloud; skeuomorphic naming pass (manifest); pi-primary decision; Purser added.
- v3: Fresh editor confirmed (Scuttlebutt); window-per-role deck; charters/voyages/fleet model (§6.5); deck-layout.svg + fleet mermaid produced; this handoff created.
- v4 (Claude Code, July 1–2, 2026): extracted `shipyard-handoff.zip` into the repo; Phase 0 item 1 (shellcheck + hardening + regression drill) done — see §4c. Repo committed and pushed public. Multipass installed. Phase 0 items 2–3 (`fitout.sh`, `keel.yaml`) built and validated on a real ARM64 Multipass ship, three real bugs found and fixed (fnm install dir, PATH not reaching login shells / muster's crew scripts, cloud-init schema type coercion) — see §4d. Phase 0 item 4 done: real-ship deck + concurrent-decks + muster-with-real-`pi` drill over actual `ssh`, found and fixed a fourth, more serious PATH bug (`ssh ship 'command'` is non-login by default — same shape as muster's crew scripts — so the §4d fix silently missed the case that mattered most; fixed with `/usr/local/bin` symlinks to fnm's stable install dir). Phase 0 is complete — see §4e. DeepInfra wiring done and verified with a real crew agent completing real work end-to-end (model slug, `models.json`, strongbox populated, four more real bugs found and fixed: DeepInfra's 422 on the `developer` role, `muster` never loading the strongbox, `crew.md` never reaching `pi`, and the ambiguous report path) — see §4f.
- v5 (Claude Code, July 2, 2026): x86_64 validation done on Eric's Windows/Hyper-V machine — Multipass installed via winget, real amd64 Ubuntu 24.04 ship drilled end-to-end over SSH (cloud-init, agent-CLI PATH, fitout idempotency, charter/sail/muster/dry-dock). Two more real bugs found and fixed: `fd` unreachable from non-login shells (same class as §4d/§4e's PATH bugs, just never exercised for `fd` before), and `muster` corrupting its own generated crew-run script when `SHIP_AGENT` contains a literal `"` (diagnostic echo line's quoting collided with the interpolated value; real invocation line was unaffected). Confirmed `multipass exec` is unreliable for login-shell checks on this Hyper-V backend (client hangs even though the guest command completes) — real `ssh` remains the right tool, per §4e. Flagged, not fixed: no ship (or this dev host) has a default git identity, so crew-agent commits fail until an operator sets one — needs a decision, not a guess. See §4g.
