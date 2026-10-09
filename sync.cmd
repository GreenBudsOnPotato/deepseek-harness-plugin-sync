@echo off
rem ---------------------------------------------------------------------------
rem sync.cmd - one-click plugin sync for the two DSH installations.
rem
rem   sync.cmd                 sync the desktop and web profiles
rem   sync.cmd -DryRun         show what would change, write nothing
rem   sync.cmd -Force          reinstall every plugin on both sides
rem   sync.cmd -GrantExemptions -AllowRunningDesktop
rem
rem The working script lives in scripts\ and is not code-signed, while a default
rem Windows PowerShell policy (RemoteSigned) refuses to load unsigned .ps1
rem files. -ExecutionPolicy Bypass relaxes that for THIS PROCESS ONLY: no
rem machine-wide policy is changed and nothing is permanently bypassed.
rem Any argument is forwarded verbatim to scripts\Sync-DshPlugins.ps1.
rem ---------------------------------------------------------------------------
setlocal
set "SCRIPT=%~dp0scripts\Sync-DshPlugins.ps1"
if not exist "%SCRIPT%" (
  echo [ERROR] not found: %SCRIPT%
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
