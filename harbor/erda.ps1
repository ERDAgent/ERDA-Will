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
    doctor                                   host-side credential health check (no ship
                                              needed) -- also runs automatically before
                                              christen/board, which refuse to proceed if
                                              it fails
    board [ship]                             connect: multipass info + ssh in, deploying
                                              the age key if needed and connecting with
                                              the strongbox already unlocked (captain
                                              scope: model keys + GH_TOKEN)
    telescope <charter> [ship] [port]        SSH-tunnel to a charter's dev server
                                              (integration branch); port read from
                                              charter.md if not given
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
  doctor                                    host-side credential health check (no ship
                                             needed); christen/board also run this first
                                             and refuse to proceed if it fails
  board [ship]                              connect (multipass info + ssh), deploying the
                                             age key if needed and unlocking the strongbox
  telescope <charter> [ship] [port]         SSH-tunnel to a charter's dev server (port
                                             read from charter.md if not given)
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
      Write-AgeSecret "DEEPINFRA_API_KEY=$PlainDeepInfra" $Recipient $KeysEnvPath
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
          Write-AgeSecret "GH_TOKEN=$PlainGh" $Recipient $CaptainEnvPath
          $CaptainLen = (& age -d -i $KeyPath $CaptainEnvPath | Measure-Object -Character).Characters
          Write-Host "wrote captain.env.age (decrypts to $CaptainLen bytes)"
        }
      }

      Write-Host ""
      $AddCc = Read-Host "Also set up the shipwright compartment (ANTHROPIC_API_KEY) now? [y/N]"
      if ($AddCc -match '^[Yy]$') {
        $CcKey = Read-Host "ANTHROPIC_API_KEY (input hidden)" -AsSecureString
        $PlainCc = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($CcKey))
        if (-not $PlainCc) {
          Write-Warning "strongbox: empty value entered, skipping shipwright compartment"
        } else {
          $ShipwrightEnvPath = Join-Path $RepoRoot "strongbox\shipwright.env.age"
          Write-AgeSecret "ANTHROPIC_API_KEY=$PlainCc" $Recipient $ShipwrightEnvPath
          $ShipwrightLen = (& age -d -i $KeyPath $ShipwrightEnvPath | Measure-Object -Character).Characters
          Write-Host "wrote shipwright.env.age (decrypts to $ShipwrightLen bytes)"
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
      Write-Host "verify with: erda board <ship>"
    }

    default {
      Write-Error "usage: erda strongbox <init|backup|restore> [args...]"
      exit 1
    }
  }
}

# Writes plaintext to a real temp file with an explicit LF terminator, then
# hands that file to `age` as its input argument -- NOT `"text" | & age ...`.
# Piping a string to a native process's stdin in PowerShell appends CRLF, not
# a bare LF, which silently bakes a stray \r into the encrypted secret. That
# \r decrypts to a plausible, right-length-looking value on Windows (both
# PowerShell's own pipeline and even git-bash's sed launder it back out
# transparently), so it only ever breaks on a real Linux ship's bash/sed --
# GitHub rejected the resulting GH_TOKEN outright, indistinguishable from a
# genuinely revoked/expired one, until traced to this encoding bug.
function Write-AgeSecret([string]$PlainText, [string]$Recipient, [string]$OutPath) {
  $Tmp = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($Tmp, "$PlainText`n", (New-Object Text.UTF8Encoding $false))
    & age -r $Recipient -o $OutPath $Tmp
  } finally {
    Remove-Item $Tmp -Force -ErrorAction SilentlyContinue
  }
}

# Detects a stray CR byte in a decrypted secret. Can't just check the
# PowerShell-captured `& age -d ...` output for this: PowerShell's own
# pipeline splits native stdout into line objects and silently drops the
# very \r this needs to catch, same as git-bash's sed does -- both would
# report a false "clean" result for exactly the corruption this exists to
# find. Routing the redirection through cmd.exe instead keeps it a raw
# byte-for-byte file write, bypassing PowerShell's pipeline entirely.
function Test-HasCR([string]$KeyPath, [string]$AgeFile) {
  $Tmp = [IO.Path]::GetTempFileName()
  try {
    cmd /c "age -d -i `"$KeyPath`" `"$AgeFile`" > `"$Tmp`" 2>nul" | Out-Null
    $Bytes = [IO.File]::ReadAllBytes($Tmp)
    return ($Bytes -contains 0x0D)
  } finally {
    Remove-Item $Tmp -Force -ErrorAction SilentlyContinue
  }
}

function Test-KeyLive([string]$Url, [hashtable]$Headers) {
  try {
    $Resp = Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    return [int]$Resp.StatusCode
  } catch {
    if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
    return 0
  }
}

# doctor — host-side credential health check, no ship needed. Distinguishes
# the three states an operator actually cares about (no key at all / a key
# that can't decrypt the committed .env.age files / a key that decrypts fine
# but the credential inside has gone bad upstream) instead of letting all
# three surface identically, deep inside charter's or muster's own silent
# fallback. That collapse is real, not hypothetical: an expired/revoked
# GH_TOKEN decrypts to a perfectly valid-looking string and produces the
# exact same "gh not authenticated" fallback message a missing token does --
# only a live call to GitHub itself tells them apart.
#
# DEEPINFRA_API_KEY and GH_TOKEN are treated differently on purpose:
# keys.env.age is required baseline (nothing works without a model key), but
# captain.env.age/shipwright.env.age are optional compartments -- not having
# them at all is a legitimate "local-only, no push" choice charter already
# supports gracefully. Only a compartment that EXISTS but is broken fails
# doctor; one that was never provisioned is silently skipped.
function Invoke-Doctor {
  # Local override, same reasoning as Invoke-Strongbox: `age -d` (and gh/curl
  # failures below) must not become terminating exceptions under the script's
  # global "Stop" preference just because we check $LASTEXITCODE ourselves.
  $ErrorActionPreference = "Continue"
  $KeyPath = Join-Path $RepoRoot "strongbox\ship.key"
  $Ok = $true

  if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
    Write-Warning "doctor: 'age' isn't installed on this machine (winget install --id FiloSottile.age)"
    return $false
  }

  if (-not (Test-Path $KeyPath)) {
    Write-Warning "doctor: NO KEY -- $KeyPath doesn't exist yet. Run: erda strongbox init"
    return $false
  }

  $KeysAge = Join-Path $RepoRoot "strongbox\keys.env.age"
  if (-not (Test-Path $KeysAge)) {
    Write-Warning "doctor: NO KEY -- $KeysAge doesn't exist yet. Run: erda strongbox init"
    return $false
  }

  $KeysPlain = & age -d -i $KeyPath $KeysAge 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "doctor: WRONG KEY -- $KeyPath can't decrypt $KeysAge (stale/regenerated ship.key? see strongbox/README.md's stale-checkout note)"
    return $false
  }
  if (Test-HasCR $KeyPath $KeysAge) {
    Write-Warning "doctor: $KeysAge has a Windows CRLF baked into its plaintext (stray \r) -- likely encrypted via a PowerShell 'string | age' pipe before that was fixed. Re-encrypt via 'erda strongbox init'; it silently 'looks' fine from Windows tools but breaks on a real Linux ship"
    $Ok = $false
  }
  $DeepInfraMatch = $KeysPlain | Select-String '^DEEPINFRA_API_KEY=(.*)$'
  $DeepInfraKey = if ($DeepInfraMatch) { $DeepInfraMatch.Matches[0].Groups[1].Value } else { $null }
  if (-not $DeepInfraKey) {
    Write-Warning "doctor: keys.env.age decrypts but DEEPINFRA_API_KEY is empty -- re-run erda strongbox init"
    $Ok = $false
  } else {
    $Code = Test-KeyLive "https://api.deepinfra.com/v1/openai/models" @{ Authorization = "Bearer $DeepInfraKey" }
    if ($Code -ne 200) {
      Write-Warning "doctor: DEEPINFRA_API_KEY decrypts fine but DeepInfra rejected it (HTTP $Code) -- mint a new key and re-encrypt keys.env.age"
      $Ok = $false
    } else {
      Write-Host "doctor: DEEPINFRA_API_KEY OK"
    }
  }

  $CaptainAge = Join-Path $RepoRoot "strongbox\captain.env.age"
  if (Test-Path $CaptainAge) {
    $CaptainPlain = & age -d -i $KeyPath $CaptainAge 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "doctor: WRONG KEY -- $KeyPath can't decrypt $CaptainAge"
      $Ok = $false
    } elseif (Test-HasCR $KeyPath $CaptainAge) {
      Write-Warning "doctor: $CaptainAge has a Windows CRLF baked into its plaintext (stray \r) -- likely encrypted via a PowerShell 'string | age' pipe before that was fixed. Re-encrypt via 'erda strongbox init'; it silently 'looks' fine from Windows tools but breaks on a real Linux ship"
      $Ok = $false
    } else {
      $GhMatch = $CaptainPlain | Select-String '^GH_TOKEN=(.*)$'
      $GhToken = if ($GhMatch) { $GhMatch.Matches[0].Groups[1].Value } else { $null }
      if (-not $GhToken) {
        Write-Warning "doctor: captain.env.age decrypts but GH_TOKEN is empty -- re-encrypt captain.env.age"
        $Ok = $false
      } elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning "doctor: 'gh' isn't installed on this machine -- can't live-check GH_TOKEN, only that it decrypts"
      } else {
        $env:GH_TOKEN = $GhToken
        & gh auth status *> $null
        $GhOk = ($LASTEXITCODE -eq 0)
        Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
        if (-not $GhOk) {
          Write-Warning "doctor: GH_TOKEN decrypts fine but GitHub rejected it (expired/revoked?) -- mint a new fine-grained PAT (Repository access: All repositories, Administration: Read and write) and re-encrypt captain.env.age, see strongbox/README.md"
          $Ok = $false
        } else {
          Write-Host "doctor: GH_TOKEN OK"
        }
      }

      # Backend-switching (see ship/backends.json / docs/backend-switching-guide.md)
      # can put CLAUDE_CODE_OAUTH_TOKEN and/or ANTHROPIC_API_KEY in this same
      # file, independent of GH_TOKEN above -- optional, not having either yet
      # is a legitimate "still on deepinfra/codex" state, not a failure.
      $ClaudeOauthMatch = $CaptainPlain | Select-String '^CLAUDE_CODE_OAUTH_TOKEN=(.*)$'
      $ClaudeOauth = if ($ClaudeOauthMatch) { $ClaudeOauthMatch.Matches[0].Groups[1].Value } else { $null }
      $ClaudeApiKeyMatch = $CaptainPlain | Select-String '^ANTHROPIC_API_KEY=(.*)$'
      $ClaudeApiKey = if ($ClaudeApiKeyMatch) { $ClaudeApiKeyMatch.Matches[0].Groups[1].Value } else { $null }
      if ($ClaudeOauth) {
        # Live-tested directly against api.anthropic.com/v1/models while building
        # this check: a bogus ANTHROPIC_API_KEY gets a real 401 there, but that
        # endpoint has no confirmed relationship to CLAUDE_CODE_OAUTH_TOKEN's own
        # auth flow -- and `claude --version`/`claude auth status` were both
        # live-tested and confirmed to report success even for a bogus or absent
        # credential, so neither substitutes for a real check. Presence is
        # reported honestly instead of guessing at an unverified probe.
        Write-Host "doctor: captain.env.age has CLAUDE_CODE_OAUTH_TOKEN (present -- not live-verifiable via a direct API probe; a charter Captain's first real turn under backend=claude will surface an auth failure immediately if it's bad)"
      } elseif ($ClaudeApiKey) {
        $Code = Test-KeyLive "https://api.anthropic.com/v1/models" @{ "x-api-key" = $ClaudeApiKey; "anthropic-version" = "2023-06-01" }
        if ($Code -ne 200) {
          Write-Warning "doctor: captain.env.age's ANTHROPIC_API_KEY decrypts fine but Anthropic rejected it (HTTP $Code) -- mint a new key, see strongbox/README.md's Backend-switching section"
          $Ok = $false
        } else {
          Write-Host "doctor: captain.env.age's ANTHROPIC_API_KEY OK (charter Captain can use backend=claude)"
        }
      }
    }
  }

  $ShipwrightAge = Join-Path $RepoRoot "strongbox\shipwright.env.age"
  if (Test-Path $ShipwrightAge) {
    $ShipwrightPlain = & age -d -i $KeyPath $ShipwrightAge 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "doctor: WRONG KEY -- $KeyPath can't decrypt $ShipwrightAge"
      $Ok = $false
    } elseif (Test-HasCR $KeyPath $ShipwrightAge) {
      Write-Warning "doctor: $ShipwrightAge has a Windows CRLF baked into its plaintext (stray \r) -- likely encrypted via a PowerShell 'string | age' pipe before that was fixed. Re-encrypt via 'erda strongbox init'; it silently 'looks' fine from Windows tools but breaks on a real Linux ship"
      $Ok = $false
    } else {
      $AnthropicMatch = $ShipwrightPlain | Select-String '^ANTHROPIC_API_KEY=(.*)$'
      $AnthropicKey = if ($AnthropicMatch) { $AnthropicMatch.Matches[0].Groups[1].Value } else { $null }
      if (-not $AnthropicKey) {
        Write-Warning "doctor: shipwright.env.age decrypts but ANTHROPIC_API_KEY is empty"
        $Ok = $false
      } else {
        $Code = Test-KeyLive "https://api.anthropic.com/v1/models" @{ "x-api-key" = $AnthropicKey; "anthropic-version" = "2023-06-01" }
        if ($Code -ne 200) {
          Write-Warning "doctor: ANTHROPIC_API_KEY decrypts fine but Anthropic rejected it (HTTP $Code)"
          $Ok = $false
        } else {
          Write-Host "doctor: ANTHROPIC_API_KEY OK"
        }
      }
    }
  }

  return $Ok
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
    if (-not (Invoke-Doctor)) {
      Write-Error "christen: fix the strongbox issues above first (see 'erda doctor')"
      exit 1
    }
    Invoke-Christen @Rest
  }

  "strongbox" {
    Invoke-Strongbox @Rest
  }

  "doctor" {
    if (Invoke-Doctor) { Write-Host "doctor: all checks passed" } else { exit 1 }
  }

  "board" {
    # Ships get sunk and christened often enough that a separate "now unlock
    # it" step was pure friction -- boarding always deploys ship.key (if
    # missing) and connects with the strongbox already unlocked, as long as a
    # local strongbox\ship.key exists at all. Before `erda strongbox init` has
    # ever been run there's nothing to deploy, so it falls back to a plain
    # connect rather than failing hard.
    if (-not (Invoke-Doctor)) {
      Write-Error "board: fix the strongbox issues above first (see 'erda doctor')"
      exit 1
    }
    $Name = Get-Arg0
    $Ip = Get-ShipIp $Name
    Write-Host "boarding '$Name' ($Ip)..."

    $KeyPath = Join-Path $RepoRoot "strongbox\ship.key"
    if (-not (Test-Path $KeyPath)) {
      Write-Warning "erda: no local strongbox\ship.key yet -- connecting without the strongbox unlocked (see strongbox/README.md)"
      ssh -i $SshPriv eric@$Ip
    } else {
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
      ssh -i $SshPriv -t eric@$Ip 'eval "$(unlock captain)"; exec bash -l'
    }
  }

  "telescope" {
    # SSH port-forward to a charter's dev server (see ship/bin/telescope,
    # sail's "telescope" window) -- never a raw exposed port, so the dev
    # server only ever needs to bind localhost on the ship itself.
    if ($Rest.Count -lt 1 -or -not $Rest[0]) {
      Write-Error "usage: erda telescope <charter> [ship] [port]"
      exit 1
    }
    $Name = $Rest[0]
    $ShipName = if ($Rest.Count -ge 2 -and $Rest[1]) { $Rest[1] } else { "ship" }
    $Port = if ($Rest.Count -ge 3 -and $Rest[2]) { $Rest[2] } else { $null }
    $Ip = Get-ShipIp $ShipName

    Write-Host "ensuring the deck is up for '$Name' on '$ShipName' ($Ip)..."
    ssh -i $SshPriv -o LogLevel=ERROR eric@$Ip "SHIP_NO_ATTACH=1 sail $Name"

    if (-not $Port) {
      $Port = ssh -i $SshPriv -o LogLevel=ERROR eric@$Ip "sed -n '/^## Dev server/,/^## /{/^- port:/s/^- port: *//p}' ~/fleet/$Name/charter.md 2>/dev/null | head -1"
      if (-not $Port -or $Port -match '^\(') {
        Write-Error "erda: no port configured in ~/fleet/$Name/charter.md's '## Dev server' section (and none given as an argument)"
        Write-Error "  fill it in, or run: erda telescope $Name $ShipName <port>"
        exit 1
      }
    }

    Write-Host "tunneling localhost:$Port -> ${ShipName}:$Port ..."
    Write-Host "open: http://localhost:$Port"
    Write-Host "(Ctrl+C to close the tunnel)"
    ssh -i $SshPriv -N -L "${Port}:localhost:${Port}" eric@$Ip
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
