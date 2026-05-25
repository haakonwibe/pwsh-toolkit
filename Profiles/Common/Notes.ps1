# Daily markdown journal
# ============================================================================
# `note "thing"`        - append a timestamped bullet to today's note file
# `note`                - open today's note in the default app (Obsidian-friendly)
# `today`               - alias for `note` — same call surface; semantically a
#                         shortcut for "open today's notes"
# `Find-Note "query"`   - grep across all .md files in NotesRoot
# `Set-NotesRoot`       - interactive picker over auto-detected candidates
#                         (Obsidian vaults, OneDrive Documents, local Documents)
#
# Storage: $script:Config.NotesRoot. When unset in config.psd1, resolved via
# the cascade in Resolve-NotesRoot below — prefers an Obsidian vault inside
# OneDrive (best sync story) over a local-only vault. Run Set-NotesRoot to
# override interactively and get a config.psd1 snippet to make it permanent.
#
# Format of YYYY-MM-DD.md (auto-created on first write):
#
#   # 2026-05-25
#
#   - **09:13** — Met with Karen re: registry policy rollout
#   - **11:42** — Fixed the rps TrustedHosts message
#   - **15:08** — Coffee with Magnus

function Get-ObsidianVault {
    # Returns the list of Obsidian vaults registered in %APPDATA%\obsidian\obsidian.json,
    # filtered to existing paths. Each item: { Path; IsOpen; Ts }.
    # Returns @() if obsidian.json is missing or unparseable.
    $configPath = Join-Path $env:APPDATA 'obsidian\obsidian.json'
    if (-not (Test-Path -LiteralPath $configPath)) { return @() }

    try {
        $raw = Get-Content -Raw -LiteralPath $configPath -ErrorAction Stop
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { return @() }

    $vaults = @()
    foreach ($prop in $cfg.vaults.PSObject.Properties) {
        $vaultPath = $prop.Value.path
        if ($vaultPath -and (Test-Path -LiteralPath $vaultPath)) {
            $vaults += [pscustomobject]@{
                Path   = $vaultPath
                IsOpen = [bool]$prop.Value.open
                Ts     = if ($prop.Value.ts) { [long]$prop.Value.ts } else { 0 }
            }
        }
    }
    return ,$vaults
}

function Resolve-NotesRoot {
    # Cascade for picking a sensible default NotesRoot, in order of preference:
    #
    #   1. Obsidian vault that lives inside $env:OneDriveCommercial
    #      (best of both worlds: Obsidian indexing + OneDrive sync)
    #   2. Any Obsidian vault flagged "open" in obsidian.json
    #   3. <$env:OneDriveCommercial>\Documents\Notes
    #   4. Most-recently-touched Obsidian vault (regardless of location)
    #   5. <$env:OneDriveConsumer>\Documents\Notes (personal OneDrive)
    #   6. <$env:USERPROFILE>\Documents\Notes (local-only fallback)
    #
    # Obsidian-vault results return <vault>\Daily — the daily-notes plugin's
    # convention — so notes live inside the vault but don't clutter the root.

    $vaults = Get-ObsidianVault

    # 1. Obsidian vault inside OneDrive Business
    if ($env:OneDriveCommercial -and $vaults.Count -gt 0) {
        $insideOneDrive = $vaults |
            Where-Object { $_.Path -like "$env:OneDriveCommercial*" } |
            Sort-Object Ts -Descending |
            Select-Object -First 1
        if ($insideOneDrive) { return (Join-Path $insideOneDrive.Path 'Daily') }
    }

    # 2. Any "open" Obsidian vault
    $openVault = $vaults | Where-Object { $_.IsOpen } | Select-Object -First 1
    if ($openVault) { return (Join-Path $openVault.Path 'Daily') }

    # 3. OneDrive Business Documents
    if ($env:OneDriveCommercial -and (Test-Path -LiteralPath $env:OneDriveCommercial)) {
        return (Join-Path $env:OneDriveCommercial 'Documents\Notes')
    }

    # 4. Most-recent Obsidian vault
    $recent = $vaults | Sort-Object Ts -Descending | Select-Object -First 1
    if ($recent) { return (Join-Path $recent.Path 'Daily') }

    # 5. Personal OneDrive Documents
    if ($env:OneDriveConsumer -and (Test-Path -LiteralPath $env:OneDriveConsumer)) {
        return (Join-Path $env:OneDriveConsumer 'Documents\Notes')
    }

    # 6. Local Documents fallback
    return (Join-Path $env:USERPROFILE 'Documents\Notes')
}

function Set-NotesRoot {
    [CmdletBinding()]
    param()

    # Gather candidates from same sources as Resolve-NotesRoot, but show
    # them all instead of picking the first match. User picks; we update
    # $script:Config.NotesRoot for the session and print the snippet to
    # paste into config.psd1 for persistence (avoids data-file roundtrip).

    $candidates = New-Object 'System.Collections.Generic.List[pscustomobject]'

    foreach ($v in (Get-ObsidianVault)) {
        $tags = @()
        if ($v.IsOpen) { $tags += 'open' }
        if ($env:OneDriveCommercial -and $v.Path -like "$env:OneDriveCommercial*") { $tags += 'OneDrive' }
        $suffix = if ($tags) { "  ($($tags -join ', '))" } else { '' }
        $candidates.Add([pscustomobject]@{
            Label = "Obsidian: $(Split-Path -Leaf $v.Path)$suffix"
            Path  = Join-Path $v.Path 'Daily'
        })
    }

    if ($env:OneDriveCommercial -and (Test-Path -LiteralPath $env:OneDriveCommercial)) {
        $candidates.Add([pscustomobject]@{
            Label = "OneDrive Business: Documents\Notes"
            Path  = Join-Path $env:OneDriveCommercial 'Documents\Notes'
        })
    }
    if ($env:OneDriveConsumer -and (Test-Path -LiteralPath $env:OneDriveConsumer)) {
        $candidates.Add([pscustomobject]@{
            Label = "OneDrive Personal: Documents\Notes"
            Path  = Join-Path $env:OneDriveConsumer 'Documents\Notes'
        })
    }
    $candidates.Add([pscustomobject]@{
        Label = "Local Documents\Notes"
        Path  = Join-Path $env:USERPROFILE 'Documents\Notes'
    })

    if ($candidates.Count -eq 0) {
        Write-Host '  No candidate locations found.' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host '  Choose a NotesRoot:' -ForegroundColor Cyan
    Write-Host "  Current: $($script:Config.NotesRoot)" -ForegroundColor DarkGray
    Write-Host ''
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ('    {0,2}. {1}' -f ($i + 1), $candidates[$i].Label)
        Write-Host ('        {0}' -f $candidates[$i].Path) -ForegroundColor DarkGray
    }
    Write-Host ''
    $response = Read-Host '  Choice (number, blank to cancel)'
    if (-not $response) { Write-Host '  Cancelled.' -ForegroundColor DarkGray; return }

    [int]$idx = 0
    if (-not [int]::TryParse($response, [ref] $idx)) {
        Write-Host "  '$response' is not a number." -ForegroundColor Yellow
        return
    }
    if ($idx -lt 1 -or $idx -gt $candidates.Count) {
        Write-Host "  Out of range (expected 1-$($candidates.Count))." -ForegroundColor Yellow
        return
    }

    $chosen = $candidates[$idx - 1]
    $script:Config.NotesRoot = $chosen.Path
    Write-Host ''
    Write-Host "  ✓ NotesRoot set for this session: $($chosen.Path)" -ForegroundColor Green
    Write-Host ''
    Write-Host '  To persist across new shells, add to Profiles/config.psd1:' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "      NotesRoot = '$($chosen.Path)'" -ForegroundColor White
    Write-Host ''
}

function note {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]] $Text
    )

    $notesRoot = $script:Config.NotesRoot
    if (-not $notesRoot) {
        Write-Host '  NotesRoot not configured. Set in Profiles/config.psd1:' -ForegroundColor Yellow
        Write-Host "      NotesRoot = '$env:USERPROFILE\Documents\Notes'" -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path -LiteralPath $notesRoot)) {
        New-Item -ItemType Directory -Path $notesRoot -Force | Out-Null
    }

    $today    = Get-Date -Format 'yyyy-MM-dd'
    $notePath = Join-Path $notesRoot "$today.md"

    # Create the file with a daily header on first touch.
    if (-not (Test-Path -LiteralPath $notePath)) {
        Set-Content -LiteralPath $notePath -Value "# $today`n`n" -Encoding utf8
    }

    if (-not $Text -or $Text.Count -eq 0) {
        # No-args: open today's note in whatever app handles .md.
        # On a typical Obsidian setup with .md → Obsidian, this jumps right
        # into the vault. Falls back to VS Code / Notepad via Windows shell.
        Invoke-Item -LiteralPath $notePath
        return
    }

    $line      = $Text -join ' '
    $timestamp = Get-Date -Format 'HH:mm'
    Add-Content -LiteralPath $notePath -Value "- **$timestamp** — $line" -Encoding utf8
    Write-Host "  + $today.md  ($timestamp)" -ForegroundColor DarkGray
}

Set-Alias today note

# Resolve NotesRoot if unset at this point. Runs once at Notes.ps1 load time
# (after the loader's hard-fallback block, which leaves NotesRoot as $null
# when neither config.psd1 nor config.example.psd1 set it).
if (-not $script:Config.NotesRoot) {
    $script:Config.NotesRoot = Resolve-NotesRoot
}

function Find-Note {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Query)

    $notesRoot = $script:Config.NotesRoot
    if (-not $notesRoot -or -not (Test-Path -LiteralPath $notesRoot)) {
        Write-Host '  No notes folder at $script:Config.NotesRoot — nothing to search.' -ForegroundColor Yellow
        return
    }

    # Select-String over the markdown files. Returns filename + line number +
    # matching line so you can quickly jump to the right note + spot.
    Select-String -Path (Join-Path $notesRoot '*.md') -Pattern $Query -ErrorAction Ignore |
        Select-Object @{ N = 'Note';     E = { Split-Path -Leaf $_.Path } },
                      @{ N = 'Line';     E = { $_.LineNumber } },
                      @{ N = 'Matched';  E = { $_.Line.Trim() } } |
        Format-Table -AutoSize
}
