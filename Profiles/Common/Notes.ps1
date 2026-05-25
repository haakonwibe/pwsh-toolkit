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
    # Cascade for picking a sensible default NotesRoot:
    #
    #   1. Obsidian vault flagged "open" in obsidian.json → <vault>\Daily
    #   2. Most-recently-touched Obsidian vault → <vault>\Daily
    #   3. OneDrive (Commercial preferred, then Consumer) → Documents\Notes
    #   4. Local <$env:USERPROFILE>\Documents\Notes
    #
    # Philosophy: respect Obsidian-as-source-of-truth. If a user has Obsidian
    # configured with a vault open, that's where they're working — whether
    # the vault is local or in OneDrive is their choice in Obsidian, NOT
    # something the cascade should second-guess. Many Obsidian users
    # deliberately keep vaults local; quietly steering their notes into
    # OneDrive would be exactly wrong. Sync via OneDrive is the fallback
    # for users who don't have Obsidian configured at all.
    #
    # Get-ObsidianVault already filters out vaults whose paths no longer
    # exist on disk, so a stale "open" entry falls through to step 2.
    # The 'Daily' subfolder mirrors Obsidian's daily-notes plugin convention
    # so notes land inside the vault without cluttering its root.

    $vaults = Get-ObsidianVault

    # 1. Obsidian "open" vault
    $openVault = $vaults | Where-Object { $_.IsOpen } | Select-Object -First 1
    if ($openVault) { return (Join-Path $openVault.Path 'Daily') }

    # 2. Most-recently-touched Obsidian vault
    $recent = $vaults | Sort-Object Ts -Descending | Select-Object -First 1
    if ($recent) { return (Join-Path $recent.Path 'Daily') }

    # 3. OneDrive (Commercial preferred for work setups, then Consumer)
    if ($env:OneDriveCommercial -and (Test-Path -LiteralPath $env:OneDriveCommercial)) {
        return (Join-Path $env:OneDriveCommercial 'Documents\Notes')
    }
    if ($env:OneDriveConsumer -and (Test-Path -LiteralPath $env:OneDriveConsumer)) {
        return (Join-Path $env:OneDriveConsumer 'Documents\Notes')
    }

    # 4. Local Documents fallback
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
        # No-args: open today's note via the OS shell association.
        # Works with whatever .md handler the user has set (Obsidian, Typora,
        # VS Code, etc.).
        #
        # Why the explicit ProcessStartInfo + UseShellExecute dance instead
        # of Invoke-Item or Start-Process: Electron-based editors (Typora,
        # Obsidian, VS Code) write Chromium-style log messages to stderr on
        # launch — "Failed to append Jump List category", GPU cache warnings,
        # etc. — and BOTH Invoke-Item and Start-Process leave console handles
        # inherited by the spawned process, so those writes spill into the
        # parent shell at random intervals (before AND after the prompt
        # returns). ProcessStartInfo with UseShellExecute = $true routes
        # through the Win32 ShellExecuteEx API — the same code path File
        # Explorer uses on double-click — which provably does not pass
        # console handles to the spawned process. Chromium's stderr writes
        # then go to NUL, the shell stays clean.
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName        = $notePath
            $psi.UseShellExecute = $true
            [void][System.Diagnostics.Process]::Start($psi)
        }
        catch {
            Write-Host "  Couldn't open $notePath via shell: $($_.Exception.Message)" -ForegroundColor Yellow
        }
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
