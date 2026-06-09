#Requires -Version 7.0
<#
.SYNOPSIS
    Tag files in a directory with FILE_ID.DIZ-style AI descriptions.

.DESCRIPTION
    Walks a directory (default: ~\Downloads), samples each file's metadata and
    a small content snippet, asks Claude Haiku for a one-line description and
    a sub-bucket suggestion, then writes:
      - The description into the file's NTFS Alternate Data Stream "description"
      - A row in <Path>\_downloads-index.csv as a portable audit copy

    No files are moved or renamed. Re-runs are cheap: results are cached in
    %LOCALAPPDATA%\DownloadsOrganizer\cache.json keyed by (name, size, mtime).

    Inspired by 4DOS / FILE_ID.DIZ. View descriptions afterwards with the
    `dird` function (see DownloadsOrganizer\Get-DirDescriptions.ps1).

.PARAMETER Path
    Directory to scan. Defaults to "$HOME\Downloads".

.PARAMETER Limit
    Process at most N files (for testing). 0 = no limit.

.PARAMETER Force
    Re-tag files even if a cached description exists.

.PARAMETER Model
    Claude model to use. Defaults to claude-haiku-4-5.

.PARAMETER SkipPattern
    Filename patterns to skip entirely (no API call, no ADS write). Defaults
    include common sensitive markers (tax, passport, .env, etc.).

.PARAMETER WhatIf
    Show which files would be tagged without calling the API or writing ADS.

.EXAMPLE
    .\Invoke-DownloadsTag.ps1
    Tag everything new under ~\Downloads.

.EXAMPLE
    .\Invoke-DownloadsTag.ps1 -Limit 10 -WhatIf
    Show the next 10 files that would be tagged.

.EXAMPLE
    .\Invoke-DownloadsTag.ps1 -Force -Path D:\Inbox
    Re-tag everything under D:\Inbox.
#>
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SkipPattern', Justification = 'Used in the skip-filter loop further down the script; the analyzer misses the cross-scope reference.')]
param(
    [string] $Path = (Join-Path $HOME 'Downloads'),
    [int]    $Limit = 0,
    [switch] $Force,
    [string] $Model = 'claude-haiku-4-5',
    [string[]] $SkipPattern = @(
        '*tax*', '*passport*', '*ssn*', '*credit*card*',
        '*.env', '*.pem', '*.key', '*secret*', '*password*'
    ),

    # Repair mode: walk the cache, restore LastWriteTime on files whose ADS
    # write stomped their original timestamp. Matches by (name, size); size
    # must equal the cached size to be safe. Skips real tagging.
    [switch] $RestoreTimestamps
)

$ErrorActionPreference = 'Stop'

# ---------- Constants ----------
$ApiUrl       = 'https://api.anthropic.com/v1/messages'
$ApiVersion   = '2023-06-01'
$CacheDir     = Join-Path $env:LOCALAPPDATA 'DownloadsOrganizer'
$CacheFile    = Join-Path $CacheDir 'cache.json'
$MaxSampleBytes = 4096
$TextExtensions = @(
    '.txt', '.md', '.markdown', '.csv', '.tsv', '.json', '.jsonl',
    '.log', '.ini', '.cfg', '.conf', '.yaml', '.yml', '.xml', '.html',
    '.htm', '.ps1', '.psm1', '.py', '.js', '.ts', '.jsx', '.tsx',
    '.cs', '.go', '.rs', '.java', '.kt', '.rb', '.sh', '.bash',
    '.sql', '.toml', '.gitignore', '.gitattributes'
)
$ZipBasedExtensions = @('.zip', '.docx', '.xlsx', '.pptx', '.jar', '.apk')

# ---------- Pre-flight ----------
if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Error "Path not found or not a directory: $Path"
    exit 1
}
$Path = (Resolve-Path -LiteralPath $Path).Path

if (-not (Test-Path -LiteralPath $CacheDir)) {
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
}

Write-Host ''
Write-Host '  Downloads Organizer (FILE_ID.DIZ revival)' -ForegroundColor Cyan
Write-Host '  -----------------------------------------' -ForegroundColor Cyan
Write-Host "  Path:   $Path" -ForegroundColor Gray
Write-Host "  Model:  $Model" -ForegroundColor Gray
if ($WhatIfPreference) { Write-Host '  Mode:   DRY RUN (no API calls, no writes)' -ForegroundColor Yellow }

# ---------- Cache ----------
$cache = @{}
if (Test-Path -LiteralPath $CacheFile) {
    try {
        $raw = Get-Content -LiteralPath $CacheFile -Raw -Encoding utf8
        $obj = $raw | ConvertFrom-Json -AsHashtable
        if ($obj) { $cache = $obj }
    }
    catch {
        Write-Warning "Failed to load cache, starting fresh: $_"
    }
}

function Save-Cache {
    param($Cache)
    ($Cache | ConvertTo-Json -Depth 5 -Compress) |
        Set-Content -LiteralPath $CacheFile -Encoding utf8
}

# ---------- API key ----------
function Get-AnthropicKey {
    # Try SecretStore via Get-OrCreateSecret. If it throws (module missing,
    # vault registration broken, etc.), fall back to env var, then to an
    # interactive prompt — don't make a broken SecretStore block the script.
    $cmd = Get-Command Get-OrCreateSecret -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $key = Get-OrCreateSecret -Name 'Anthropic-API-Key' -AsPlainText -ErrorAction Stop
            if ($key) { return $key }
        }
        catch {
            Write-Host "  SecretStore unavailable ($($_.Exception.Message.Split([Environment]::NewLine)[0]))" -ForegroundColor Yellow
            Write-Host "  Falling back to `$env:ANTHROPIC_API_KEY / prompt" -ForegroundColor Yellow
        }
    }
    if ($env:ANTHROPIC_API_KEY) {
        return $env:ANTHROPIC_API_KEY
    }
    Write-Host "  Anthropic API key not found in SecretStore or `$env:ANTHROPIC_API_KEY." -ForegroundColor Yellow
    $secure = Read-Host -AsSecureString -Prompt '  Paste your Anthropic API key (for this run only)'
    if (-not $secure -or $secure.Length -eq 0) {
        throw 'No API key supplied.'
    }
    return [System.Net.NetworkCredential]::new('', $secure).Password
}

# ---------- File sampling ----------
function Get-FileSample {
    <#
        Returns a small, model-friendly text snapshot of a file:
        - Always: name, size, extension, modified-date
        - Text-like: first ~2000 chars of decoded content
        - ZIP/DOCX/XLSX/PPTX: top-level entry listing (up to ~30 entries)
        - PDF: any /Title found in the first 8KB
        - EXE/MSI: ProductName + FileDescription from VersionInfo
    #>
    param([System.IO.FileInfo] $File)

    $ext = $File.Extension.ToLowerInvariant()
    $lines = @(
        "Filename: $($File.Name)"
        "Size: $($File.Length) bytes"
        "Extension: $ext"
        "Modified: $($File.LastWriteTime.ToString('yyyy-MM-dd'))"
    )

    try {
        if ($TextExtensions -contains $ext) {
            # Read only the first MaxSampleBytes — never slurp the whole file.
            $fs = [System.IO.File]::OpenRead($File.FullName)
            try {
                $buf  = New-Object byte[] $MaxSampleBytes
                $read = $fs.Read($buf, 0, $MaxSampleBytes)
                $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
            }
            finally { $fs.Dispose() }
            if ($text.Length -gt 2000) { $text = $text.Substring(0, 2000) + '…' }
            $lines += 'Content (truncated):'
            $lines += $text
        }
        elseif ($ZipBasedExtensions -contains $ext) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = $null
            try {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($File.FullName)
                $entries = $zip.Entries | Select-Object -First 30 | ForEach-Object { $_.FullName }
                $lines += 'Archive entries (top 30):'
                $lines += ($entries -join "`n")

                # Try to read core.xml for Office docs
                if ($ext -in '.docx', '.xlsx', '.pptx') {
                    $core = $zip.Entries | Where-Object { $_.FullName -eq 'docProps/core.xml' } | Select-Object -First 1
                    if ($core) {
                        $reader = New-Object System.IO.StreamReader($core.Open())
                        try {
                            $coreXml = $reader.ReadToEnd()
                            if ($coreXml.Length -gt 1500) { $coreXml = $coreXml.Substring(0, 1500) }
                            $lines += 'docProps/core.xml:'
                            $lines += $coreXml
                        }
                        finally { $reader.Dispose() }
                    }
                }
            }
            finally { if ($zip) { $zip.Dispose() } }
        }
        elseif ($ext -eq '.pdf') {
            $fs = [System.IO.File]::OpenRead($File.FullName)
            try {
                $buf  = New-Object byte[] 8192
                $read = $fs.Read($buf, 0, 8192)
                $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
            }
            finally { $fs.Dispose() }
            $titleMatch = [regex]::Match($text, '/Title\s*\(([^)]{1,200})\)')
            if ($titleMatch.Success) { $lines += "PDF /Title: $($titleMatch.Groups[1].Value)" }
            $subjectMatch = [regex]::Match($text, '/Subject\s*\(([^)]{1,200})\)')
            if ($subjectMatch.Success) { $lines += "PDF /Subject: $($subjectMatch.Groups[1].Value)" }
            $authorMatch = [regex]::Match($text, '/Author\s*\(([^)]{1,200})\)')
            if ($authorMatch.Success) { $lines += "PDF /Author: $($authorMatch.Groups[1].Value)" }
        }
        elseif ($ext -in '.exe', '.msi', '.dll') {
            $vi = $File.VersionInfo
            if ($vi.ProductName)      { $lines += "ProductName: $($vi.ProductName)" }
            if ($vi.FileDescription)  { $lines += "FileDescription: $($vi.FileDescription)" }
            if ($vi.CompanyName)      { $lines += "CompanyName: $($vi.CompanyName)" }
            if ($vi.FileVersion)      { $lines += "FileVersion: $($vi.FileVersion)" }
        }
        elseif ($ext -in '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp') {
            # Filename + size is usually enough signal; dimensions need System.Drawing
            # which is unreliable cross-version. Skip for now.
            $lines += '(image — no content sample)'
        }
    }
    catch {
        $lines += "(sample failed: $($_.Exception.Message))"
    }

    return ($lines -join "`n")
}

# ---------- Anthropic call ----------
$SystemPrompt = @'
You generate FILE_ID.DIZ-style descriptions of files for a personal file
organizer. Given a file's name, metadata, and a small content sample,
return strict JSON with two fields:

  description : 100-300 character description, written like a 90s BBS
                FILE_ID.DIZ blurb — concrete, informative, multi-line in
                spirit. Include what the file is, version/edition if you
                can see it, what makes it specific (project name, vendor,
                purpose, key contents), and any notable details from the
                content sample. Skip filler like "this is a file that...".
                If the content is opaque, describe what you can see
                ("ZIP archive of Node project, package.json + src/, last
                modified March 2026"). No newlines in the value — keep it
                as one continuous string; the viewer wraps it.

  sub_bucket  : one of these labels, picked for "where would I file this?":
                Documents, Installers, Archives, Images, Code, Media, Data,
                Receipts, References, Tax, Other

No prose, no markdown, no explanation. Return only the JSON object.
'@

function Get-DescriptionFromClaude {
    param(
        [string] $Sample,
        [securestring] $ApiKeySecure
    )

    $body = @{
        model       = $Model
        max_tokens  = 500
        system      = $SystemPrompt
        messages    = @(
            @{ role = 'user'; content = $Sample }
        )
        output_config = @{
            format = @{
                type   = 'json_schema'
                schema = @{
                    type       = 'object'
                    properties = @{
                        description = @{ type = 'string' }
                        sub_bucket  = @{
                            type = 'string'
                            enum = @('Documents','Installers','Archives','Images','Code','Media','Data','Receipts','References','Tax','Other')
                        }
                    }
                    required             = @('description', 'sub_bucket')
                    additionalProperties = $false
                }
            }
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $key = ConvertFrom-SecureString -SecureString $ApiKeySecure -AsPlainText
    $headers = @{
        'x-api-key'         = $key
        'anthropic-version' = $ApiVersion
        'content-type'      = 'application/json'
    }

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $ApiUrl -Headers $headers -Body $body -TimeoutSec 60
    }
    catch {
        throw "API call failed: $($_.Exception.Message)"
    }

    # Response: { content: [ { type: "text", text: "<json>" } ], ... }
    $text = ($resp.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
    if (-not $text) { throw 'No text block in response' }

    try {
        $parsed = $text | ConvertFrom-Json
    }
    catch {
        throw "Response was not valid JSON: $text"
    }
    return [pscustomobject]@{
        Description = $parsed.description
        SubBucket   = $parsed.sub_bucket
        InputTokens = $resp.usage.input_tokens
        OutputTokens = $resp.usage.output_tokens
    }
}

# ---------- Helpers ----------
function Test-SkipFile {
    param([System.IO.FileInfo] $File)
    foreach ($pattern in $SkipPattern) {
        if ($File.Name -like $pattern) { return $true }
    }
    # Skip our own index/cache files
    if ($File.Name -eq '_downloads-index.csv') { return $true }
    if ($File.Name.StartsWith('.no-ai'))       { return $true }
    return $false
}

function Get-FileCacheKey {
    param([System.IO.FileInfo] $File)
    return "{0}|{1}|{2}" -f $File.FullName, $File.Length, $File.LastWriteTimeUtc.Ticks
}

function Write-Description {
    param(
        [System.IO.FileInfo] $File,
        [string] $Description
    )
    # NTFS quirk: writing any stream (default or alternate) bumps the file's
    # LastWriteTime. Capture timestamps before the write, restore after.
    $origCreate = $File.CreationTime
    $origWrite  = $File.LastWriteTime
    $origAccess = $File.LastAccessTime

    # ADS — survives moves within NTFS, lost on copy off-volume
    Set-Content -LiteralPath $File.FullName -Stream 'description' -Value $Description -Encoding utf8

    # Restore via static methods — the $File FileInfo object now holds stale state.
    try {
        [System.IO.File]::SetCreationTime($File.FullName, $origCreate)
        [System.IO.File]::SetLastWriteTime($File.FullName, $origWrite)
        [System.IO.File]::SetLastAccessTime($File.FullName, $origAccess)
    } catch {
        Write-Verbose "Failed to restore timestamps on $($File.Name): $($_.Exception.Message)"
    }
}

# ---------- Restore mode ----------
# Cache keys are "FullName|Length|LastWriteTimeUtc.Ticks" — the third field
# holds the original ticks from before the ADS write. We can recover the
# pre-stomp timestamp for every still-existing file whose size matches.
if ($RestoreTimestamps) {
    Write-Host ''
    Write-Host '  Restoring timestamps from cache' -ForegroundColor Cyan
    Write-Host '  -------------------------------' -ForegroundColor Cyan

    $restored = 0
    $missing  = 0
    $changed  = 0
    foreach ($key in $cache.Keys) {
        $parts = $key -split '\|', 3
        if ($parts.Count -ne 3) { continue }
        $cachedPath  = $parts[0]
        $cachedSize  = [long] $parts[1]
        $cachedTicks = [long] $parts[2]

        if (-not (Test-Path -LiteralPath $cachedPath)) {
            $missing++
            continue
        }
        $f = Get-Item -LiteralPath $cachedPath -Force
        if ($f.Length -ne $cachedSize) {
            Write-Host ("  SKIP    {0}  (size changed: {1} → {2})" -f $f.Name, $cachedSize, $f.Length) -ForegroundColor DarkYellow
            $changed++
            continue
        }

        $originalUtc = [DateTime]::new($cachedTicks, [DateTimeKind]::Utc)
        $originalLocal = $originalUtc.ToLocalTime()
        if ($WhatIfPreference) {
            Write-Host ("  WHATIF  {0}  {1} → {2}" -f $f.Name, $f.LastWriteTime, $originalLocal) -ForegroundColor Yellow
        }
        else {
            try {
                [System.IO.File]::SetLastWriteTime($cachedPath, $originalLocal)
                Write-Host ("  RESTORE {0}  → {1}" -f $f.Name, $originalLocal) -ForegroundColor Green
                $restored++
            }
            catch {
                Write-Host ("  FAIL    {0}  → {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor Red
            }
        }
    }

    Write-Host ''
    Write-Host "  Restored:      $restored" -ForegroundColor Gray
    Write-Host "  Size changed:  $changed   (skipped; file was modified after tagging)" -ForegroundColor Gray
    Write-Host "  Missing:       $missing   (file no longer at cached path)" -ForegroundColor Gray
    exit 0
}

# ---------- Main loop ----------
# Skip if a .no-ai marker is present at the directory root
if (Test-Path -LiteralPath (Join-Path $Path '.no-ai')) {
    Write-Host "  .no-ai marker present — skipping entire directory" -ForegroundColor Yellow
    exit 0
}

$files = Get-ChildItem -LiteralPath $Path -File | Sort-Object LastWriteTime -Descending
$total = $files.Count
Write-Host "  Found:  $total file(s)" -ForegroundColor Gray

if ($total -eq 0) { exit 0 }

$apiKeySecure = $null
$results = New-Object System.Collections.Generic.List[object]
$processed = 0
$tagged = 0
$skipped = 0
$cached = 0
$failed = 0

foreach ($file in $files) {
    if ($Limit -gt 0 -and $processed -ge $Limit) { break }
    $processed++

    Write-Progress -Activity 'Tagging files' -Status $file.Name `
        -PercentComplete ([math]::Min(100, [int](($processed / [math]::Max(1, [math]::Min($total, $Limit)) * 100))))

    if (Test-SkipFile -File $file) {
        Write-Host ("  SKIP  {0}" -f $file.Name) -ForegroundColor DarkGray
        $skipped++
        continue
    }

    $cacheKey = Get-FileCacheKey -File $file
    if (-not $Force -and $cache.ContainsKey($cacheKey)) {
        $cached_entry = $cache[$cacheKey]
        Write-Host ("  CACHE {0}  —  {1}" -f $file.Name, $cached_entry.Description) -ForegroundColor DarkCyan
        $results.Add([pscustomobject]@{
            Name        = $file.Name
            Description = $cached_entry.Description
            SubBucket   = $cached_entry.SubBucket
            TaggedAt    = $cached_entry.TaggedAt
        })
        $cached++
        continue
    }

    if ($WhatIfPreference) {
        Write-Host ("  WHATIF {0}" -f $file.Name) -ForegroundColor Yellow
        continue
    }

    # Lazy API key fetch — only if we'll actually call the API
    if (-not $apiKeySecure) {
        $plain = Get-AnthropicKey
        $apiKeySecure = ConvertTo-SecureString -String $plain -AsPlainText -Force
        $plain = $null
    }

    Write-Host ("  …     {0,-50}  sampling..." -f $file.Name) -ForegroundColor DarkGray -NoNewline
    $sampleSw = [System.Diagnostics.Stopwatch]::StartNew()
    $sample = Get-FileSample -File $file
    $sampleSw.Stop()
    Write-Host ("`r  …     {0,-50}  sample {1,4}ms  calling API..." -f $file.Name, $sampleSw.ElapsedMilliseconds) -ForegroundColor DarkGray -NoNewline

    $apiSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = Get-DescriptionFromClaude -Sample $sample -ApiKeySecure $apiKeySecure
    }
    catch {
        $apiSw.Stop()
        Write-Host ("`r  FAIL  {0,-50}  API {1,5}ms  —  {2}" -f $file.Name, $apiSw.ElapsedMilliseconds, $_.Exception.Message) -ForegroundColor Red
        $failed++
        continue
    }
    $apiSw.Stop()
    # Clear the in-progress line before printing the TAG line below
    Write-Host ("`r" + (' ' * 120) + "`r") -NoNewline

    $taggedAt = (Get-Date).ToString('o')
    try {
        Write-Description -File $file -Description $result.Description
    }
    catch {
        Write-Host ("  ADS-FAIL {0}  —  {1}" -f $file.Name, $_.Exception.Message) -ForegroundColor Red
        # Still record in cache + CSV — at least we have the description somewhere
    }

    $cache[$cacheKey] = @{
        Description = $result.Description
        SubBucket   = $result.SubBucket
        TaggedAt    = $taggedAt
    }
    $results.Add([pscustomobject]@{
        Name        = $file.Name
        Description = $result.Description
        SubBucket   = $result.SubBucket
        TaggedAt    = $taggedAt
    })
    $tagged++

    $color = switch ($result.SubBucket) {
        'Receipts'   { 'Green' }
        'Tax'        { 'Magenta' }
        'Installers' { 'Yellow' }
        'Code'       { 'Cyan' }
        default      { 'White' }
    }
    Write-Host ("  TAG   {0}  [{1}]  ({2}ms)  —  {3}" -f $file.Name, $result.SubBucket, $apiSw.ElapsedMilliseconds, $result.Description) -ForegroundColor $color

    # Persist cache every 10 files in case the run is interrupted
    if ($tagged % 10 -eq 0) { Save-Cache -Cache $cache }
}

Write-Progress -Activity 'Tagging files' -Completed

# Final cache write
Save-Cache -Cache $cache

# Write the index CSV (audit / portable copy)
if ($results.Count -gt 0 -and -not $WhatIfPreference) {
    $indexPath = Join-Path $Path '_downloads-index.csv'
    $results | Sort-Object SubBucket, Name | Export-Csv -LiteralPath $indexPath -NoTypeInformation -Encoding utf8
    Write-Host "`n  Index:  $indexPath" -ForegroundColor Gray
}

Write-Host ''
Write-Host '  Summary' -ForegroundColor Cyan
Write-Host '  -------' -ForegroundColor Cyan
Write-Host "  Tagged:  $tagged"
Write-Host "  Cached:  $cached"
Write-Host "  Skipped: $skipped"
Write-Host "  Failed:  $failed"
Write-Host ''
