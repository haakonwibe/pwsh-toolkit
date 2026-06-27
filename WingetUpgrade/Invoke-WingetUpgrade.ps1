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

.PARAMETER InstallWinGetModule
    Install the Microsoft.WinGet.Client module (CurrentUser scope) before listing,
    then list through it. The module reads upgrades from WinGet's API instead of
    parsing console text, so listing is robust and works in any display language.
    Without this switch, an interactive run offers to install the module when it's
    absent; -All / non-interactive runs just print a one-line suggestion.

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
    [switch] $InstallWinGetModule,
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
    # InvariantCulture so the CMTrace time field is always colon-delimited
    # (HH:mm:ss.fff) regardless of region — the current culture's time separator
    # varies (e.g. '.' on Finnish), which would otherwise emit an unparseable stamp.
    '<![LOG[{0}]LOG]!><time="{1}{2}{3}" date="{4}" component="{5}" context="" type="{6}" thread="{7}" file="">' -f `
        $Message, $now.ToString('HH:mm:ss.fff', [cultureinfo]::InvariantCulture), $sign, $offset, $now.ToString('MM-dd-yyyy', [cultureinfo]::InvariantCulture), $Component, $Type, $PID
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
# Prefer the Microsoft.WinGet.Client module when it's installed: it returns
# structured objects from WinGet's COM API, so the listing is locale-proof. The
# text path below scrapes `winget upgrade`, whose column header is localized to
# the Windows display language — on a non-English box the header match fails and
# the script silently reports "nothing to upgrade." The module path covers the
# default run; -IncludeUnknown still routes through the CLI text path, which maps
# winget's --include-unknown flag precisely (the module has no clean equivalent).
function Get-WingetUpgrades {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a collection of available upgrades; plural reads naturally for this internal helper.')]
    param([switch] $IncludeUnknown)

    # Single source-of-truth for the module check (Get-Module -ListAvailable scans
    # the module path, so don't run it twice) and log which path we took, so a run
    # on a localized box can be confirmed to be using the locale-proof module path.
    $moduleAvailable = [bool](Get-Module -ListAvailable -Name Microsoft.WinGet.Client)
    if (-not $IncludeUnknown -and $moduleAvailable) {
        try {
            $list = Get-WingetUpgradeObject
            $script:ListingChannel = 'WinGet module'
            Write-Log 'Listing source: Microsoft.WinGet.Client module (structured, locale-independent).'
            return $list
        }
        catch {
            # Keep only the first line so the WARN stays one CMTrace record. Split
            # on a regex (CRLF or bare LF) — .Split([Environment]::NewLine) binds
            # to the string-separator overload and silently leaves an LF-delimited
            # message untrimmed.
            $firstLine = ($_.Exception.Message -split '\r?\n', 2)[0]
            Write-Log ("WinGet module listing failed ({0}); falling back to console parsing." -f $firstLine) -Level WARN
        }
    }
    $why = if ($IncludeUnknown)      { '-IncludeUnknown requires the CLI flag' }
           elseif ($moduleAvailable) { 'module listing failed' }
           else                      { 'Microsoft.WinGet.Client not installed' }
    $script:ListingChannel = 'winget CLI'
    Write-Log "Listing source: winget console output ($why)."
    return Get-WingetUpgradeText -IncludeUnknown:$IncludeUnknown
}

# Structured listing via Microsoft.WinGet.Client (COM-backed, no console-text
# parsing — immune to the localized-header problem). Mapped to the same shape
# Get-WingetUpgradeText returns so the rest of the script never knows which path
# produced the list.
function Get-WingetUpgradeObject {
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop

    # `winget upgrade` (the text path) hides Pinning/Blocking-pinned packages by
    # default; Get-WinGetPackage exposes no pin state, so to keep the two paths
    # consistent we drop pinned IDs when the module offers a pin query. Current
    # module builds ship no Get-WinGetPin, making this a fail-safe no-op there (a
    # pinned-but-upgradable package may then appear; selecting a Blocking-pinned one
    # just fails its per-package upgrade, which winget refuses without --force). We
    # deliberately do NOT parse `winget pin list` console text — that would
    # reintroduce the localized-output fragility this module path exists to avoid.
    $pinnedIds = @()
    if (Get-Command Get-WinGetPin -ErrorAction Ignore) {
        try {
            $pinnedIds = @(Get-WinGetPin -ErrorAction Stop |
                ForEach-Object { if ($_.Id) { $_.Id } elseif ($_.PackageIdentifier) { $_.PackageIdentifier } })
        } catch {
            Write-Verbose "Get-WinGetPin failed; not filtering pinned packages: $($_.Exception.Message)"
        }
    }

    $pkgs = New-Object System.Collections.Generic.List[object]
    foreach ($p in (Get-WinGetPackage -ErrorAction Stop |
                    Where-Object { $_.IsUpdateAvailable -and $_.Id -notin $pinnedIds })) {
        $pkgs.Add([pscustomobject]@{
            Name      = $p.Name
            Id        = $p.Id
            Version   = $p.InstalledVersion
            Available = @($p.AvailableVersions)[0]   # newest first; blank-safe if absent
            Source    = $p.Source
        })
    }
    return $pkgs
}

# Fallback listing: parse `winget upgrade` console output. Used when the module
# isn't installed, when -IncludeUnknown is requested, or if the module path
# throws. Locale-fragile by nature (see the note above), which is exactly why the
# module path is preferred when available.
function Get-WingetUpgradeText {
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

# Bring in the Microsoft.WinGet.Client module when it would help and isn't already
# present. The module makes listing locale-proof (see Get-WingetUpgrades). Params
# are passed in (not read from script scope) so the decision is explicit and the
# function is unit-testable without touching the console or the real module.
#   -Install     : install without asking (the -InstallWinGetModule switch)
#   -Unattended  : -All or redirected stdin — suggest in the log, never prompt
#   -SkipModule  : -IncludeUnknown — the CLI text path is required, module won't help
function Initialize-WinGetModule {
    param([switch] $Install, [switch] $Unattended, [switch] $SkipModule)

    if ($SkipModule) { return }
    if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) { return }

    $doInstall = $false
    if ($Install) {
        $doInstall = $true
    }
    elseif (-not $Unattended) {
        Write-Host ''
        Write-Host '  The Microsoft.WinGet.Client module is not installed.' -ForegroundColor Yellow
        Write-Host '  It lets winup read upgrades from WinGet''s API instead of scraping console' -ForegroundColor DarkGray
        Write-Host '  text — more robust, and independent of your Windows display language.' -ForegroundColor DarkGray
        Write-Host '  Install it now? (CurrentUser scope, no admin needed) [y/N] ' -ForegroundColor Yellow -NoNewline
        $doInstall = ((Read-Host) -match '^(y|yes)$')
    }
    else {
        Write-Log 'Tip: Install-Module Microsoft.WinGet.Client gives winup locale-independent listing (or run: winup -InstallWinGetModule).'
        return
    }

    if (-not $doInstall) {
        Write-Log 'Microsoft.WinGet.Client install declined; using console-text listing.'
        return
    }

    try {
        Write-Host '  Installing Microsoft.WinGet.Client (CurrentUser)...' -ForegroundColor Cyan
        Install-Module -Name Microsoft.WinGet.Client -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
        Write-Log 'Installed Microsoft.WinGet.Client.' -Level OK
    }
    catch {
        $firstLine = ($_.Exception.Message -split '\r?\n', 2)[0]
        Write-Log ("Could not install Microsoft.WinGet.Client ({0}); using console-text listing." -f $firstLine) -Level WARN
    }
}

Initialize-WinGetModule -Install:$InstallWinGetModule `
    -Unattended:($All -or [Console]::IsInputRedirected) `
    -SkipModule:$IncludeUnknown

Write-Log 'Querying winget for available upgrades (this can take several seconds)...'
$packages = Get-WingetUpgrades -IncludeUnknown:$IncludeUnknown
if (-not $packages -or $packages.Count -eq 0) {
    Write-Log "Nothing to upgrade — you are up to date (checked via $script:ListingChannel)." -Level OK
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
    return Show-InteractiveSelector -Items $Packages -Title "Select packages to upgrade  ·  source: $script:ListingChannel"
}

$chosen = @(Select-Packages -Packages $packages)
if (-not $chosen -or $chosen.Count -eq 0) {
    Write-Log 'No packages selected. Exiting.' -Level INFO
    exit 0
}

# ---------- Partition: self-replacing packages run detached, last ----------
# Restart Manager closes any process holding a file the installer must replace.
# The only such file in a normal batch is this session's own host image — so a
# package that upgrades the running interpreter would kill this loop mid-batch
# (every package after it silently skipped, no summary written). We can't survive
# that in-process, so those IDs are split out and handed to a detached
# powershell.exe (Windows PowerShell — never the pwsh that's being replaced) once
# everything else is done. Add an ID here only if upgrading it replaces a file
# THIS session holds open; transient CLIs the prompt shells out to per render
# (oh-my-posh, node, git) are not candidates — a clash there is just a normal
# retryable "file in use" failure the loop already logs and steps past.
$selfReplacingIds = @('Microsoft.PowerShell', 'Microsoft.PowerShell.Preview')
$inProcess   = @($chosen | Where-Object { $_.Id -notin $selfReplacingIds })
$deferred    = @($chosen | Where-Object { $_.Id -in $selfReplacingIds })
$deferredIds = @($deferred.Id)

# ---------- Confirm ----------
Write-Host ''
Write-Host '  About to upgrade:' -ForegroundColor Cyan
Write-Host ("  (upgrade list obtained via {0})" -f $script:ListingChannel) -ForegroundColor DarkGray
foreach ($p in $chosen) {
    $isDeferred = $deferredIds -contains $p.Id
    $tail = if ($isDeferred) { '   (deferred — runs in a separate process)' } else { '' }
    Write-Host ("    - {0}  {1} -> {2}{3}" -f `
        (Format-Cell $p.Name 45),
        (Format-Cell $p.Version 14),
        (Format-Cell $p.Available 14),
        $tail) -ForegroundColor $(if ($isDeferred) { 'DarkYellow' } else { 'Gray' })
}
if ($deferred.Count -gt 0) {
    Write-Host ''
    Write-Host '  Note: upgrading the running PowerShell would terminate this session, so the' -ForegroundColor DarkYellow
    Write-Host '  package(s) marked above are handed to a detached process at the end.' -ForegroundColor DarkYellow
}
Write-Host ''
# -All promises a non-interactive run (scheduled tasks, the -Elevated relaunch),
# so it must not block on Read-Host — under -NonInteractive that throws, and in
# an unattended elevated window it would hang forever.
if ($All) {
    Write-Log 'Skipping confirmation (-All).' -Level INFO
} else {
    Write-Host '  Proceed? [Y/n] ' -ForegroundColor Yellow -NoNewline
    $confirm = Read-Host
    if ($confirm -and $confirm -notmatch '^(y|yes)$') {
        Write-Log 'User cancelled at confirmation.' -Level INFO
        exit 0
    }
}

# ---------- Upgrade (in-process batch) ----------
$results = @()
$idx = 0
foreach ($p in $inProcess) {
    $idx++
    Write-Host ''
    Write-Host ("  [{0}/{1}] Upgrading {2} ({3})" -f $idx, $inProcess.Count, $p.Name, $p.Id) -ForegroundColor Cyan
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

# ---------- Summary (in-process batch) ----------
if ($results.Count -gt 0) {
    Write-Host ''
    Write-Host '  Summary' -ForegroundColor Cyan
    Write-Host '  -------' -ForegroundColor Cyan
    $results | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }

    # Write each table row as its own CMTrace info line so the file stays valid format throughout.
    $results | Format-Table -AutoSize | Out-String -Stream |
        Where-Object { $_.Trim() } |
        ForEach-Object { Add-Content -Path $logFile -Value (Format-CMTraceLine -Message $_ -Type 1) -Encoding utf8 }
}

$failed = @($results | Where-Object { $_.Status -ne 'Success' })
if ($results.Count -gt 0) {
    $succeeded = $results.Count - $failed.Count
    if ($failed.Count -gt 0) {
        Write-Log ("Done. {0} succeeded, {1} failed. Log: {2}" -f $succeeded, $failed.Count, $logFile) -Level ERROR
    } else {
        # Word the all-succeeded summary without "failed"/"error"/etc. CMTrace red-
        # highlights any line containing those keywords regardless of the entry's
        # type, so a literal "0 failed" paints a clean (type=1) run as a red error
        # line. "N of N succeeded" carries the same information, no trigger words.
        Write-Log ("Done. {0} of {1} succeeded. Log: {2}" -f $succeeded, $results.Count, $logFile) -Level OK
    }
}

# ---------- Deferred self-replacing upgrades (detached, after we're done) ----------
# Run in-process these would close this very session. Hand them to a separate
# Windows PowerShell process — never the pwsh being replaced — then exit so
# Restart Manager finds nothing of ours holding the host files open. The child
# waits for us to exit, upgrades each package, and records the result to a side
# log in CMTrace format (any other pwsh windows you have open are still fair game
# for Restart Manager to close — that is inherent to upgrading PowerShell live).
if ($deferred.Count -gt 0) {
    $deferredLog = Join-Path $LogDirectory ("winget-upgrade-{0:yyyyMMdd-HHmmss}-deferred.log" -f (Get-Date))
    $wingetPath  = (Get-Command winget).Source

    $pkgLiterals = foreach ($p in $deferred) {
        "    [pscustomobject]@{{ Id = '{0}'; Name = '{1}'; Source = '{2}' }}" -f `
            ($p.Id -replace "'", "''"), ($p.Name -replace "'", "''"), (([string]$p.Source) -replace "'", "''")
    }

    # Child runs under Windows PowerShell 5.1 (always present, never the package
    # being upgraded), so keep this body 5.1-compatible. `$ stays literal for the
    # child; $( ) is expanded now to bake in the paths and package list.
    $childScript = @"
`$ErrorActionPreference = 'Stop'
`$sideLog    = '$($deferredLog -replace "'", "''")'
`$wingetPath = '$($wingetPath -replace "'", "''")'

function Format-CMTraceLine {
    param([string]`$Message, [int]`$Type = 1, [string]`$Component = 'WingetUpgrade')
    `$now    = Get-Date
    `$offset = [int][System.TimeZoneInfo]::Local.GetUtcOffset(`$now).TotalMinutes
    `$sign   = if (`$offset -ge 0) { '+' } else { '' }
    '<![LOG[{0}]LOG]!><time="{1}{2}{3}" date="{4}" component="{5}" context="" type="{6}" thread="{7}" file="">' -f `$Message, `$now.ToString('HH:mm:ss.fff', [cultureinfo]::InvariantCulture), `$sign, `$offset, `$now.ToString('MM-dd-yyyy', [cultureinfo]::InvariantCulture), `$Component, `$Type, `$PID
}
function Write-Side {
    param([string]`$Message, [int]`$Type = 1)
    Add-Content -LiteralPath `$sideLog -Value (Format-CMTraceLine -Message `$Message -Type `$Type) -Encoding utf8
}

# Let the parent session exit first so Restart Manager has no in-use copy of the
# host to close when the installer swaps the files.
Start-Sleep -Seconds 3
Write-Side 'Detached self-replacing upgrade pass started.'

`$pkgs = @(
$($pkgLiterals -join "`n")
)
`$fail = 0
foreach (`$p in `$pkgs) {
    Write-Side ("Upgrading {0} ({1}) [source={2}]" -f `$p.Name, `$p.Id, `$p.Source)
    `$a = @('upgrade','--id',`$p.Id,'--exact','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
    if (`$p.Source) { `$a += @('--source', `$p.Source) }
    & `$wingetPath @a *> `$null
    `$code = `$LASTEXITCODE
    if (`$code -eq 0) { Write-Side ("OK: {0}" -f `$p.Id) }
    else { Write-Side ("FAILED ({0}): {1}" -f `$code, `$p.Id) -Type 3; `$fail++ }
}
Write-Side ("Detached pass complete. {0} of {1} succeeded." -f (`$pkgs.Count - `$fail), `$pkgs.Count)
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) `
        -WindowStyle Hidden | Out-Null

    $names = $deferredIds -join ', '
    Write-Log ("Handed {0} self-replacing package(s) to a detached process: {1}" -f $deferred.Count, $names) -Level INFO
    Write-Log ("Detached upgrade log: {0}" -f $deferredLog) -Level INFO
    Write-Host ''
    Write-Host ("  Upgrading {0} in the background (would close this session if run here)." -f $names) -ForegroundColor Yellow
    Write-Host ("  Watch: {0}" -f $deferredLog) -ForegroundColor DarkGray
}

exit ([int]([bool]$failed.Count))
