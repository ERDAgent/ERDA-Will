# erda commands

Run install.ps1 on windows, or ASDF on mac/linux, or enable erda commands.

From host OS

  - `erda christen [name] [cpus] [memory] [disk]`: launches a new ship.
  - `erda open lockbox [ship]`: deploys keys and connects to a ship, must do for newely christened ships.
  - `erda board [ship]`: connects to a ship.
  - `erda anchor [ship]`: gracefully shuts down.
  - `erda force-anchor [ship]`: immediate shuts down, can corrupt a running instance.
  - `erda sail [ship]`: starts a ship.
  - `erda resail [ship]`: restarts a ship.
  - `erda suspend [ship]`: suspends a ship, no CPU/RAM use while suspended.
  - `erda view`: list all ships.
  - `erda view [ship]`: view ship info.
  - `sink [ship]`: deletes and purges ship.

From a ship

  - `captain charter [name] --local`: creates or continues a github repo.
  - `captain work [charter]`: starts work on a charter.
