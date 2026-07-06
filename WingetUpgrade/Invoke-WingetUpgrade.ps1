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

.PARAMETER Pin
    Anchor package(s): create a winget pin so the package stops being offered —
    by this script AND by plain `winget upgrade --all` outside it. Matches
    installed packages by name/id substring (resolved through the WinGet module
    when it's installed; otherwise winget resolves the query itself). Combine
    with -Version to gate instead of hide, -Blocking to refuse even explicit
    upgrades. The picker's P key pins the highlighted row the same way.

.PARAMETER Version
    With -Pin: create a gating pin instead of hiding the package. Upgrades
    within the gate keep being offered; a trailing '*' wildcards the last
    version part.

.PARAMETER Blocking
    With -Pin: block the package from upgrading even when named explicitly
    (`winget upgrade <id>`), until the pin is removed.

.PARAMETER Unpin
    Remove a pin created with -Pin or the picker's P key, by name/id substring.
    Falls back to letting winget resolve the query for pins created outside
    this script.

.PARAMETER Pins
    List pins: first the ones this script created (its local mirror), then
    winget's full pin store.

.EXAMPLE
    .\Invoke-WingetUpgrade.ps1
    Show the picker, choose packages, upgrade.

.EXAMPLE
    .\Invoke-WingetUpgrade.ps1 -All
    Upgrade everything non-interactively.

.EXAMPLE
    .\Invoke-WingetUpgrade.ps1 -Pin 'Assessment and Deployment' -Version '10.1.26100.*'
    Gate both ADK packages to the 26100 branch: fixes within the branch keep
    being offered, the arm64-only 28000 line is never offered.

.EXAMPLE
    .\Invoke-WingetUpgrade.ps1 -Unpin ADK
    Drop the ADK pins again.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'All', Justification = 'Read via $script:All inside Select-Packages (verified); the analyzer cannot trace the cross-scope reference.')]
param(
    [switch] $All,
    [switch] $IncludeUnknown,
    [switch] $InstallWinGetModule,
    [string] $LogDirectory,
    [string] $Pin,
    [string] $Version,
    [switch] $Blocking,
    [string] $Unpin,
    [switch] $Pins
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

# ---------- Pins (anchors) ----------
# winget's native pin store IS the anchoring mechanism: a pinned package is
# hidden from `winget upgrade` (the text listing path) and the pin also protects
# manual `winget upgrade --all` runs outside this script. -Pin/-Unpin/-Pins are
# the front door; the picker's P key pins in place.
#
# The mirror file exists because current Microsoft.WinGet.Client builds ship no
# Get-WinGetPin, so the module listing path cannot see winget's pin store at
# all. Every pin created HERE is therefore recorded locally, and
# Get-WingetUpgradeObject filters against the union of this mirror and
# Get-WinGetPin (for whenever a module version ships it). Pins created with raw
# `winget pin add` outside this script stay invisible to the module path until
# then — the text path hides them natively either way. `winget pin list` output
# is never parsed (localized text; see the note in Get-WingetUpgradeObject).
$script:PinMirrorFile = Join-Path $env:LOCALAPPDATA 'WingetUpgrade\pinned.json'

function Get-PinMirror {
    # Read the mirror. Missing/empty/corrupt file → empty list, never throws.
    if (-not (Test-Path -LiteralPath $script:PinMirrorFile)) { return @() }
    try {
        $raw = Get-Content -Raw -LiteralPath $script:PinMirrorFile -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log ("Couldn't read the pin mirror ({0}): {1}" -f $script:PinMirrorFile, $_.Exception.Message) -Level WARN
        return @()
    }
    @($data) | Where-Object { $_ -and $_.Id } | ForEach-Object {
        [pscustomobject]@{ Id = [string]$_.Id; Gate = [string]$_.Gate; Blocking = [bool]$_.Blocking }
    }
}

function Save-PinMirror {
    param([AllowEmptyCollection()][object[]] $Entry)
    $dir = Split-Path -Parent $script:PinMirrorFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $clean = @($Entry | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Gate = $_.Gate; Blocking = [bool]$_.Blocking } })
    $json  = if ($clean.Count -eq 0) { '[]' } else { $clean | ConvertTo-Json -Depth 3 -AsArray }
    Set-Content -LiteralPath $script:PinMirrorFile -Value $json -Encoding utf8
}

# One `winget pin add/remove` for a concrete ID, output suppressed — only the
# exit code matters, and pin output is localized console text that must not
# repaint over the picker when P is pressed mid-selection.
function Invoke-WingetPin {
    param(
        [Parameter(Mandatory)][ValidateSet('add', 'remove')][string] $Action,
        [Parameter(Mandatory)][string] $Id,
        [string] $Gate,
        [switch] $Blocking
    )
    $pinArgs = @('pin', $Action, '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ($Action -eq 'add' -and $Gate)     { $pinArgs += @('--version', $Gate) }
    if ($Action -eq 'add' -and $Blocking) { $pinArgs += '--blocking' }
    & winget @pinArgs *> $null
    return $LASTEXITCODE
}

function Add-WinupPin {
    param([Parameter(Mandatory)][string] $Match, [string] $Gate, [switch] $Blocking)

    # Resolve the match to concrete IDs through the module when it's installed
    # (structured, locale-proof). Without it, hand the query to winget itself —
    # its resolution is fine; we just can't learn the chosen ID for the mirror,
    # which is harmless because the mirror only feeds the module listing path
    # that is equally unavailable without the module.
    if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        $hits = @(Get-WinGetPackage -ErrorAction Stop |
            Where-Object { $_.Id -like "*$Match*" -or $_.Name -like "*$Match*" })
        if (-not $hits) {
            Write-Log ("No installed package matches '{0}'." -f $Match) -Level ERROR
            return 1
        }
        $kind = if ($Blocking) { ' (blocking)' } elseif ($Gate) { " (gate $Gate)" } else { '' }
        Write-Host ''
        Write-Host ("  About to pin{0}:" -f $kind) -ForegroundColor Cyan
        foreach ($h in $hits) { Write-Host ("    - {0}  ({1})" -f $h.Name, $h.Id) -ForegroundColor Gray }
        if ($hits.Count -gt 1 -and -not [Console]::IsInputRedirected) {
            Write-Host ("  Pin all {0}? [Y/n] " -f $hits.Count) -ForegroundColor Yellow -NoNewline
            # Read-Host throws under -NonInteractive; treat that as the default (Y),
            # same as pressing Enter — the prompt's default is to proceed.
            $answer = try { Read-Host } catch { '' }
            if ($answer -match '^(n|no)$') { Write-Log 'Pin cancelled at confirmation.'; return 0 }
        }
        $mirror = @(Get-PinMirror)
        $fail = 0
        foreach ($h in $hits) {
            $exit = Invoke-WingetPin -Action add -Id $h.Id -Gate $Gate -Blocking:$Blocking
            if ($exit -eq 0) {
                # Upsert so re-pinning with a new gate replaces the old entry.
                $mirror  = @($mirror | Where-Object { $_.Id -ne $h.Id })
                $mirror += [pscustomobject]@{ Id = $h.Id; Gate = $Gate; Blocking = [bool]$Blocking }
                Write-Log ("Pinned {0}{1} — no longer offered for upgrade." -f $h.Id, $kind) -Level OK
            } else {
                Write-Log ("winget pin add failed for {0} (exit {1}). Already pinned? Check: winget pin list" -f $h.Id, $exit) -Level ERROR
                $fail++
            }
        }
        Save-PinMirror -Entry $mirror
        return ([int][bool]$fail)
    }

    # No module: let winget resolve the query itself and show its output
    # (Out-Host so the text displays without becoming this function's return value).
    $pinArgs = @('pin', 'add', '--query', $Match, '--accept-source-agreements', '--disable-interactivity')
    if ($Gate)     { $pinArgs += @('--version', $Gate) }
    if ($Blocking) { $pinArgs += '--blocking' }
    & winget @pinArgs | Out-Host
    if ($LASTEXITCODE -eq 0) { Write-Log ("Pinned '{0}' (resolved by winget)." -f $Match) -Level OK; return 0 }
    Write-Log ("winget pin add failed for '{0}' (exit {1})." -f $Match, $LASTEXITCODE) -Level ERROR
    return 1
}

function Remove-WinupPin {
    param([Parameter(Mandatory)][string] $Match)

    $mirror = @(Get-PinMirror)
    $hits   = @($mirror | Where-Object { $_.Id -like "*$Match*" })
    if ($hits) {
        foreach ($h in $hits) {
            $exit = Invoke-WingetPin -Action remove -Id $h.Id
            # Drop the mirror entry regardless: a nonzero exit here usually means
            # the pin was already removed with raw `winget pin remove`, and a
            # stale mirror entry would keep hiding the package from the module
            # listing forever.
            $mirror = @($mirror | Where-Object { $_.Id -ne $h.Id })
            if ($exit -eq 0) { Write-Log ("Unpinned {0} — it will be offered again." -f $h.Id) -Level OK }
            else { Write-Log ("winget reported no pin for {0} (exit {1}); cleared it from the mirror." -f $h.Id, $exit) -Level WARN }
        }
        Save-PinMirror -Entry $mirror
        return 0
    }

    # Not in the mirror — maybe pinned outside this script. Let winget resolve it.
    & winget pin remove --query $Match --accept-source-agreements --disable-interactivity | Out-Host
    if ($LASTEXITCODE -eq 0) { Write-Log ("Unpinned '{0}' (was not in the mirror)." -f $Match) -Level OK; return 0 }
    Write-Log ("No pin matching '{0}' found by winup or winget (exit {1})." -f $Match, $LASTEXITCODE) -Level ERROR
    return 1
}

function Show-WinupPin {
    $mirror = @(Get-PinMirror)
    Write-Host ''
    if ($mirror.Count -gt 0) {
        Write-Host '  Pins created by winup (mirrored for the module listing):' -ForegroundColor Cyan
        foreach ($m in $mirror) {
            $kind = if ($m.Blocking) { 'blocking' } elseif ($m.Gate) { "gate $($m.Gate)" } else { 'pin' }
            Write-Host ("    - {0}  [{1}]" -f $m.Id, $kind) -ForegroundColor Gray
        }
    } else {
        Write-Host '  No pins created by winup.  (Anchor one with: winup -Pin <name>, or P in the picker.)' -ForegroundColor DarkGray
    }
    # winget's full pin store (also covers pins added outside winup). Display-only
    # passthrough — never parsed, so localized output is fine here.
    Write-Host ''
    Write-Host '  winget pin list:' -ForegroundColor Cyan
    & winget pin list --accept-source-agreements --disable-interactivity | ForEach-Object { Write-Host "  $_" }
}

# Pin verbs run and exit before any upgrade listing happens.
if (($Version -or $Blocking) -and -not $Pin) {
    Write-Log '-Version and -Blocking only apply together with -Pin.' -Level ERROR
    exit 2
}
if ($Pins)  { Show-WinupPin; exit 0 }
if ($Unpin) { exit (Remove-WinupPin -Match $Unpin) }
if ($Pin)   { exit (Add-WinupPin -Match $Pin -Gate $Version -Blocking:$Blocking) }

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

    # winup's own pin mirror closes that gap for pins created here (-Pin or the
    # picker's P key): plain and blocking pins hide the package outright; a
    # gated pin hides only offers OUTSIDE the gate — the newest in-gate version
    # is still offered, matching winget's own gating semantics on the text path.
    $mirror     = @(Get-PinMirror)
    $hideAlways = @($pinnedIds) + @($mirror | Where-Object { -not $_.Gate } | ForEach-Object Id)
    $gate       = @{}
    foreach ($m in $mirror) { if ($m.Gate) { $gate[$m.Id] = $m.Gate } }

    $pkgs = New-Object System.Collections.Generic.List[object]
    foreach ($p in (Get-WinGetPackage -ErrorAction Stop |
                    Where-Object { $_.IsUpdateAvailable -and $_.Id -notin $hideAlways })) {
        $available = @($p.AvailableVersions)[0]   # newest first; blank-safe if absent
        if ($gate.ContainsKey($p.Id)) {
            $available = @($p.AvailableVersions) | Where-Object { $_ -like $gate[$p.Id] } | Select-Object -First 1
            if (-not $available -or $available -eq $p.InstalledVersion) { continue }   # nothing new within the gate
        }
        $pkgs.Add([pscustomobject]@{
            Name      = $p.Name
            Id        = $p.Id
            Version   = $p.InstalledVersion
            Available = $available
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
        # Couldn't locate the (English) header. On an English system this just means
        # nothing is pending; on a language winget localizes its output into, it
        # means we failed to parse a list that may well be non-empty. Flag it so the
        # caller doesn't report a false "up to date" — see Test-WingetLocalizedCulture.
        $script:ListingParseFailed = $true
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

# True when the current (or given) UI culture is one winget actually ships a
# translation for. winget localizes its console output — including the upgrade-table
# header the text path keys off — for exactly these languages (folders under
# microsoft/winget-cli Localization/Resources): de, es, fr, it, ja, ko, ru, zh
# (both zh-CN and zh-TW), and pt-BR (Brazil only, NOT pt-PT). On any of them the
# English-only text parser can't read the header, so an empty text-path result there
# means "couldn't parse", not "up to date". en-* and untranslated languages
# (Norwegian, Danish, Dutch, Polish, ...) get English winget output, so the text
# path is reliable and this returns $false.
function Test-WingetLocalizedCulture {
    param([string] $Culture = (Get-UICulture).Name)
    if ($Culture -eq 'pt-BR') { return $true }                       # pt-BR only; pt-PT falls through
    return (($Culture -split '-')[0] -in @('de','es','fr','it','ja','ko','ru','zh'))
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

$script:ListingParseFailed = $false
Write-Log 'Querying winget for available upgrades (this can take several seconds)...'
$packages = Get-WingetUpgrades -IncludeUnknown:$IncludeUnknown
if (-not $packages -or $packages.Count -eq 0) {
    # Distinguish "genuinely up to date" from "couldn't read winget's output." When
    # the text path failed to find the header AND we're on a display language winget
    # localizes, an empty result almost certainly means we couldn't parse the list —
    # not that nothing is pending. Don't hand back a clean bill of health we can't
    # vouch for; point at the locale-proof module instead. (A localized box with
    # genuinely nothing pending also lands here — hence the honest "couldn't tell"
    # wording rather than a false "up to date.")
    if ($script:ListingParseFailed -and (Test-WingetLocalizedCulture)) {
        $uiName = (Get-UICulture).Name
        Write-Log ("Could not read winget's upgrade list. Your display language ($uiName) is one winget localizes its output into, and winup's text parser only reads winget's English header — so it cannot tell whether upgrades are pending. Install the locale-independent module: winup -InstallWinGetModule") -Level WARN
        Write-Host ''
        Write-Host "  Couldn't reliably read upgrades on a localized Windows ($uiName)." -ForegroundColor Yellow
        Write-Host '  Fix: winup -InstallWinGetModule   (one-time, CurrentUser, no admin)' -ForegroundColor Yellow
        exit 1
    }
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
    $emptied   = $false
    $notice    = ''

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
            $hint = '  Up/Down move  Space toggle  A toggle-all  P pin (never offer again)  Enter confirm  Esc cancel'
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
            # The footer line doubles as the P-key feedback slot: a pin action's
            # result shows here for one keypress, then the scroll info returns.
            $footer      = if ($notice) { "  $notice" } else { $scrollInfo }
            $footerColor = if ($notice) { 'Yellow' } else { 'DarkGray' }
            if ($footer.Length -ge [Console]::WindowWidth) { $footer = $footer.Substring(0, [Console]::WindowWidth - 1) }
            Write-Host $footer.PadRight([Math]::Max(0, [Console]::WindowWidth - 1)) -ForegroundColor $footerColor

            $key = [Console]::ReadKey($true)
            $notice = ''
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
                    elseif ($c -eq 'p') {
                        # Anchor the highlighted package: winget pin (native store,
                        # so plain `winget upgrade --all` skips it too) + the mirror
                        # (so the module listing skips it), then drop the row.
                        # Invoke-WingetPin suppresses winget's output — anything it
                        # printed would repaint over this UI.
                        $item = $Items[$cursor]
                        $exit = Invoke-WingetPin -Action add -Id $item.Id
                        if ($exit -eq 0) {
                            $mirror  = @(Get-PinMirror | Where-Object { $_.Id -ne $item.Id })
                            $mirror += [pscustomobject]@{ Id = $item.Id; Gate = ''; Blocking = $false }
                            Save-PinMirror -Entry $mirror
                            $script:PinnedInPicker += , $item
                            $keep     = @(0..($Items.Count - 1) | Where-Object { $_ -ne $cursor })
                            $Items    = @($Items[$keep])
                            $rows     = @($rows[$keep])
                            $selected = @($selected[$keep])
                            if ($Items.Count -eq 0) { $emptied = $true }
                            elseif ($cursor -ge $Items.Count) { $cursor = $Items.Count - 1 }
                            $notice = "Pinned $($item.Name) — never offered again  (undo: winup -Unpin $($item.Id))"
                            Clear-Host   # the list shrank; full repaint so no stale bottom row lingers
                        } else {
                            $notice = "Pin failed for $($item.Name) (winget exit $exit)"
                        }
                    }
                }
            }
            if ($emptied) { break }
            if ($key.Key -eq 'Enter' -or $key.Key -eq 'Escape' -or [char]::ToLower($key.KeyChar) -eq 'q') { break }
        }
    }
    finally {
        [Console]::CursorVisible = $true
        Clear-Host
    }

    if ($cancelled -or $emptied) { return @() }
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

# Pins made with the P key are collected here and logged after the picker exits
# — Write-Log prints to the console, which would repaint over the selector UI.
$script:PinnedInPicker = @()
$chosen = @(Select-Packages -Packages $packages)
foreach ($p in $script:PinnedInPicker) {
    Write-Log ("Pinned from picker: {0} ({1}) — never offered again. Undo: winup -Unpin {1}" -f $p.Name, $p.Id) -Level OK
}
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
