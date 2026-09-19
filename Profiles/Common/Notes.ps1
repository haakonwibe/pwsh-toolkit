# Daily markdown journal
# ============================================================================
# `note "thing"`        - append a timestamped bullet to today's note file
# `note`                - print today's note in the terminal
# `note -Edit`          - open today's note in the default .md app (Obsidian-friendly)
# `today`               - alias for `note` — same call surface; semantically a
#                         shortcut for "show today's notes"
# `notes [query]`       - picker over every daily note (or the days mentioning
#                         query); Enter prints the chosen day
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
    <#
    .SYNOPSIS
        Interactively choose where daily notes are stored.
    .DESCRIPTION
        Lists auto-detected candidate locations (Obsidian vaults, OneDrive
        Documents, local Documents), sets the chosen one as NotesRoot for the
        session, and prints the config.psd1 snippet to make it permanent.
    .EXAMPLE
        Set-NotesRoot

        Lists the detected candidate folders (Obsidian vaults, OneDrive
        Documents, local Documents), lets you pick one by number, applies it for
        this session, and prints the line to paste into config.psd1 to keep it.
    #>
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

function Get-NoteFile {
    <#
    .SYNOPSIS
        The daily note files in NotesRoot, newest first.
    .DESCRIPTION
        Only YYYY-MM-DD.md names count: NotesRoot is usually an Obsidian vault's
        Daily folder, which can hold other notes that aren't journal days.
        Returns nothing when the folder doesn't exist.
    #>
    [OutputType([System.IO.FileInfo])]
    param([string] $Root = $script:Config.NotesRoot)

    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return }
    Get-ChildItem -LiteralPath $Root -Filter '*.md' -File -ErrorAction Ignore |
        Where-Object Name -Match '^\d{4}-\d{2}-\d{2}\.md$' |
        Sort-Object Name -Descending
}

function ConvertTo-NotePlainLine {
    <#
    .SYNOPSIS
        One note line as plain text for a picker row.
    .DESCRIPTION
        "- **09:13** — Met with Karen" -> "09:13  Met with Karen". Lines written
        by hand in Obsidian go through the same path, so a bullet, a heading or
        a stray **bold** reads as its text rather than its markup.
    #>
    [OutputType([string])]
    param([string] $Line)

    $t = $Line.Trim() -replace '^(#+|[-*+])\s+', ''
    $t = $t -replace '^\*\*(\d{1,2}:\d{2})\*\*\s*[—–-]\s*', '$1  '
    $t -replace '\*\*', ''
}

function Get-NoteSummary {
    <#
    .SYNOPSIS
        One picker item per daily note: its date, its lines, and query hits.
    .DESCRIPTION
        Lines are the note's content as plain text, with the "# YYYY-MM-DD"
        header and blank lines dropped. With -Query, only the notes containing
        it are returned (case-insensitive, matched literally so `c++` or `(x)`
        need no escaping) and Hits holds the matching lines; without it Hits is
        empty. A file whose name isn't a real date (2026-13-45.md) is skipped.
    #>
    param(
        [System.IO.FileInfo[]] $File,
        [string] $Query
    )

    foreach ($f in $File) {
        $date = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($f.BaseName, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref] $date)) { continue }

        $lines = @(Get-Content -LiteralPath $f.FullName -Encoding utf8 -ErrorAction Ignore |
            Where-Object { $_.Trim() -and $_ -notmatch '^#\s+\d{4}-\d{2}-\d{2}\s*$' } |
            ForEach-Object { ConvertTo-NotePlainLine $_ })

        $hits = @()
        if ($Query) {
            $hits = @($lines | Where-Object { $_.IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
            if ($hits.Count -eq 0) { continue }
        }

        [pscustomobject]@{
            Date  = $date
            Path  = $f.FullName
            Lines = $lines
            Hits  = $hits
        }
    }
}

function Show-NoteFile {
    <#
    .SYNOPSIS
        Print one daily note in the terminal.
    .DESCRIPTION
        A dated title with the weekday, then the note's markdown rendered by
        Show-Markdown (built into PowerShell 7, so bold, code and headings come
        out styled with nothing to install), indented like the rest of the
        toolkit's output. The file's own "# YYYY-MM-DD" header is dropped in
        favour of the title, which says the same thing plus the day.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $name  = [IO.Path]::GetFileNameWithoutExtension($Path)
    $date  = [datetime]::MinValue
    $title = if ([datetime]::TryParseExact($name, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref] $date)) {
        $date.ToString('dddd d MMMM yyyy', [cultureinfo]::InvariantCulture)
    } else { $name }

    $body = [string](Get-Content -Raw -LiteralPath $Path -Encoding utf8) -replace '^#\s+\d{4}-\d{2}-\d{2}[ \t]*\r?\n', ''

    Write-Host ''
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ''
    if (-not $body.Trim()) {
        Write-Host '  (empty)' -ForegroundColor DarkGray
    } else {
        $rendered = ([string](Show-Markdown -InputObject $body.Trim())).TrimEnd() -split '\r?\n'
        foreach ($l in $rendered) { Write-Host "  $l" }
    }
    Write-Host ''
}

function note {
    <#
    .SYNOPSIS
        Append a timestamped bullet to today's note, or show today's note.
    .DESCRIPTION
        With text, appends "- **HH:mm** — <text>" to <NotesRoot>/YYYY-MM-DD.md
        (creating the file with a daily header on first write). With no text,
        prints today's note in the terminal. -Edit opens it in your default .md
        app instead, for when an entry needs fixing. Aliased as `today`.
        `notes` browses earlier days; `Find-Note` searches them.
    .PARAMETER Text
        The note text. Everything after `note` is captured, so quotes are optional.
    .PARAMETER Edit
        Open today's note in your default .md app (Obsidian, Typora, VS Code, …)
        rather than printing it. Given with text, appends first, then opens.
    .EXAMPLE
        note Met with Karen re: policy rollout

        Appends "- **14:05** — Met with Karen re: policy rollout" to today's
        dated note file, creating it with a header if it's the first note today.
    .EXAMPLE
        today

        With no text, prints today's entries right in the terminal.
    .EXAMPLE
        note -Edit

        Opens today's note in your default .md app to fix or rewrite an entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]] $Text,
        [switch] $Edit
    )

    $notesRoot = $script:Config.NotesRoot
    if (-not $notesRoot) {
        Write-Host '  NotesRoot not configured. Set in Profiles/config.psd1:' -ForegroundColor Yellow
        Write-Host "      NotesRoot = '$env:USERPROFILE\Documents\Notes'" -ForegroundColor DarkGray
        return
    }

    $today    = Get-Date -Format 'yyyy-MM-dd'
    $notePath = Join-Path $notesRoot "$today.md"
    $line     = ($Text -join ' ').Trim()

    if (-not $line -and -not $Edit) {
        # Reading never creates the file, so a day you only looked at stays
        # empty on disk instead of leaving a header-only note behind.
        if (Test-Path -LiteralPath $notePath) {
            Show-NoteFile -Path $notePath
            return
        }
        Write-Host '  No notes yet today.  note <text> starts one.' -ForegroundColor DarkGray
        $last = Get-NoteFile -Root $notesRoot | Select-Object -First 1
        if ($last) {
            Write-Host "  Last note: $($last.BaseName)  —  notes to browse them." -ForegroundColor DarkGray
        }
        return
    }

    if (-not (Test-Path -LiteralPath $notesRoot)) {
        New-Item -ItemType Directory -Path $notesRoot -Force | Out-Null
    }

    # Create the file with a daily header on first write.
    if (-not (Test-Path -LiteralPath $notePath)) {
        Set-Content -LiteralPath $notePath -Value "# $today`n`n" -Encoding utf8
    }

    if ($line) {
        $timestamp = Get-Date -Format 'HH:mm'
        Add-Content -LiteralPath $notePath -Value "- **$timestamp** — $line" -Encoding utf8
        Write-Host "  + $today.md  ($timestamp)" -ForegroundColor DarkGray
    }

    if ($Edit) {
        # Whatever app handles .md: on an Obsidian setup that jumps right into
        # the vault; otherwise Typora / VS Code / Notepad via the shell
        # association. If Windows asks which app to use, that's the association
        # being unset — pick one and tick "Always" once.
        #
        # NOTE: v0.1.19-21 chased a "Chromium stderr leaks into the parent
        # shell" issue with some Electron handlers (Typora was the reported
        # case) — Start-Process, ProcessStartInfo+UseShellExecute, and
        # `cmd /c start` were all tried. None made a real-world difference
        # the user cared about (the noise is harmless and the fix on the
        # user side is either "use a different .md handler" or "flip the
        # Windows Privacy Jump-List setting"). Reverted to the idiomatic
        # Invoke-Item in v0.1.22 — keep this simple. Don't re-add workarounds
        # unless someone reports an actually-broken behavior, not just noise.
        Invoke-Item -LiteralPath $notePath
    }
}

Set-Alias today note

function notes {
    <#
    .SYNOPSIS
        Browse your daily notes in a picker; Enter prints the chosen day.
    .DESCRIPTION
        Lists every daily note in NotesRoot, newest first, with its entry count
        and first entry; the highlighted day's entries show in full beneath the
        list. Enter prints that day in the terminal, the same way `today` does.
        With a query, only the days that mention it are listed and the detail
        shows the matching lines — the browse-and-read counterpart to
        Find-Note, which prints every hit as a table.
    .PARAMETER Query
        Only list the days containing this text (case-insensitive, matched
        literally). Everything after `notes` is captured, so quotes are optional.
    .EXAMPLE
        notes

        Every day you've written a note, newest first. The digit and letter keys
        jump straight to a day, so yesterday is usually one keypress away.
    .EXAMPLE
        notes karen

        Only the days that mention Karen; the matching lines show beneath the
        list for whichever day is highlighted.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]] $Query)

    $notesRoot = $script:Config.NotesRoot
    $files = @(Get-NoteFile -Root $notesRoot)
    if ($files.Count -eq 0) {
        Write-Host "  No daily notes in '$notesRoot' yet.  note <text> starts one." -ForegroundColor Yellow
        return
    }

    $q     = ($Query -join ' ').Trim()
    $items = @(Get-NoteSummary -File $files -Query $q)
    if ($items.Count -eq 0) {
        Write-Host "  No notes mention '$q'." -ForegroundColor Yellow
        return
    }

    $render = {
        param($i)
        # With a query the count and preview are about the hits, since those
        # are why the day is on the list at all.
        $shown = if ($q) { $i.Hits } else { $i.Lines }
        $noun  = if ($q) { 'hit' } else { 'entry' }
        $count = if ($shown.Count -eq 1) { "1 $noun" } elseif ($q) { "$($shown.Count) hits" } else { "$($shown.Count) entries" }
        $day   = $i.Date.ToString('ddd', [cultureinfo]::InvariantCulture)
        "{0:yyyy-MM-dd}  `e[90m{1}`e[0m  {2,-11}  `e[90m{3}`e[0m" -f $i.Date, $day, $count, ($shown | Select-Object -First 1)
    }.GetNewClosure()

    $detail = {
        param($i)
        $(if ($q) { $i.Hits } else { $i.Lines }) -join '  ·  '
    }.GetNewClosure()

    $title = if ($q) { "Daily notes mentioning '$q'" } else { 'Daily notes' }
    $selected = Show-Picker -Items $items -RenderRow $render -DetailRow $detail `
        -Title $title -Hint 'Up/Down + Enter show  PgUp/PgDn  Esc cancel  |  1-9, a-z jump'
    if (-not $selected) { return }

    Show-NoteFile -Path $selected.Path
}

# Resolve NotesRoot if unset at this point. Runs once at Notes.ps1 load time
# (after the loader's hard-fallback block, which leaves NotesRoot as $null
# when neither config.psd1 nor config.example.psd1 set it).
if (-not $script:Config.NotesRoot) {
    $script:Config.NotesRoot = Resolve-NotesRoot
}

function Find-Note {
    <#
    .SYNOPSIS
        Search across all daily notes for a term.
    .DESCRIPTION
        Greps the markdown files in NotesRoot, returning the note file, line
        number, and matching line for each hit. To read one of those days in
        full, `notes <query>` lists the same days in a picker.
    .PARAMETER Query
        The text or pattern to search for.
    .EXAMPLE
        Find-Note "registry policy"

        Searches every daily note for "registry policy" and lists each hit as
        note file + line number + the matching line — so you can find when you
        wrote something and jump back to it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Query)

    $notesRoot = $script:Config.NotesRoot
    if (-not $notesRoot) {
        Write-Host '  NotesRoot not configured. Run Set-NotesRoot or set it in Profiles/config.psd1.' -ForegroundColor Yellow
        return
    }
    if (-not (Test-Path -LiteralPath $notesRoot)) {
        Write-Host "  No notes folder at '$notesRoot' — nothing to search." -ForegroundColor Yellow
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
