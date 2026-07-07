# Quick Start

To get started building, follow these steps:

  - `erda christen my-ship`
  - `erda board my-ship`
  - `captain charter my-charter`
  - `captain work my-charter`
  - order the captain

# erda commands

Run `harbor\install.cmd` on Windows, or `harbor/erda.sh install` on mac/linux, to enable erda commands.

From host OS

  - `erda christen [name] [cpus] [memory] [disk]`: launches a new ship.
  - `erda strongbox init`: input deepinfra, github, and claude (anthropic) keys.
  - `erda strongbox backup/restore`: backs up or restores the strongbox.
  - `erda board [ship]`: connects to a ship, deploying the age key if needed and unlocking the strongbox (captain scope) automatically.
  - `erda telescope <charter> [ship] [port]`: SSH-tunnels to a charter's dev server (integration branch) so you can view it at `http://localhost:<port>` -- no external tunneling service, port comes from charter.md's "## Dev server" section if not given.
  - `erda anchor [ship]`: gracefully shuts down.
  - `erda force-anchor [ship]`: immediate shuts down, can corrupt a running instance.
  - `erda sail [ship]`: starts a ship.
  - `erda resail [ship]`: restarts a ship.
  - `erda suspend [ship]`: suspends a ship, no CPU/RAM use while suspended.
  - `erda view`: list all ships.
  - `erda view [ship]`: view ship info.
  - `erda sink [ship]`: deletes and purges ship.

From a ship

  - `captain charter [name] --local`: creates or continues a github repo.
  - `captain work [charter]`: starts work on a charter.
  - `captain list charters`: lists existing charters and their status.
  - `captain work`'s deck has a "shipwright" window (Claude Code, cwd `~/shipyard`) for system-level changes to ERDA-Will itself — not the charter.
  - `captain work`'s deck also has a "telescope" window running the charter's dev server against the integration branch (fill in charter.md's "## Dev server" section: `command` + `port`) -- view it from the host with `erda telescope <charter>`.

From the Captain's `pi` session (bridge window, window 0), once you're chartered and working:

  - `/mission <goal>`: plans a mission -- writes `mission.md` + work orders, runs `/critique` (First Mate) automatically, and stops for your go-ahead before mustering anything.
  - `/muster`: spawns crew for the approved orders -- berth + branch + tmux window + headless agent, zero added LLM cost.
  - `/harbor`: status from the roster + reports -- what's running, done, or SOS.
  - `/review <task-id>`: Quartermaster -- merges a done task into `integration`, runs the dry-dock tests, judges the diff, approves or rejects.
  - `/critique`: First Mate's plan critique on demand (also runs automatically as part of `/mission`) -- advisory only, never blocks `/muster`.
  - `/debrief`: narrates what shipped, what's blocked, and real per-role cost.
  - window 1 "chartroom" (Fresh) -- open mission/orders/reports (flags SOS), jump to a crew member's tmux window, live roster dashboard.
  - window 3 "bosun" -- auto-refreshing dashboard, flags any crew task over its declared turn/token budget (detect-only, v1).
