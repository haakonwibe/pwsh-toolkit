#Requires -Version 7.0
<#
.SYNOPSIS
    `dird` — Get-ChildItem with FILE_ID.DIZ-style descriptions appended,
    colored by file format and AI-assigned bucket.

.DESCRIPTION
    Reads the "description" NTFS Alternate Data Stream written by
    Invoke-DownloadsTag.ps1 and renders Get-ChildItem with an extra
    Description column. Files without an ADS show a blank description.

    Falls back to _downloads-index.csv if ADS is missing (e.g. file was
    copied off-volume and lost its streams).

    Dot-source this file or load it from your PowerShell profile to make
    `Get-DirDescriptions` and the `dird` alias available.

.EXAMPLE
    . .\Get-DirDescriptions.ps1
    dird
    dird ~\Downloads
    dird ~\Downloads -Bucket Installers
    dird -NoColor                # plain output (for pipes / non-TTY)
#>

# ANSI color codes. Use the numeric SGR codes directly so this works on
# PowerShell 7.0+ (older than 7.2 doesn't have $PSStyle).
#   30-37  : normal       90-97  : bright
#   31 red    32 green   33 yellow   34 blue
#   35 magenta 36 cyan   37 white   90 dark gray
#   91-97 are the bright variants
# Extension colors align with the bucket each file most likely belongs to.
# That way the Name column color and the Bucket column color tell the same
# story (and a still-untagged file already hints at its category by its color).
$script:ExtensionColors = @{
    # → Documents bucket (blue, 34)
    '.pdf' = 34
    '.docx' = 34; '.doc' = 34; '.odt' = 34; '.rtf' = 34
    '.pptx' = 34; '.ppt' = 34; '.odp' = 34
    '.txt' = 34; '.md' = 34; '.markdown' = 34; '.rst' = 34; '.log' = 34

    # → Data bucket (bright cyan, 96)
    '.xlsx' = 96; '.xls' = 96; '.ods' = 96; '.csv' = 96; '.tsv' = 96
    '.json' = 96; '.xml' = 96; '.yaml' = 96; '.yml' = 96
    '.toml' = 96; '.ini' = 96; '.conf' = 96; '.cfg' = 96

    # → Code bucket (cyan, 36)
    '.py' = 36; '.js' = 36; '.ts' = 36; '.jsx' = 36; '.tsx' = 36
    '.cs' = 36; '.go' = 36; '.rs' = 36; '.java' = 36; '.kt' = 36
    '.rb' = 36; '.swift' = 36; '.c' = 36; '.cpp' = 36; '.h' = 36; '.hpp' = 36
    '.ps1' = 36; '.psm1' = 36; '.bat' = 36; '.cmd' = 36; '.sh' = 36; '.bash' = 36
    '.html' = 36; '.htm' = 36; '.css' = 36
    '.gpx' = 36; '.kml' = 36; '.kmz' = 36

    # → Installers bucket (bright yellow, 93)
    '.exe' = 93; '.msi' = 93; '.msix' = 93; '.appx' = 93; '.dmg' = 93

    # → Archives bucket (magenta, 35)
    '.zip' = 35; '.7z' = 35; '.rar' = 35; '.tar' = 35
    '.gz' = 35;  '.bz2' = 35; '.xz' = 35; '.jar' = 35

    # → Images bucket (bright magenta, 95)
    '.jpg' = 95; '.jpeg' = 95; '.png' = 95; '.gif' = 95; '.bmp' = 95
    '.webp' = 95; '.svg' = 95; '.ico' = 95; '.heic' = 95

    # → Media bucket (bright blue, 94)
    '.mp4' = 94; '.mkv' = 94; '.mov' = 94; '.avi' = 94
    '.webm' = 94; '.wmv' = 94; '.flv' = 94
    '.mp3' = 94; '.wav' = 94; '.flac' = 94; '.ogg' = 94; '.m4a' = 94; '.aac' = 94; '.opus' = 94
}

# Bucket colors mirror the colors Invoke-DownloadsTag prints on tag.
$script:BucketColors = @{
    'Receipts'   = 92  # bright green
    'Tax'        = 95  # bright magenta
    'Installers' = 93  # bright yellow
    'Code'       = 36  # cyan
    'Documents'  = 34  # blue
    'Archives'   = 35  # magenta
    'Images'     = 95  # bright magenta
    'Media'      = 94  # bright blue
    'Data'       = 96  # bright cyan
    'References' = 37  # white
    'Other'      = 90  # dark gray
}

function script:Add-Ansi {
    param([string] $Text, [int] $Code, [bool] $Use)
    if (-not $Use -or [string]::IsNullOrEmpty($Text) -or -not $Code) { return $Text }
    return "$([char]27)[${Code}m$Text$([char]27)[0m"
}

# Small pager. Replaces Out-Host -Paging which:
#   - shows a spurious final prompt when input ends
#   - throws OperationStopped when the user presses Q
# Keys: SPACE = next page, ENTER = next line, Q / ESC = quit cleanly.
function script:Invoke-Pager {
    param([string[]] $Lines)

    # Non-interactive (redirected, no TTY) — just dump everything.
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $Lines | ForEach-Object { Write-Host $_ }
        return
    }

    $termHeight = $Host.UI.RawUI.WindowSize.Height
    if (-not $termHeight -or $termHeight -lt 5) { $termHeight = 24 }
    $termWidth  = $Host.UI.RawUI.WindowSize.Width
    if (-not $termWidth -or $termWidth -lt 20) { $termWidth = 80 }
    $pageSize   = $termHeight - 2   # leave room for the prompt + return cursor

    $linesLeft = $pageSize
    foreach ($line in $Lines) {
        Write-Host $line
        $linesLeft--
        if ($linesLeft -le 0) {
            Write-Host -NoNewline '-- More -- (SPACE next page, ENTER next line, Q quit) ' -ForegroundColor Yellow
            $key = [Console]::ReadKey($true)
            # Erase prompt line
            Write-Host -NoNewline ("`r{0}`r" -f (' ' * ($termWidth - 1)))
            switch ($key.Key) {
                'Q'        { return }
                'Escape'   { return }
                'Enter'    { $linesLeft = 1 }
                default    { $linesLeft = $pageSize }
            }
        }
    }
}

# Human-readable byte size — always 7 chars wide so the column doesn't jitter.
# Tiers: B (<1 KB), KB (<1 MB), MB (<1 GB), GB (>=1 GB).
function script:Format-Size {
    param([long] $Bytes)
    if     ($Bytes -ge 1GB) { '{0,4:N1} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0,4:N1} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0,4:N0} KB' -f ($Bytes / 1KB) }
    else                    { '{0,5} B'    -f $Bytes }
}

# Word-aware wrap. Returns an array of lines no wider than $Width. Breaks at
# the last space if possible; falls back to hard-break for words that can't fit.
function script:Wrap-Text {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'File-local rendering helper; "Wrap" reads better than an approved verb here.')]
    param([string] $Text, [int] $Width)
    if ([string]::IsNullOrEmpty($Text)) { return @('') }
    $lines = @()
    $remaining = $Text
    while ($remaining.Length -gt $Width) {
        $break = $remaining.LastIndexOf(' ', $Width - 1)
        if ($break -lt [int]($Width / 2)) { $break = $Width - 1 }  # no decent break point — hard wrap
        $lines += $remaining.Substring(0, $break + 1).TrimEnd()
        $remaining = $remaining.Substring($break + 1).TrimStart()
    }
    if ($remaining) { $lines += $remaining }
    return $lines
}

# BBS-style renderer (the 4DOS / 90s warez look):
#   NAME.EXT       SIZE  yy-MM-dd HH:mm  [Bucket] Description wraps to
#                                                  multiple lines as needed
#                                                  in the right column.
#                                                  Blank line between files.
# Returns lines as pipeline strings (so the caller can | Out-Host -Paging).
function script:Render-BBSStyle {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'File-local rendering helper; "Render" reads better than an approved verb here.')]
    param([object[]] $Rows, [bool] $UseColor)

    # Detect terminal width up front so the name column can scale with it.
    $termWidth = $Host.UI.RawUI.WindowSize.Width
    if (-not $termWidth -or $termWidth -lt 80) { $termWidth = 120 }

    # Target ~40% of terminal width for the name+size+date block (BBS feel,
    # not too cramped on narrow terms, not too sparse on ultrawides).
    $sizeWidth = 8
    $dateWidth = 8        # "yy-MM-dd" — no time in BBS style
    $gap       = '  '
    $fixedSlots = $sizeWidth + $dateWidth + ($gap.Length * 3)   # size + date + 3 gaps
    $targetLeft = [int]($termWidth * 0.40)
    $nameWidth  = [Math]::Max(15, $targetLeft - $fixedSlots)
    $leftBlock  = $nameWidth + $fixedSlots
    $descWidth  = [Math]::Max(30, $termWidth - $leftBlock - 1)

    $firstRow = $true
    foreach ($row in $Rows) {
        # Leading blank between rows (not trailing — avoids Out-Host -Paging
        # showing an extra empty prompt after the final file).
        if (-not $firstRow) { Write-Output '' }
        $firstRow = $false

        # Wrap both name and description. Name only takes additional lines if
        # the description does too (no point growing vertically for nothing).
        $descBucketTag = if ($row.Bucket) { "[$($row.Bucket)] " } else { '' }
        $descRaw  = $row.Description ?? ''
        $fullDesc = "$descBucketTag$descRaw"
        $descLines = @(Wrap-Text -Text $fullDesc -Width $descWidth)
        $nameLines = @(Wrap-Text -Text $row.Name -Width $nameWidth)
        # Cap name lines at the number of desc lines so we don't grow vertically
        # for a long name when the description is short — truncate any overflow
        # of name with an ellipsis on the last allowed line.
        if ($nameLines.Count -gt $descLines.Count) {
            $allowed = [Math]::Max(1, $descLines.Count)
            if ($allowed -lt $nameLines.Count) {
                $last = [string] $nameLines[$allowed - 1]
                if ($last.Length -gt $nameWidth - 1) {
                    $last = $last.Substring(0, $nameWidth - 1)
                }
                $last = $last + [char]0x2026
                # Beware $arr[0..-1] in PowerShell — that's the descending range
                # (0, -1), not an empty slice. Handle the single-line case explicitly.
                if ($allowed -eq 1) {
                    $nameLines = @($last)
                } else {
                    $nameLines = @($nameLines[0..($allowed - 2)] + $last)
                }
            }
        }

        # Size and date are always single-line, shown on row 0.
        $sizeFormatted = (Format-Size $row.Size).PadLeft($sizeWidth)
        $dateOnly = if ($row.Modified.Length -ge 8) { $row.Modified.Substring(0, 8) } else { $row.Modified }
        $dateFormatted = $dateOnly.PadRight($dateWidth)

        $extCode    = $script:ExtensionColors[$row.Extension]
        $bucketCode = if ($row.Bucket) { $script:BucketColors[$row.Bucket] } else { $null }

        $maxLines = [Math]::Max($nameLines.Count, $descLines.Count)
        for ($i = 0; $i -lt $maxLines; $i++) {
            # Name (or empty padding when name has fewer lines than desc)
            $nameSeg = if ($i -lt $nameLines.Count) { [string] $nameLines[$i] } else { '' }
            $nameSegPadded = $nameSeg.PadRight($nameWidth)
            $nameOut = if ($nameSeg) {
                Add-Ansi -Text $nameSegPadded -Code $extCode -Use $UseColor
            } else { $nameSegPadded }

            # Size / date only on line 0
            if ($i -eq 0) {
                $sizeOut = Add-Ansi -Text $sizeFormatted -Code 93 -Use $UseColor   # bright yellow
                $dateOut = Add-Ansi -Text $dateFormatted -Code 96 -Use $UseColor   # bright cyan
            } else {
                $sizeOut = ' ' * $sizeWidth
                $dateOut = ' ' * $dateWidth
            }

            # Description segment for this line
            $descSeg = if ($i -lt $descLines.Count) { [string] $descLines[$i] } else { '' }

            # Color the [Bucket] prefix only on line 0
            if ($i -eq 0 -and $descBucketTag -and $descSeg.StartsWith($descBucketTag.TrimEnd())) {
                $tag        = "[$($row.Bucket)]"
                $rest       = $descSeg.Substring($tag.Length)
                $tagColored = Add-Ansi -Text $tag -Code $bucketCode -Use $UseColor
                $descSeg    = $tagColored + $rest
            }

            Write-Output ("{0}{1}{2}{1}{3}{1}{4}" -f $nameOut, $gap, $sizeOut, $dateOut, $descSeg)
        }
    }
}

function Get-DirDescriptions {
    <#
    .SYNOPSIS
        Directory listing with AI descriptions, color-coded by bucket (alias: dird).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a collection of descriptions; the plural name is the established public command.')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string] $Path = '.',

        # Optional sub-bucket filter (matches the index CSV column).
        [string] $Bucket,

        # Sort by sub-bucket then name (default is name).
        [switch] $GroupByBucket,

        # Newest-first (sort by LastWriteTime descending). 4DOS-style.
        [switch] $Newest,

        # Pause between pages of output. Combined with -Newest, gives the
        # classic BBS "fr" (filelisting reverse) behavior.
        [switch] $Page,

        # 4DOS / BBS-style stacked layout instead of the default table.
        # One file per block: name/size/date on the left, description wraps
        # on the right with a blank-line separator between files.
        [switch] $BBS,

        # Disable color output (useful for piping or dumb terminals).
        [switch] $NoColor
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Error "Path not found or not a directory: $Path"
        return
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path

    # Detect color support. Disable on -NoColor, on plain-text PSStyle, or when
    # virtual-terminal escapes aren't supported by the current host.
    $useColor = -not $NoColor -and `
                ($Host.UI.SupportsVirtualTerminal -or `
                 ($null -ne $PSStyle -and $PSStyle.OutputRendering -ne 'PlainText'))

    # Load CSV fallback if present
    $indexPath = Join-Path $resolved '_downloads-index.csv'
    $indexByName = @{}
    if (Test-Path -LiteralPath $indexPath) {
        try {
            Import-Csv -LiteralPath $indexPath | ForEach-Object {
                $indexByName[$_.Name] = $_
            }
        } catch {
            Write-Verbose "Failed to load index CSV: $_"
        }
    }

    $rows = Get-ChildItem -LiteralPath $resolved -File |
        Where-Object { $_.Name -ne '_downloads-index.csv' } |
        ForEach-Object {
            $file = $_
            $description = $null
            $subBucket = $null

            # ADS first
            try {
                $ads = Get-Content -LiteralPath $file.FullName -Stream 'description' -ErrorAction Stop
                if ($ads) { $description = ($ads -join ' ').Trim() }
            }
            catch {
                # No ADS on this file — expected for most; fall back to CSV
                # index. Routed to the debug stream rather than swallowed.
                Write-Debug "No 'description' ADS on $($file.Name): $($_.Exception.Message)"
            }

            if ($indexByName.ContainsKey($file.Name)) {
                $entry = $indexByName[$file.Name]
                if (-not $description) { $description = $entry.Description }
                $subBucket = $entry.SubBucket
            }

            [pscustomobject]@{
                Size        = $file.Length
                Modified    = $file.LastWriteTime.ToString('yy-MM-dd HH:mm')
                # Real timestamp kept for sorting; -Newest sorts on this, not the
                # 'yy-MM-dd HH:mm' display string (which only happens to sort
                # chronologically this century and would break on a format change).
                SortTime    = $file.LastWriteTime
                Name        = $file.Name
                Extension   = $file.Extension.ToLowerInvariant()
                Bucket      = $subBucket
                Description = $description
            }
        }

    if ($Bucket) {
        $rows = @($rows | Where-Object { $_.Bucket -eq $Bucket })
    } else {
        $rows = @($rows)
    }

    # Sort precedence: GroupByBucket (bucket) > Newest (date desc) > Name asc.
    # Both can combine — `-GroupByBucket -Newest` groups by bucket, newest first within each.
    if ($GroupByBucket -and $Newest) {
        $rows = @($rows | Sort-Object @{ Expression = { $_.Bucket ?? 'zzzz' } }, @{ Expression = 'SortTime'; Descending = $true })
    }
    elseif ($GroupByBucket) {
        $rows = @($rows | Sort-Object @{ Expression = { $_.Bucket ?? 'zzzz' } }, Name)
    }
    elseif ($Newest) {
        $rows = @($rows | Sort-Object @{ Expression = 'SortTime'; Descending = $true })
    }

    if ($BBS) {
        $bbsLines = @(Render-BBSStyle -Rows $rows -UseColor $useColor)
        if ($Page) {
            Invoke-Pager -Lines $bbsLines
        } else {
            $bbsLines | ForEach-Object { Write-Host $_ }
        }
    } else {
        # Explicit Widths on Bucket and Name cap those columns so long names wrap to
        # multiple lines within the row; Description gets the remaining width and
        # also wraps via -Wrap.
        $table = $rows | Format-Table `
            @{ Name = 'Size';     Expression = { Format-Size $_.Size }; Alignment = 'Right'; Width = 8 },
            @{ Name = 'Modified'; Expression = { $_.Modified }; Width = 14 },
            @{ Name = 'Bucket';   Expression = {
                    $b = $_.Bucket
                    $code = if ($b) { $script:BucketColors[$b] } else { $null }
                    Add-Ansi -Text $b -Code $code -Use $useColor
                }; Width = 10 },
            @{ Name = 'Name';     Expression = {
                    $code = $script:ExtensionColors[$_.Extension]
                    Add-Ansi -Text $_.Name -Code $code -Use $useColor
                }; Width = 40 },
            @{ Name = 'Description'; Expression = { $_.Description } } `
            -Wrap

        if ($Page) {
            # Format-Table emits format records; Out-String -Stream converts them
            # to printable lines (preserving ANSI in PS 7.2+) so the pager can
            # work with them line-by-line.
            $tableLines = @($table | Out-String -Stream | Where-Object { $_ -ne $null })
            Invoke-Pager -Lines $tableLines
        } else {
            $table
        }
    }

    $tagged = @($rows | Where-Object { $_.Description }).Count
    Write-Host ("  {0} of {1} files have descriptions" -f $tagged, $rows.Count) -ForegroundColor DarkGray
}

# `fr` — 4DOS / BBS-style "filelisting reverse": newest first, BBS layout, paged.
# Forwards positional and named args to Get-DirDescriptions.
function Show-FileListingReverse {
    <#
    .SYNOPSIS
        Newest-first BBS-style file listing with AI descriptions (alias: fr).
    #>
    Get-DirDescriptions -Newest -Page -BBS @args
}
Set-Alias -Name fr -Value Show-FileListingReverse -Scope Global -Force

Set-Alias -Name dird -Value Get-DirDescriptions -Scope Global -Force
