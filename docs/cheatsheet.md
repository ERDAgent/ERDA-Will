# Quick Start

  - `erda christen my-ship`
  - `erda open lockbox my-ship`
  - `captain charter my-charter`
  - `captain work my-charter`
  - order the captain

# erda commands

Run `harbor\install.cmd` on Windows, or `harbor/erda.sh install` on mac/linux, to enable erda commands.

From host OS

  - `erda christen [name] [cpus] [memory] [disk]`: launches a new ship.
  - `erda strongbox init`: input github and deepinfra keys.
  - `erda open lockbox [ship]`: deploys keys and connects to a ship, must do for newely christened ships.
  - `erda strongbox backup/restore`: backs up or restores the strongbox.
  - `erda board [ship]`: connects to a ship.
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
