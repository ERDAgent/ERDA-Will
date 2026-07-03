@echo off
rem install.cmd — bootstrap wrapper for install.ps1.
rem
rem Batch files aren't PowerShell scripts, so they're never subject to
rem PowerShell's execution policy -- unlike install.ps1 itself, which (on a
rem fresh machine with the default Restricted policy) can't run at all,
rem including to fix that same policy. This wrapper breaks that chicken-
rem and-egg problem: -ExecutionPolicy Bypass applies only to this one
rem invocation, not permanently, and install.ps1 itself sets a real,
rem permanent CurrentUser policy (RemoteSigned) so every later christen
rem call works normally without needing Bypass tricks again.
rem
rem Double-click this file, or run it from cmd.exe: harbor\install.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
