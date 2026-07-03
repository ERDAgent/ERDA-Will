# How this system relates to git and GitHub

Direct answer to the question that prompted this doc: **no, the system never creates
new GitHub repos.** `charter` either clones an *existing* repo, or creates a repo with
no GitHub involvement at all. Everything below explains exactly what does happen,
verified against the real ship (2026-07-02), not assumed from the design doc.

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

## What `charter` actually does to git

```bash
charter <name> <git-url>   # existing repo
charter <name>              # local-only, no remote at all
```

**With a URL**: `git clone --bare <url> .hold.git`. This requires the repo to already
exist — `charter` has no GitHub API integration, no `gh repo create`, nothing that
mints a new remote repo. Verified directly: chartering against a real GitHub URL
produces a `.hold.git` whose config has `origin` set to exactly that URL, for both
fetch *and* push:

```
[remote "origin"]
	url = https://github.com/ERDAgent/ERDA-Will.git
```

**Without a URL**: `git init --bare -b main .hold.git`, then a single empty "lay the
keel" commit pushed in locally from a scratch temp repo. There is no `origin` at all
— nothing to push to, nothing to fetch from. This charter's entire git history will
only ever exist on this one ship's disk unless someone manually adds a remote later.

Either way, the **berths** (worktrees) inherit whatever remote config the hold has —
confirmed: `git -C berths/home-port remote -v` shows the same `origin` as the hold
itself, when one exists.

## The part that's easy to assume and would be wrong: nothing pushes to GitHub

Even when a charter's hold *does* have a real `origin` pointing at GitHub, **nothing
in this system currently pushes to it.** Checked directly, not inferred:

- `crew.md`'s hard limits, verbatim: *"Never merge, never push, never switch
  branches, never leave your berth."* Crew commits stay on their own branch inside
  the hold, full stop.
- `captain.md`'s INTEGRATE step says "merge accepted branches into `integration`
  (dry dock)... fast-forward `main`. Worktrees pruned, log updated." — this is
  entirely a local operation *within* `.hold.git`. It says nothing about `origin`,
  and there's no `git push` anywhere in `ship/bin/*` except one line in `charter`
  itself (pushing the bootstrap empty commit into a *local-only* hold that has no
  remote to begin with).

So a fully shipped, integrated, tested mission lands on that charter's **local**
`main` — inside `.hold.git` on the ship — and getting it onto GitHub proper is a
manual step nobody's automated yet: `git -C ~/fleet/<name>/.hold.git push origin
main`, run by you.

**And even that manual push might not work yet, today.** Checked directly on a real
ship: no `gh` CLI installed, no `credential.helper` configured beyond the OS default,
no stored `~/.git-credentials`. Anonymous HTTPS is enough to *clone/fetch* a public
repo (which is all `charter` needs), but *pushing* needs real authentication that
doesn't exist on the ship yet. If/when auto-push gets built, it'll need a real
GitHub credential wired in — almost certainly via the strongbox, the same mechanism
`DEEPINFRA_API_KEY` already uses (see `strongbox/README.md`), and for any repo
`ERDAgent` doesn't already own outright, that account will need to actually be
granted push access (collaborator, org membership, or a fork+PR flow) — none of which
is set up yet.

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
   `agentic@ericrose.dev`, the same session this doc's sibling files were committed.
   `ERDA-Will` itself has no repo-local override; it inherits that host's global
   config, verified directly (no `user.name`/`user.email` in this repo's local git
   config).

Practical consequence: **every commit this system produces, anywhere, is currently
authored as ERDAgent** — crew work, Captain-integrated missions, and Claude Code's own
shipwright commits to the shipyard repo alike. That's the deliberate point (keeping
automated/agent work visually separate from your own `EricRoseDev`-authored commits in
git log/blame) — but it means: if a charter ever points at a repo `ERDAgent` doesn't
have write access to, commits will still happen locally on the ship without any error
(git doesn't need push access to commit), but a manual push to `origin` will fail with
a permission error until `ERDAgent` is added as a collaborator on that specific repo.

## How this scales across multiple charters

Each charter's hold is completely independent — one ship can carry a charter cloned
from an `ERDAgent`-owned repo, another cloned from an `EricRoseDev`-owned repo (if
`ERDAgent` has collaborator access), a local-only charter with no remote at all, and a
client's charter cloned from a repo neither personal account owns, all at once, with
zero relationship between them beyond living on the same disk. There is no
shipyard-wide GitHub org requirement, no monorepo assumption — `charter <name>
<any-git-url>` is genuinely independent per project.

## Summary

| Question | Answer |
|---|---|
| Does `charter` create new GitHub repos? | No — clones an existing URL, or goes fully local with no remote |
| Does the system push anything to GitHub automatically? | No — crew is forbidden from pushing; the Captain's integrate step is local-only |
| Could it push even if something tried to? | Not yet — no GitHub write credentials exist on the ship today |
| Who authors commits? | `ERDAgent` / `agentic@ericrose.dev`, set globally per-ship by `fitout.sh` (D13) — same identity used on your Windows host by your own separate, manual configuration |
| Is one GitHub account required for everything? | No — each charter's remote (if any) is independent; `ERDAgent` just needs write access to whichever specific repos you eventually want it pushing to |
