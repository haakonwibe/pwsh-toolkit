# Recent-files browser: `recent`
# ============================================================================
# "I downloaded/saved something an hour ago — where did it go?" Recent stuff
# lands in a handful of folders; this shows the newest files across all of them
# in one picker. Enter opens the file with its default app — except archives,
# which are handed to `peek` (extract to temp + jump there). Descriptions
# written by `tagdl` (the :description ADS) ride along in the listing.
#
# Sources: the built-ins below. For machine-specific additions, append in
# Machines/<COMPUTERNAME>.ps1 — same pattern as $script:JumpFolders:
#   $script:RecentFolders += 'D:\Scans'
#
# Load order: Navigation.ps1 defines $script:OneDrivePath and sorts before this
# file alphabetically, so the OneDrive-redirected Desktop resolves at load time.
# Missing folders are skipped at scan time, so both Desktop variants can be
# listed unconditionally.
$script:RecentFolders = @(
    (Join-Path $env:USERPROFILE 'Downloads')
    (Join-Path $script:OneDrivePath 'Desktop')
    (Join-Path $env:USERPROFILE 'Desktop')
)

function Get-RecentFile {
    # Newest files (top level only — sortdl's bucket subfolders are the archive,
    # not the "recent" pile) across the given folders, newest first.
    param(
        [string[]] $Folder,
        [int]      $Limit = 30
    )
    if (-not $Folder) { $Folder = $script:RecentFolders }
    $files = foreach ($dir in ($Folder | Select-Object -Unique)) {
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            Get-ChildItem -LiteralPath $dir -File -ErrorAction Ignore
        }
    }
    $files | Sort-Object LastWriteTime -Descending | Select-Object -First $Limit
}

function Format-FileAge {
    # Compact age for the picker: now / 5m / 3h / 12d, then a date for 30+ days.
    param([Parameter(Mandatory)][datetime] $Time)
    $span = (Get-Date) - $Time
    if ($span.TotalMinutes -lt 1) { return 'now' }      # includes future stamps
    if ($span.TotalHours -lt 1)   { return ('{0}m' -f [int][math]::Floor($span.TotalMinutes)) }
    if ($span.TotalDays -lt 1)    { return ('{0}h' -f [int][math]::Floor($span.TotalHours)) }
    if ($span.TotalDays -lt 30)   { return ('{0}d' -f [int][math]::Floor($span.TotalDays)) }
    return $Time.ToString('yyyy-MM-dd')
}

function Get-FileDizDescription {
    # First line of the FILE_ID.DIZ-style description tagdl writes to the
    # :description ADS. Best-effort: no stream (or FAT/exFAT volume) → ''.
    param([Parameter(Mandatory)][string] $Path)
    try {
        [string](Get-Content -LiteralPath $Path -Stream 'description' -TotalCount 1 -ErrorAction Stop)
    } catch { '' }
}

function recent {
    <#
    .SYNOPSIS
        Newest files across Downloads + Desktop in one picker; Enter opens.
    .DESCRIPTION
        Scans the configured recent-file folders (Downloads and Desktop by
        default; machine files can append to $script:RecentFolders) and shows
        the newest files in the shared picker — age, name, source folder, and
        the tagdl description when one exists. Enter opens the selection with
        its default app; archives (.zip/.rar/.7z) are handed to `peek` instead,
        which extracts to a temp folder and jumps you there.
    .PARAMETER Limit
        How many files to show (default 30).
    .EXAMPLE
        recent

        The 30 newest files across Downloads and Desktop — the "where did that
        file just go" view.
    .EXAMPLE
        recent 50

        Same, deeper.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][int] $Limit = 30)

    $files = @(Get-RecentFile -Limit $Limit)
    if ($files.Count -eq 0) {
        Write-Host '  No files found in the recent folders.' -ForegroundColor Yellow
        return
    }

    # Precompute the row fields once; the render scriptblock only formats.
    $items = foreach ($f in $files) {
        [pscustomobject]@{
            Name   = $f.Name
            Age    = Format-FileAge $f.LastWriteTime
            Where  = Split-Path -Leaf $f.DirectoryName
            Desc   = Get-FileDizDescription $f.FullName
            Path   = $f.FullName
        }
    }

    $nameWidth = [Math]::Min(40, ($items | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
    $render = {
        param($i)
        $name = if ($i.Name.Length -gt $nameWidth) { $i.Name.Substring(0, $nameWidth - 1) + [char]0x2026 } else { $i.Name.PadRight($nameWidth) }
        $tail = if ($i.Desc) { "$($i.Where)  · $($i.Desc)" } else { $i.Where }
        '{0,5}  {1}  {2}' -f $i.Age, $name, $tail
    }.GetNewClosure()

    $selected = Show-Picker -Items $items -RenderRow $render `
        -Title 'Recent files' -Hint 'Up/Down + Enter open  PgUp/PgDn  Esc cancel  |  archives open via peek'
    if (-not $selected) { return }

    # Archives are better peeked than launched: extract + jump beats whatever
    # the shell's default association would do with them.
    $ext = [IO.Path]::GetExtension($selected.Path).ToLowerInvariant()
    if ($ext -in @('.zip', '.rar', '.7z') -and (Get-Command peek -ErrorAction Ignore)) {
        peek $selected.Path
    } else {
        Invoke-Item -LiteralPath $selected.Path
    }
}
