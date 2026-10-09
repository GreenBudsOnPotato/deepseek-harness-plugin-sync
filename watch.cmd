@echo off
rem ---------------------------------------------------------------------------
rem watch.cmd - keep the two DSH installations in sync automatically.
rem
rem   watch.cmd                          watch until closed (Ctrl+C)
rem   watch.cmd -IntervalSec 10 -SettleSec 30
rem   watch.cmd -Once -DryRun            single check, change nothing
rem
rem Polls the plugin manifests of both profiles and runs the sync whenever one
rem changes. See scripts\Watch-DshPlugins.ps1 for details.
rem ---------------------------------------------------------------------------
setlocal
set "SCRIPT=%~dp0scripts\Watch-DshPlugins.ps1"
if not exist "%SCRIPT%" (
  echo [ERROR] not found: %SCRIPT%
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
