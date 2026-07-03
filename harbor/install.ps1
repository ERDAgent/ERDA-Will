<#
.SYNOPSIS
  install — wire up `erda` (harbor/erda.ps1, the command dispatcher for all
  harbor/* operations: christen, board, open lockbox, anchor, sail, ...) as
  a global shell command, so you can type `erda <command>` from anywhere.
.DESCRIPTION
  This is the reproducibility story for "just typing erda from anywhere":
  PATH and PowerShell profile changes are per-machine state that git can't
  carry across computers, so instead of asking you to hand-edit your profile,
  the setup step itself lives in this repo. On a fresh machine: clone the
  repo, run this script once, restart your terminal (or dot-source $PROFILE).
  `erda` then works globally, permanently, on that machine.

  Idempotent: re-running (e.g. after moving the repo to a new path, or after
  pulling an updated harbor/) replaces the previously-installed block rather
  than duplicating it.
.EXAMPLE
  .\harbor\install.ps1
  # or, on a fresh machine where this script itself can't run yet (see below):
  harbor\install.cmd
#>
$ErrorActionPreference = "Stop"

# On a fresh Windows account, PowerShell's default execution policy
# (Restricted, when every scope shows Undefined) blocks *any* local .ps1
# file, including christen.ps1 and, on some paths to get here, this script
# itself -- install.cmd exists specifically to bootstrap around that
# chicken-and-egg case via a one-time -ExecutionPolicy Bypass, since batch
# files aren't subject to PowerShell's execution policy at all. This section
# is what makes the fix permanent: RemoteSigned at CurrentUser scope, so
# every later `christen` call (and this script, if re-run) works normally
# without needing Bypass again. Scoped to CurrentUser only -- doesn't touch
# other accounts or require admin rights.
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

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ErdaPath = Join-Path $RepoRoot "harbor\erda.ps1"
if (-not (Test-Path $ErdaPath)) {
  Write-Error "install: expected $ErdaPath to exist -- run this from a real ERDA-Will checkout"
  exit 1
}

if (-not (Test-Path $PROFILE)) {
  New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$MarkerStart = "# --- ERDA-Will harbor commands (managed by harbor/install.ps1) ---"
$MarkerEnd = "# --- end ERDA-Will harbor commands ---"
$Block = "$MarkerStart`nfunction erda { & `"$ErdaPath`" @args }`n$MarkerEnd"

$Existing = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if ($Existing -and $Existing.Contains($MarkerStart)) {
  # Strip the previously-installed block (by marker lines), then append the
  # current one -- handles both a stale path (repo moved) and an update to
  # this script's own logic.
  $Lines = Get-Content $PROFILE
  $Kept = New-Object System.Collections.Generic.List[string]
  $Skipping = $false
  foreach ($line in $Lines) {
    if ($line -eq $MarkerStart) { $Skipping = $true; continue }
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
