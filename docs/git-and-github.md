# How this system relates to git and GitHub

Direct answer to the question that prompted this doc, updated as the system has grown
real GitHub integration since it was first written: **as of `captain charter` (July 3,
2026), the system *does* create new GitHub repos when you don't give it one — and,
separately, the Captain now pushes integrated missions back to GitHub automatically.**
Neither was true when this doc was first written; both are now, verified against the
real ship, not assumed from a design doc. Read on for exactly what happens and what
still doesn't.

## The three layers of git in this system

1. **The shipyard itself** (`ERDA-Will`, this repo) — infrastructure, not a charter.
   Lives on GitHub under the `ERDAgent` account/org. `keel.yaml` clones it onto a ship
   at provisioning time (plain HTTPS, public repo, no credentials needed for that
   clone). Claude Code's work on this repo (including this document) happens directly
   against this clone from whatever host is running Claude Code — today that's your
   Windows machine, using **its own, separately-configured** git identity (see
   "Identity" below) — not through the charter/crew system at all.
2. **Charters** — one per project, under `~/fleet/<name>/` on a ship. This is where
   your question actually lives; see next section.
3. **Berths** — git worktrees inside a charter's hold, one per crew task. Not
   independent repos; they share the hold's object store and (usually) its remote
   config.

## What `charter` (or `captain charter`) actually does to git

```bash
captain charter <name> <git-url>   # clone an existing repo
captain charter <name>             # no url: create (or reuse) a private GitHub repo
captain charter <name> --local     # explicitly local-only, no remote at all
```

**With a URL**: `git clone --bare <url> .hold.git`, same as always. Requires the repo
to already exist. Verified: `.hold.git`'s config gets `origin` set to exactly that
URL, for both fetch *and* push.

**No URL, no `--local`** (the new default, since `captain charter` was added): checks
`gh repo view ERDAgent/<name>` first — if that repo already exists, uses it; if not,
tries `gh repo create ERDAgent/<name> --private`. Either way the result feeds into the
same `git clone --bare` path above, so `origin` ends up set exactly like the
existing-URL case. **This needs `gh` authenticated with repo-*creation* permission** —
broader than the Contents-R/W-on-specific-repos scope the strongbox's `GH_TOKEN` was
originally minted with (D14). Verified directly against the real ship: the original
scope gets `Resource not accessible by personal access token (createRepository)` from
`gh repo create` — a fine-grained PAT needs "All repositories" access plus
`Administration: Read and write` to create new repos at all, which is a meaningfully
bigger grant than the original minimal, push-only scope. `charter` doesn't fail hard
on this — it prints exactly that explanation and falls back to a local-only charter,
so an operator without the broader scope configured still gets a working charter, just
without the auto-create convenience.

**`--local`**: `git init --bare -b main .hold.git`, then a single empty "lay the keel"
commit pushed in locally from a scratch temp repo — no `origin` at all, no GitHub
involvement whatsoever, exactly the original (pre-`captain charter`) local-only
behavior, now opt-in rather than the default when no URL is given.

Either way, the **berths** (worktrees) inherit whatever remote config the hold has —
confirmed: `git -C berths/home-port remote -v` shows the same `origin` as the hold
itself, when one exists.

## Does anything push to GitHub automatically? Yes, now — the Captain does

This flipped since the doc was first written. As of the `gh-captain-access` patch
(D14/D15) and Eric's push-on-integrate policy decision, `captain.md`'s INTEGRATE step
now explicitly pushes both `integration` and `main` to `origin` after a mission's
dry-dock tests pass and `main` fast-forwards — when the hold has a real `origin`
(local-only charters skip this, not an error). Verified end-to-end: a real push from
the bridge, authenticated via the credential helper with no interactive prompt,
succeeded against a disposable test branch (not this repo's actual history).

What's still true, unchanged: **crew never pushes.** `crew.md`'s hard limits,
verbatim: *"Never merge, never push, never switch branches, never leave your berth."*
This is also a structural guarantee, not just a prompt rule — crew windows only ever
load the strongbox's *crew* compartment (plain `unlock`, via `muster`'s
`.crew-run.sh`), which never contains `GH_TOKEN`. Only the bridge (the Captain) loads
`unlock captain`, which does. Verified with a real negative test: a crew-scope shell
attempting `git push` fails cleanly (`could not read Username ... terminal prompts
disabled`) rather than succeeding or hanging.

**GitHub write auth exists now, scoped narrowly on purpose.** `gh` is installed on
every ship (D14), and the git credential helper for `github.com`/`gist.github.com` is
wired to `gh auth git-credential`, reading `$GH_TOKEN` from whichever strongbox
compartment was unlocked. No `gh auth login` state is ever written to disk — the token
lives only in `strongbox/captain.env.age`, encrypted, loaded per-session.

## Identity: where "ERDAgent" actually comes from

There are **two separate places** this gets configured, not one — they currently
happen to agree because you set them to agree, not because one derives from the
other:

1. **On every ship**, `fitout.sh` sets `git config --global user.name/email` to
   `ERDAgent` / `agentic@ericrose.dev` unconditionally (see `HANDOFF.md` D13). This
   applies to *every* commit made anywhere on that ship — any charter, any crew agent,
   any manual commit you make while SSH'd in as `eric`. There's no per-charter
   override built in; it's one identity for the whole ship.
2. **On your Windows host** (or any machine where Claude Code works on `ERDA-Will`
   directly, outside the charter system), git identity is whatever's configured
   locally on that machine — you set it globally yourself, to the same `ERDAgent` /
   `agentic@ericrose.dev`. `ERDA-Will` itself has no repo-local override; it inherits
   that host's global config.

Practical consequence: **every commit and every push this system produces, anywhere,
is authored/attributed as ERDAgent** — crew work, Captain-integrated missions and
pushes, auto-created repos, and Claude Code's own shipwright commits to the shipyard
repo alike. That's the deliberate point (keeping automated/agent work visually
separate from your own `EricRoseDev`-authored commits in git log/blame). For a charter
pointing at a repo `ERDAgent` doesn't own or have collaborator access to, `git clone`
and local commits still work fine, but both `charter`'s auto-create and the Captain's
auto-push will fail with a clear permissions error rather than silently doing nothing
or guessing at different credentials.

## How this scales across multiple charters

Each charter's hold is completely independent — one ship can carry a charter whose
repo `captain charter` just created, another cloned from a pre-existing
`ERDAgent`-owned repo, another from an `EricRoseDev`-owned repo (if `ERDAgent` has
collaborator access), a local-only charter with no remote at all, and a client's
charter cloned from a repo neither personal account owns, all at once, with zero
relationship between them beyond living on the same disk. There is no shipyard-wide
GitHub org requirement, no monorepo assumption.

## Summary

| Question | Answer |
|---|---|
| Does `captain charter` create new GitHub repos? | **Yes**, by default, when no `git-url` and no `--local` — private, under ERDAgent, reusing one if it already exists. Needs a broader PAT scope than the original push-only one; falls back to local-only with a clear message if that's not configured. |
| Does the system push anything to GitHub automatically? | **Yes**, now — the Captain pushes `integration` and `main` on every mission's INTEGRATE step, when the charter has a real `origin`. |
| Does crew ever push? | No — structurally can't; crew-scope shells never hold `GH_TOKEN` at all. |
| Who authors commits and pushes? | `ERDAgent` / `agentic@ericrose.dev`, set globally per-ship by `fitout.sh` (D13) — same identity used on your Windows host by your own separate, manual configuration |
| Is one GitHub account required for everything? | No — each charter's remote (if any) is independent; `ERDAgent` just needs the right permissions (creation and/or write) for whichever specific repos are in play |
