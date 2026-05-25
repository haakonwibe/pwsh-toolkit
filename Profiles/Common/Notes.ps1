# Daily markdown journal
# ============================================================================
# `note "thing"`        - append a timestamped bullet to today's note file
# `note`                - open today's note in the default app (Obsidian-friendly)
# `today`               - alias for `note` — same call surface; semantically a
#                         shortcut for "open today's notes"
# `Find-Note "query"`   - grep across all .md files in NotesRoot
#
# Storage: $script:Config.NotesRoot, default ~\Documents\Notes (auto-created).
# Point NotesRoot at an Obsidian vault subfolder to write directly into it —
# Obsidian picks the file up as soon as it lands on disk.
#
# Format of YYYY-MM-DD.md (auto-created on first write):
#
#   # 2026-05-25
#
#   - **09:13** — Met with Karen re: registry policy rollout
#   - **11:42** — Fixed the rps TrustedHosts message
#   - **15:08** — Coffee with Magnus

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
