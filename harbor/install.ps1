<#
.SYNOPSIS
  install — wire up harbor/* commands (currently: christen) as global shell
  commands, so you can type `christen` from any directory.
.DESCRIPTION
  This is the reproducibility story for "just typing christen from anywhere":
  PATH and PowerShell profile changes are per-machine state that git can't
  carry across computers, so instead of asking you to hand-edit your profile,
  the setup step itself lives in this repo. On a fresh machine: clone the
  repo, run this script once, restart your terminal (or dot-source $PROFILE).
  `christen` then works globally, permanently, on that machine.

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
  Write-Host "setting your execution policy to RemoteSigned (needed to run local scripts like christen)..."
  try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
  } catch {
    Write-Warning "couldn't set execution policy automatically: $($_.Exception.Message)"
    Write-Warning "if this machine is managed by Group Policy, ask an admin to allow RemoteSigned (or less restrictive) for your account."
  }
}
$EffectivePolicy = Get-ExecutionPolicy
if ($EffectivePolicy -in @("Restricted", "AllSigned")) {
  Write-Warning "effective execution policy is still $EffectivePolicy -- christen may not run yet."
  Write-Warning "run 'Get-ExecutionPolicy -List' to see what's overriding CurrentUser (likely MachinePolicy or UserPolicy via Group Policy)."
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ChristenPath = Join-Path $RepoRoot "harbor\christen.ps1"
if (-not (Test-Path $ChristenPath)) {
  Write-Error "install: expected $ChristenPath to exist -- run this from a real ERDA-Will checkout"
  exit 1
}

if (-not (Test-Path $PROFILE)) {
  New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$MarkerStart = "# --- ERDA-Will harbor commands (managed by harbor/install.ps1) ---"
$MarkerEnd = "# --- end ERDA-Will harbor commands ---"
$Block = "$MarkerStart`nfunction christen { & `"$ChristenPath`" @args }`n$MarkerEnd"

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
  Write-Host "updated existing christen install in $PROFILE (path may have changed)"
} else {
  Add-Content -Path $PROFILE -Value "`n$Block"
  Write-Host "installed christen into $PROFILE"
}

Write-Host ""
Write-Host "Restart your terminal, or run: . `$PROFILE"
Write-Host "Then 'christen' works from any directory."
