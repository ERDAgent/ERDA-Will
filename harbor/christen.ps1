<#
.SYNOPSIS
  christen — launch a new ship with one command and sensible defaults.
.DESCRIPTION
  Handles the whole first-provisioning dance: substitutes your real SSH key
  into keel.yaml (never writing the substituted copy into the repo), calls
  `multipass launch`, then waits for SSH and cloud-init to actually finish
  before handing control back -- so "christen" means "ready to use", not
  just "instance exists". Runs from the Harbor (your host machine), before
  any ship exists -- that's why this isn't in ship/bin/*, which only exists
  once a ship is already up.

  Fleet naming (D16): flagships get Will-class virtue names (resolve,
  endeavour, tenacity...); skiffs use skiff-<purpose> and get purged same
  day. This script doesn't enforce either -- name whatever you want.
.EXAMPLE
  .\christen.ps1
  .\christen.ps1 -Name resolve
  .\christen.ps1 -Name resolve -Cpus 4 -Memory 8G -Disk 40G
#>
param(
  [string]$Name = "ship",
  [int]$Cpus = 2,
  [string]$Memory = "4G",
  [string]$Disk = "20G"
)

# Deliberately NOT $ErrorActionPreference = "Stop": in PowerShell 5.1, any
# redirected stderr output from a native exe (ssh, multipass) gets wrapped
# into an ErrorRecord and promoted to a terminating exception under Stop --
# turning ssh's harmless "Warning: Permanently added ... to the list of
# known hosts" notice into a script-ending failure. Every native call below
# is checked explicitly via $LASTEXITCODE instead.

if ($Name -notmatch '^[A-Za-z]$' -and $Name -notmatch '^[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$') {
  Write-Error "christen: invalid name '$Name' (letters, digits, hyphens; must start with a letter, end alphanumeric)"
  exit 1
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$KeelSrc = Join-Path $RepoRoot "keel.yaml"
if (-not (Test-Path $KeelSrc)) {
  Write-Error "christen: keel.yaml not found at $KeelSrc"
  exit 1
}

$SshPriv = "$env:USERPROFILE\.ssh\id_ed25519"
$SshPub = "$SshPriv.pub"
if (-not (Test-Path $SshPub)) {
  Write-Error "christen: no SSH public key at $SshPub -- generate one first: ssh-keygen -t ed25519"
  exit 1
}

$PubKey = (Get-Content $SshPub -Raw).Trim()
$TmpKeel = Join-Path $env:TEMP "keel-christen-$([guid]::NewGuid().ToString('N')).yaml"
(Get-Content $KeelSrc) -replace 'REPLACE-ME-with-your-ssh-public-key', $PubKey | Set-Content -Encoding utf8 $TmpKeel

$MP = "multipass"
if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
  $MP = "C:\Program Files\Multipass\bin\multipass.exe"
}

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
    $Ip = ($IpLine -split '\s+')[1]
    if ($Ip) { break }
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
