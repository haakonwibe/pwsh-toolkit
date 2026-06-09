#Requires -Version 7.0
<#
.SYNOPSIS
    Interactive winget upgrade selector with logging.

.DESCRIPTION
    Lists all available winget upgrades, lets you pick which ones to install via
    an interactive selector (Up/Down to move, Space to toggle, A to toggle all,
    Enter to confirm, Esc to cancel), then upgrades the selected packages.
    Everything is logged to ProgramData.

.PARAMETER All
    Skip the selector and upgrade everything that has a pending update.

.PARAMETER IncludeUnknown
    Pass --include-unknown to winget so packages with unknown installed versions
    are listed (off by default — they often can't be safely upgraded).

.PARAMETER LogDirectory
    Override the log directory. Defaults to C:\ProgramData\WingetUpgrade\Logs.

.EXAMPLE
    .\Invoke-WingetUpgrade.ps1
    Show the picker, choose packages, upgrade.

.EXAMPLE
    .\Invoke-WingetUpgrade.ps1 -All
    Upgrade everything non-interactively.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'All', Justification = 'Read via $script:All inside Select-Packages (verified); the analyzer cannot trace the cross-scope reference.')]
param(
    [switch] $All,
    [switch] $IncludeUnknown,
    [string] $LogDirectory
)

$ErrorActionPreference = 'Stop'

# ---------- Logging ----------
if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $programData = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { 'C:\ProgramData' } else { $env:ProgramData }
    $LogDirectory = Join-Path $programData 'WingetUpgrade\Logs'
}
if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
$logFile = Join-Path $LogDirectory ("winget-upgrade-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

# CMTrace XML format: lets the log render properly in CMTrace (severity coloring
# by `type` attribute, Date/Time/Component pane populated, filtering). CMTrace
# has no "success" color — OK and INFO both map to type=1 (info).
function Format-CMTraceLine {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet(1,2,3)][int]      $Type = 1,
        [string]                       $Component = 'WingetUpgrade'
    )
    $now    = Get-Date
    $offset = [int][System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
    $sign   = if ($offset -ge 0) { '+' } else { '' }
    '<![LOG[{0}]LOG]!><time="{1}{2}{3}" date="{4}" component="{5}" context="" type="{6}" thread="{7}" file="">' -f `
        $Message, $now.ToString('HH:mm:ss.fff'), $sign, $offset, $now.ToString('MM-dd-yyyy'), $Component, $Type, $PID
}

function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Script-local CMTrace logger; not exported, shadows nothing outside this script.')]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','OK')] [string] $Level = 'INFO'
    )
    $stamp     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $humanLine = "[$stamp] [$Level] $Message"

    $cmType = switch ($Level) { 'WARN' { 2 } 'ERROR' { 3 } default { 1 } }
    Add-Content -Path $logFile -Value (Format-CMTraceLine -Message $Message -Type $cmType) -Encoding utf8

    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'OK'    { 'Green' }
        default { 'Gray' }
    }
    Write-Host $humanLine -ForegroundColor $color
}

# ---------- Pre-flight ----------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Log 'winget not found on PATH. Install App Installer from the Microsoft Store.' -Level ERROR
    exit 1
}

Write-Host ''
Write-Host '  Winget Upgrade Helper' -ForegroundColor Cyan
Write-Host '  ---------------------' -ForegroundColor Cyan
Write-Log "Log file: $logFile"
Write-Log "winget: $((winget --version) 2>&1)"

# Non-elevated runs still work — machine-scope packages just trigger a UAC
# prompt each. Warn so the user isn't surprised by a click-fest mid-batch.
$isAdmin = ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  Not running elevated — expect a UAC prompt per machine-scope package.' -ForegroundColor Yellow
    Write-Host '  Tip: winup -Elevated approves a single prompt up front instead.' -ForegroundColor Yellow
    Write-Log 'Non-elevated session — UAC prompts will appear for machine-scope packages.' -Level WARN
}

# ---------- Get upgrade list ----------
function Get-WingetUpgrades {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a collection of available upgrades; plural reads naturally for this internal helper.')]
    param([switch] $IncludeUnknown)

    $cmdArgs = @('upgrade', '--accept-source-agreements')
    if ($IncludeUnknown) { $cmdArgs += '--include-unknown' }

    # Force UTF-8 so the box-drawing header parses reliably.
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    try {
        $raw = & winget @cmdArgs 2>&1 | Out-String
    }
    finally {
        [Console]::OutputEncoding = $prevEnc
    }

    $lines = $raw -split "`r?`n"

    # Find the header line (has Name + Id + Version + Available + Source).
    $headerIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*Name\s+' -and $l -match '\bId\b' -and $l -match '\bAvailable\b') {
            $headerIdx = $i; break
        }
    }
    if ($headerIdx -lt 0) {
        Write-Log 'No upgradable packages detected (no header line found).' -Level INFO
        return @()
    }

    $header = $lines[$headerIdx]
    # Column starts are anchored to header keyword positions.
    $colStarts = @{
        Name      = $header.IndexOf('Name')
        Id        = $header.IndexOf('Id')
        Version   = $header.IndexOf('Version')
        Available = $header.IndexOf('Available')
        Source    = $header.IndexOf('Source')
    }

    function Get-Slice {
        param([string] $Line, [int] $Start, [int] $End)
        if ($Start -lt 0 -or $Start -ge $Line.Length) { return '' }
        if ($End -lt 0 -or $End -gt $Line.Length) { $End = $Line.Length }
        return $Line.Substring($Start, $End - $Start).Trim()
    }

    $pkgs = New-Object System.Collections.Generic.List[object]
    # Skip the separator line (---- ----) immediately after the header.
    for ($i = $headerIdx + 2; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Footer lines from winget: "N upgrades available." / "The following packages have an upgrade..." / pin notices etc.
        if ($line -match '^\s*\d+\s+upgrades?\s+available') { break }
        if ($line -match '^\s*The following packages') { continue }
        if ($line -match '^\s*\d+\s+package(s)?\s+have') { break }
        if ($line -match '^\s*-+\s*$') { continue }
        # A real row should start with text at the Name column.
        if ($colStarts.Name -ge 0 -and $line.Length -gt $colStarts.Name) {
            $name      = Get-Slice $line $colStarts.Name      $colStarts.Id
            $id        = Get-Slice $line $colStarts.Id        $colStarts.Version
            $version   = Get-Slice $line $colStarts.Version   $colStarts.Available
            $available = Get-Slice $line $colStarts.Available $colStarts.Source
            $source    = Get-Slice $line $colStarts.Source    $line.Length

            if ([string]::IsNullOrWhiteSpace($id)) { continue }

            $pkgs.Add([pscustomobject]@{
                Name      = $name
                Id        = $id
                Version   = $version
                Available = $available
                Source    = $source
            })
        }
    }

    return $pkgs
}

Write-Log 'Querying winget for available upgrades...'
$packages = Get-WingetUpgrades -IncludeUnknown:$IncludeUnknown
if (-not $packages -or $packages.Count -eq 0) {
    Write-Log 'Nothing to upgrade. You are up to date.' -Level OK
    exit 0
}
Write-Log ("Found {0} package(s) with available upgrades." -f $packages.Count) -Level OK

# ---------- Selection ----------
function Format-Cell {
    param([string] $Text, [int] $Width)
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Width) {
        return $t.Substring(0, [Math]::Max(1, $Width - 1)) + [char]0x2026  # …
    }
    return $t.PadRight($Width)
}

function Show-InteractiveSelector {
    param(
        [Parameter(Mandatory)] [object[]] $Items,
        [string] $Title = 'Select items'
    )

    if (-not $Items -or $Items.Count -eq 0) { return @() }

    $nameWidth = 45
    $verWidth  = 14
    $rows = foreach ($p in $Items) {
        "{0}  {1} -> {2}" -f `
            (Format-Cell $p.Name $nameWidth),
            (Format-Cell $p.Version $verWidth),
            (Format-Cell $p.Available $verWidth)
    }
    $rows = @($rows)

    $selected = New-Object 'bool[]' $Items.Count
    $cursor   = 0
    $viewTop  = 0
    $cancelled = $false

    Clear-Host
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $winH = [Console]::WindowHeight
            $chrome = 6   # title + hint + blank + blank + footer + blank
            $maxVisible = [Math]::Max(3, $winH - $chrome)
            $visible = [Math]::Min($Items.Count, $maxVisible)

            # Keep cursor in viewport
            if ($cursor -lt $viewTop) { $viewTop = $cursor }
            if ($cursor -ge $viewTop + $visible) { $viewTop = $cursor - $visible + 1 }

            [Console]::SetCursorPosition(0, 0)

            $countSel = @($selected | Where-Object { $_ }).Count
            $headerLine = "  $Title  ($countSel of $($Items.Count) selected)"
            Write-Host $headerLine.PadRight([Math]::Max(0, [Console]::WindowWidth - 1)) -ForegroundColor Cyan
            $hint = '  Up/Down move  Space toggle  A toggle-all  Enter confirm  Esc cancel'
            Write-Host $hint.PadRight([Math]::Max(0, [Console]::WindowWidth - 1)) -ForegroundColor DarkGray
            Write-Host ''.PadRight([Math]::Max(0, [Console]::WindowWidth - 1))

            for ($i = 0; $i -lt $visible; $i++) {
                $idx = $viewTop + $i
                $isCursor = ($idx -eq $cursor)
                $marker = if ($isCursor) { '>' } else { ' ' }
                $check  = if ($selected[$idx]) { '[x]' } else { '[ ]' }
                $line   = "  $marker $check $($rows[$idx])"
                $line = $line.PadRight([Math]::Max(0, [Console]::WindowWidth - 1))
                if ($line.Length -ge [Console]::WindowWidth) {
                    $line = $line.Substring(0, [Console]::WindowWidth - 1)
                }

                if ($isCursor) {
                    Write-Host $line -ForegroundColor Black -BackgroundColor Cyan
                } elseif ($selected[$idx]) {
                    Write-Host $line -ForegroundColor Green
                } else {
                    Write-Host $line
                }
            }

            $scrollInfo = ''
            if ($Items.Count -gt $visible) {
                $scrollInfo = "  -- showing $($viewTop + 1)-$($viewTop + $visible) of $($Items.Count) --"
            }
            Write-Host ''.PadRight([Math]::Max(0, [Console]::WindowWidth - 1))
            Write-Host $scrollInfo.PadRight([Math]::Max(0, [Console]::WindowWidth - 1)) -ForegroundColor DarkGray

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $Items.Count - 1) { $cursor++ } }
                'PageUp'    { $cursor = [Math]::Max(0, $cursor - $visible) }
                'PageDown'  { $cursor = [Math]::Min($Items.Count - 1, $cursor + $visible) }
                'Home'      { $cursor = 0 }
                'End'       { $cursor = $Items.Count - 1 }
                'Spacebar'  { $selected[$cursor] = -not $selected[$cursor] }
                'Enter'     { break }
                'Escape'    { $cancelled = $true; break }
                default {
                    $c = [char]::ToLower($key.KeyChar)
                    if ($c -eq 'a') {
                        $allOn = -not (@($selected | Where-Object { -not $_ }).Count -gt 0)
                        for ($i = 0; $i -lt $selected.Count; $i++) { $selected[$i] = -not $allOn }
                    }
                    elseif ($c -eq 'q') { $cancelled = $true; break }
                }
            }
            if ($key.Key -eq 'Enter' -or $key.Key -eq 'Escape' -or [char]::ToLower($key.KeyChar) -eq 'q') { break }
        }
    }
    finally {
        [Console]::CursorVisible = $true
        Clear-Host
    }

    if ($cancelled) { return @() }
    $result = for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($selected[$i]) { $Items[$i] }
    }
    return $result
}

function Select-Packages {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Operates on and returns a collection of packages; plural reads naturally for this internal helper.')]
    param([object[]] $Packages)
    if ($script:All) { return $Packages }
    return Show-InteractiveSelector -Items $Packages -Title 'Select packages to upgrade'
}

$chosen = @(Select-Packages -Packages $packages)
if (-not $chosen -or $chosen.Count -eq 0) {
    Write-Log 'No packages selected. Exiting.' -Level INFO
    exit 0
}

# ---------- Confirm ----------
Write-Host ''
Write-Host '  About to upgrade:' -ForegroundColor Cyan
foreach ($p in $chosen) {
    Write-Host ("    - {0}  {1} -> {2}" -f `
        (Format-Cell $p.Name 45),
        (Format-Cell $p.Version 14),
        (Format-Cell $p.Available 14))
}
Write-Host ''
Write-Host '  Proceed? [Y/n] ' -ForegroundColor Yellow -NoNewline
$confirm = Read-Host
if ($confirm -and $confirm -notmatch '^(y|yes)$') {
    Write-Log 'User cancelled at confirmation.' -Level INFO
    exit 0
}

# ---------- Upgrade ----------
$results = @()
$idx = 0
foreach ($p in $chosen) {
    $idx++
    Write-Host ''
    Write-Host ("  [{0}/{1}] Upgrading {2} ({3})" -f $idx, $chosen.Count, $p.Name, $p.Id) -ForegroundColor Cyan
    Write-Log ("Upgrading {0} ({1}) {2} -> {3} [source={4}]" -f $p.Name, $p.Id, $p.Version, $p.Available, $p.Source)

    $wingetArgs = @(
        'upgrade',
        '--id', $p.Id,
        '--exact',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($p.Source) { $wingetArgs += @('--source', $p.Source) }

    try {
        # Let winget draw directly to the console — capturing through a pipe
        # turns its spinner frames into separate lines and breaks the progress
        # bar's encoding. We only need the exit code afterwards.
        & winget @wingetArgs
        $exit = $LASTEXITCODE
        if ($exit -eq 0) {
            Write-Log ("OK: {0}" -f $p.Id) -Level OK
            $results += [pscustomobject]@{ Id = $p.Id; Name = $p.Name; Status = 'Success'; ExitCode = $exit }
        }
        else {
            Write-Log ("FAILED ({0}): {1}" -f $exit, $p.Id) -Level ERROR
            $results += [pscustomobject]@{ Id = $p.Id; Name = $p.Name; Status = 'Failed'; ExitCode = $exit }
        }
    }
    catch {
        Write-Log ("EXCEPTION upgrading {0}: {1}" -f $p.Id, $_.Exception.Message) -Level ERROR
        $results += [pscustomobject]@{ Id = $p.Id; Name = $p.Name; Status = 'Exception'; ExitCode = -1 }
    }
}

# ---------- Summary ----------
Write-Host ''
Write-Host '  Summary' -ForegroundColor Cyan
Write-Host '  -------' -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }

# Write each table row as its own CMTrace info line so the file stays valid format throughout.
$results | Format-Table -AutoSize | Out-String -Stream |
    Where-Object { $_.Trim() } |
    ForEach-Object { Add-Content -Path $logFile -Value (Format-CMTraceLine -Message $_ -Type 1) -Encoding utf8 }

$failed = @($results | Where-Object { $_.Status -ne 'Success' })
$finalLevel = if ($failed.Count -gt 0) { 'ERROR' } else { 'OK' }
Write-Log ("Done. {0} succeeded, {1} failed. Log: {2}" -f ($results.Count - $failed.Count), $failed.Count, $logFile) -Level $finalLevel

exit ([int]([bool]$failed.Count))
