<#
.SYNOPSIS
  erda — command-line entry point for Harbor-side ship operations.
.DESCRIPTION
  usage: erda <command> [ship] [args...]

    christen [name] [cpus] [memory] [disk]   launch a new ship (see christen.ps1)
    board [ship]                             connect: multipass info + ssh in
    open lockbox [ship]                      deploy the age key if needed, connect
                                              with the strongbox already unlocked
                                              (captain scope: model keys + GH_TOKEN)
    anchor [ship]                            multipass stop
    force-anchor [ship]                      multipass stop --force
    sail [ship]                              multipass start
    resail [ship]                            multipass restart
    suspend [ship]                           multipass suspend
    view [ship]                              multipass list (no ship) / info <ship>
    sink [ship]                              multipass delete --purge
                                              (asks to confirm; -y/-Force skips)

  [ship] defaults to "ship" everywhere it's optional, matching christen's own default.

  Note: `erda sail` (start a stopped VM, this script) and `ship/bin/sail <charter>`
  (open the tmux deck, runs ON the ship) share a name but never actually collide --
  different sides of the SSH connection -- worth knowing so "sail" isn't confusing
  when you're used to the other one.
#>
param(
  [Parameter(Position=0)] [string]$Command,
  [Parameter(ValueFromRemainingArguments=$true)] [string[]]$Rest = @()
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SshPriv = "$env:USERPROFILE\.ssh\id_ed25519"

$MP = "multipass"
if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
  $MP = "C:\Program Files\Multipass\bin\multipass.exe"
}

function Get-Arg0([string]$Default = "ship") {
  if ($Rest.Count -ge 1 -and $Rest[0]) { return $Rest[0] }
  return $Default
}

function Get-ShipIp([string]$Name) {
  $IpLine = & $MP info $Name | Select-String "IPv4"
  if (-not $IpLine) {
    Write-Error "erda: couldn't get an IP for '$Name' -- is it running? (erda sail $Name)"
    exit 1
  }
  return ($IpLine -split '\s+')[1]
}

$Usage = @"
usage: erda <command> [ship] [args...]
  christen [name] [cpus] [memory] [disk]   launch a new ship
  board [ship]                             connect (multipass info + ssh)
  open lockbox [ship]                      deploy the age key if needed, connect unlocked
  anchor [ship]                            stop
  force-anchor [ship]                      stop --force
  sail [ship]                              start
  resail [ship]                            restart
  suspend [ship]                           suspend
  view [ship]                              list (no ship) / info <ship>
  sink [ship]                              delete --purge (asks to confirm; -y/-Force skips)
[ship] defaults to "ship" everywhere it's optional.
"@

if ([string]::IsNullOrEmpty($Command)) {
  Write-Host $Usage
  exit 1
}

switch ($Command) {
  "christen" {
    & (Join-Path $PSScriptRoot "christen.ps1") @Rest
  }

  "board" {
    $Name = Get-Arg0
    $Ip = Get-ShipIp $Name
    Write-Host "boarding '$Name' ($Ip)..."
    ssh -i $SshPriv eric@$Ip
  }

  "open" {
    if ($Rest.Count -lt 1 -or $Rest[0] -ne "lockbox") {
      Write-Error "erda: 'open' only supports 'open lockbox [ship]'"
      exit 1
    }
    $Name = if ($Rest.Count -ge 2 -and $Rest[1]) { $Rest[1] } else { "ship" }
    $Ip = Get-ShipIp $Name
    Write-Host "opening the lockbox on '$Name' ($Ip)..."

    $KeyPath = Join-Path $RepoRoot "strongbox\ship.key"
    if (-not (Test-Path $KeyPath)) {
      Write-Error "erda: no local strongbox\ship.key -- generate/place it first (see strongbox/README.md)"
      exit 1
    }

    # -o LogLevel=ERROR: suppress ssh's routine notices at the ssh level
    # rather than redirecting PowerShell's stream (see christen.ps1's own
    # note on why -- redirected native stderr + strict error handling is a
    # real PowerShell 5.1 footgun).
    $KeyPresent = ssh -i $SshPriv -o LogLevel=ERROR eric@$Ip "test -f ~/.config/age/ship.key && echo yes || echo no"
    if ($KeyPresent -ne "yes") {
      Write-Host "no age key on '$Name' yet -- copying strongbox\ship.key..."
      ssh -i $SshPriv -o LogLevel=ERROR eric@$Ip "mkdir -p ~/.config/age"
      scp -i $SshPriv -o LogLevel=ERROR $KeyPath eric@${Ip}:~/.config/age/ship.key
      ssh -i $SshPriv -o LogLevel=ERROR eric@$Ip "chmod 600 ~/.config/age/ship.key"
    }

    Write-Host "connecting with the lockbox unlocked (captain scope: model keys + GH_TOKEN if present)..."
    ssh -i $SshPriv -t eric@$Ip 'eval "$(unlock captain)"; exec bash -l'
  }

  "anchor" {
    & $MP stop (Get-Arg0)
  }
  "force-anchor" {
    & $MP stop (Get-Arg0) --force
  }
  "sail" {
    & $MP start (Get-Arg0)
  }
  "resail" {
    & $MP restart (Get-Arg0)
  }
  "suspend" {
    & $MP suspend (Get-Arg0)
  }
  "view" {
    if ($Rest.Count -ge 1 -and $Rest[0]) {
      & $MP info $Rest[0]
    } else {
      & $MP list
    }
  }
  "sink" {
    $Name = Get-Arg0
    $Force = ($Rest -contains "-y") -or ($Rest -contains "-Force") -or ($Rest -contains "--force")
    if (-not $Force) {
      $Confirm = Read-Host "This will permanently destroy '$Name' and everything on it. Type the ship name to confirm"
      if ($Confirm -ne $Name) {
        Write-Host "cancelled."
        exit 1
      }
    }
    & $MP delete $Name --purge
  }

  default {
    Write-Error "erda: unknown command '$Command'. Run 'erda' with no args for the command list."
    exit 1
  }
}
