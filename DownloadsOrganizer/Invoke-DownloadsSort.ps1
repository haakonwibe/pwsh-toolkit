#Requires -Version 7.0
<#
.SYNOPSIS
    Sort tagged Downloads into per-bucket subfolders, with preview and undo.

.DESCRIPTION
    The hands to `tagdl`'s brain. `tagdl` already classifies every download into
    a fixed bucket (Documents, Installers, Archives, Images, Code, Media, Data,
    Receipts, References, Tax, Other) and records it in <Path>\_downloads-index.csv.
    This reads that index and moves each file currently at the Downloads *root*
    into <Path>\<Bucket>\.

    Nothing ever leaves the Downloads folder — buckets are subfolders of it, so a
    sort is contained and trivially reversible. Files tagged "Other" and files
    with no tag are left at the root: an "unsorted" pile you can still see beats a
    junk drawer you can't.

    Safety, because this is the only toolkit command that moves your files:
      - A real run prints the move plan grouped by bucket, then asks before moving
        (the prompt defaults to No). -WhatIf shows the plan and stops; -Yes skips
        the prompt for scheduled/`task` use.
      - It never overwrites: if a same-named file already sits in the destination,
        the file is left where it is and reported as a collision.
      - Every run records its moves to %LOCALAPPDATA%\DownloadsOrganizer\last-sort.json;
        `sortdl -Undo` moves them all back and removes the bucket folders it emptied.

    Descriptions written by `tagdl` live in each file's NTFS Alternate Data Stream
    and travel with the file (the move stays on one volume), so `dird <bucket>`
    still shows them after a sort.

.PARAMETER Path
    Directory to organize. Defaults to "$HOME\Downloads".

.PARAMETER Yes
    Skip the confirmation prompt and move immediately. For non-interactive and
    scheduled runs (e.g. via `task`).

.PARAMETER Undo
    Reverse the most recent sort: move every file recorded in the manifest back to
    the Downloads root and delete any bucket folders left empty. Ignores -Path.

.PARAMETER WhatIf
    Show the move plan without moving anything (no prompt, no writes).

.EXAMPLE
    sortdl
    Preview the planned moves, then confirm to file everything into bucket folders.

.EXAMPLE
    sortdl -WhatIf
    Show what would move, change nothing.

.EXAMPLE
    sortdl -Undo
    Put the last sort back the way it was.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Path = (Join-Path $HOME 'Downloads'),
    [switch] $Yes,
    [switch] $Undo
)

$ErrorActionPreference = 'Stop'

# ---------- Constants ----------
$StateDir     = Join-Path $env:LOCALAPPDATA 'DownloadsOrganizer'
$ManifestFile = Join-Path $StateDir 'last-sort.json'
$IndexName    = '_downloads-index.csv'

# Buckets `tagdl` assigns that map to a folder. 'Other' is deliberately absent —
# unclassifiable files stay at the root rather than disappear into an 'Other' bin.
$MovableBuckets = @(
    'Documents', 'Installers', 'Archives', 'Images', 'Code',
    'Media', 'Data', 'Receipts', 'References', 'Tax'
)

# Partial-download markers — never move a file the browser is still writing.
$InProgressExtensions = @('.crdownload', '.part', '.partial', '.tmp', '.opdownload', '.download')

function Get-BucketColor {
    param([string] $Bucket)
    switch ($Bucket) {
        'Receipts'   { 'Green' }
        'Tax'        { 'Magenta' }
        'Installers' { 'Yellow' }
        'Code'       { 'Cyan' }
        default      { 'White' }
    }
}

if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

Write-Host ''
Write-Host '  Downloads Sorter' -ForegroundColor Cyan
Write-Host '  ----------------' -ForegroundColor Cyan

# ============================================================================
# Undo: reverse the most recent sort, then exit.
# ============================================================================
if ($Undo) {
    if (-not (Test-Path -LiteralPath $ManifestFile)) {
        Write-Host '  Nothing to undo — no sort has been recorded.' -ForegroundColor Yellow
        return
    }
    try {
        $manifest = Get-Content -LiteralPath $ManifestFile -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        Write-Error "Could not read the sort manifest ($ManifestFile): $($_.Exception.Message)"
        return
    }

    $moves = @($manifest.Moves)
    if ($moves.Count -eq 0) {
        Write-Host '  Nothing to undo — the last sort moved no files.' -ForegroundColor Yellow
        return
    }

    Write-Host "  Reversing $($moves.Count) move(s) from $($manifest.SortedAt)" -ForegroundColor Gray
    Write-Host ''

    $restored = 0; $missing = 0; $blocked = 0
    $touchedDirs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Reverse order so the manifest reads as a clean rewind.
    for ($i = $moves.Count - 1; $i -ge 0; $i--) {
        $m = $moves[$i]
        if (-not (Test-Path -LiteralPath $m.To)) {
            Write-Host ("  GONE  {0}  (not in {1})" -f $m.Name, $m.Bucket) -ForegroundColor DarkGray
            $missing++
            continue
        }
        if (Test-Path -LiteralPath $m.From) {
            Write-Host ("  BLOCK {0}  (something is back at the root)" -f $m.Name) -ForegroundColor Yellow
            $blocked++
            continue
        }
        try {
            Move-Item -LiteralPath $m.To -Destination $m.From
            [void]$touchedDirs.Add((Split-Path -Parent $m.To))
            Write-Host ("  BACK  {0}  <-  {1}\" -f $m.Name, $m.Bucket) -ForegroundColor Gray
            $restored++
        }
        catch {
            Write-Host ("  FAIL  {0}  —  {1}" -f $m.Name, $_.Exception.Message) -ForegroundColor Red
            $blocked++
        }
    }

    # Remove bucket folders we emptied (only if truly empty — never recursive).
    foreach ($dir in $touchedDirs) {
        if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) {
            Remove-Item -LiteralPath $dir
        }
    }

    # Clear the manifest so a second -Undo is a no-op rather than a double-rewind.
    @{ SortedAt = $manifest.SortedAt; Path = $manifest.Path; Moves = @() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ManifestFile -Encoding utf8

    Write-Host ''
    Write-Host "  Restored $restored file(s)." -ForegroundColor Cyan
    if ($missing) { Write-Host "  $missing already gone (moved or deleted since)." -ForegroundColor DarkGray }
    if ($blocked) { Write-Host "  $blocked left in place (name taken at root, or move failed)." -ForegroundColor Yellow }
    return
}

# ============================================================================
# Sort: build the plan from the index, preview, confirm, move, record.
# ============================================================================
if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Error "Path not found or not a directory: $Path"
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path
Write-Host "  Path:   $Path" -ForegroundColor Gray

$indexPath = Join-Path $Path $IndexName
if (-not (Test-Path -LiteralPath $indexPath)) {
    Write-Host "  No $IndexName here. Run 'tagdl' first to classify your downloads." -ForegroundColor Yellow
    return
}

# Name -> bucket. PowerShell hashtables key case-insensitively on strings, which
# matches how Windows treats filenames. Last row wins (the index is deduped).
$bucketOf = @{}
foreach ($row in (Import-Csv -LiteralPath $indexPath)) {
    if ($row.Name) { $bucketOf[$row.Name] = $row.SubBucket }
}

# Walk the root only — never descend into the bucket folders themselves.
$plan       = [System.Collections.Generic.List[object]]::new()
$untagged   = 0
$otherKept  = 0
$collisions = [System.Collections.Generic.List[string]]::new()

foreach ($file in (Get-ChildItem -LiteralPath $Path -File)) {
    if ($file.Name -eq $IndexName) { continue }
    if ($InProgressExtensions -contains $file.Extension.ToLowerInvariant()) { continue }

    $bucket = $bucketOf[$file.Name]
    if (-not $bucket) { $untagged++; continue }
    if ($bucket -eq 'Other' -or $bucket -notin $MovableBuckets) { $otherKept++; continue }

    $destDir  = Join-Path $Path $bucket
    $destFile = Join-Path $destDir $file.Name
    if (Test-Path -LiteralPath $destFile) { $collisions.Add($file.Name); continue }

    $plan.Add([pscustomobject]@{
        Name   = $file.Name
        Bucket = $bucket
        From   = $file.FullName
        To     = $destFile
    })
}

# ---------- Preview ----------
Write-Host ''
if ($plan.Count -eq 0) {
    Write-Host '  Nothing to sort.' -ForegroundColor Green
    if ($untagged)          { Write-Host "  $untagged file(s) untagged — run 'tagdl' to classify them." -ForegroundColor DarkGray }
    if ($otherKept)         { Write-Host "  $otherKept file(s) tagged 'Other' — left at the root by design." -ForegroundColor DarkGray }
    if ($collisions.Count)  { Write-Host "  $($collisions.Count) file(s) skipped — a same-named file already exists in the bucket." -ForegroundColor Yellow }
    return
}

Write-Host "  Plan: $($plan.Count) file(s) into $(($plan | Group-Object Bucket).Count) bucket(s)" -ForegroundColor Gray
Write-Host ''
foreach ($grp in ($plan | Group-Object Bucket | Sort-Object Name)) {
    $color = Get-BucketColor -Bucket $grp.Name
    Write-Host ("  {0}\  ({1})" -f $grp.Name, $grp.Count) -ForegroundColor $color
    foreach ($item in ($grp.Group | Sort-Object Name)) {
        Write-Host "      $($item.Name)" -ForegroundColor Gray
    }
}
Write-Host ''
if ($untagged)         { Write-Host "  $untagged untagged file(s) stay at the root (run 'tagdl' to classify)." -ForegroundColor DarkGray }
if ($otherKept)        { Write-Host "  $otherKept 'Other' file(s) stay at the root by design." -ForegroundColor DarkGray }
if ($collisions.Count) { Write-Host "  $($collisions.Count) file(s) skipped — name already taken in the bucket: $($collisions -join ', ')" -ForegroundColor Yellow }

# ---------- Dry run / confirm ----------
if ($WhatIfPreference) {
    Write-Host ''
    Write-Host '  Dry run — nothing moved.' -ForegroundColor Yellow
    return
}
if (-not $Yes) {
    Write-Host ''
    $answer = Read-Host '  Proceed? [y/N]'
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host '  Aborted — nothing moved.' -ForegroundColor Yellow
        return
    }
}

# ---------- Move ----------
$done   = [System.Collections.Generic.List[object]]::new()
$failed = 0
foreach ($item in $plan) {
    $destDir = Split-Path -Parent $item.To
    try {
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        # Re-check the destination: a collision could have appeared since the plan
        # was built (or two planned names could collapse on a case-only difference).
        if (Test-Path -LiteralPath $item.To) {
            Write-Host ("  SKIP  {0}  —  already in {1}\" -f $item.Name, $item.Bucket) -ForegroundColor Yellow
            continue
        }
        Move-Item -LiteralPath $item.From -Destination $item.To
        $done.Add([pscustomobject]@{
            Name   = $item.Name
            Bucket = $item.Bucket
            From   = $item.From
            To     = $item.To
        })
    }
    catch {
        Write-Host ("  FAIL  {0}  —  {1}" -f $item.Name, $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
}

# ---------- Record manifest for -Undo ----------
@{
    SortedAt = (Get-Date).ToString('o')
    Path     = $Path
    Moves    = $done.ToArray()
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ManifestFile -Encoding utf8

# ---------- Summary ----------
Write-Host ''
Write-Host '  Summary' -ForegroundColor Cyan
Write-Host '  -------' -ForegroundColor Cyan
Write-Host "  Moved:   $($done.Count)"
if ($failed)           { Write-Host "  Failed:  $failed" -ForegroundColor Red }
if ($untagged)         { Write-Host "  Untagged at root: $untagged" -ForegroundColor DarkGray }
if ($otherKept)        { Write-Host "  Other at root:    $otherKept" -ForegroundColor DarkGray }
if ($collisions.Count) { Write-Host "  Collisions:       $($collisions.Count)" -ForegroundColor DarkGray }
if ($done.Count)       { Write-Host "  Undo with: sortdl -Undo" -ForegroundColor DarkGray }
