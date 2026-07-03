# The Ship, by hand — Multipass cheatsheet

Everything in this file is a plain `multipass`/`ssh` command. No Claude Code, no
`ship/bin/*` helper required — this is the manual reference for deploying, using, and
destroying the Ship on your own, on either Harbor (macOS or Windows). Verified against
Multipass 1.16.3 on Windows/Hyper-V (2026-07-02); the macOS/Multipass driver differs
(HyperKit or QEMU, not Hyper-V) but the command surface below is the same client CLI on
both.

Command reference for anything not covered here: `multipass help <command>`.

## 0. One-time setup

**Install Multipass**
- macOS: `brew install --cask multipass`
- Windows: `winget install --id Canonical.Multipass -e` (needs Hyper-V enabled;
  `Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All` from an admin
  PowerShell to check, `Enable-WindowsOptionalFeature ... -All` + reboot if not)

Confirm the backend: `multipass get local.driver` → `hyperv` (Windows) or
`hyperkit`/`qemu` (macOS).

**Get a real SSH key ready** — `keel.yaml` ships with a placeholder
(`REPLACE-ME-with-your-ssh-public-key`) in `ssh_authorized_keys`. Before launching, make
a working copy with your real key substituted in. Run this from **inside the repo**
(`cd` to wherever you cloned `ERDA-Will` first — `keel.yaml` is at its root, not one
level up):

```bash
# bash/zsh/git-bash — never commit the substituted copy
cd /path/to/ERDA-Will                 # e.g. cd /c/repos/ERDA-Will on Windows/git-bash
PUBKEY=$(cat ~/.ssh/id_ed25519.pub)   # generate one first if you don't have it:
                                       #   ssh-keygen -t ed25519
sed "s|REPLACE-ME-with-your-ssh-public-key|$PUBKEY|" keel.yaml > /tmp/keel-real.yaml
grep ssh-ed25519 /tmp/keel-real.yaml  # sanity check: should print your real key,
                                       # not the literal word REPLACE-ME
```

## 1. Launch (first provisioning)

```bash
multipass launch 24.04 \
  --name ship \
  --cpus 2 --memory 4G --disk 20G \
  --cloud-init /tmp/keel-real.yaml
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

```bash
multipass info ship | grep -i ipv4     # note the IP
ssh -i ~/.ssh/id_ed25519 eric@<ip>     # preferred — see the gotcha below
multipass shell ship                   # Multipass's own shell, logs in as `ubuntu` not `eric`
```

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

## 3. Day-to-day lifecycle

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

## 4. Backup / restore (same host only)

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

## 5. Files in and out

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

## 6. Destroy

```bash
multipass delete ship            # soft-delete, recoverable
multipass recover ship           # ...until you do this instead
multipass delete ship --purge    # immediate, permanent
multipass purge                  # purge everything already soft-deleted
```

Every drill in this project's history destroys its test ship with `delete --purge`
when done — don't leave one running as a matter of practice.

## 7. Known non-idempotent / manual steps

These are the only things `fitout.sh` deliberately does **not** automate — by design,
not oversight:

- **SSH key** in `keel.yaml` (§0) — one placeholder substitution per operator, same
  spirit as the age key below.
- **Strongbox age key** — `mkdir -p ~/.config/age && scp ship.key <ship>:~/.config/age/ship.key`,
  then `eval "$(unlock)"`. `fitout.sh` verifies the strongbox decrypts if the key is
  already present, and skips gracefully (no error) if it isn't yet — see
  `strongbox/README.md`.
- Everything else — git identity (`ERDAgent` / `agentic@ericrose.dev`, the ship's own
  persona), agent CLIs, PATH wiring, `ship/bin/*` on PATH, tmux/Fresh config — is set by
  `fitout.sh` on every launch, unconditionally and idempotently. A fresh `multipass
  launch --cloud-init keel.yaml` should need nothing beyond the two steps above to be
  fully usable.
