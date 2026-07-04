<#
.SYNOPSIS
  erda — single entry point for all Harbor-side ship operations.
.DESCRIPTION
  usage: erda <command> [ship] [args...]

    install                                  wire up `erda` as a global shell
                                              command (run once per machine, or
                                              again after moving/updating the repo)
    christen [name] [cpus] [memory] [disk]   launch a new ship
    strongbox <init|backup|restore>          manage the local age keypair (see below)
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

  [ship] defaults to "ship" everywhere it's optional.

  Before `erda` is a shell function, run this once by its full path:
    .\harbor\erda.ps1 install
  On a fresh Windows account, PowerShell's default execution policy blocks
  any local .ps1 (including this one) -- use harbor\install.cmd instead,
  which bypasses that policy just long enough to run this same install.

  Note: `erda sail` (start a stopped VM, this command) and `ship/bin/sail
  <charter>` (open the tmux deck, runs ON the ship) share a name but never
  actually collide -- different sides of the SSH connection.
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
  $Ip = if ($IpLine) { ($IpLine -split '\s+')[1] } else { $null }
  if (-not $Ip -or $Ip -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    Write-Error "erda: couldn't get an IP for '$Name' -- is it running? (erda sail $Name)"
    exit 1
  }
  return $Ip
}

$Usage = @"
usage: erda <command> [ship] [args...]
  install                                   wire up `erda` as a global command (run once)
  christen [name] [cpus] [memory] [disk]    launch a new ship
  strongbox init                            generate a new keypair + encrypt secrets
  strongbox backup <path>                   copy ship.key to a path of your choosing
  strongbox restore <path>                  copy ship.key back from a path
  board [ship]                              connect (multipass info + ssh)
  open lockbox [ship]                       deploy the age key if needed, connect unlocked
  anchor [ship]                             stop
  force-anchor [ship]                       stop --force
  sail [ship]                               start
  resail [ship]                             restart
  suspend [ship]                            suspend
  view [ship]                               list (no ship) / info <ship>
  sink [ship]                               delete --purge (asks to confirm; -y/-Force skips)
[ship] defaults to "ship" everywhere it's optional.
"@

# install — wire up `erda` as a global PowerShell function. Profile/PATH
# state is per-machine and can't live in git, so the setup step lives here
# instead of a manual profile edit. Idempotent: re-running (e.g. after moving
# the repo, or pulling an updated harbor/) replaces the previously-installed
# block rather than duplicating it.
function Invoke-Install {
  # On a fresh Windows account, PowerShell's default execution policy
  # (Restricted, when every scope shows Undefined) blocks any local .ps1,
  # including this one on some paths to get here -- install.cmd exists
  # specifically to bootstrap around that chicken-and-egg case via a
  # one-time -ExecutionPolicy Bypass. This makes the fix permanent:
  # RemoteSigned at CurrentUser scope, so every later `erda` call (or this
  # install, if re-run) works normally without needing Bypass again.
  # Scoped to CurrentUser only -- doesn't touch other accounts or require
  # admin rights.
  $CurrentUserPolicy = Get-ExecutionPolicy -Scope CurrentUser
  if ($CurrentUserPolicy -in @("Restricted", "AllSigned", "Undefined")) {
    Write-Host "setting your execution policy to RemoteSigned (needed to run local scripts like erda)..."
    try {
      Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    } catch {
      Write-Warning "couldn't set execution policy automatically: $($_.Exception.Message)"
      Write-Warning "if this machine is managed by Group Policy, ask an admin to allow RemoteSigned (or less restrictive) for your account."
    }
  }
  $EffectivePolicy = Get-ExecutionPolicy
  if ($EffectivePolicy -in @("Restricted", "AllSigned")) {
    Write-Warning "effective execution policy is still $EffectivePolicy -- erda may not run yet."
    Write-Warning "run 'Get-ExecutionPolicy -List' to see what's overriding CurrentUser (likely MachinePolicy or UserPolicy via Group Policy)."
  }

  # 'erda strongbox init' needs age-keygen. Installing it here (once, at
  # first-time setup) means that command never has to fail partway through
  # -- otherwise a user would confirm the scary "overwrite ship.key" prompt
  # only to then discover the tool it needed isn't present.
  if (-not (Get-Command age-keygen -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      Write-Host "'age' (needed by 'erda strongbox') isn't installed -- installing via winget..."
      try {
        winget install --id FiloSottile.age -e --accept-package-agreements --accept-source-agreements
        Write-Host "age installed. Open a new terminal (so PATH updates take effect) before running 'erda strongbox init'."
      } catch {
        Write-Warning "couldn't install age automatically: $($_.Exception.Message)"
        Write-Warning "install it yourself: winget install --id FiloSottile.age"
      }
    } else {
      Write-Warning "'age' (needed by 'erda strongbox') isn't installed, and winget isn't available to install it automatically."
      Write-Warning "install it from https://github.com/FiloSottile/age/releases and put age-keygen.exe on your PATH."
    }
  }

  $ErdaPath = Join-Path $PSScriptRoot "erda.ps1"

  if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
  }

  $MarkerStart = "# --- ERDA-Will harbor commands (managed by harbor/erda.ps1 install) ---"
  $MarkerPrefix = "# --- ERDA-Will harbor commands"
  $MarkerEnd = "# --- end ERDA-Will harbor commands ---"
  $Block = "$MarkerStart`nfunction erda { & `"$ErdaPath`" @args }`n$MarkerEnd"

  # Matched by prefix, not exact text: an older install (e.g. the
  # since-merged harbor/install.ps1) wrote a marker with different wording
  # after "harbor commands" -- matching only the prefix means an upgrade
  # replaces that stale block instead of leaving it duplicated alongside a
  # new one.
  $Existing = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
  if ($Existing -and $Existing.Contains($MarkerPrefix)) {
    $Lines = Get-Content $PROFILE
    $Kept = New-Object System.Collections.Generic.List[string]
    $Skipping = $false
    foreach ($line in $Lines) {
      if ($line.StartsWith($MarkerPrefix)) { $Skipping = $true; continue }
      if ($line -eq $MarkerEnd) { $Skipping = $false; continue }
      if (-not $Skipping) { $Kept.Add($line) }
    }
    Set-Content -Path $PROFILE -Value $Kept
    Add-Content -Path $PROFILE -Value $Block
    Write-Host "updated existing erda install in $PROFILE (path may have changed)"
  } else {
    Add-Content -Path $PROFILE -Value "`n$Block"
    Write-Host "installed erda into $PROFILE"
  }

  Write-Host ""
  Write-Host "Restart your terminal, or run: . `$PROFILE"
  Write-Host "Then 'erda <command>' works from any directory (e.g. erda christen, erda board)."
}

# christen — launch a new ship with one command and sensible defaults.
# Handles the whole first-provisioning dance: substitutes your real SSH key
# into keel.yaml (never writing the substituted copy into the repo), calls
# `multipass launch`, then waits for SSH and cloud-init to actually finish
# before handing control back -- so "christen" means "ready to use", not just
# "instance exists".
#
# Fleet naming (D16): flagships get Will-class virtue names (resolve,
# endeavour, tenacity...); skiffs use skiff-<purpose> and get purged same
# day. This command doesn't enforce either -- name whatever you want.
function Invoke-Christen {
  param(
    [string]$Name = "ship",
    [int]$Cpus = 2,
    [string]$Memory = "4G",
    [string]$Disk = "20G"
  )

  # Deliberately NOT inheriting the script's $ErrorActionPreference = "Stop"
  # here: in PowerShell 5.1, any redirected stderr output from a native exe
  # (ssh, multipass) gets wrapped into an ErrorRecord and promoted to a
  # terminating exception under Stop -- turning ssh's harmless "Warning:
  # Permanently added ... to the list of known hosts" notice into a
  # script-ending failure. Assigning inside this function shadows the outer
  # value only for the duration of this call; every native call below is
  # checked explicitly via $LASTEXITCODE instead.
  $ErrorActionPreference = "Continue"

  if ($Name -notmatch '^[A-Za-z]$' -and $Name -notmatch '^[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$') {
    Write-Error "christen: invalid name '$Name' (letters, digits, hyphens; must start with a letter, end alphanumeric)"
    exit 1
  }

  $KeelSrc = Join-Path $RepoRoot "keel.yaml"
  if (-not (Test-Path $KeelSrc)) {
    Write-Error "christen: keel.yaml not found at $KeelSrc"
    exit 1
  }

  $SshPub = "$SshPriv.pub"
  if (-not (Test-Path $SshPub)) {
    Write-Error "christen: no SSH public key at $SshPub -- generate one first: ssh-keygen -t ed25519"
    exit 1
  }

  $PubKey = (Get-Content $SshPub -Raw).Trim()
  $TmpKeel = Join-Path $env:TEMP "keel-christen-$([guid]::NewGuid().ToString('N')).yaml"
  (Get-Content $KeelSrc) -replace 'REPLACE-ME-with-your-ssh-public-key', $PubKey | Set-Content -Encoding utf8 $TmpKeel

  try {
    Write-Host "christening '$Name': $Cpus cpu(s), $Memory memory, $Disk disk"
    & $MP launch 24.04 --name $Name --cpus $Cpus --memory $Memory --disk $Disk --cloud-init $TmpKeel
    if ($LASTEXITCODE -ne 0) {
      Write-Error "christen: multipass launch failed (exit $LASTEXITCODE)"
      exit 1
    }
  } finally {
    Remove-Item $TmpKeel -ErrorAction SilentlyContinue
  }

  Write-Host ""
  Write-Host -NoNewline "waiting for '$Name' to get an IP..."
  $Ip = $null
  for ($i = 0; $i -lt 20; $i++) {
    $IpLine = & $MP info $Name | Select-String "IPv4"
    if ($IpLine) {
      $Candidate = ($IpLine -split '\s+')[1]
      if ($Candidate -match '^\d+\.\d+\.\d+\.\d+$') { $Ip = $Candidate; break }
    }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 2
  }
  if (-not $Ip) {
    Write-Host ""
    Write-Error "christen: never got an IP for '$Name' -- check: multipass info $Name"
    exit 1
  }
  Write-Host " $Ip"

  Write-Host -NoNewline "waiting for ssh..."
  $SshOk = $false
  for ($i = 0; $i -lt 40; $i++) {
    # -o LogLevel=ERROR suppresses ssh's routine notices (e.g. "Warning:
    # Permanently added ... to the list of known hosts") at the ssh level,
    # rather than redirecting stderr in PowerShell -- see the note above
    # $ErrorActionPreference for why that redirection is the thing to avoid.
    ssh -i $SshPriv -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes eric@$Ip "true"
    if ($LASTEXITCODE -eq 0) { $SshOk = $true; break }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 3
  }
  if (-not $SshOk) {
    Write-Host ""
    Write-Warning "christen: ssh never came up on '$Name' ($Ip) after 2 minutes -- check manually: ssh -i $SshPriv eric@$Ip"
    exit 1
  }
  Write-Host " up"

  Write-Host "waiting for cloud-init to finish provisioning (a couple of minutes)..."
  ssh -i $SshPriv -o StrictHostKeyChecking=accept-new eric@$Ip "cloud-init status --wait"

  Write-Host ""
  Write-Host "'$Name' is ready: ssh -i $SshPriv eric@$Ip"
}

# strongbox — manage the local age keypair (strongbox\ship.key) and the
# encrypted secret bundles it decrypts. ship.key is host-side, permanent
# infrastructure -- it has nothing to do with any one ship instance, so
# sinking a ship never touches it and losing it is NOT recoverable by
# generating a new one (the existing keys.env.age/captain.env.age were
# encrypted to the OLD key's public half specifically). Back it up.
function Invoke-Strongbox {
  param(
    [Parameter(Position=0)] [string]$Sub,
    [Parameter(ValueFromRemainingArguments=$true)] [string[]]$SubArgs = @()
  )

  # See Invoke-Christen's note on $ErrorActionPreference: age-keygen writes
  # its "Public key: ..." line to stderr by design, and redirecting that
  # (2>&1 below) while Stop is active would turn it into a terminating
  # exception under PowerShell 5.1. Shadowed locally only for this call.
  $ErrorActionPreference = "Continue"

  $KeyPath = Join-Path $RepoRoot "strongbox\ship.key"

  switch ($Sub) {
    "init" {
      if (-not (Get-Command age-keygen -ErrorAction SilentlyContinue)) {
        Write-Error "strongbox: 'age' isn't installed on this machine (winget install --id FiloSottile.age, then open a new terminal so PATH updates take effect)"
        exit 1
      }

      if (Test-Path $KeyPath) {
        Write-Warning "strongbox: $KeyPath already exists."
        Write-Warning "  Overwriting it orphans anything already encrypted with the old key"
        Write-Warning "  (keys.env.age / captain.env.age would become permanently undecryptable)."
        $Confirm = Read-Host "  Type 'overwrite' to replace it anyway"
        if ($Confirm -ne "overwrite") { Write-Host "cancelled."; exit 1 }
      }

      & age-keygen -o $KeyPath 2>&1 | Out-Null
      Write-Host "generated $KeyPath"
      # Select-String returns the whole matched line ("# public key: age1...");
      # extract just the age1... token itself, matching what `grep -o 'age1.*'`
      # does on the bash side -- otherwise `age -r` gets handed the comment
      # prefix as the recipient and silently fails to encrypt.
      $Recipient = [regex]::Match((Get-Content $KeyPath -Raw), 'age1[a-z0-9]+').Value

      Write-Host ""
      $DeepInfraKey = Read-Host "DEEPINFRA_API_KEY (input hidden)" -AsSecureString
      $PlainDeepInfra = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($DeepInfraKey))
      if (-not $PlainDeepInfra) { Write-Error "strongbox: empty value entered, aborting"; exit 1 }
      $KeysEnvPath = Join-Path $RepoRoot "strongbox\keys.env.age"
      "DEEPINFRA_API_KEY=$PlainDeepInfra" | & age -r $Recipient -o $KeysEnvPath -
      $KeysLen = (& age -d -i $KeyPath $KeysEnvPath | Measure-Object -Character).Characters
      Write-Host "wrote keys.env.age (decrypts to $KeysLen bytes)"

      Write-Host ""
      $AddGh = Read-Host "Also set up the captain compartment (GH_TOKEN) now? [y/N]"
      if ($AddGh -match '^[Yy]$') {
        $GhToken = Read-Host "GH_TOKEN (input hidden)" -AsSecureString
        $PlainGh = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($GhToken))
        if (-not $PlainGh) {
          Write-Warning "strongbox: empty value entered, skipping captain compartment"
        } else {
          $CaptainEnvPath = Join-Path $RepoRoot "strongbox\captain.env.age"
          "GH_TOKEN=$PlainGh" | & age -r $Recipient -o $CaptainEnvPath -
          $CaptainLen = (& age -d -i $KeyPath $CaptainEnvPath | Measure-Object -Character).Characters
          Write-Host "wrote captain.env.age (decrypts to $CaptainLen bytes)"
        }
      }

      Write-Host ""
      Write-Host "strongbox initialized. Back up $KeyPath now: erda strongbox backup <path>"
      Write-Host "(without a backup, losing this file again means repeating this whole process)"
    }

    "backup" {
      $Dest = if ($SubArgs.Count -ge 1) { $SubArgs[0] } else { $null }
      if (-not $Dest) { Write-Error "usage: erda strongbox backup <destination-path>"; exit 1 }
      if (-not (Test-Path $KeyPath)) { Write-Error "strongbox: no local $KeyPath to back up"; exit 1 }
      if (Test-Path $Dest -PathType Container) { $Dest = Join-Path $Dest "ship.key" }
      Copy-Item -Path $KeyPath -Destination $Dest -Force
      Write-Host "backed up $KeyPath -> $Dest"
      Write-Host "keep this somewhere durable and private (password manager, encrypted drive, etc.) -- it's the only copy outside this machine."
    }

    "restore" {
      $Src = if ($SubArgs.Count -ge 1) { $SubArgs[0] } else { $null }
      if (-not $Src) { Write-Error "usage: erda strongbox restore <source-path>"; exit 1 }
      if (-not (Test-Path $Src)) { Write-Error "strongbox: no file at $Src"; exit 1 }
      if (Test-Path $KeyPath) {
        $Confirm = Read-Host "strongbox: $KeyPath already exists. Type 'overwrite' to replace it"
        if ($Confirm -ne "overwrite") { Write-Host "cancelled."; exit 1 }
      }
      Copy-Item -Path $Src -Destination $KeyPath -Force
      Write-Host "restored $KeyPath from $Src"
      Write-Host "verify with: erda open lockbox <ship>"
    }

    default {
      Write-Error "usage: erda strongbox <init|backup|restore> [args...]"
      exit 1
    }
  }
}

if ([string]::IsNullOrEmpty($Command)) {
  Write-Host $Usage
  exit 1
}

switch ($Command) {
  "install" {
    Invoke-Install
  }

  "christen" {
    Invoke-Christen @Rest
  }

  "strongbox" {
    Invoke-Strongbox @Rest
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
    # rather than redirecting PowerShell's stream (see Invoke-Christen's own
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
