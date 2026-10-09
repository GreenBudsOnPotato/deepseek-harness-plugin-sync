<#
.SYNOPSIS
    Bidirectional plugin sync between the two DSH installations on this machine:
      profile "desktop" -> DeepSeek Harness Desktop (Electron app)
      profile "web"     -> web version (DSH Studio / `dsh web`)

.DESCRIPTION
    Both installations share one $DSH_HOME but keep plugins in their own profile
    directory:
      <DSH_HOME>\profiles\desktop
      <DSH_HOME>\profiles\web
    so plugins installed on one side are invisible to the other. This script
    merges the two sides (dependencies + bundle order + exact-version
    exemptions) and then installs only on the side that is actually missing
    something. Run it after installing/changing/removing a plugin on either
    side and both sides converge.

    Merge rules (deterministic, so the two sides never flap):
      * dependencies         union; for a package present on both sides the
                             higher version range wins.
      * dsh.profile.bundles  union; each side keeps its own order first, then
                             the other side's extra entries are appended.
      * compatibility.json   union of exact-version exemptions (a union only
                             ever loosens policy; it never disables a plugin
                             that already works here).
      * cordis.patch.yml     NOT touched by default. The desktop profile holds
                             desktop-only settings (model / theme) while the web
                             profile's file is empty, so merging would push the
                             desktop settings into the web profile.
                             Use -SyncPatchFile to merge it as well.

    This script only reads and writes the two profile directories. It does not
    touch sessions, credentials or anything else under $DSH_HOME.

.PARAMETER ProfileA
    First profile name. Default: desktop.
.PARAMETER ProfileB
    Second profile name. Default: web.
.PARAMETER DshHome
    DSH home directory. Defaults to $env:DSH_HOME, else ~\.dsh.
.PARAMETER DryRun
    Show what would change. Writes nothing, installs nothing.
.PARAMETER SyncPatchFile
    Merge cordis.patch.yml as well (off by default).
.PARAMETER Force
    Reinstall every plugin on both sides even when the manifests already agree.
    Useful to repair a damaged node_modules.
.PARAMETER NoExemptions
    Do not copy compatibility.json exact-version exemptions.
.PARAMETER Pin
    Pin a plugin to one version on both sides, e.g.
      -Pin dsh-mnemon@0.5.25
    Repeatable. Use this to move both installations onto versions that declare
    support for the newer harness line.
.PARAMETER AllowRunningDesktop
    By default the script refuses to install into the desktop profile while the
    desktop app is running. Pass this to install anyway; the plugins only take
    effect after the desktop app is fully restarted.
.PARAMETER GrantExemptions
    Before installing, grant a dsh exact-version exemption for every plugin in
    the merged set on both sides. This is what lets a plugin whose declared peer
    range predates the newer harness release still install and start.
.PARAMETER DesktopRoot
    Installation directory of DeepSeek Harness Desktop. Discovered from the
    running process and the usual install locations when omitted. The
    DSH_DESKTOP_ROOT environment variable works too.
.PARAMETER WebCliNode
    Node.js executable used to run the web CLI. Defaults to node.exe on PATH,
    then the DSH-managed runtime. DSH_WEB_NODE works too.
.PARAMETER WebCliScript
    Path to @deepseek-ai/dsh/lib/bin.js for the web installation. Defaults to
    the one behind the dsh launcher on PATH, then the npm global prefix, then
    the DSH-managed runtime. DSH_WEB_CLI works too.
.PARAMETER LogPath
    Log file. Defaults to <script folder>\dsh-plugin-sync.log.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Sync-DshPlugins.ps1 -DryRun
    Preview the changes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Sync-DshPlugins.ps1
    Normal sync.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Sync-DshPlugins.ps1 -GrantExemptions -AllowRunningDesktop
    Sync and accept the exact-version risk for plugins behind the new harness line.
#>
[CmdletBinding()]
param(
    [string]$ProfileA = 'desktop',
    [string]$ProfileB = 'web',
    [string]$DshHome,
    [switch]$DryRun,
    [switch]$SyncPatchFile,
    [switch]$Force,
    [switch]$NoExemptions,
    [string[]]$Pin = @(),
    [switch]$AllowRunningDesktop,
    [switch]$GrantExemptions,
    [string]$DesktopRoot,
    [string]$WebCliNode,
    [string]$WebCliScript,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -Pin may arrive as one comma/space separated string (that is what
# `powershell -File script.ps1 -Pin a@1,b@2` produces), so normalize it into a
# real list before anything else.
$Pin = @(
    foreach ($entry in $Pin) {
        foreach ($part in ([string]$entry -split '[,;\s]+')) {
            if ($part.Trim()) { $part.Trim() }
        }
    }
)

# ------------------------------------------------------------- infrastructure

if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'dsh-plugin-sync.log' }

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$stamp] [$Level] $Message"
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

function Resolve-DshHome {
    param([string]$Explicit)
    if ($Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
    if ($env:DSH_HOME) { return $env:DSH_HOME }
    return (Join-Path $env:USERPROFILE '.dsh')
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    if ($DryRun) { Write-Log "DRY-RUN, not writing: $Path" 'STEP'; return }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = ($Object | ConvertTo-Json -Depth 12) + "`n"
    # Atomic write: never let a running app read a half-written manifest.
    $tmp = "$Path.tmp-$PID"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    Write-Log "wrote $Path"
}

# JSON objects are safer as hashtables here: under StrictMode, reading a
# missing property throws.
#
# IMPORTANT: PSObject.Properties does NOT enumerate the entries of a dictionary
# (including [ordered]); it reports the dictionary's own CLR properties, so a
# dictionary converted that way silently becomes a map of nulls. Enumerate the
# dictionary explicitly, and fall back to PSObject.Properties only for real
# object graphs produced by ConvertFrom-Json.
function ConvertTo-Hashtable {
    param($InputObject)
    $ht = @{}
    if ($null -eq $InputObject) { return $ht }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { $ht[[string]$key] = $InputObject[$key] }
        return $ht
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $InputObject.PSObject.Properties) { $ht[$p.Name] = $p.Value }
        return $ht
    }
    foreach ($p in $InputObject.PSObject.Properties) { $ht[$p.Name] = $p.Value }
    return $ht
}

# ------------------------------------------------------------------ CLI layer

<#
    Each installation ships its own CLI and neither accepts the other's
    reserved profile, so both must be addressed separately:
      web     : the global dsh (<node>\...\@deepseek-ai\dsh\lib\bin.js)
      desktop : DeepSeek Harness Desktop's own dsh-desktop-host/lib/cli.js,
                executed by its bundled Electron binary in Node mode. That CLI
                is the only one allowed to manage the reserved desktop profile.
    A side with no CLI still gets its manifest merged; only the install is skipped.
#>
function Get-WebCli {
    param([Parameter(Mandatory)][string]$HomePath)
    # Any Node.js on PATH runs the web CLI (it is plain JavaScript), so PATH is
    # tried first and no per-machine Node location is hard-coded. Override with
    # the DSH_WEB_NODE / DSH_WEB_CLI environment variables or -WebCliNode /
    # -WebCliScript if discovery picks the wrong one.
    $nodes = @()
    if ($env:DSH_WEB_NODE) { $nodes += $env:DSH_WEB_NODE }
    if ($WebCliNode) { $nodes += $WebCliNode }
    $onPath = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $nodes += $onPath.Source }
    $nodes += (Join-Path $HomePath 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe')
    $node = $nodes | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

    $bins = @()
    if ($env:DSH_WEB_CLI) { $bins += $env:DSH_WEB_CLI }
    if ($WebCliScript) { $bins += $WebCliScript }
    # Derive from the `dsh` launcher on PATH: <prefix>\dsh.cmd -> <prefix>\node_modules\@deepseek-ai\dsh\lib\bin.js
    foreach ($launcher in @(Get-Command dsh.cmd, dsh.ps1, dsh -ErrorAction SilentlyContinue)) {
        if (-not $launcher.Source) { continue }
        $prefix = Split-Path -Parent $launcher.Source
        $bins += (Join-Path $prefix 'node_modules\@deepseek-ai\dsh\lib\bin.js')
    }
    $bins += (Join-Path $HomePath 'dsh-runtimes\dsh-primary-runtime\dependencies\node\node_modules\@deepseek-ai\dsh\lib\bin.js')
    # Last resort: the npm global prefix, which is where a global dsh lands.
    try {
        $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($npmCmd) {
            $prefix = (& cmd /c "`"$($npmCmd.Source)`" prefix -g" 2>$null | Select-Object -First 1)
            if ($prefix) { $bins += (Join-Path $prefix.Trim() 'node_modules\@deepseek-ai\dsh\lib\bin.js') }
        }
    } catch { }
    $bin = $bins | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

    if (-not $node -or -not $bin) { return $null }
    return [pscustomobject]@{ Kind = 'web'; Node = $node; Script = $bin; Label = "web ($bin)" }
}

function Get-DesktopCli {
    param([Parameter(Mandatory)][string]$HomePath)
    # The desktop app installs wherever the user put it, so the location is
    # discovered (running process -> explicit override -> common defaults)
    # instead of being hard-coded.
    $roots = @()
    if ($env:DSH_DESKTOP_ROOT) { $roots += $env:DSH_DESKTOP_ROOT }
    if ($DesktopRoot) { $roots += $DesktopRoot }
    foreach ($proc in @(Get-DesktopProcess)) {
        if ($proc.Path) { $roots += (Split-Path -Parent $proc.Path) }
    }
    $roots += (Join-Path ${env:ProgramFiles} 'DeepSeek Harness Desktop')
    if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness Desktop') }
    $roots += (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness Desktop')

    foreach ($root in $roots) {
        if (-not $root) { continue }
        $exe = Join-Path $root 'DeepSeek Harness.exe'
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        # app.asar looks like a plain FILE to PowerShell/.NET, so the script
        # inside it cannot be probed with Test-Path. Electron resolves asar
        # paths itself, which is exactly how the shipped dsh.cmd works.
        $cli = Join-Path $root 'resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js'
        return [pscustomobject]@{ Kind = 'desktop'; Node = $exe; Script = $cli; Label = "desktop ($cli)" }
    }
    return $null
}

function Get-DesktopProcess {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like '*DeepSeek Harness Desktop*' -or $_.ProcessName -eq 'DeepSeek Harness' }
}

# Arguments that make a CLI runnable, plus the environment it needs.
function Get-CliInvocation {
    param([Parameter(Mandatory)]$Cli)
    if ($Cli.Kind -eq 'desktop') {
        return [pscustomobject]@{ Prefix = @('--expose-internals'); SetElectronNode = $true }
    }
    return [pscustomobject]@{ Prefix = @(); SetElectronNode = $false }
}

function Invoke-Cli {
    param(
        [Parameter(Mandatory)]$Cli,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $inv = Get-CliInvocation -Cli $Cli
    $saved = $env:ELECTRON_RUN_AS_NODE
    $savedEap = $ErrorActionPreference
    if ($inv.SetElectronNode) { $env:ELECTRON_RUN_AS_NODE = '1' }
    try {
        # Native tools write progress and warnings to stderr; with
        # ErrorActionPreference=Stop that would abort the whole run, so relax it
        # for the duration of the call and capture both streams.
        $ErrorActionPreference = 'Continue'
        $argv = $inv.Prefix + @($Cli.Script) + $Arguments
        $out = & $Cli.Node @argv 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedEap
        if ($inv.SetElectronNode) {
            if ($null -eq $saved) { Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue }
            else { $env:ELECTRON_RUN_AS_NODE = $saved }
        }
    }
    # Keep only plain text; pnpm/electron can emit ErrorRecord objects.
    $lines = @()
    foreach ($item in @($out)) {
        if ($item -is [System.Management.Automation.ErrorRecord]) { $lines += [string]$item.Exception.Message }
        elseif ($null -ne $item) { $lines += [string]$item }
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $lines }
}

function Invoke-PluginAdd {
    param(
        [Parameter(Mandatory)]$Cli,
        [Parameter(Mandatory)][string[]]$Packages,
        [Parameter(Mandatory)][string]$Profile
    )
    $args = @('plugin', '--profile', $Profile, 'add') + $Packages
    Write-Log ("run: {0} {1}" -f $Cli.Node, (($args) -join ' ')) 'STEP'
    if ($DryRun) { Write-Log 'DRY-RUN, not executing' 'STEP'; return 0 }
    $r = Invoke-Cli -Cli $Cli -Arguments $args
    foreach ($l in $r.Output) {
        $text = [string]$l
        if (-not $text.Trim()) { continue }
        $level = if ($text -match '^(dsh:|WARN|warn|ERR_)') { 'WARN' } else { 'INFO' }
        if ($text -match '^(Progress|Packages:|Done in|\+{5,})') { $level = 'INFO' }
        Write-Log "  $text" $level
    }
    return $r.ExitCode
}

<#
    Grant an exact-version exemption: "<package>@<version>" is allowed to run on
    one exact harness version. dsh refuses to install/start a plugin whose
    declared @deepseek-ai/dsh* peer range excludes the running harness, which is
    common right after moving to a newer prerelease line. The grant is narrow
    (exact package version + exact harness version) and revocable with
    `dsh plugin revoke-version`.
#>
function Grant-VersionExemptions {
    param(
        [Parameter(Mandatory)]$Cli,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string[]]$Packages
    )
    if ($Packages.Count -le 0 -or $DryRun) { return }
    $verResult = Invoke-Cli -Cli $Cli -Arguments @('--version')
    $runtime = ''
    foreach ($l in $verResult.Output) {
        $s = ([string]$l).Trim()
        if ($s -match '^\d+\.\d+\.\d+') { $runtime = $s; break }
    }
    if (-not $runtime) { Write-Log "[$Profile] cannot read harness version, skipping exemptions" 'WARN'; return }
    Write-Log "[$Profile] harness version = $runtime" 'STEP'
    # Fallback target: dsh reads exemptions from the profile's
    # compatibility.json. Writing that file directly is equivalent to what
    # `dsh plugin allow-version` does, and is needed when the installed CLI is
    # too old to expose the command (that CLI forwards unknown verbs to pnpm).
    $exemptFile = Join-Path (Join-Path (Join-Path $dshHomeRoot 'profiles') $Profile) 'compatibility.json'
    foreach ($spec in $Packages) {
        $at = $spec.LastIndexOf('@')
        if ($at -le 0) { continue }
        $name = $spec.Substring(0, $at)
        $ver = $spec.Substring($at + 1) -replace '^[\^~]', ''
        $exemptKey = "$name@$ver"
        $args = @('plugin', 'allow-version', $exemptKey, '--profile', $Profile, '--dsh-version', $runtime, '--accept-risk')
        $r = Invoke-Cli -Cli $Cli -Arguments $args
        if ($r.ExitCode -eq 0) {
            Write-Log "  exemption granted via CLI: $exemptKey on $runtime" 'OK'
            continue
        }
        # Try to see whether the grant actually landed despite a noisy exit code.
        $current = ConvertTo-Hashtable (Read-JsonFile -Path $exemptFile)
        if ($current.ContainsKey($exemptKey) -and @($current[$exemptKey]) -contains $runtime) {
            Write-Log "  exemption already present: $exemptKey on $runtime" 'OK'
            continue
        }
        Write-Log "  CLI could not grant $exemptKey (exit $($r.ExitCode)); writing $exemptFile directly" 'WARN'
        $mergedMap = @{}
        foreach ($k in $current.Keys) { $mergedMap[$k] = @($current[$k]) }
        $versions = if ($mergedMap.ContainsKey($exemptKey)) { @($mergedMap[$exemptKey]) } else { @() }
        if ($versions -notcontains $runtime) { $versions = @($versions) + @($runtime) }
        $mergedMap[$exemptKey] = @($versions | Select-Object -Unique)
        Write-JsonFile -Path $exemptFile -Object $mergedMap
        Write-Log "  exemption written: $exemptKey -> $runtime" 'OK'
    }
}

# --------------------------------------------------------------- merge rules

# Extract the leading numeric version from a range such as "^1.2.3",
# ">=0.1.5-rc.1" or "1.0.0 || 2.0.0".
function ConvertTo-SortableVersion {
    param([string]$Range)
    $pattern = '(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?'
    $m = [regex]::Match([string]$Range, $pattern)
    if (-not $m.Success) { return $null }
    $pre = if ($m.Groups[4].Success) { $m.Groups[4].Value } else { '' }
    return [pscustomobject]@{
        Major = [int]$m.Groups[1].Value
        Minor = [int]$m.Groups[2].Value
        Patch = [int]$m.Groups[3].Value
        Pre   = $pre
    }
}

# Deliberately conservative: compare the leading numeric versions, treat a
# stable release as higher than a prerelease, and otherwise keep the longer
# range. The goal is a stable, repeatable answer, not a full version solver.
function Select-HigherRange {
    param([string]$A, [string]$B)
    if ($A -eq $B) { return $A }
    if (-not $A) { return $B }
    if (-not $B) { return $A }
    if ($A -eq '*') { return $B }
    if ($B -eq '*') { return $A }
    $va = ConvertTo-SortableVersion -Range $A
    $vb = ConvertTo-SortableVersion -Range $B
    if ($va -and $vb) {
        if ($va.Major -ne $vb.Major) { if ($va.Major -gt $vb.Major) { return $A } else { return $B } }
        if ($va.Minor -ne $vb.Minor) { if ($va.Minor -gt $vb.Minor) { return $A } else { return $B } }
        if ($va.Patch -ne $vb.Patch) { if ($va.Patch -gt $vb.Patch) { return $A } else { return $B } }
        if ($va.Pre -ne $vb.Pre) {
            if (-not $va.Pre) { return $A }
            if (-not $vb.Pre) { return $B }
            if ([string]::CompareOrdinal($va.Pre, $vb.Pre) -gt 0) { return $A }
            return $B
        }
    }
    if ($A.Length -ge $B.Length) { return $A }
    return $B
}

function Merge-Dependencies {
    param($DepsA, $DepsB)
    $ha = ConvertTo-Hashtable $DepsA
    $hb = ConvertTo-Hashtable $DepsB
    $names = @(@($ha.Keys) + @($hb.Keys) | Select-Object -Unique | Sort-Object)
    # A plain hashtable, not [ordered]: Windows PowerShell 5.1's ConvertTo-Json
    # turns an [ordered] dictionary into null instead of an object.
    $merged = @{}
    foreach ($n in $names) {
        $a = if ($ha.ContainsKey($n)) { [string]$ha[$n] } else { $null }
        $b = if ($hb.ContainsKey($n)) { [string]$hb[$n] } else { $null }
        $merged[$n] = Select-HigherRange -A $a -B $b
    }
    return $merged
}

function Merge-Bundles {
    param([string[]]$BundlesA, [string[]]$BundlesB)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($BundlesA) + @($BundlesB)) {
        if ($n -and -not $out.Contains($n)) { $out.Add($n) }
    }
    return $out.ToArray()
}

function Test-EqualStringArray {
    param([string[]]$A, [string[]]$B)
    $x = @($A); $y = @($B)
    if ($x.Count -ne $y.Count) { return $false }
    for ($i = 0; $i -lt $x.Count; $i++) { if ($x[$i] -ne $y[$i]) { return $false } }
    return $true
}

# ------------------------------------------------------------------ main flow

$dshHomeRoot = Resolve-DshHome -Explicit $DshHome
$dirA = Join-Path (Join-Path $dshHomeRoot 'profiles') $ProfileA
$dirB = Join-Path (Join-Path $dshHomeRoot 'profiles') $ProfileB
$manifestA = Join-Path $dirA 'package.json'
$manifestB = Join-Path $dirB 'package.json'

Write-Log "DSH_HOME = $dshHomeRoot"
Write-Log "profile A = $ProfileA  ($dirA)"
Write-Log "profile B = $ProfileB  ($dirB)"
if ($DryRun) { Write-Log 'DRY-RUN: nothing will be modified' 'WARN' }

if (-not (Test-Path -LiteralPath $manifestA)) { throw "manifest not found: $manifestA (start the desktop app once to initialize its profile)" }
if (-not (Test-Path -LiteralPath $manifestB)) { throw "manifest not found: $manifestB (start the web version once to initialize the web profile)" }
if (-not (Test-Path -LiteralPath $dirA)) { throw "profile directory not found: $dirA" }
if (-not (Test-Path -LiteralPath $dirB)) { throw "profile directory not found: $dirB" }

$hA = ConvertTo-Hashtable (Read-JsonFile -Path $manifestA)
$hB = ConvertTo-Hashtable (Read-JsonFile -Path $manifestB)

$depsA = if ($hA.ContainsKey('dependencies')) { $hA['dependencies'] } else { $null }
$depsB = if ($hB.ContainsKey('dependencies')) { $hB['dependencies'] } else { $null }

function Get-BundlesOf {
    param($ManifestTable)
    if (-not $ManifestTable.ContainsKey('dsh')) { return @() }
    $dsh = ConvertTo-Hashtable $ManifestTable['dsh']
    if (-not $dsh.ContainsKey('profile')) { return @() }
    $prof = ConvertTo-Hashtable $dsh['profile']
    if (-not $prof.ContainsKey('bundles')) { return @() }
    return @($prof['bundles'])
}

$bunA = Get-BundlesOf -ManifestTable $hA
$bunB = Get-BundlesOf -ManifestTable $hB

$mergedDeps = Merge-Dependencies -DepsA $depsA -DepsB $depsB
[array]$mergedBundles = Merge-Bundles -BundlesA $bunA -BundlesB $bunB

# Guard against junk left by an earlier bad run: a dependency key must be an npm
# package name (never a "name@version" spec) and a bundle entry must be a name
# that is present in the merged dependencies.
$packageNamePattern = '^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$'
$badDeps = @($mergedDeps.Keys | Where-Object { $_ -notmatch $packageNamePattern })
foreach ($bad in $badDeps) {
    Write-Log "dropping invalid dependency key: '$bad'" 'WARN'
    $mergedDeps.Remove($bad)
}
$badBundles = @($mergedBundles | Where-Object { $_ -notmatch $packageNamePattern })
foreach ($bad in $badBundles) {
    Write-Log "dropping invalid bundle entry: '$bad'" 'WARN'
    [array]$mergedBundles = @($mergedBundles | Where-Object { $_ -ne $bad })
}

if ($Pin.Count -gt 0) {
    foreach ($spec in $Pin) {
        $at = $spec.LastIndexOf('@')
        if ($at -le 0) { throw "-Pin expects package@version, got '$spec'" }
        $name = $spec.Substring(0, $at)
        $ver = $spec.Substring($at + 1)
        $old = if ($mergedDeps.Contains($name)) { [string]$mergedDeps[$name] } else { '(not installed)' }
        $mergedDeps[$name] = $ver
        Write-Log "-Pin: $name  $old -> $ver" 'WARN'
        if ($mergedBundles -notcontains $name) {
            [array]$mergedBundles = Merge-Bundles -BundlesA $mergedBundles -BundlesB @($name)
        }
    }
}

# Read the version actually present in a profile's node_modules.
function Get-InstalledVersion {
    param([string]$ProfileDir, [string]$Package)
    $pj = Join-Path (Join-Path (Join-Path $ProfileDir 'node_modules') $Package) 'package.json'
    if (-not (Test-Path -LiteralPath $pj)) { return $null }
    try {
        $j = ConvertTo-Hashtable (Read-JsonFile -Path $pj)
        if ($j.ContainsKey('version')) { return [string]$j['version'] }
    } catch { }
    return $null
}

# A wanted range covers an installed version? Handles the simple forms used by
# plugin manifests: exact, ^x.y.z, ~x.y.z, >=x.y.z and * . Anything more exotic
# falls back to "not satisfied", which merely triggers a reinstall.
function Test-VersionSatisfies {
    param([string]$Range, [string]$Version)
    if (-not $Range -or -not $Version) { return $false }
    $r = $Range.Trim()
    if ($r -eq '*' -or $r -eq 'latest') { return $true }
    if ($r -eq $Version) { return $true }
    if ($r -match '^\^') {
        $want = ConvertTo-SortableVersion -Range $r
        $have = ConvertTo-SortableVersion -Range $Version
        if (-not $want -or -not $have) { return $false }
        $cmp = Compare-Sortable -A $have -B $want
        if ($cmp -lt 0) { return $false }
        # ^0.x.y allows only the same minor; ^x.y.z (x>0) allows the same major.
        if ($want.Major -eq 0) {
            if ($want.Minor -eq 0) { return ($have.Major -eq 0 -and $have.Minor -eq 0 -and $have.Patch -eq $want.Patch) }
            return ($have.Major -eq 0 -and $have.Minor -eq $want.Minor)
        }
        return ($have.Major -eq $want.Major)
    }
    if ($r -match '^~') {
        $want = ConvertTo-SortableVersion -Range $r
        $have = ConvertTo-SortableVersion -Range $Version
        if (-not $want -or -not $have) { return $false }
        if ((Compare-Sortable -A $have -B $want) -lt 0) { return $false }
        return ($have.Major -eq $want.Major -and $have.Minor -eq $want.Minor)
    }
    if ($r -match '^>=\s*') {
        $want = ConvertTo-SortableVersion -Range $r
        $have = ConvertTo-SortableVersion -Range $Version
        if (-not $want -or -not $have) { return $false }
        return ((Compare-Sortable -A $have -B $want) -ge 0)
    }
    if ($r -match '^[0-9]+\.[0-9]+\.[0-9]+') {
        $want = ConvertTo-SortableVersion -Range $r
        $have = ConvertTo-SortableVersion -Range $Version
        if (-not $want -or -not $have) { return $false }
        return ((Compare-Sortable -A $have -B $want) -eq 0)
    }
    return $false
}

function Compare-Sortable {
    param($A, $B)
    if ($A.Major -ne $B.Major) { if ($A.Major -gt $B.Major) { return 1 } else { return -1 } }
    if ($A.Minor -ne $B.Minor) { if ($A.Minor -gt $B.Minor) { return 1 } else { return -1 } }
    if ($A.Patch -ne $B.Patch) { if ($A.Patch -gt $B.Patch) { return 1 } else { return -1 } }
    if ($A.Pre -eq $B.Pre) { return 0 }
    if (-not $A.Pre) { return 1 }
    if (-not $B.Pre) { return -1 }
    return [string]::CompareOrdinal($A.Pre, $B.Pre)
}

function Get-Plan {
    param([string]$Label, $Deps, [string[]]$Bundles, $MergedDeps, [string[]]$MergedBundles, [string]$Dir)
    $needPkgs = New-Object System.Collections.Generic.List[string]
    $localDeps = ConvertTo-Hashtable $Deps
    foreach ($n in $MergedDeps.Keys) {
        $want = [string]$MergedDeps[$n]
        $installedVersion = Get-InstalledVersion -ProfileDir $Dir -Package $n
        $declared = if ($localDeps.ContainsKey($n)) { [string]$localDeps[$n] } else { $null }

        if (-not $installedVersion) {
            $needPkgs.Add("$n@$want")
            Write-Log "  [$Label] missing: $n@$want" 'STEP'
        } elseif ($declared -ne $want) {
            # The manifest disagrees with the merged range. Reinstalling also
            # covers the case where the installed version no longer satisfies it.
            $needPkgs.Add("$n@$want")
            Write-Log "  [$Label] declared range differs: $n  local=$declared -> $want (installed $installedVersion)" 'STEP'
        } elseif (-not (Test-VersionSatisfies -Range $want -Version $installedVersion)) {
            $needPkgs.Add("$n@$want")
            Write-Log "  [$Label] installed version outside range: $n  installed=$installedVersion want=$want" 'STEP'
        }
    }
    # Extra packages present only in node_modules are pruned by pnpm itself.
    $bundlesChanged = -not (Test-EqualStringArray -A $Bundles -B $MergedBundles)
    return [pscustomobject]@{ Packages = $needPkgs.ToArray(); BundlesChanged = $bundlesChanged }
}

Write-Log '--- diff ---' 'STEP'
$planA = Get-Plan -Label $ProfileA -Deps $depsA -Bundles $bunA -MergedDeps $mergedDeps -MergedBundles $mergedBundles -Dir $dirA
$planB = Get-Plan -Label $ProfileB -Deps $depsB -Bundles $bunB -MergedDeps $mergedDeps -MergedBundles $mergedBundles -Dir $dirB

if ($Force) {
    $all = @($mergedDeps.Keys | Sort-Object | ForEach-Object { "$_@$($mergedDeps[$_])" })
    Write-Log "-Force: reinstalling all $($all.Count) plugins on both sides" 'WARN'
    $planA = [pscustomobject]@{ Packages = $all; BundlesChanged = $planA.BundlesChanged }
    $planB = [pscustomobject]@{ Packages = $all; BundlesChanged = $planB.BundlesChanged }
}

Write-Log ("merged dependencies: " + (($mergedDeps.Keys | Sort-Object) -join ', '))
Write-Log ("merged bundles: " + ($mergedBundles -join ', '))

# --- exact-version exemptions ---
$exemptA = Read-JsonFile -Path (Join-Path $dirA 'compatibility.json')
$exemptB = Read-JsonFile -Path (Join-Path $dirB 'compatibility.json')
$mergedExempt = $null
$exemptObject = $null
if (-not $NoExemptions -and ($exemptA -or $exemptB)) {
    # compatibility.json is a FLAT map: "<package>@<exact version>" -> [exact
    # harness versions]. No wrapper object, no schema field.
    $mapA = ConvertTo-Hashtable $exemptA
    $mapB = ConvertTo-Hashtable $exemptB
    $mergedExempt = @{}
    $allKeys = @(@($mapA.Keys) + @($mapB.Keys) | Select-Object -Unique | Sort-Object)
    foreach ($k in $allKeys) {
        $vals = New-Object System.Collections.Generic.List[string]
        foreach ($src in @($mapA, $mapB)) {
            if ($src.ContainsKey($k)) {
                foreach ($v in @($src[$k])) { if (-not $vals.Contains([string]$v)) { $vals.Add([string]$v) } }
            }
        }
        $mergedExempt[$k] = $vals.ToArray()
    }
    Write-Log ("merged exemptions: " + (($mergedExempt.Keys | Sort-Object) -join ', '))
    $exemptObject = $mergedExempt
}

# --- write manifests ---
<#
    NOTE (Windows PowerShell 5.1): ConvertTo-Json serializes an [ordered]
    dictionary as a plain string/null instead of an object. Only a real
    [hashtable] survives serialization, so the root document is built as one.
    Key order is irrelevant to dsh, which reads these files by name.
#>
function Write-MergedManifest {
    param([string]$Path, $Manifest, $MergedDeps, [string[]]$MergedBundles)
    $m = ConvertTo-Hashtable $Manifest
    $out = @{}
    foreach ($k in $m.Keys) {
        if ($k -eq 'dependencies' -or $k -eq 'dsh') { continue }
        $out[$k] = $m[$k]
    }
    # Normalize before serializing: PS 5.1 writes an [ordered] dictionary as null.
    $depsTable = ConvertTo-Hashtable $MergedDeps
    $depsOut = @{}
    foreach ($k in $depsTable.Keys) { $depsOut[$k] = $depsTable[$k] }
    $out['dependencies'] = $depsOut

    $dshIn = if ($m.ContainsKey('dsh')) { ConvertTo-Hashtable $m['dsh'] } else { @{} }
    $dshOut = @{}
    foreach ($k in $dshIn.Keys) { if ($k -ne 'profile') { $dshOut[$k] = $dshIn[$k] } }

    $profIn = if ($dshIn.ContainsKey('profile')) { ConvertTo-Hashtable $dshIn['profile'] } else { @{} }
    $profileOut = @{}
    foreach ($k in $profIn.Keys) { if ($k -ne 'bundles') { $profileOut[$k] = $profIn[$k] } }
    $profileOut['bundles'] = $MergedBundles

    $dshOut['profile'] = $profileOut
    $out['dsh'] = $dshOut
    Write-JsonFile -Path $Path -Object $out
}

Write-Log '--- manifests ---' 'STEP'
Write-MergedManifest -Path $manifestA -Manifest $hA -MergedDeps $mergedDeps -MergedBundles $mergedBundles
Write-MergedManifest -Path $manifestB -Manifest $hB -MergedDeps $mergedDeps -MergedBundles $mergedBundles

if (-not $NoExemptions -and $exemptObject) {
    Write-JsonFile -Path (Join-Path $dirA 'compatibility.json') -Object $exemptObject
    Write-JsonFile -Path (Join-Path $dirB 'compatibility.json') -Object $exemptObject
}

# --- optional: merge the per-profile patch layer ---
if ($SyncPatchFile) {
    $patchA = Join-Path $dirA 'cordis.patch.yml'
    $patchB = Join-Path $dirB 'cordis.patch.yml'
    Write-Log '--- cordis.patch.yml ---' 'STEP'
    foreach ($pair in @(@($patchA, $dirB), @($patchB, $dirA))) {
        $src = $pair[0]
        if (Test-Path -LiteralPath $src) {
            $bak = "$src.bak"
            if (-not $DryRun) { Copy-Item -LiteralPath $src -Destination $bak -Force }
            $target = Join-Path $pair[1] 'cordis.patch.yml'
            Write-Log "backup -> $bak ; candidate patch source $src (compare manually before overwriting $target)" 'WARN'
        }
    }
    Write-Log 'Patch layers are NOT auto-merged: desktop holds desktop-only settings. Review the .bak files and merge by hand.' 'WARN'
}

# --- install ---
$cliA = Get-DesktopCli -HomePath $dshHomeRoot
$cliB = Get-WebCli -HomePath $dshHomeRoot

$desktopProcs = @(Get-DesktopProcess)
$desktopRunning = $desktopProcs.Count -gt 0
if ($desktopRunning) {
    Write-Log ("desktop app is running: PID " + (($desktopProcs | ForEach-Object { $_.Id }) -join ', ')) 'WARN'
    if ($AllowRunningDesktop) { Write-Log '-AllowRunningDesktop: installing anyway; plugins take effect after a full restart' 'WARN' }
}

function Install-Side {
    param([string]$Profile, $Plan, $Cli, [string]$CliKind)
    if (@($Plan.Packages).Count -le 0) {
        if ($Plan.BundlesChanged) {
            Write-Log "[$Profile] only the bundle list changed (packages already present); manifest written, effective after restart" 'OK'
        } else {
            Write-Log "[$Profile] already in sync, skipping install" 'OK'
        }
        return $true
    }
    if (-not $Cli) { Write-Log "[$Profile] no usable CLI found, skipping install (manifest still merged)" 'WARN'; return $false }
    if ($CliKind -eq 'desktop' -and $desktopRunning -and -not $AllowRunningDesktop) {
        Write-Log "[$Profile] desktop app is running; refusing to touch its reserved profile. Re-run with -AllowRunningDesktop to go ahead." 'WARN'
        return $false
    }
    $code = Invoke-PluginAdd -Cli $Cli -Packages @($Plan.Packages) -Profile $Profile
    if ($code -eq 0) { Write-Log "[$Profile] install finished" 'OK'; return $true }
    Write-Log "[$Profile] install failed with exit $code (most often an incompatible declared peer range -> grant an exact-version exemption)" 'ERROR'
    return $false
}

Write-Log '--- install ---' 'STEP'
if ($GrantExemptions) {
    Write-Log 'granting exact-version exemptions (-GrantExemptions)' 'STEP'
    $specs = @($mergedDeps.Keys | Sort-Object | ForEach-Object { "$_@$($mergedDeps[$_])" })
    if ($cliB) { Grant-VersionExemptions -Cli $cliB -Profile $ProfileB -Packages $specs }
    if ($cliA -and (-not $desktopRunning -or $AllowRunningDesktop)) {
        Grant-VersionExemptions -Cli $cliA -Profile $ProfileA -Packages $specs
    }
}
$okB = Install-Side -Profile $ProfileB -Plan $planB -Cli $cliB -CliKind 'web'
$okA = Install-Side -Profile $ProfileA -Plan $planA -Cli $cliA -CliKind 'desktop'

# --- verify ---
Write-Log '--- verify ---' 'STEP'
$report = @()
foreach ($side in @(
        [pscustomobject]@{ Name = $ProfileA; Dir = $dirA },
        [pscustomobject]@{ Name = $ProfileB; Dir = $dirB })) {
    $sideManifest = ConvertTo-Hashtable (Read-JsonFile -Path (Join-Path $side.Dir 'package.json'))
    $sideDeps = if ($sideManifest.ContainsKey('dependencies')) { ConvertTo-Hashtable $sideManifest['dependencies'] } else { @{} }
    foreach ($n in $mergedDeps.Keys) {
        $want = [string]$mergedDeps[$n]
        $installedVersion = Get-InstalledVersion -ProfileDir $side.Dir -Package $n
        $declared = if ($sideDeps.ContainsKey($n)) { [string]$sideDeps[$n] } else { '(missing)' }
        $report += [pscustomobject]@{
            Profile   = $side.Name
            Package   = $n
            Declared  = $declared
            Installed = if ($installedVersion) { $installedVersion } else { '(none)' }
            InRange   = if ($installedVersion) { Test-VersionSatisfies -Range $want -Version $installedVersion } else { $false }
        }
    }
}
$report | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$missing = @($report | Where-Object { -not $_.InRange })
if ($missing.Count -gt 0) {
    Write-Log ("still missing: " + (($missing | ForEach-Object { "$($_.Profile)/$($_.Package)" }) -join ', ')) 'WARN'
} else {
    Write-Log 'both profiles carry the same plugin set' 'OK'
}

if (-not $okA) { exit 2 }
if (-not $okB) { exit 3 }
exit 0
