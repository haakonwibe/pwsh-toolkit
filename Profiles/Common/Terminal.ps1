# Windows Terminal helpers: read and set the font face.
# ============================================================================
# `Get-TerminalFont`        - report the font Windows Terminal uses (PowerShell
#                             profile's override if set, else the default).
# `Set-TerminalFont <name>` - change the font face in settings.json.
#
# settings.json is JSON-with-comments and Windows Terminal owns its formatting,
# so Set-TerminalFont does a targeted, value-only text edit (it replaces just the
# "face": "..." value, leaving the rest of the file byte-for-byte) rather than a
# parse-and-rewrite that would reflow the whole thing. It backs the file up and
# validates the result still parses before saving.

function Get-TerminalSettingsPath {
    <#
    .SYNOPSIS
        Path to the active Windows Terminal settings.json, or $null if not found.
    #>
    [OutputType([string])]
    param()
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json')
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Update-FontFaceText {
    <#
    .SYNOPSIS
        Return the settings.json text with the first font "face" value replaced.
    .DESCRIPTION
        Pure string transform: swaps the value of the first `"face": "..."` it
        finds, preserving everything else exactly. A MatchEvaluator is used so the
        new font name is inserted literally (no regex-substitution surprises if a
        name ever contained a `$`). Pulled out so the edit logic is unit-testable
        without touching a real settings.json.
    #>
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Font', Justification = 'Used inside the MatchEvaluator scriptblock closure below; the analyzer cannot trace the capture.')]
    param(
        [Parameter(Mandatory)][string] $Json,
        [Parameter(Mandatory)][string] $Font
    )
    $rx = [regex] '("face"\s*:\s*")[^"]*(")'
    $rx.Replace($Json, { param($m) $m.Groups[1].Value + $Font + $m.Groups[2].Value }, 1)
}

function Get-TerminalFont {
    <#
    .SYNOPSIS
        Show the font face Windows Terminal is using.
    .DESCRIPTION
        Reads settings.json and returns the effective font for the PowerShell
        profile — its own font.face override if it has one, otherwise the
        profiles.defaults font. Run with -Verbose to see the default vs.
        per-profile breakdown.
    .EXAMPLE
        Get-TerminalFont

        Prints the active font, e.g. 'MesloLGMDZ Nerd Font Mono'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $path = Get-TerminalSettingsPath
    if (-not $path) { Write-Host '  Windows Terminal settings.json not found.' -ForegroundColor Yellow; return }
    try { $json = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Host "  Couldn't parse settings.json: $($_.Exception.Message)" -ForegroundColor Yellow; return }

    $defFace = $json.profiles.defaults.font.face
    $ps = $json.profiles.list | Where-Object {
        $_.source -eq 'Windows.Terminal.PowershellCore' -or $_.name -eq 'PowerShell' -or $_.commandline -match 'pwsh'
    } | Select-Object -First 1
    $psFace = $ps.font.face

    Write-Verbose "Default font.face: $(if ($defFace) { $defFace } else { '(none)' })"
    Write-Verbose "PowerShell profile font.face: $(if ($psFace) { $psFace } else { '(none — inherits default)' })"

    $effective = if ($psFace) { $psFace } elseif ($defFace) { $defFace } else { $null }
    if (-not $effective) {
        Write-Host '  No explicit font set — Windows Terminal is using its built-in default.' -ForegroundColor DarkGray
        return
    }
    $effective
}

function Set-TerminalFont {
    <#
    .SYNOPSIS
        Change the Windows Terminal font face.
    .DESCRIPTION
        Updates the single font.face value in settings.json with a targeted,
        value-only edit (the rest of the file is left untouched), backs the file
        up to settings.json.bak first, and validates the result is still valid
        JSON before saving. Windows Terminal reloads settings.json automatically,
        so open tabs re-render. Supports -WhatIf.

        Limited to the common one-font case: if settings.json has no font.face
        yet, set one once via the Terminal UI; if it has several (per-profile
        overrides), edit it by hand so the target is unambiguous.
    .PARAMETER Name
        The font face to set, e.g. 'MesloLGM Nerd Font'.
    .EXAMPLE
        Set-TerminalFont 'MesloLGM Nerd Font'

        Switches the terminal font, backing up settings.json first.
    .EXAMPLE
        Set-TerminalFont 'Cascadia Code' -WhatIf

        Shows what would change without writing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory, Position = 0)][string] $Name)

    $path = Get-TerminalSettingsPath
    if (-not $path) { Write-Host '  Windows Terminal settings.json not found.' -ForegroundColor Yellow; return }
    $raw = Get-Content -Raw -LiteralPath $path

    $faceCount = ([regex]::Matches($raw, '"face"\s*:')).Count
    if ($faceCount -eq 0) {
        Write-Host '  No font is set in settings.json yet. Set one once via Windows Terminal' -ForegroundColor Yellow
        Write-Host '  (Settings -> your profile -> Appearance -> Font face), then this can update it.' -ForegroundColor DarkGray
        return
    }
    if ($faceCount -gt 1) {
        Write-Host "  settings.json has $faceCount font.face entries — can't tell which to change safely." -ForegroundColor Yellow
        Write-Host '  Edit it by hand so just one remains, then re-run.' -ForegroundColor DarkGray
        return
    }

    $current = [regex]::Match($raw, '"face"\s*:\s*"([^"]*)"').Groups[1].Value
    if ($current -eq $Name) {
        Write-Host "  Font is already '$Name'." -ForegroundColor DarkGray
        return
    }

    $new = Update-FontFaceText -Json $raw -Font $Name
    try { $null = $new | ConvertFrom-Json -ErrorAction Stop }
    catch {
        Write-Host '  Aborting — the edit would produce invalid JSON. settings.json left unchanged.' -ForegroundColor Red
        return
    }

    if ($PSCmdlet.ShouldProcess($path, "Set font face '$current' -> '$Name'")) {
        Copy-Item -LiteralPath $path -Destination "$path.bak" -Force
        Set-Content -LiteralPath $path -Value $new -Encoding utf8 -NoNewline
        Write-Host "  Font: '$current' -> '$Name'   (backup: settings.json.bak)" -ForegroundColor Green
        Write-Host '  Windows Terminal reloads automatically — open tabs should re-render.' -ForegroundColor DarkGray
    }
}
