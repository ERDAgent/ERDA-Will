# The Ship, by hand — Multipass cheatsheet

Everything in this file is a plain `multipass`/`ssh` command. No Claude Code, no
`ship/bin/*` helper required — this is the manual reference for deploying, using, and
destroying the Ship on your own, on either Harbor (macOS or Windows). Verified against
Multipass 1.16.3 on Windows/Hyper-V (2026-07-02); the macOS/Multipass driver differs
(HyperKit or QEMU, not Hyper-V) but the `multipass` command surface below is the same
client CLI on both.

**Shell note**: `multipass ...` and `ssh ...`/`scp ...` invocations are identical
regardless of shell — Windows OpenSSH does its own `~` expansion, so those work
verbatim in PowerShell too. Only the *scripting glue* around them (setting a variable,
substituting text in a file, redirecting output) differs by shell, so those few steps
below are given twice: **Bash** (macOS/Linux/git-bash) and **PowerShell** (Windows
native — this is Eric's primary shell on the Windows Harbor, confirmed 2026-07-02).
Pick the block matching whatever's actually running — mixing bash syntax into a
PowerShell prompt (or vice versa) is what caused the very first attempt at this
section to fail.

Command reference for anything not covered here: `multipass help <command>`.

**`erda` — the friendly command prefix.** Once installed (§0), `erda <command> [ship]`
covers everything in this file short of one-off/advanced operations (snapshots,
file transfer): `christen`, `board` (connect, deploying + unlocking the strongbox as
needed), `anchor`/`force-anchor` (stop), `sail`/`resail` (start/restart), `suspend`, `view`
(list/info), `sink` (destroy). Each section below leads with its `erda` equivalent,
then the plain `multipass`/`ssh` commands underneath — useful for understanding what
`erda` is actually doing, adapting it, or falling back to it if `erda` itself is ever
unavailable. `[ship]` defaults to `ship` everywhere it's optional. Run `harbor/erda.sh`
or `harbor\erda.ps1` with no arguments for the full command list.

## 0. One-time setup

**Install Multipass**
- macOS: `brew install --cask multipass`
- Windows: `winget install --id Canonical.Multipass -e` (needs Hyper-V enabled;
  `Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All` from an admin
  PowerShell to check, `Enable-WindowsOptionalFeature ... -All` + reboot if not)

Confirm the backend: `multipass get local.driver` → `hyperv` (Windows) or
`hyperkit`/`qemu` (macOS). If `multipass` isn't recognized right after installing,
close and reopen your terminal (PATH is set machine-wide by the installer but existing
shells don't pick it up); as a one-off fallback the full path on Windows is
`"C:\Program Files\Multipass\bin\multipass.exe"`.

**Get a real SSH key ready** — `keel.yaml` ships with a placeholder
(`REPLACE-ME-with-your-ssh-public-key`) in `ssh_authorized_keys`. Before launching, make
a working copy with your real key substituted in. Run this from **inside the repo**
(`cd`/`Set-Location` to wherever you cloned `ERDA-Will` first — `keel.yaml` is at its
root, not one level up). Generate a key first if you don't have one:
`ssh-keygen -t ed25519` (same command, either shell).

Bash / git-bash:
```bash
cd /path/to/ERDA-Will                 # e.g. cd /c/repos/ERDA-Will on Windows/git-bash
PUBKEY=$(cat ~/.ssh/id_ed25519.pub)
sed "s|REPLACE-ME-with-your-ssh-public-key|$PUBKEY|" keel.yaml > /tmp/keel-real.yaml
grep ssh-ed25519 /tmp/keel-real.yaml  # sanity check: should print your real key,
                                       # not the literal word REPLACE-ME
```

PowerShell (Windows native):
```powershell
Set-Location C:\path\to\ERDA-Will      # e.g. Set-Location C:\repos\ERDA-Will
$PUBKEY = (Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw).Trim()
(Get-Content keel.yaml) -replace 'REPLACE-ME-with-your-ssh-public-key', $PUBKEY |
  Set-Content -Encoding utf8 "$env:TEMP\keel-real.yaml"
Select-String -Path "$env:TEMP\keel-real.yaml" -Pattern 'ssh-ed25519'  # sanity check
```

Never commit either substituted copy — both write outside the repo (`/tmp` or
`$env:TEMP`) specifically so `git status` in the repo stays clean.

## 1. Launch (first provisioning)

### The easy way: `erda christen`

`harbor/erda.sh` (bash/git-bash) and `harbor/erda.ps1` (PowerShell) — the same single
script that handles every other `erda` command — do §0's key substitution and this
section's launch-and-wait in one command via their `christen` case, so "christen" means
the ship is actually ready to use when it returns, not just that the instance exists.
Once `erda` is installed (below), this is `erda christen [options]`:

```bash
erda christen [name] [cpus] [memory] [disk]     # any/all args optional
erda christen resolve                           # named, defaults for the rest
erda christen resolve 4 8G 40G                  # fully custom
```
```powershell
erda christen [-Name <name>] [-Cpus <n>] [-Memory <size>] [-Disk <size>]
erda christen -Name resolve
erda christen -Name resolve -Cpus 4 -Memory 8G -Disk 40G
```

Without `erda` installed, call the script directly the same way:
`harbor/erda.sh christen [...]` / `harbor\erda.ps1 christen [...]`.

Defaults (no args at all): name `ship`, 2 cpus, 4G memory, 20G disk — matching every
manual example in this file. Both scripts read your key from
`~/.ssh/id_ed25519[.pub]` and resolve `keel.yaml` from their own location, so they
work from any directory as long as you give a correct path to the script itself.
Verified end-to-end on this Harbor, both shells: launch → IP → SSH up →
`cloud-init status --wait: done` → ready message, then torn down again with
`delete --purge`.

**Want to just type `erda <command>` from anywhere, no path?** Run the installer once
— `harbor/erda.sh install` (macOS/Linux) or, on Windows, **`harbor\install.cmd`** (not
`erda.ps1 install` directly — see the gotcha below) — which wires an `erda` function
into your shell profile (`~/.bashrc`/`~/.zshrc`, or PowerShell's `$PROFILE`), pointing
at this exact checkout's `harbor/erda.{sh,ps1}`. This is the reproducibility story for
a fresh computer: profile/PATH state itself can't live in git, but the *setup step*
does — clone the repo, run the installer once, restart your terminal, `erda` works
globally from then on. Idempotent (safe to re-run, e.g. after moving the repo or
pulling an update — replaces the old block rather than duplicating it, including
across the upgrade from an older marker). Verified for real: installed, confirmed bare
`erda` commands (`christen`, `board`, `anchor`, `sail`, `resail`,
`suspend`, `view`, `sink`) all work from a completely unrelated directory in a fresh
shell session, re-ran the installer and confirmed no duplication.

**Windows gotcha, real one**: a fresh Windows account's default PowerShell execution
policy (`Restricted`) blocks *any* local `.ps1` file from running at all — including
`erda.ps1` itself, even just to run its own `install` case. `harbor\install.cmd`
exists specifically to bootstrap around this: batch files aren't subject to
PowerShell's execution policy, so it can invoke `erda.ps1 install` with a one-time
`-ExecutionPolicy Bypass`, and that install step itself then sets a real, permanent
`RemoteSigned` policy at `CurrentUser` scope (doesn't need admin rights, doesn't touch
other accounts) so every later `erda` call works normally. If you ever see "running
scripts is disabled on this system," that's this — `Get-ExecutionPolicy -List` shows
which scope is blocking you; `harbor\install.cmd` fixes the common case in one step.

The rest of this section is what `christen` is actually doing under the hood — useful
if you want to understand it, adapt it, or it ever needs debugging.

### By hand

Bash / git-bash:
```bash
multipass launch 24.04 \
  --name ship \
  --cpus 2 --memory 4G --disk 20G \
  --cloud-init /tmp/keel-real.yaml
```

PowerShell:
```powershell
multipass launch 24.04 `
  --name ship `
  --cpus 2 --memory 4G --disk 20G `
  --cloud-init "$env:TEMP\keel-real.yaml"
```

`keel.yaml` clones the repo over HTTPS (public, no baked-in credentials) and hands off
to `fitout.sh`, which is idempotent — safe to re-run. Watch it finish:

```bash
multipass exec ship -- cloud-init status --wait   # should print "status: done"
```

If `launch` fails at the "Verifying image" step with a hash mismatch, the image cache is
corrupt (happened once during the x86_64 drill — a partial/interrupted prior download).
Fix: delete the cached image and relaunch.
- Windows: `Remove-Item -Recurse -Force "C:\ProgramData\Multipass\cache\vault\images\<release-folder>"`
- macOS: check `multipass get local.driver` docs for the cache path on your backend (not
  verified from this session — different from Windows's `ProgramData` location).

## 2. Get in

### The easy way: `erda board`

```bash
erda board [ship]
```

Does exactly what §2's manual steps below do (`multipass info` for the IP, then
`ssh eric@<ip>`) in one command — verified end-to-end, including the "ship isn't
running" error path (`multipass info` returns no IP → clear message pointing at
`erda sail`, not a confusing hang). **Also handles all of §3 automatically**: if a
local `strongbox/ship.key` exists, `board` deploys it to the ship first (only if
missing) and connects with the strongbox already unlocked at captain scope — no
separate command needed, on a freshly christened ship or otherwise. Ships get sunk
and re-christened often enough that a separate "now unlock it" step was pure
friction, so this is just what `board` does now.

### By hand

```bash
multipass info ship               # find the "IPv4:" line, e.g. 172.22.224.86
```

Then **substitute that address** for `<ip>` below — don't paste `<ip>` literally, it's
a placeholder, not something `ssh` understands (`Could not resolve hostname <ip>` means
exactly that mistake happened):

```
ssh -i ~/.ssh/id_ed25519 eric@172.22.224.86
```

**Use `ssh eric@<ip>`, not `multipass shell ship`, for anything beyond a quick peek.**
`multipass shell` is Multipass's own convenience shell and always logs in as the
*default* `ubuntu` account, not `eric` — the user `keel.yaml` actually provisions, with
the sudo rights and SSH key. This isn't just a different prompt: `ubuntu`'s home
directory has no access into `/home/eric` (normal Linux permissions, not a bug), and
since the agent CLIs (`pi`, `claude`, `codex`, `opencode`) are symlinked into
`/usr/local/bin` pointing at binaries installed under `/home/eric/...`, **none of them
resolve for `ubuntu`** — `command -v pi` will come back empty even though `fitout.sh`'s
own end-of-run summary just listed it as installed. That's expected: `ubuntu` was never
the intended operator, and every crew/muster interaction always runs as `eric`. Use
`multipass shell ship` only to poke at the VM as Multipass sees it (disk usage, is it
even booted) — do real work over `ssh eric@<ip>`.

**Gotcha, found during the x86_64 drill**: `multipass exec` is unreliable for anything
beyond a trivial one-shot command on the Hyper-V backend — a `bash -lc '...'` login-shell
invocation through it hung the *client* indefinitely, even though the command had already
finished on the guest side. Real `ssh eric@<ip> '...'` doesn't have this problem and is
also the more honest test of what a human operator (or any headless caller) actually
hits — use it instead of `multipass exec` for anything beyond a quick one-liner.

Non-login vs login shell matters here, deliberately: `ssh host 'cmd'` is **non-login**
(only `/etc/profile.d/*` and the ship's `/usr/local/bin` symlinks are on PATH — this is
the exact shape `muster`'s crew windows run in). `ssh host -tt 'bash -lc "cmd"'` or
`multipass shell` is a **login** shell (`~/.profile`, `~/.bashrc`, `fnm` all in play). If
something works one way and not the other, that's expected, not a bug — check which PATH
you actually need.

## 3. Unlock the strongbox (every new ship)

`fitout.sh` deliberately never does this step — it's the one thing that would put a
real secret into the git-cloned image. Every *new* ship (including a fresh one after
`delete --purge` + relaunch — the private key doesn't survive that, only the
committed, encrypted `strongbox/keys.env.age` does) needs its private age key copied
in once before `pi` can reach DeepInfra. Without it, `pi` starts with `Warning: No
models available` / `Error: No API key found` — that's this exact step missing, not a
bug.

### The easy way: it's just `erda board` now (§2)

There used to be a separate `erda open lockbox` command for this. Ships get sunk and
re-christened often enough that having to remember a second command right after
`board` was pure friction, so `board` (§2) now does this automatically as part of
connecting: checks whether `~/.config/age/ship.key` already exists on the target
ship, copies `strongbox/ship.key` in (with the right permissions) only if it's
missing, then connects with the strongbox already unlocked at **captain scope** —
both `DEEPINFRA_API_KEY` and `GH_TOKEN` (if `strongbox/captain.env.age` exists) land
in your shell's environment the moment you're connected, no separate `eval
"$(unlock)"` needed. Verified end-to-end on a ship with no key yet: correctly
detected the missing key, copied it, and the resulting session had both real secret
values loaded (checked by byte-length, not printing them). If you don't have a local
`strongbox/ship.key` at all yet (run `erda strongbox init` first), `board` just
connects plainly instead of failing.

What it *can't* automate: `unlock`'s whole mechanism only makes sense inside a live
shell session (it prints `export` lines for that shell to `eval`), so "unlocking" from
outside always means "connect with it already done" — there's no way to pre-load
secrets into a session you haven't started yet.

### By hand

You need `strongbox/ship.key` (gitignored, never committed — wherever you generated it
per `strongbox/README.md`). Run from your host, **not** inside the SSH session:

Bash / git-bash:
```bash
SHIP_IP=<ip-from-multipass-info>
ssh -i ~/.ssh/id_ed25519 eric@$SHIP_IP 'mkdir -p ~/.config/age'
scp -i ~/.ssh/id_ed25519 strongbox/ship.key eric@$SHIP_IP:~/.config/age/ship.key
ssh -i ~/.ssh/id_ed25519 eric@$SHIP_IP 'chmod 600 ~/.config/age/ship.key'
```

PowerShell:
```powershell
$SHIP_IP = "<ip-from-multipass-info>"
ssh -i ~/.ssh/id_ed25519 eric@$SHIP_IP "mkdir -p ~/.config/age"
scp -i ~/.ssh/id_ed25519 C:\repos\ERDA-Will\strongbox\ship.key eric@${SHIP_IP}:~/.config/age/ship.key
ssh -i ~/.ssh/id_ed25519 eric@$SHIP_IP "chmod 600 ~/.config/age/ship.key"
```

Then, in your SSH session, before starting `pi` (if you're using `charter`/`sail`, the
bridge window does this automatically — this manual step is only needed for a bare,
standalone `pi`):

```bash
eval "$(unlock)"
pi
```

`unlock` degrades gracefully (prints a note, sets nothing) if the key isn't there yet
— it never blocks the rest of the ship from working.

## 4. Day-to-day lifecycle

| `erda` | Equivalent | Notes |
|---|---|---|
| `erda anchor [ship]` | `multipass stop ship` | graceful shutdown |
| `erda force-anchor [ship]` | `multipass stop ship --force` | immediate; can corrupt a running instance, last resort |
| `erda sail [ship]` | `multipass start ship` | note: same name as `ship/bin/sail <charter>` (opens the tmux deck), which runs *on* the ship, not the Harbor — they never collide but both exist |
| `erda resail [ship]` | `multipass restart ship` | |
| `erda suspend [ship]` | `multipass suspend ship` | pause to disk, no CPU/RAM use while suspended |
| `erda view` | `multipass list` | all instances + state |
| `erda view [ship]` | `multipass info ship` | IP, disk/mem usage, mounts |

All verified for real against a throwaway test ship: stop → start → restart →
suspend → resume, each confirmed via `multipass info` showing the correct state
transition.

By hand:
```bash
multipass stop ship                    # graceful shutdown
multipass stop ship --force            # immediate; can corrupt a running instance, last resort
multipass start ship
multipass restart ship
multipass suspend ship                 # pause to disk, no CPU/RAM use while suspended
multipass list                         # all instances + state
multipass info ship                    # IP, disk/mem usage, mounts
```

Re-running fitout after a git pull inside the ship (no relaunch needed — this is the
idempotency the whole design leans on):

```bash
ssh eric@<ip> 'cd ~/shipyard && git pull --ff-only && ./fitout.sh'
```

## 5. Backup / restore (same host only)

Multipass snapshots and clones are **local to one Multipass installation** — they live
inside that backend's own disk format (Hyper-V `.vhdx` on Windows, HyperKit/QEMU on
macOS) and don't transfer between hosts or platforms. For that reason there's no
"export the ship from Windows and import it on the Mac" command; the two Harbors don't
share a snapshot format. **Cross-platform reproducibility is what `keel.yaml` +
`fitout.sh` are already for** — treat the ship itself as disposable, re-provision with
`multipass launch --cloud-init` (§1) on whichever Harbor you're on. Secrets survive
this by design: `strongbox/keys.env.age` is committed (encrypted) and just needs the
one manual `ship.key` copy-in per new ship (see `strongbox/README.md`).

Within a single host, snapshots and clones are real and useful — e.g. before a risky
manual change:

```bash
multipass stop ship                          # snapshot/clone require a stopped instance
multipass snapshot ship -n before-risky-change -m "before trying the pi extension"
multipass start ship
# ... do the risky thing ...
# if it goes wrong:
multipass stop ship
multipass restore ship.before-risky-change    # -d/--destructive to discard current state outright
multipass start ship

multipass list --snapshots                    # see what you've got
multipass info ship --snapshots                # detail per snapshot
multipass clone ship -n ship-experiment        # independent full copy, same host
```

## 6. Files in and out

```bash
multipass transfer local-file.txt ship:/home/eric/local-file.txt
multipass transfer ship:/home/eric/fleet/some-charter/.ship/reports/T-001.report.md ./
multipass transfer -r ./some-dir ship:/home/eric/some-dir   # recursive
```

**Windows gotcha**: run this from a shell where the local path doesn't start with a
drive letter followed by `:` (e.g. `C:/...`) in the same argument list as an
`instance:path` destination — Multipass's client parses `X:` as an instance-name
prefix, and seeing two of them in one command fails with "Cannot specify an instance
name for both source and destination". `cd` into the directory first and use a
relative path, or set `MSYS_NO_PATHCONV=1` if you're in Git Bash and the path is being
mangled outright.

Plain `scp -i ~/.ssh/id_ed25519 file eric@<ip>:~/` works too and avoids all of the
above; prefer it once you have the IP.

## 7. Destroy

### The easy way: `erda sink`

```bash
erda sink [ship]              # asks you to type the ship's name to confirm
erda sink [ship] -y           # skips confirmation (scripting/muscle-memory use)
```

`multipass delete <ship> --purge` in one step — immediate and permanent, so it asks
for confirmation by default (type the exact ship name; anything else cancels with
nothing destroyed). Verified both paths for real: wrong confirmation correctly
cancelled without touching the VM, `-y` correctly skipped the prompt and destroyed it.

### By hand

```bash
multipass delete ship            # soft-delete, recoverable
multipass recover ship           # ...until you do this instead
multipass delete ship --purge    # immediate, permanent
multipass purge                  # purge everything already soft-deleted
```

Every drill in this project's history destroys its test ship with `delete --purge`
when done — don't leave one running as a matter of practice.

## 8. Known non-idempotent / manual steps

These are the only things `fitout.sh` deliberately does **not** automate — by design,
not oversight:

- **SSH key** in `keel.yaml` (§0) — one placeholder substitution per operator, same
  spirit as the age key below. `erda christen` (§1) automates the substitution itself.
- **Strongbox age key** (§3) — needed again on every *new* ship, including a fresh one
  after `delete --purge` + relaunch. `fitout.sh` verifies the strongbox decrypts if the
  key is already present, and skips gracefully (no error) if it isn't yet — see
  `strongbox/README.md`. `erda board` (§2/§3) automates the copy-in step and connects
  with it already unlocked, automatically, every time.
- Everything else — git identity (`ERDAgent` / `agentic@ericrose.dev`, the ship's own
  persona), agent CLIs, PATH wiring, `ship/bin/*` on PATH, tmux/Fresh config — is set by
  `fitout.sh` on every launch, unconditionally and idempotently. A fresh `multipass
  launch --cloud-init keel.yaml` should need nothing beyond the two steps above to be
  fully usable.

## 9. Sailing multiple ships

`keel.yaml` is name-agnostic — nothing in it or `fitout.sh` depends on the
instance name, so the fleet scales by just launching again:

```
multipass launch 24.04 --name resolve --cloud-init keel.yaml
```

Every ship is fully self-contained (own `~/fleet/`, own tmux server, own
strongbox unlock step). Multipass sets the VM hostname to the instance name,
and the deck's status bar shows `#H` — so every tmux session already displays
which ship you're standing on.

### Naming (D16): the Will class

| Class | Purpose | Lifecycle | Naming |
|---|---|---|---|
| **Flagship** | Daily driver, one per harbor | Long-lived | Will-class virtues: `resolve`, `endeavour`, `tenacity`, `grit`… (ERDA-**Will** is the class namesake: the impetus that drives the navy to sail) |
| **Skiff** | Drill / test / scratch | Launch, use, `delete --purge` same day | `skiff-<purpose>`: `skiff-drill`, `skiff-x86`, `skiff-shellcheck` |
| **Named vessel** | Hard-isolation ships (a client whose secrets warrant their own hull — the D8 exception) | Life of the engagement | client-evocative, e.g. `palm-court` |

Gotchas:
- Instance names must be unique per harbor **including deleted-but-unpurged
  instances** — `multipass list` shows `Deleted` entries; `multipass purge`
  frees their names.
- Each ship defaults to real RAM/disk. Check headroom before a second
  flagship on a laptop; skiffs can launch smaller (`--memory 4G --disk 20G`).

### The one-charter-one-ship rule (D16, load-bearing)

A charter must **reside on exactly one ship at a time**. Nothing technically
prevents chartering the same repo on two ships — but that is two Captains on
one charter, and now that ships hold push credentials (D14), it is two agents
racing pushes to the same `integration`/`main`. Charters may *move* ships
freely (push everything → `delete --purge` → `charter` again elsewhere —
that's the portability working as intended); they must never *live* on two
at once. Before chartering on a new ship, be sure the old berth is gone or
was never there.

## 10. Previewing a charter's dev server (D18)

Every charter's deck has a "preview" window (`sail`'s window 8) running a dev
server against the `integration` branch — crew's merged, reviewed work, kept
in sync every time the Captain runs INTEGRATE. Not any one crew berth; not a
raw exposed port — the dev server only ever needs to bind `localhost` on the
ship itself.

### The easy way: `erda preview`

```bash
erda preview <charter> [ship] [port]
```

Ensures the charter's deck is up (idempotent — a no-op if it already is),
reads the port from the charter's `charter.md` ("## Dev server" section) if
you don't pass one explicitly, then opens an SSH local port-forward and
prints the URL to open (`http://localhost:<port>`). No external tunneling
service (ngrok, Cloudflare Tunnel, etc.) — this rides the same SSH
connection everything else in this project uses. `Ctrl+C` closes the tunnel;
the dev server itself keeps running in its tmux window regardless.

### Setup (once per charter)

Fill in `charter.md`'s "## Dev server" section:
```
## Dev server
- command: npm run dev
- port: 5173
```
Leave it as the placeholder text (starts with `(`) and both `ship/bin/preview`
(the window) and `erda preview` (the tunnel) will tell you it isn't configured
yet, rather than trying to run garbage as a command.

### By hand

```bash
ssh -i ~/.ssh/id_ed25519 -N -L 5173:localhost:5173 eric@<ship-ip>
```
Then browse to `http://localhost:5173`. Requires the dev server to already be
running on the ship (`tmux attach`, jump to the "preview" window — or run
`ship/bin/preview <charter>` yourself in any shell on the ship).
