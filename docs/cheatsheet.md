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
