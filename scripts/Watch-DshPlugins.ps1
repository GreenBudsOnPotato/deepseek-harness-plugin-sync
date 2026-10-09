<#
.SYNOPSIS
    Watch both DSH plugin manifests and keep the two installations in sync
    automatically.

.DESCRIPTION
    Runs Sync-DshPlugins.ps1 whenever the plugin manifest of either profile or
    the profile's compatibility.json changes -- that is, whenever a plugin is
    installed, upgraded or removed through either app's plugin UI.

    Behaviour:
      * Polls the watched files every -IntervalSec seconds (default 5).
      * After detecting a change it waits -SettleSec seconds (default 20) so a
        multi-step install finishes before syncing.
      * Never overlaps two sync runs.
      * Runs with -AllowRunningDesktop, because the desktop app is normally
        open. Sync-DshPlugins.ps1 still refuses to install into the desktop
        profile unless that flag is given; when the desktop side cannot be
        updated the run is logged and retried on the next change.
      * Writes everything to dsh-plugin-watch.log.

.PARAMETER IntervalSec
    Poll interval in seconds. Default 5.
.PARAMETER SettleSec
    Quiet period after a detected change before syncing. Default 20.
.PARAMETER Once
    Check once and exit (useful from a scheduled task).
.PARAMETER DryRun
    Forward -DryRun to the sync script: log what would happen, change nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Watch-DshPlugins.ps1
    Watch until interrupted (Ctrl+C).
#>
[CmdletBinding()]
param(
    [int]$IntervalSec = 5,
    [int]$SettleSec = 20,
    [switch]$Once,
    [switch]$DryRun,
    [string]$DshHome,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = $PSScriptRoot
$syncScript = Join-Path $scriptDir 'Sync-DshPlugins.ps1'
if (-not $LogPath) { $LogPath = Join-Path $scriptDir 'dsh-plugin-watch.log' }
if (-not (Test-Path -LiteralPath $syncScript)) { throw "sync script not found: $syncScript" }

if (-not $DshHome) {
    if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME } else { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
}

function Write-WatchLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

# Files whose content tells us a plugin set changed.
$watched = @()
foreach ($profile in @('desktop', 'web')) {
    foreach ($name in @('package.json', 'compatibility.json', 'cordis.patch.yml')) {
        $watched += (Join-Path (Join-Path (Join-Path $DshHome 'profiles') $profile) $name)
    }
}

function Get-WatchSignature {
    $parts = @()
    foreach ($f in $watched) {
        if (Test-Path -LiteralPath $f) {
            $item = Get-Item -LiteralPath $f
            $parts += ("{0}|{1}|{2}" -f $item.FullName, $item.Length, $item.LastWriteTimeUtc.Ticks)
        } else {
            $parts += ("{0}|missing" -f $f)
        }
    }
    return ($parts -join ';')
}

function Invoke-Sync {
    param([string]$Reason)
    Write-WatchLog "syncing ($Reason)"
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $syncScript, '-AllowRunningDesktop')
    if ($DryRun) { $argv += '-DryRun' }
    $out = & powershell @argv 2>&1
    foreach ($line in @($out)) {
        $text = [string]$line
        if ($text.Trim()) { Write-WatchLog "  $text" }
    }
    Write-WatchLog "sync finished with exit $LASTEXITCODE"
}

Write-WatchLog "watching $($watched.Count) files under $DshHome"
$previous = Get-WatchSignature

if ($Once) {
    Invoke-Sync 'once'
    exit 0
}

$pendingSince = $null
while ($true) {
    Start-Sleep -Seconds $IntervalSec
    $current = Get-WatchSignature
    if ($current -ne $previous) {
        if ($null -eq $pendingSince) {
            Write-WatchLog 'change detected, waiting for the install to settle'
            $pendingSince = Get-Date
        }
        $previous = $current
    }
    if ($null -ne $pendingSince) {
        $quietFor = (New-TimeSpan -Start $pendingSince).TotalSeconds
        if ($quietFor -ge $SettleSec) {
            $pendingSince = $null
            try { Invoke-Sync 'change detected' } catch { Write-WatchLog "sync failed: $_" 'ERROR' }
            $previous = Get-WatchSignature
        }
    }
}
