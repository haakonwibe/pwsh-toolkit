<#
.SYNOPSIS
    Keep a systemwide PowerShell 7 current from the official ZIP packages.

.DESCRIPTION
    From 7.7 on there is no MSI, and the Store (MSIX) build installs for one user
    only - no inbound remoting, no LocalMachine execution policy, no all-users
    profiles. The ZIP is the only systemwide package left, and nothing updates
    it. This script is that updater.

    Layout (under -InstallRoot, default C:\Program Files\PowerShell):
        7\                      junction -> pwshup\versions\<current>
        pwshup\versions\<v>\    one unpacked release per folder (current + previous)
        pwshup\staging, trash, state, logs, updater
        Modules\, Scripts\      the all-users module scope - never touched

    Every path that runs pwsh (PATH, Start Menu, scheduled tasks, Windows
    Terminal) uses ...\7\pwsh.exe, so an update is a junction swap. A release
    is staged and verified in full (SHA-256 against the release's
    hashes.sha256, Authenticode on every exe/dll, a smoke run) before 7 moves.

    The switch waits until no process is running from 7: pwsh does not resolve
    the junction ($PSHOME is the 7 path), so a shell left open across a swap
    would load the rest of its assemblies from the new version. The scheduled
    run defers instead and the boot run applies it; -Force switches anyway.

    Runs under Windows PowerShell 5.1 by design - it must never depend on the
    pwsh it replaces - and as SYSTEM from a scheduled task, which only ever
    runs the admin-only copy in pwshup\updater (never a user-writable repo).
    Keep this file ASCII-only and 5.1-compatible.

.PARAMETER Install
    One-time setup (elevated): moves an empty leftover 7 folder aside, installs
    the latest Stable, adds the machine PATH entry, the App Paths key and a
    Start Menu shortcut, and registers the \pwsh-toolkit\PwshUpdate task.

.PARAMETER Update
    Check for and apply a newer Stable release now (elevated).

.PARAMETER Rollback
    Point 7 back at the previous version and mark the current one bad, so the
    nightly run doesn't reinstall it (elevated).

.PARAMETER Uninstall
    Remove exactly what -Install added (elevated). Modules\ and Scripts\ stay.

.PARAMETER Version
    With -Install/-Update: install this exact version (e.g. 7.6.5) instead of
    the latest Stable. Explicit requests may downgrade.

.PARAMETER AllowMajor
    With -Install/-Update: allow a new major version (8.x). Without it a new
    major is reported but not installed, since everything pointing at 7 would
    silently change major.

.PARAMETER Force
    With -Update/-Rollback/-Uninstall: act even while pwsh processes are
    running from 7. Restart them afterwards.

.PARAMETER Scheduled
    Set by the scheduled task: never forces, pings the Healthchecks URL.

.PARAMETER HealthcheckUrl
    With -Install: a Healthchecks-style URL pinged after each scheduled run
    (<url>/fail on failure).

.PARAMETER Offline
    Status only: don't look up the latest release.

.PARAMETER InstallRoot
    Where PowerShell lives. Default: $env:ProgramFiles\PowerShell (the 64-bit
    one, even from a 32-bit host).

.EXAMPLE
    .\Invoke-PwshUpdate.ps1
    Status: current version, latest Stable, task health, tasks to re-point.

.EXAMPLE
    .\Invoke-PwshUpdate.ps1 -Install
    One-time setup, from an elevated Windows PowerShell.
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Install', Mandatory)]   [switch] $Install,
    [Parameter(ParameterSetName = 'Update', Mandatory)]    [switch] $Update,
    [Parameter(ParameterSetName = 'Rollback', Mandatory)]  [switch] $Rollback,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)] [switch] $Uninstall,

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Update')]
    [string] $Version,

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Update')]
    [switch] $AllowMajor,

    [Parameter(ParameterSetName = 'Update')]
    [Parameter(ParameterSetName = 'Rollback')]
    [Parameter(ParameterSetName = 'Uninstall')]
    [switch] $Force,

    [Parameter(ParameterSetName = 'Update')]
    [switch] $Scheduled,

    [Parameter(ParameterSetName = 'Install')]
    [string] $HealthcheckUrl,

    [Parameter(ParameterSetName = 'Status')]
    [switch] $Offline,

    [string] $InstallRoot = $(if ($env:ProgramW6432) { Join-Path $env:ProgramW6432 'PowerShell' } else { Join-Path $env:ProgramFiles 'PowerShell' })
)

# ---------- Constants ----------
$script:PwshMetadataUri = 'https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json'
$script:PwshReleaseBase = 'https://github.com/PowerShell/PowerShell/releases/download'
$script:PwshTaskPath    = '\pwsh-toolkit\'
$script:PwshTaskName    = 'PwshUpdate'
$script:PwshMinFree     = 1GB
# The longest entry in a 7.6 ZIP is 109 characters, and 5.1 can't open paths
# past 259. Capping the root keeps root\pwshup\versions\<v>.partial-<id>\<entry>
# inside that with room to spare.
$script:PwshMaxRootLength = 100
$script:PwshCoreSigned  = @('pwsh.exe', 'pwsh.dll', 'System.Management.Automation.dll')
$script:PwshLogFile     = $null
$script:PwshQuiet       = $false
$script:PwshLock        = $null

# 5.1's progress bar slows a 100 MB download to a crawl; and it doesn't offer
# TLS 1.2 unless asked on every .NET Framework build.
$ProgressPreference = 'SilentlyContinue'
try {
    $tls = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') { $tls = $tls -bor [Net.SecurityProtocolType]'Tls13' }
    [Net.ServicePointManager]::SecurityProtocol = $tls
} catch { $null = $_ }

# ---------- Logging (CMTrace format, same shape as WingetUpgrade) ----------
function Format-CMTraceLine {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet(1, 2, 3)][int]    $Type = 1,
        [string]                       $Component = 'PwshUpdate'
    )
    $now    = Get-Date
    $offset = [int][System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
    $sign   = if ($offset -ge 0) { '+' } else { '' }
    '<![LOG[{0}]LOG]!><time="{1}{2}{3}" date="{4}" component="{5}" context="" type="{6}" thread="{7}" file="">' -f `
        $Message, $now.ToString('HH:mm:ss.fff', [cultureinfo]::InvariantCulture), $sign, $offset, $now.ToString('MM-dd-yyyy', [cultureinfo]::InvariantCulture), $Component, $Type, $PID
}

function Write-PwshLog {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string] $Level = 'INFO'
    )
    if ($script:PwshLogFile) {
        $type = switch ($Level) { 'WARN' { 2 } 'ERROR' { 3 } default { 1 } }
        try { Add-Content -LiteralPath $script:PwshLogFile -Value (Format-CMTraceLine -Message $Message -Type $type) -Encoding UTF8 } catch { $null = $_ }
    }
    if (-not $script:PwshQuiet) {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } default { 'Gray' } }
        Write-Host "  $Message" -ForegroundColor $color
    }
}

function Start-PwshLog {
    param([Parameter(Mandatory)] $Ctx)
    if (-not (Test-Path -LiteralPath $Ctx.Logs)) { return }
    $script:PwshLogFile = $Ctx.LogFile
    # One rolling file, CMTrace-style: at 2 MB the old one becomes .lo_.
    $f = Get-Item -LiteralPath $Ctx.LogFile -ErrorAction SilentlyContinue
    if ($f -and $f.Length -gt 2MB) { Move-Item -LiteralPath $Ctx.LogFile -Destination ($Ctx.LogFile -replace '\.log$', '.lo_') -Force }
}

# ---------- Context ----------
function New-PwshContext {
    param([Parameter(Mandatory)][string] $InstallRoot)
    $root = $InstallRoot.TrimEnd('\')
    $work = Join-Path $root 'pwshup'
    [pscustomobject]@{
        Root      = $root
        Link      = Join-Path $root '7'
        Work      = $work
        Versions  = Join-Path $work 'versions'
        Staging   = Join-Path $work 'staging'
        Trash     = Join-Path $work 'trash'
        State     = Join-Path $work 'state'
        Logs      = Join-Path $work 'logs'
        Updater   = Join-Path $work 'updater'
        StateFile = Join-Path $work 'state\state.json'
        LockFile  = Join-Path $work 'state\update.lock'
        LogFile   = Join-Path $work 'logs\PwshUpdate.log'
        Installed = Join-Path $work 'updater\Invoke-PwshUpdate.ps1'
    }
}

# ---------- Pure helpers ----------
function ConvertTo-PwshVersion {
    # 'v7.6.6' / '7.6.6' -> [version]; anything else (previews, junk) -> $null.
    param([string] $Text)
    if ($Text -match '^\s*v?(\d{1,3})\.(\d{1,3})\.(\d{1,4})\s*$') {
        return [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3])
    }
    return $null
}

function Get-PwshArchitecture {
    # The OS architecture, not the process's: a 32-bit host on 64-bit Windows
    # reports x86 in PROCESSOR_ARCHITECTURE and the truth in ..._ARCHITEW6432.
    param(
        [string] $ArchW6432 = $env:PROCESSOR_ARCHITEW6432,
        [string] $Arch = $env:PROCESSOR_ARCHITECTURE
    )
    $a = if ($ArchW6432) { $ArchW6432 } else { $Arch }
    switch ("$a".ToUpperInvariant()) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'X86'   { return 'x86' }
        default { throw "Unsupported processor architecture '$a'." }
    }
}

function Get-PwshAssetName {
    param([Parameter(Mandatory)][string] $Version, [Parameter(Mandatory)][string] $Arch)
    'PowerShell-{0}-win-{1}.zip' -f $Version, $Arch
}

function Read-PwshHashFile {
    # hashes.sha256 ships as UTF-16 LE with a BOM ("<sha256> *<file>" lines).
    # Decode from the bytes by BOM rather than trusting a reader's default, and
    # require exactly one exact filename match - a near miss or a duplicate is
    # an error, never a guess.
    param([Parameter(Mandatory)][byte[]] $Bytes, [Parameter(Mandatory)][string] $FileName)
    $enc = New-Object System.Text.UTF8Encoding $false
    $skip = 0
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { $enc = [Text.Encoding]::Unicode; $skip = 2 }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { $enc = [Text.Encoding]::BigEndianUnicode; $skip = 2 }
    elseif ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $skip = 3 }
    $text = $enc.GetString($Bytes, $skip, $Bytes.Length - $skip)

    $found = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*([0-9A-Fa-f]{64})\s+\*?(\S.*?)\s*$' -and $Matches[2] -eq $FileName) {
            $found += $Matches[1].ToLowerInvariant()
        }
    }
    if ($found.Count -ne 1) { throw "hashes.sha256 has $($found.Count) entries for $FileName (expected exactly one)." }
    return $found[0]
}

function Select-PwshTarget {
    # Decide what (if anything) to install. Returns Action = Update | None |
    # Skip | Blocked, plus the version and a reason for the log.
    param(
        [version] $Available,
        [version] $Current,
        [string[]] $Bad = @(),
        [switch] $AllowMajor,
        [switch] $Explicit
    )
    $result = { param($a, $r) [pscustomobject]@{ Action = $a; Version = $(if ($Available) { $Available.ToString(3) } else { $null }); Reason = $r } }
    if (-not $Available) { return (& $result 'None' 'no release information') }
    if ($Current -and $Available -eq $Current) { return (& $result 'None' 'up to date') }
    if ($Explicit) { return (& $result 'Update' 'requested explicitly') }
    if ($Current -and $Available -lt $Current) { return (& $result 'None' "installed $($Current.ToString(3)) is newer than the latest Stable") }
    if ($Bad -contains $Available.ToString(3)) { return (& $result 'Skip' 'marked bad by an earlier rollback or failed switch') }
    if ($Current -and $Available.Major -gt $Current.Major -and -not $AllowMajor) {
        return (& $result 'Blocked' "a new major version; opt in with -AllowMajor")
    }
    return (& $result 'Update' $(if ($Current) { "newer than $($Current.ToString(3))" } else { 'first install' }))
}

function Merge-PwshConfigJson {
    # Carry the machine's own settings (LocalMachine execution policy,
    # experimental features, ...) from the old version's powershell.config.json
    # into the new one's, without freezing the new release's defaults: a
    # top-level key moves over only when the old live file differs from what
    # the old release shipped. A key the user deleted stays deleted. With no
    # record of what the old release shipped, anything that differs from the
    # new defaults is treated as the user's.
    param([string] $OldShipped, [string] $OldLive, [string] $NewShipped)

    $new = if ($NewShipped) { $NewShipped | ConvertFrom-Json } else { New-Object psobject }
    $carried = @(); $removed = @()
    if ($OldLive) {
        $live = $OldLive | ConvertFrom-Json
        $base = if ($OldShipped) { $OldShipped | ConvertFrom-Json } else { $NewShipped | ConvertFrom-Json }
        if ($null -eq $base) { $base = New-Object psobject }
        $baseNames = @($base.PSObject.Properties | ForEach-Object { $_.Name })
        $liveNames = @($live.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($p in $live.PSObject.Properties) {
            $changed = ($baseNames -notcontains $p.Name) -or
                ((ConvertTo-Json -InputObject $p.Value -Depth 20 -Compress) -ne (ConvertTo-Json -InputObject $base.($p.Name) -Depth 20 -Compress))
            if ($changed) {
                $new | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                $carried += $p.Name
            }
        }
        foreach ($n in $baseNames) {
            if ($liveNames -notcontains $n -and ($new.PSObject.Properties | Where-Object { $_.Name -eq $n })) {
                $new.PSObject.Properties.Remove($n)
                $removed += $n
            }
        }
    }
    [pscustomobject]@{ Json = (ConvertTo-Json -InputObject $new -Depth 20); Carried = $carried; Removed = $removed }
}

function Edit-PwshPathValue {
    # Add or remove one entry in a PATH string, leaving every other entry -
    # including %VAR% references and empty segments - exactly as it was.
    param([string] $Value, [Parameter(Mandatory)][string] $Entry, [switch] $Remove)
    $norm = { param($p) $p.Trim().TrimEnd('\').ToLowerInvariant() }
    $want = & $norm $Entry
    $parts = if ($Value) { $Value -split ';' } else { @() }
    $present = @($parts | Where-Object { $_ -and (& $norm $_) -eq $want }).Count -gt 0
    if ($Remove) {
        if (-not $present) { return $Value }
        return (@($parts | Where-Object { -not ($_ -and (& $norm $_) -eq $want) }) -join ';')
    }
    if ($present) { return $Value }
    if (-not $Value) { return $Entry }
    if ($Value.EndsWith(';')) { return $Value + $Entry }
    return $Value + ';' + $Entry
}

function Get-PwshPruneSet {
    # Version folders to delete: everything but the ones still needed.
    param([string[]] $Present = @(), [string[]] $Keep = @())
    @($Present | Where-Object { $_ -and $Keep -notcontains $_ })
}

# ---------- Link-safe filesystem helpers ----------
# Windows PowerShell 5.1's Remove-Item -Recurse follows junctions, so deleting
# a folder that contains one can delete what it points at - here, potentially
# the all-users Modules. Nothing in this script uses it; every removal goes
# through these helpers, which never enumerate inside a reparse point.
function Get-PwshItem {
    param([Parameter(Mandatory)][string] $Path)
    Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Test-PwshReparsePoint {
    param([Parameter(Mandatory)][string] $Path)
    $i = Get-PwshItem $Path
    [bool]($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint))
}

function Remove-PwshLink {
    # Remove a junction itself; refuse anything that isn't one.
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Get-PwshItem $Path)) { return }
    if (-not (Test-PwshReparsePoint $Path)) { throw "Refusing to remove '$Path' as a link: it is a real folder." }
    [IO.Directory]::Delete($Path, $false)
}

function Remove-PwshTree {
    param([Parameter(Mandatory)][string] $Path)
    $item = Get-PwshItem $Path
    if (-not $item) { return }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($item -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($Path, $false) } else { $item.Delete() }
        return
    }
    if ($item -isnot [IO.DirectoryInfo]) { $item.Attributes = 'Normal'; $item.Delete(); return }
    foreach ($e in $item.GetFileSystemInfos()) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($e -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($e.FullName, $false) } else { $e.Delete() }
        } elseif ($e -is [IO.DirectoryInfo]) {
            Remove-PwshTree $e.FullName
        } else {
            if ($e.Attributes -band [IO.FileAttributes]::ReadOnly) { $e.Attributes = 'Normal' }
            $e.Delete()
        }
    }
    [IO.Directory]::Delete($Path, $false)
}

function Get-PwshTreeContent {
    # Count files and reparse points under a folder without following links.
    param([Parameter(Mandatory)][string] $Path)
    $files = 0; $links = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push((Get-PwshItem $Path))
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        foreach ($e in $d.GetFileSystemInfos()) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $links++ }
            elseif ($e -is [IO.DirectoryInfo]) { $stack.Push($e) }
            else { $files++ }
        }
    }
    [pscustomobject]@{ Files = $files; Links = $links }
}

function New-PwshJunction {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Target)
    $null = New-Item -ItemType Junction -Path $Path -Value $Target
}

function Get-PwshLinkTarget {
    # 5.1 returns the target as a one-element array, 7 as a string.
    param([Parameter(Mandatory)][string] $Path)
    $i = Get-PwshItem $Path
    if (-not $i -or -not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    $t = @($i.Target)
    if ($t.Count -gt 0 -and $t[0]) { return [string]$t[0] }
    return $null
}

function Switch-PwshLink {
    # Point 7 at Target. The new link is built beside the old one and renamed
    # into place, so 7 is missing only between two renames - and a run that
    # dies in that gap leaves 7.next/7.prev for Repair-PwshLink to finish.
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Target)
    $next = $Ctx.Link + '.next'
    $prev = $Ctx.Link + '.prev'
    Remove-PwshLink $next
    New-PwshJunction -Path $next -Target $Target
    if (Get-PwshItem $Ctx.Link) {
        if (-not (Test-PwshReparsePoint $Ctx.Link)) { Remove-PwshLink $next; throw "$($Ctx.Link) is a real folder, not the updater's link." }
        Remove-PwshLink $prev
        [IO.Directory]::Move($Ctx.Link, $prev)
    }
    [IO.Directory]::Move($next, $Ctx.Link)
    Remove-PwshLink $prev
}

function Repair-PwshLink {
    # Finish or undo a switch that was interrupted between its renames.
    param([Parameter(Mandatory)] $Ctx)
    $next = $Ctx.Link + '.next'
    $prev = $Ctx.Link + '.prev'
    if (-not (Get-PwshItem $Ctx.Link)) {
        foreach ($candidate in @($next, $prev)) {
            if ((Test-PwshReparsePoint $candidate) -and (Get-PwshItem (Get-PwshLinkTarget $candidate))) {
                [IO.Directory]::Move($candidate, $Ctx.Link)
                Write-PwshLog "Repaired $($Ctx.Link) from an interrupted switch." -Level WARN
                break
            }
        }
    }
    foreach ($leftover in @($next, $prev)) {
        if (Test-PwshReparsePoint $leftover) { Remove-PwshLink $leftover }
    }
}

function Get-PwshCurrentVersion {
    # The truth is where 7 points, not what state.json remembers.
    param([Parameter(Mandatory)] $Ctx)
    $t = Get-PwshLinkTarget $Ctx.Link
    if (-not $t -or -not (Test-Path -LiteralPath (Join-Path $t 'pwsh.exe'))) { return $null }
    ConvertTo-PwshVersion (Split-Path -Leaf $t)
}

function Get-PwshVersionFolder {
    param([Parameter(Mandatory)] $Ctx)
    if (-not (Test-Path -LiteralPath $Ctx.Versions)) { return @() }
    @(Get-ChildItem -LiteralPath $Ctx.Versions -Directory -Force |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
}

function Test-PwshVersionReady {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Version)
    Test-Path -LiteralPath (Join-Path (Join-Path $Ctx.Versions $Version) 'pwsh.exe')
}

# ---------- State ----------
function Read-PwshState {
    param([Parameter(Mandatory)] $Ctx)
    $s = $null
    if (Test-Path -LiteralPath $Ctx.StateFile) {
        try { $s = Get-Content -Raw -LiteralPath $Ctx.StateFile | ConvertFrom-Json } catch { Write-PwshLog "state.json unreadable ($($_.Exception.Message)); starting fresh." -Level WARN }
    }
    $defaults = [ordered]@{
        Current = $null; Previous = $null; Staged = $null; StagedAt = $null; Bad = @()
        LatestStable = $null; BlockedMajor = $null; LastCheck = $null; LastSuccess = $null; LastResult = $null
        HealthcheckUrl = $null
    }
    $o = New-Object psobject
    foreach ($k in $defaults.Keys) {
        $v = $defaults[$k]
        if ($s -and ($s.PSObject.Properties | Where-Object { $_.Name -eq $k })) { $v = $s.$k }
        $o | Add-Member -NotePropertyName $k -NotePropertyValue $v
    }
    $o.Bad = @($o.Bad | Where-Object { $_ })
    return $o
}

function Save-PwshState {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] $State)
    $State.Bad = @($State.Bad | Where-Object { $_ } | Select-Object -Unique)
    $json = ConvertTo-Json -InputObject $State -Depth 5
    [IO.File]::WriteAllText($Ctx.StateFile, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-PwshStamp { (Get-Date).ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture) }

# ---------- System probes (stubbed in tests) ----------
function Test-PwshIsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PwshIsSystem {
    [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
}

function Get-PwshMsiRegistration {
    # A PowerShell 7 MSI would install *through* the 7 junction into our
    # version folder, and uninstalling it would delete our files.
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        foreach ($sub in (Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
            if ($p -and "$($p.DisplayName)" -like 'PowerShell 7*' -and "$($p.DisplayName)" -notlike '*preview*' -and $p.WindowsInstaller -eq 1) {
                "$($p.DisplayName) $($p.DisplayVersion)"
            }
        }
    }
}

function Get-PwshProcessUsing {
    # Processes whose image lives under any of the given folders. pwsh keeps
    # the path it was launched by (the 7 junction), so both 7 and the version
    # folder it points at are checked.
    param([string[]] $Prefix = @())
    $pre = @($Prefix | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' })
    if ($pre.Count -eq 0) { return }
    foreach ($p in (Get-CimInstance -ClassName Win32_Process -Property ProcessId, Name, ExecutablePath -ErrorAction SilentlyContinue)) {
        if (-not $p.ExecutablePath) { continue }
        foreach ($x in $pre) {
            if ($p.ExecutablePath.StartsWith($x, [StringComparison]::OrdinalIgnoreCase)) {
                [pscustomobject]@{ Id = $p.ProcessId; Name = $p.Name; Path = $p.ExecutablePath }
                break
            }
        }
    }
}

function Get-PwshStableTag {
    $r = Invoke-RestMethod -Uri $script:PwshMetadataUri -UseBasicParsing -TimeoutSec 30
    if ($r -is [string]) { $r = $r | ConvertFrom-Json }   # raw.githubusercontent serves text/plain
    [string]$r.StableReleaseTag
}

function Save-PwshFile {
    param([Parameter(Mandatory)][string] $Uri, [Parameter(Mandatory)][string] $OutFile)
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 900
}

function Test-PwshSignature {
    # Authenticode is the real trust anchor: hashes.sha256 comes from the same
    # release as the ZIP, so it proves the download is intact, not genuine.
    # Every exe/dll must be Valid, and the core three signed by Microsoft
    # Corporation (a 7.6.6 ZIP: 517 binaries, all Valid).
    param([Parameter(Mandatory)][string] $Directory)
    $failures = New-Object System.Collections.Generic.List[string]
    $bins = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force | Where-Object { $_.Extension -eq '.exe' -or $_.Extension -eq '.dll' })
    foreach ($f in $bins) {
        $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
        if ($sig.Status -ne 'Valid') { $failures.Add("$($f.Name): $($sig.Status)") }
    }
    foreach ($core in $script:PwshCoreSigned) {
        $p = Join-Path $Directory $core
        if (-not (Test-Path -LiteralPath $p)) { $failures.Add("$core is missing"); continue }
        $sig = Get-AuthenticodeSignature -LiteralPath $p
        if (-not $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') {
            $failures.Add("$core is not signed by Microsoft Corporation")
        }
    }
    [pscustomobject]@{ Ok = ($failures.Count -eq 0); Checked = $bins.Count; Failures = $failures.ToArray() }
}

function Invoke-PwshSmokeTest {
    # Start the candidate with no profile and check it reports the version we
    # think we installed. A hang is a failure, not a wait.
    param([Parameter(Mandatory)][string] $Exe, [Parameter(Mandatory)][string] $Expected, [int] $TimeoutSec = 60)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = '-NoProfile -NonInteractive -NoLogo -Command "$PSVersionTable.PSVersion.ToString()"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['POWERSHELL_UPDATECHECK'] = 'Off'
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { $null = $_ }
        throw "$Exe did not finish within $TimeoutSec s."
    }
    $got = "$($out.Result)".Trim()
    if ($p.ExitCode -ne 0 -or $got -ne $Expected) {
        throw "$Exe reported '$got' (exit $($p.ExitCode)), expected $Expected. $("$($err.Result)".Trim())"
    }
}

function Expand-PwshZip {
    # Reject any entry that would land outside the destination before
    # extracting anything.
    param([Parameter(Mandatory)][string] $ZipPath, [Parameter(Mandatory)][string] $Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dest = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName -match '^[\\/]' -or $e.FullName -match ':') { throw "Unsafe entry in ZIP: $($e.FullName)" }
            $full = [IO.Path]::GetFullPath((Join-Path $dest $e.FullName))
            if (-not $full.StartsWith($dest, [StringComparison]::OrdinalIgnoreCase)) { throw "ZIP entry escapes the destination: $($e.FullName)" }
        }
    } finally { $zip.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function Assert-PwshFreeSpace {
    param([Parameter(Mandatory)][string] $Path, [long] $Bytes = $script:PwshMinFree)
    $drive = New-Object System.IO.DriveInfo ([IO.Path]::GetPathRoot($Path))
    if ($drive.AvailableFreeSpace -lt $Bytes) {
        throw ('Only {0:N0} MB free on {1}; need {2:N0} MB.' -f ($drive.AvailableFreeSpace / 1MB), $drive.Name, ($Bytes / 1MB))
    }
}

function Send-PwshHealthcheck {
    param([string] $Url, [switch] $Fail)
    if (-not $Url) { return }
    $u = if ($Fail) { $Url.TrimEnd('/') + '/fail' } else { $Url }
    try { $null = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 15 } catch { Write-PwshLog "Healthcheck ping failed: $($_.Exception.Message)" -Level WARN }
}

# ---------- Machine integration ----------
function Set-PwshMachinePath {
    # Edit the machine PATH through the registry, keeping its value type
    # (REG_EXPAND_SZ) and reading it unexpanded, so %SystemRoot%-style entries
    # survive. [Environment]::SetEnvironmentVariable would write back a plain
    # string with every reference already expanded.
    param(
        [Parameter(Mandatory)][string] $Entry,
        [switch] $Remove,
        [Microsoft.Win32.RegistryHive] $Hive = 'LocalMachine',
        [string] $KeyPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    )
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $base.OpenSubKey($KeyPath, $true)
    if (-not $key) { throw "Registry key not found: $Hive\$KeyPath" }
    try {
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        $old = ''
        if ($key.GetValueNames() -contains 'Path') {
            $kind = $key.GetValueKind('Path')
            $old = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
        $new = Edit-PwshPathValue -Value $old -Entry $Entry -Remove:$Remove
        if ($new -eq $old) { return $false }
        $key.SetValue('Path', $new, $kind)
    } finally { $key.Close(); $base.Close() }
    if ($Hive -eq 'LocalMachine') {
        # Deleting a variable that doesn't exist is a no-op that still makes
        # .NET broadcast WM_SETTINGCHANGE, so Explorer picks up the new PATH.
        [Environment]::SetEnvironmentVariable('PWSHUP_REFRESH', $null, 'Machine')
    }
    return $true
}

function Set-PwshAppPath {
    # App Paths lets Win+R and Start > Run find pwsh even before PATH refreshes.
    param([Parameter(Mandatory)][string] $Exe, [switch] $Remove)
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe'
    if ($Remove) {
        $cur = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).'(default)'
        if ($cur -and $cur -eq $Exe) { Remove-Item -LiteralPath $k -Recurse -Force }   # a registry key: no junctions here
        return
    }
    if (-not (Test-Path -LiteralPath $k)) { $null = New-Item -Path $k -Force }
    Set-ItemProperty -LiteralPath $k -Name '(default)' -Value $Exe
    Set-ItemProperty -LiteralPath $k -Name 'Path' -Value (Split-Path -Parent $Exe)
}

function Get-PwshShortcutPath {
    Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\PowerShell\PowerShell 7.lnk'
}

function Set-PwshShortcut {
    param([Parameter(Mandatory)][string] $Exe, [switch] $Remove)
    $lnk = Get-PwshShortcutPath
    $shell = New-Object -ComObject WScript.Shell
    if ($Remove) {
        if ((Test-Path -LiteralPath $lnk) -and $shell.CreateShortcut($lnk).TargetPath -eq $Exe) {
            Remove-Item -LiteralPath $lnk -Force
            $dir = Split-Path -Parent $lnk
            if (-not (Get-ChildItem -LiteralPath $dir -Force)) { [IO.Directory]::Delete($dir, $false) }
        }
        return
    }
    $dir = Split-Path -Parent $lnk
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = $Exe
    $sc.Arguments = '-WorkingDirectory ~'
    $sc.IconLocation = "$Exe,0"
    $sc.Description = 'PowerShell 7 (kept current by pwshup)'
    $sc.Save()
}

function Register-PwshTask {
    param([Parameter(Mandatory)] $Ctx)
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Update -Scheduled -InstallRoot "{1}"' -f $Ctx.Installed, $Ctx.Root
    $action   = New-ScheduledTaskAction -Execute $ps51 -Argument $taskArgs -WorkingDirectory $Ctx.Updater
    $daily    = New-ScheduledTaskTrigger -Daily -At '03:00' -RandomDelay (New-TimeSpan -Hours 1)
    # The boot run is what applies an update the nightly run had to defer
    # because a pwsh window was open; no network needed for that part.
    $boot     = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = 'PT3M'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $null = Register-ScheduledTask -TaskPath $script:PwshTaskPath -TaskName $script:PwshTaskName -Action $action -Trigger @($daily, $boot) `
        -Settings $settings -Principal $principal -Description 'Keeps PowerShell 7 (ZIP) current. pwsh-toolkit: pwshup' -Force
}

function Unregister-PwshTask {
    $t = Get-ScheduledTask -TaskPath $script:PwshTaskPath -TaskName $script:PwshTaskName -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskPath $script:PwshTaskPath -TaskName $script:PwshTaskName -Confirm:$false }
}

function Get-PwshTaskReference {
    # Scheduled tasks that run pwsh: the Store alias (will break when the
    # Store build is removed) or the 7 path (what they should use).
    param([Parameter(Mandatory)] $Ctx)
    $stable = Join-Path $Ctx.Link 'pwsh.exe'
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        foreach ($a in @($t.Actions)) {
            $exe = [Environment]::ExpandEnvironmentVariables("$($a.Execute)".Trim('"'))
            $kind = if ($exe -like '*\WindowsApps\pwsh.exe' -or $exe -like '*\WindowsApps\Microsoft.PowerShell_*\pwsh.exe') { 'Store' }
                    elseif ($exe -ieq $stable) { 'Stable' }
                    else { $null }
            if ($kind) { [pscustomobject]@{ Task = $t.TaskPath + $t.TaskName; Kind = $kind; Execute = $exe }; break }
        }
    }
}

# ---------- Update transaction ----------
function Clear-PwshLeftover {
    # Debris from an interrupted run: half-extracted versions, staging
    # downloads, and anything waiting in trash. All best-effort.
    param([Parameter(Mandatory)] $Ctx)
    $targets = @()
    if (Test-Path -LiteralPath $Ctx.Versions) { $targets += @(Get-ChildItem -LiteralPath $Ctx.Versions -Directory -Force | Where-Object { $_.Name -like '*.partial-*' } | ForEach-Object { $_.FullName }) }
    foreach ($d in @($Ctx.Staging, $Ctx.Trash)) {
        if (Test-Path -LiteralPath $d) { $targets += @(Get-ChildItem -LiteralPath $d -Force | ForEach-Object { $_.FullName }) }
    }
    foreach ($t in $targets) {
        try { Remove-PwshTree $t } catch { Write-PwshLog "Couldn't clear $t yet ($($_.Exception.Message)); will retry." -Level WARN }
    }
}

function Install-PwshVersion {
    # Download, verify and unpack one release into versions\<v>. Nothing
    # outside pwshup\ changes; on any failure the half-built folder goes.
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Version)
    $arch  = Get-PwshArchitecture
    $asset = Get-PwshAssetName -Version $Version -Arch $arch
    Assert-PwshFreeSpace -Path $Ctx.Root
    $id      = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $stage   = Join-Path $Ctx.Staging $id
    $partial = Join-Path $Ctx.Versions ("$Version.partial-$id")
    $final   = Join-Path $Ctx.Versions $Version
    $null = New-Item -ItemType Directory -Path $stage -Force
    try {
        $zip    = Join-Path $stage $asset
        $hashes = Join-Path $stage 'hashes.sha256'
        Write-PwshLog "Downloading $asset ..."
        Save-PwshFile -Uri "$script:PwshReleaseBase/v$Version/$asset" -OutFile $zip
        Save-PwshFile -Uri "$script:PwshReleaseBase/v$Version/hashes.sha256" -OutFile $hashes

        $expected = Read-PwshHashFile -Bytes ([IO.File]::ReadAllBytes($hashes)) -FileName $asset
        $actual   = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "SHA-256 mismatch for ${asset}: got $actual, release says $expected." }
        Write-PwshLog 'SHA-256 matches the release.'

        Expand-PwshZip -ZipPath $zip -Destination $partial
        $sig = Test-PwshSignature -Directory $partial
        if (-not $sig.Ok) { throw ("Signature check failed: " + (($sig.Failures | Select-Object -First 5) -join '; ')) }
        Write-PwshLog "Authenticode: $($sig.Checked) binaries valid."

        Invoke-PwshSmokeTest -Exe (Join-Path $partial 'pwsh.exe') -Expected $Version

        # Keep what this release shipped, so a later switch can tell the
        # machine's own settings from the defaults.
        $shipped = Join-Path $Ctx.State "shipped\$Version"
        if (Get-PwshItem $shipped) { Remove-PwshTree $shipped }
        $null = New-Item -ItemType Directory -Path $shipped -Force
        $cfg = Join-Path $partial 'powershell.config.json'
        if (Test-Path -LiteralPath $cfg) { Copy-Item -LiteralPath $cfg -Destination $shipped -Force }

        if (Get-PwshItem $final) {
            if ((Get-PwshLinkTarget $Ctx.Link) -eq $final) { throw "$final is the running version; refusing to replace it." }
            Remove-PwshTree $final
        }
        [IO.Directory]::Move($partial, $final)
        Write-PwshLog "Staged PowerShell $Version." -Level OK
    } catch {
        try { Remove-PwshTree $partial } catch { $null = $_ }
        throw
    } finally {
        try { Remove-PwshTree $stage } catch { $null = $_ }
    }
}

function Copy-PwshMachineConfig {
    # Settings that live inside $PSHOME and so inside one version folder:
    # powershell.config.json (merged, see Merge-PwshConfigJson) and the
    # all-users profiles (copied).
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $FromDir, [Parameter(Mandatory)][string] $ToDir)
    $fromVersion = Split-Path -Leaf $FromDir
    $live      = Join-Path $FromDir 'powershell.config.json'
    $newPath   = Join-Path $ToDir 'powershell.config.json'
    $shipped   = Join-Path $Ctx.State "shipped\$fromVersion\powershell.config.json"
    $read      = { param($p) if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { $null } }
    $oldLive   = & $read $live
    if ($oldLive) {
        $m = Merge-PwshConfigJson -OldShipped (& $read $shipped) -OldLive $oldLive -NewShipped (& $read $newPath)
        [IO.File]::WriteAllText($newPath, $m.Json, (New-Object System.Text.UTF8Encoding $false))
        if ($m.Carried.Count -gt 0) { Write-PwshLog ("Carried machine settings: " + ($m.Carried -join ', ')) }
        if ($m.Removed.Count -gt 0) { Write-PwshLog ("Kept removed settings removed: " + ($m.Removed -join ', ')) }
    }
    foreach ($name in 'profile.ps1', 'Microsoft.PowerShell_profile.ps1') {
        $src = Join-Path $FromDir $name
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $ToDir $name) -Force
            Write-PwshLog "Carried the all-users profile $name."
        }
    }
}

function Set-PwshActiveVersion {
    # Switch 7 to an already staged version. Returns 'Switched' or 'Deferred'.
    param(
        [Parameter(Mandatory)] $Ctx,
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $Version,
        [switch] $Force
    )
    $target = Join-Path $Ctx.Versions $Version
    $oldDir = Get-PwshLinkTarget $Ctx.Link
    if ($oldDir -and -not (Get-PwshItem $oldDir)) { $oldDir = $null }   # broken link: nothing to protect or carry

    $users = @(Get-PwshProcessUsing -Prefix @($Ctx.Link, $oldDir))
    if ($users.Count -gt 0) {
        $list = ($users | Select-Object -First 5 | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', '
        if (-not $Force) {
            Write-PwshLog "PowerShell $Version is staged; switching waits until no pwsh runs from $($Ctx.Link): $list." -Level WARN
            return 'Deferred'
        }
        Write-PwshLog "Switching with pwsh still running ($list). Restart those windows." -Level WARN
    }

    if ($oldDir) { Copy-PwshMachineConfig -Ctx $Ctx -FromDir $oldDir -ToDir $target }
    Switch-PwshLink -Ctx $Ctx -Target $target
    try {
        Invoke-PwshSmokeTest -Exe (Join-Path $Ctx.Link 'pwsh.exe') -Expected $Version
    } catch {
        # Bad, and no longer staged - so the next prune clears its folder.
        $State.Bad = @($State.Bad) + $Version
        $State.Staged = $null; $State.StagedAt = $null
        if ($oldDir) {
            Switch-PwshLink -Ctx $Ctx -Target $oldDir
            Write-PwshLog "PowerShell $Version failed its check after the switch; switched back and marked it bad." -Level ERROR
        }
        throw
    }
    if ($oldDir) { $State.Previous = Split-Path -Leaf $oldDir }
    $State.Current = $Version
    $State.Staged = $null; $State.StagedAt = $null
    Write-PwshLog "PowerShell $Version is now active at $($Ctx.Link)." -Level OK
    return 'Switched'
}

function Invoke-PwshPrune {
    # Keep current + previous (+ a staged one); move the rest to trash first,
    # so a folder that's in use fails the rename cleanly instead of being
    # left half-deleted.
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] $State)
    $current = Get-PwshLinkTarget $Ctx.Link
    $keep = @($State.Current, $State.Previous, $State.Staged) + @($(if ($current) { Split-Path -Leaf $current }))
    $present = @(Get-PwshVersionFolder $Ctx | Where-Object { $_.Name -notlike '*.partial-*' } | ForEach-Object { $_.Name })
    foreach ($name in (Get-PwshPruneSet -Present $present -Keep $keep)) {
        $src = Join-Path $Ctx.Versions $name
        $dst = Join-Path $Ctx.Trash ("$name-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            [IO.Directory]::Move($src, $dst)
            Remove-PwshTree $dst
            $shipped = Join-Path $Ctx.State "shipped\$name"
            if (Get-PwshItem $shipped) { Remove-PwshTree $shipped }
            Write-PwshLog "Removed PowerShell $name."
        } catch {
            Write-PwshLog "PowerShell $name is still in use; will remove it later." -Level WARN
        }
    }
}

function Invoke-PwshUpdateRun {
    param(
        [Parameter(Mandatory)] $Ctx,
        [string] $Version,
        [switch] $AllowMajor,
        [switch] $Force
    )
    $state = Read-PwshState $Ctx
    $state.LastCheck = Get-PwshStamp
    Repair-PwshLink $Ctx
    Clear-PwshLeftover $Ctx

    $msi = @(Get-PwshMsiRegistration)
    if ($msi.Count -gt 0) { throw "A PowerShell 7 MSI is installed ($($msi -join ', ')). It would install through $($Ctx.Link); uninstall it first." }

    $current = Get-PwshCurrentVersion $Ctx
    $explicit = [bool]$Version
    $available = $null
    if ($explicit) {
        $available = ConvertTo-PwshVersion $Version
        if (-not $available) { throw "'$Version' isn't a release version like 7.6.6." }
    } else {
        try {
            $tag = Get-PwshStableTag
            $available = ConvertTo-PwshVersion $tag
            if (-not $available) { throw "metadata.json returned an unexpected StableReleaseTag '$tag'." }
            $state.LatestStable = $available.ToString(3)
        } catch {
            Write-PwshLog "Couldn't look up the latest release: $($_.Exception.Message)" -Level WARN
        }
    }

    $decision = Select-PwshTarget -Available $available -Current $current -Bad $state.Bad -AllowMajor:$AllowMajor -Explicit:$explicit
    $state.BlockedMajor = $(if ($decision.Action -eq 'Blocked') { $decision.Version } else { $null })
    if ($decision.Action -ne 'Update' -and $decision.Version) {
        $level = if ($decision.Action -eq 'None') { 'OK' } else { 'WARN' }
        Write-PwshLog ("PowerShell {0}: {1}." -f $decision.Version, $decision.Reason) -Level $level
    }

    $toApply = $null
    if ($decision.Action -eq 'Update') {
        Write-PwshLog ("PowerShell {0}: {1}." -f $decision.Version, $decision.Reason)
        if ($explicit) { $state.Bad = @($state.Bad | Where-Object { $_ -ne $decision.Version }) }
        if (-not (Test-PwshVersionReady -Ctx $Ctx -Version $decision.Version)) {
            Install-PwshVersion -Ctx $Ctx -Version $decision.Version
        }
        $toApply = $decision.Version
        if ($state.Staged -ne $toApply) { $state.Staged = $toApply; $state.StagedAt = Get-PwshStamp }
        Save-PwshState -Ctx $Ctx -State $state
    } elseif ($state.Staged -and ($state.Bad -notcontains $state.Staged) -and (Test-PwshVersionReady -Ctx $Ctx -Version $state.Staged)) {
        $staged = ConvertTo-PwshVersion $state.Staged
        if ($staged -and (-not $current -or $staged -gt $current)) { $toApply = $state.Staged }
        else { $state.Staged = $null; $state.StagedAt = $null }
    }

    $outcome = 'UpToDate'
    if ($toApply) {
        try { $outcome = Set-PwshActiveVersion -Ctx $Ctx -State $state -Version $toApply -Force:$Force }
        finally { Save-PwshState -Ctx $Ctx -State $state }
    }
    Invoke-PwshPrune -Ctx $Ctx -State $state

    if (-not $state.Current) { $cv = Get-PwshCurrentVersion $Ctx; if ($cv) { $state.Current = $cv.ToString(3) } }
    # A failed lookup isn't a success: the stale-check banner should notice a
    # machine that has been offline (or proxied away from GitHub) for a week.
    if ($available) { $state.LastSuccess = Get-PwshStamp }
    $state.LastResult = $outcome
    Save-PwshState -Ctx $Ctx -State $state
    return $outcome
}

# ---------- Commands ----------
function Assert-PwshAdmin {
    if (-not (Test-PwshIsAdmin)) { throw 'This needs an elevated (Administrator) PowerShell.' }
}

function Assert-PwshRoot {
    param([Parameter(Mandatory)] $Ctx)
    if ($Ctx.Root.Length -gt $script:PwshMaxRootLength) { throw "InstallRoot is longer than $script:PwshMaxRootLength characters; Windows PowerShell couldn't reach the deepest files under it." }
    foreach ($p in @($Ctx.Root, $Ctx.Work)) {
        if (Test-PwshReparsePoint $p) { throw "$p is a link; refusing to work through it." }
    }
}

function Enter-PwshLock {
    # One run at a time: the nightly task and an interactive pwshup -Update
    # must not both move the junction. The lock file lives in the admin-only
    # state folder, so nothing unprivileged can hold it first.
    param([Parameter(Mandatory)] $Ctx)
    try {
        $script:PwshLock = [IO.File]::Open($Ctx.LockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw 'Another pwshup run is in progress.'
    }
}

function Exit-PwshLock {
    if ($script:PwshLock) { $script:PwshLock.Dispose(); $script:PwshLock = $null }
}

function Initialize-PwshWorkspace {
    param([Parameter(Mandatory)] $Ctx)
    foreach ($d in @($Ctx.Work, $Ctx.Versions, $Ctx.Staging, $Ctx.Trash, $Ctx.State, $Ctx.Logs, $Ctx.Updater)) {
        if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
    }
}

function Invoke-PwshInstall {
    param(
        [Parameter(Mandatory)] $Ctx,
        [Parameter(Mandatory)][string] $SourceScript,
        [string] $Version,
        [switch] $AllowMajor,
        [string] $HealthcheckUrl
    )
    Assert-PwshAdmin
    Assert-PwshRoot $Ctx
    $msi = @(Get-PwshMsiRegistration)
    if ($msi.Count -gt 0) { throw "A PowerShell 7 MSI is installed ($($msi -join ', ')). Uninstall it first; it would install through $($Ctx.Link)." }

    # A real 7 folder is either a leftover from an MSI that is gone (empty
    # directories only - move it aside) or something else (stop).
    if ((Get-PwshItem $Ctx.Link) -and -not (Test-PwshReparsePoint $Ctx.Link)) {
        $c = Get-PwshTreeContent $Ctx.Link
        if ($c.Files -gt 0 -or $c.Links -gt 0) {
            throw "$($Ctx.Link) holds $($c.Files) file(s) and $($c.Links) link(s) - a real install? Remove it first."
        }
        $aside = '{0}.debris-{1}' -f $Ctx.Link, (Get-Date -Format 'yyyyMMdd-HHmmss')
        [IO.Directory]::Move($Ctx.Link, $aside)
        Write-Host "  Moved the empty leftover $($Ctx.Link) to $aside." -ForegroundColor Yellow
    }

    Initialize-PwshWorkspace $Ctx
    Start-PwshLog $Ctx
    Enter-PwshLock $Ctx
    try {
        Write-PwshLog "Installing from $SourceScript."
        if ([IO.Path]::GetFullPath($SourceScript) -ne [IO.Path]::GetFullPath($Ctx.Installed)) {
            Copy-Item -LiteralPath $SourceScript -Destination $Ctx.Installed -Force
        }
        if ($HealthcheckUrl) {
            $st = Read-PwshState $Ctx; $st.HealthcheckUrl = $HealthcheckUrl; Save-PwshState -Ctx $Ctx -State $st
        }

        $outcome = Invoke-PwshUpdateRun -Ctx $Ctx -Version $Version -AllowMajor:$AllowMajor
        if (-not (Get-PwshCurrentVersion $Ctx)) {
            throw "No PowerShell is active at $($Ctx.Link) ($outcome). See $($Ctx.LogFile)."
        }

        $exe = Join-Path $Ctx.Link 'pwsh.exe'
        if (Set-PwshMachinePath -Entry $Ctx.Link) { Write-PwshLog "Added $($Ctx.Link) to the machine PATH." }
        Set-PwshAppPath -Exe $exe
        Set-PwshShortcut -Exe $exe
        Register-PwshTask -Ctx $Ctx
        Write-PwshLog "Registered $($script:PwshTaskPath)$($script:PwshTaskName) (daily and at startup, as SYSTEM)." -Level OK
    } finally { Exit-PwshLock }

    $refs = @(Get-PwshTaskReference -Ctx $Ctx)
    Write-Host ''
    Write-Host '  Next steps' -ForegroundColor Cyan
    $store = @($refs | Where-Object { $_.Kind -eq 'Store' })
    if ($store.Count -gt 0) {
        Write-Host '  These scheduled tasks run the Store build and stop working when it is removed.' -ForegroundColor Yellow
        Write-Host "  Re-point them at $exe first:" -ForegroundColor Yellow
        foreach ($r in $store) { Write-Host "    $($r.Task)" }
    }
    $stable = @($refs | Where-Object { $_.Kind -eq 'Stable' })
    if ($stable.Count -gt 0) { Write-Host ("  Working again now that $exe exists: " + (($stable | ForEach-Object { $_.Task }) -join ', ')) -ForegroundColor DarkGray }
    Write-Host '  Open a new terminal, then from the NEW pwsh remove the Store build:' -ForegroundColor Gray
    Write-Host '    Get-AppxPackage Microsoft.PowerShell | Remove-AppxPackage' -ForegroundColor White
    Write-Host ''
}

function Invoke-PwshRollback {
    param([Parameter(Mandatory)] $Ctx, [switch] $Force)
    Assert-PwshAdmin
    Assert-PwshRoot $Ctx
    Start-PwshLog $Ctx
    Enter-PwshLock $Ctx
    try {
        Repair-PwshLink $Ctx
        $state = Read-PwshState $Ctx
        $current = Get-PwshCurrentVersion $Ctx
        if (-not $current) { throw "Nothing is active at $($Ctx.Link) to roll back from." }
        $prev = $state.Previous
        if (-not $prev -or -not (Test-PwshVersionReady -Ctx $Ctx -Version $prev) -or $prev -eq $current.ToString(3)) {
            # state.json lost or stale: fall back to the newest older folder.
            $prev = Get-PwshVersionFolder $Ctx | ForEach-Object { ConvertTo-PwshVersion $_.Name } |
                Where-Object { $_ -and $_ -lt $current } | Sort-Object -Descending | Select-Object -First 1
            if ($prev) { $prev = $prev.ToString(3) }
        }
        if (-not $prev) { throw 'No previous version is kept to roll back to.' }
        $from = $current.ToString(3)
        $outcome = Set-PwshActiveVersion -Ctx $Ctx -State $state -Version $prev -Force:$Force
        if ($outcome -eq 'Switched') {
            $state.Bad = @($state.Bad) + $from
            Write-PwshLog "Rolled back to $prev; $from is marked bad and won't be reinstalled automatically (pwshup -Update -Version $from overrides)." -Level OK
        } else {
            Write-PwshLog 'Close the pwsh windows listed above, or re-run with -Force.' -Level WARN
        }
        Save-PwshState -Ctx $Ctx -State $state
    } finally { Exit-PwshLock }
}

function Invoke-PwshUninstall {
    param([Parameter(Mandatory)] $Ctx, [switch] $Force)
    Assert-PwshAdmin
    Assert-PwshRoot $Ctx
    $users = @(Get-PwshProcessUsing -Prefix @($Ctx.Link, $Ctx.Versions))
    if ($users.Count -gt 0 -and -not $Force) {
        throw ("pwsh is still running from here: " + (($users | Select-Object -First 5 | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', ') + '. Close it, or use -Force.')
    }
    $exe = Join-Path $Ctx.Link 'pwsh.exe'
    Unregister-PwshTask
    if (Set-PwshMachinePath -Entry $Ctx.Link -Remove) { Write-Host "  Removed $($Ctx.Link) from the machine PATH." }
    Set-PwshAppPath -Exe $exe -Remove
    Set-PwshShortcut -Exe $exe -Remove
    if (Test-PwshReparsePoint $Ctx.Link) { Remove-PwshLink $Ctx.Link }
    try {
        Remove-PwshTree $Ctx.Work
        Write-Host "  Removed $($Ctx.Work)." -ForegroundColor Green
    } catch {
        Write-Host "  Couldn't remove all of $($Ctx.Work) ($($_.Exception.Message)); delete it after closing pwsh." -ForegroundColor Yellow
    }
    $debris = @(Get-ChildItem -LiteralPath $Ctx.Root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '7.debris-*' })
    if ($debris.Count -gt 0) { Write-Host ("  Left alone: " + (($debris | ForEach-Object { $_.FullName }) -join ', ') + ' (the folder -Install moved aside).') -ForegroundColor DarkGray }
    Write-Host "  $($Ctx.Root)\Modules and \Scripts are untouched." -ForegroundColor DarkGray
}

function Get-PwshLogTail {
    param([Parameter(Mandatory)] $Ctx, [int] $Count = 5)
    if (-not (Test-Path -LiteralPath $Ctx.LogFile)) { return }
    foreach ($l in (Get-Content -LiteralPath $Ctx.LogFile -Tail $Count)) {
        if ($l -match '^<!\[LOG\[(.*)\]LOG\]!><time="(\d\d:\d\d:\d\d)[^"]*" date="(\d\d)-(\d\d)-(\d{4})"') {
            '{0}-{1}-{2} {3}  {4}' -f $Matches[5], $Matches[3], $Matches[4], $Matches[2], $Matches[1]
        }
    }
}

function Show-PwshStatus {
    param([Parameter(Mandatory)] $Ctx, [string] $SourceScript, [switch] $Offline)
    $row = { param($k, $v, $c) Write-Host ('  {0,-16}' -f $k) -NoNewline -ForegroundColor DarkGray; Write-Host $v -ForegroundColor $(if ($c) { $c } else { 'Gray' }) }
    Write-Host ''
    $installed = (Test-PwshReparsePoint $Ctx.Link) -and (Test-Path -LiteralPath $Ctx.Work)
    if (-not $installed) {
        & $row 'PowerShell 7' 'not installed by pwshup' 'Yellow'
        if ((Get-PwshItem $Ctx.Link) -and -not (Test-PwshReparsePoint $Ctx.Link)) {
            & $row '' "$($Ctx.Link) is a plain folder (an MSI install or its leftovers)." 'DarkGray'
        }
        if ($PSHOME -like '*\WindowsApps\*') { & $row 'This shell' 'the Store build (per-user only)' 'DarkGray' }
        & $row '' 'pwshup -Install sets up the systemwide ZIP install.' 'Cyan'
        Write-Host ''
        return
    }

    $state = Read-PwshState $Ctx
    $current = Get-PwshCurrentVersion $Ctx
    $target = Get-PwshLinkTarget $Ctx.Link
    & $row 'PowerShell 7' $(if ($current) { "$($current.ToString(3))   $($Ctx.Link) -> $target" } else { "broken link -> $target" }) $(if ($current) { 'Green' } else { 'Red' })

    if (-not $Offline) {
        $latest = $null
        try { $latest = ConvertTo-PwshVersion (Get-PwshStableTag) } catch { $null = $_ }
        if (-not $latest) { & $row 'Latest Stable' 'unknown (offline?)' 'Yellow' }
        elseif ($current -and $latest -eq $current) { & $row 'Latest Stable' "$($latest.ToString(3))   up to date" 'Green' }
        elseif ($current -and $latest.Major -gt $current.Major) { & $row 'Latest Stable' "$($latest.ToString(3))   new major - pwshup -Update -AllowMajor" 'Yellow' }
        elseif ($current -and $latest -lt $current) { & $row 'Latest Stable' "$($latest.ToString(3))" }
        else { & $row 'Latest Stable' "$($latest.ToString(3))   update available - pwshup -Update" 'Yellow' }
    }
    if ($state.Previous) { & $row 'Previous' "$($state.Previous)   (pwshup -Rollback)" }
    if ($state.Staged) { & $row 'Staged' "$($state.Staged)   waiting for pwsh windows to close (or pwshup -Update -Force)" 'Yellow' }
    if (@($state.Bad).Count -gt 0) { & $row 'Marked bad' (@($state.Bad) -join ', ') 'DarkGray' }

    $task = Get-ScheduledTask -TaskPath $script:PwshTaskPath -TaskName $script:PwshTaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        $res = if ($info) { '0x{0:X}' -f ($info.LastTaskResult -band 0xFFFFFFFFL) } else { '?' }
        $ok = $info -and $info.LastTaskResult -eq 0
        $last = if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
        $next = if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }
        & $row 'Updater task' "$($task.State), last run $last ($res), next $next" $(if ($ok -or $last -eq 'never') { 'Gray' } else { 'Yellow' })
    } elseif (Test-PwshIsAdmin) {
        & $row 'Updater task' 'not registered - pwshup -Install' 'Yellow'
    } else {
        # A SYSTEM task registered by an admin is invisible to a standard
        # user's Get-ScheduledTask, so absence here proves nothing. The task
        # stamps state.json on every run; 'Last good check' below is the
        # health signal that doesn't need elevation.
        & $row 'Updater task' 'runs as SYSTEM - its schedule is visible only from an elevated shell' 'DarkGray'
    }
    if ($state.LastSuccess) {
        $when = ([datetime]$state.LastSuccess).ToLocalTime()
        & $row 'Last good check' ('{0:yyyy-MM-dd HH:mm}   {1}' -f $when, $state.LastResult) $(if (((Get-Date) - $when).TotalDays -gt 7) { 'Yellow' } else { 'Gray' })
    }

    if ($SourceScript -and (Test-Path -LiteralPath $Ctx.Installed) -and
        [IO.Path]::GetFullPath($SourceScript) -ne [IO.Path]::GetFullPath($Ctx.Installed) -and
        (Get-FileHash -LiteralPath $SourceScript).Hash -ne (Get-FileHash -LiteralPath $Ctx.Installed).Hash) {
        & $row 'Updater copy' 'differs from the repo - pwshup -Install refreshes it' 'Yellow'
    }

    $store = @(Get-PwshTaskReference -Ctx $Ctx | Where-Object { $_.Kind -eq 'Store' })
    if ($store.Count -gt 0) {
        & $row 'Store tasks' ((($store | ForEach-Object { $_.Task }) -join ', ') + "  -> re-point to $(Join-Path $Ctx.Link 'pwsh.exe')") 'Yellow'
    }
    if ($PSHOME -like '*\WindowsApps\*') { & $row 'This shell' 'the Store build - open a new terminal for the systemwide one' 'Yellow' }

    $tail = @(Get-PwshLogTail -Ctx $Ctx -Count 4)
    if ($tail.Count -gt 0) {
        Write-Host ''
        Write-Host "  Recent log ($($Ctx.LogFile)):" -ForegroundColor DarkGray
        foreach ($l in $tail) { Write-Host "    $l" -ForegroundColor DarkGray }
    }
    Write-Host ''
}

# Dot-sourcing (the test harness does) defines the functions and stops here.
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------- Main ----------
# Stop on every error: a transaction that half-happens is the failure mode
# this script exists to prevent.
$ErrorActionPreference = 'Stop'
$ctx = New-PwshContext -InstallRoot $InstallRoot
try {
    if ($Install) {
        Invoke-PwshInstall -Ctx $ctx -SourceScript $PSCommandPath -Version $Version -AllowMajor:$AllowMajor -HealthcheckUrl $HealthcheckUrl
    } elseif ($Rollback) {
        Invoke-PwshRollback -Ctx $ctx -Force:$Force
    } elseif ($Uninstall) {
        Invoke-PwshUninstall -Ctx $ctx -Force:$Force
    } elseif ($Update) {
        Assert-PwshAdmin
        Assert-PwshRoot $ctx
        # SYSTEM only ever runs the admin-only installed copy: a SYSTEM task
        # pointed at a user-writable script would be a privilege escalation.
        if ((Test-PwshIsSystem) -and [IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($ctx.Installed)) {
            throw "Running as SYSTEM from $PSCommandPath; only $($ctx.Installed) may run as SYSTEM."
        }
        if (-not (Test-Path -LiteralPath $ctx.Work)) { throw "Not installed under $($ctx.Root); run pwshup -Install first." }
        Initialize-PwshWorkspace $ctx
        Start-PwshLog $ctx
        if ($Scheduled) { $script:PwshQuiet = $true }
        Enter-PwshLock $ctx
        try {
            Write-PwshLog ("Update run ({0})." -f $(if ($Scheduled) { 'scheduled' } else { 'interactive' }))
            $outcome = Invoke-PwshUpdateRun -Ctx $ctx -Version $Version -AllowMajor:$AllowMajor -Force:($Force -and -not $Scheduled)
            if ($outcome -eq 'Deferred' -and -not $Scheduled) {
                Write-PwshLog 'Close the pwsh windows listed above, or re-run with -Force; the next boot applies it otherwise.' -Level WARN
            }
        } finally { Exit-PwshLock }
        if ($Scheduled) { Send-PwshHealthcheck -Url (Read-PwshState $ctx).HealthcheckUrl }
    } else {
        Show-PwshStatus -Ctx $ctx -SourceScript $PSCommandPath -Offline:$Offline
    }
    exit 0
} catch {
    Write-PwshLog $_.Exception.Message -Level ERROR
    if ($Scheduled) {
        try { Send-PwshHealthcheck -Url (Read-PwshState $ctx).HealthcheckUrl -Fail } catch { $null = $_ }
    }
    exit 1
}
