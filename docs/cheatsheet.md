# erda commands

Run `harbor\install.cmd` on Windows, or `harbor/erda.sh install` on mac/linux, to enable erda commands.

From host OS

  - `erda christen [name] [cpus] [memory] [disk]`: launches a new ship.
  - `erda board [ship]`: opens tmux connection.
  - `erda open lockbox [ship]`: deploy the age key if needed, connect unlocked.
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
