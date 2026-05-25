# Archive peek: extract to a temp folder, jump in, examine, then `jb` or `peek -Clean`.
# WinRAR's CLI (Rar.exe) is RAR-only — for other formats we use 7-Zip when present,
# falling back to Expand-Archive for plain .zip if neither is installed.

$script:PeekRoot   = Join-Path $env:TEMP 'peek'
$script:PeekRarExe = $null
$script:Peek7zExe  = $null

function Get-PeekRarExe {
    if ($script:PeekRarExe -and (Test-Path -LiteralPath $script:PeekRarExe)) {
        return $script:PeekRarExe
    }
    foreach ($n in 'Rar.exe','UnRAR.exe') {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { $script:PeekRarExe = $c.Source; return $script:PeekRarExe }
    }
    foreach ($d in 'C:\Program Files\WinRAR','C:\Program Files (x86)\WinRAR') {
        foreach ($n in 'Rar.exe','UnRAR.exe') {
            $p = Join-Path $d $n
            if (Test-Path -LiteralPath $p) { $script:PeekRarExe = $p; return $script:PeekRarExe }
        }
    }
    return $null
}

function Get-Peek7zExe {
    if ($script:Peek7zExe -and (Test-Path -LiteralPath $script:Peek7zExe)) {
        return $script:Peek7zExe
    }
    $c = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($c) { $script:Peek7zExe = $c.Source; return $script:Peek7zExe }
    foreach ($p in 'C:\Program Files\7-Zip\7z.exe','C:\Program Files (x86)\7-Zip\7z.exe') {
        if (Test-Path -LiteralPath $p) { $script:Peek7zExe = $p; return $script:Peek7zExe }
    }
    return $null
}

# Pick the right tool for a given extension. WinRAR CLI only handles .rar;
# 7-Zip handles RAR + everything else; Expand-Archive is the last-resort fallback.
function Get-PeekTool {
    param([string] $Extension)
    $ext = $Extension.ToLower()
    $rar = Get-PeekRarExe
    $sz  = Get-Peek7zExe

    if ($ext -eq '.rar' -and $rar) { return @{ Kind = 'rar'; Exe = $rar } }
    if ($sz)                       { return @{ Kind = '7z';  Exe = $sz  } }
    if ($ext -eq '.rar' -and $sz)  { return @{ Kind = '7z';  Exe = $sz  } }
    if ($ext -eq '.zip')           { return @{ Kind = 'builtin-zip' } }
    return $null
}

function peek {
    [CmdletBinding(DefaultParameterSetName = 'Extract')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Extract')]
        [Parameter(Position = 0, ParameterSetName = 'List')]
        [string] $Archive,

        [Parameter(ParameterSetName = 'List')]   [switch] $List,
        [Parameter(ParameterSetName = 'Active')] [switch] $Active,
        [Parameter(ParameterSetName = 'Clean')]  [switch] $Clean
    )

    if ($Active) {
        if (-not (Test-Path -LiteralPath $script:PeekRoot)) {
            Write-Host '  No active peeks.' -ForegroundColor DarkGray
            return
        }
        Get-ChildItem -LiteralPath $script:PeekRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object @{ N = 'Name'; E = { $_.Name } },
                          @{ N = 'Size'; E = {
                                $b = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                                      Measure-Object Length -Sum).Sum
                                if ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
                                elseif ($b -ge 1KB) { '{0:N1} KB' -f ($b / 1KB) }
                                else { "$b B" }
                          } },
                          @{ N = 'Extracted'; E = { $_.LastWriteTime } },
                          @{ N = 'Path'; E = { $_.FullName } } |
            Format-Table -AutoSize
        return
    }

    if ($Clean) {
        if (-not (Test-Path -LiteralPath $script:PeekRoot)) {
            Write-Host '  Nothing to clean.' -ForegroundColor DarkGray
            return
        }
        $cur = (Get-Location).Path
        if ($cur -like "$script:PeekRoot*") {
            if ($script:JumpBack -and $script:JumpBack.Count -gt 0) { jb } else { home }
        }
        try {
            Remove-Item -LiteralPath $script:PeekRoot -Recurse -Force -ErrorAction Stop
            Write-Host "  Cleaned $script:PeekRoot" -ForegroundColor Green
        }
        catch {
            Write-Host "  Cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '  Some files may be locked. Close any handles and retry.' -ForegroundColor DarkGray
        }
        return
    }

    if (-not $Archive) {
        Write-Host '  Usage:' -ForegroundColor Cyan
        Write-Host '    peek <archive>       Extract to temp and jump there'
        Write-Host '    peek -List <archive> List contents without extracting'
        Write-Host '    peek -Active         Show currently extracted peeks'
        Write-Host '    peek -Clean          Wipe the peek temp tree'
        Write-Host '    jb                   Jump back to where you peeked from'
        return
    }

    if (-not (Test-Path -LiteralPath $Archive)) {
        Write-Host "  Archive not found: $Archive" -ForegroundColor Yellow
        return
    }
    $archivePath = (Resolve-Path -LiteralPath $Archive).Path
    $ext  = [IO.Path]::GetExtension($archivePath).ToLower()
    $tool = Get-PeekTool -Extension $ext

    if ($List) {
        if (-not $tool) {
            Write-Host "  No tool available to list '$ext'. Install WinRAR or run: winget install 7zip.7zip" -ForegroundColor Yellow
            return
        }
        switch ($tool.Kind) {
            'rar' { & $tool.Exe l -- $archivePath }
            '7z'  { & $tool.Exe l -- $archivePath }
            'builtin-zip' {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $z = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
                try {
                    $z.Entries |
                        Select-Object @{ N = 'Name'; E = { $_.FullName } },
                                      @{ N = 'Size'; E = { $_.Length } },
                                      @{ N = 'Modified'; E = { $_.LastWriteTime.LocalDateTime } } |
                        Format-Table -AutoSize
                }
                finally { $z.Dispose() }
            }
        }
        return
    }

    if (-not $tool) {
        Write-Host "  No archive tool available for '$ext'. Install WinRAR or run: winget install 7zip.7zip" -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path -LiteralPath $script:PeekRoot)) {
        New-Item -ItemType Directory -Path $script:PeekRoot -Force | Out-Null
    }
    $stem  = [IO.Path]::GetFileNameWithoutExtension($archivePath)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest  = Join-Path $script:PeekRoot "$stem-$stamp"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    Write-Host "  Extracting to: $dest  [via $($tool.Kind)]" -ForegroundColor DarkGray

    $ok = $false
    switch ($tool.Kind) {
        'rar' {
            # Rar's destination argument MUST end in a backslash, otherwise it's
            # parsed as a file-pattern filter.
            & $tool.Exe x -o+ -y -- $archivePath ($dest + [IO.Path]::DirectorySeparatorChar)
            $ok = ($LASTEXITCODE -eq 0)
        }
        '7z' {
            # 7z uses -o<dir> with NO space between switch and value.
            & $tool.Exe x -y "-o$dest" -- $archivePath
            $ok = ($LASTEXITCODE -eq 0)
        }
        'builtin-zip' {
            try {
                Expand-Archive -LiteralPath $archivePath -DestinationPath $dest -Force
                $ok = $true
            }
            catch {
                Write-Host "  Extract failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    if (-not $ok) {
        Write-Host "  Extract failed (exit code $LASTEXITCODE). Leaving $dest for inspection." -ForegroundColor Red
        return
    }

    # Polish: if the archive unpacked to a single top-level directory, jump
    # into that instead of leaving the user one cd short of the actual content.
    $entries = @(Get-ChildItem -LiteralPath $dest -Force)
    $target  = if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) { $entries[0].FullName } else { $dest }

    Write-Host '  Extracted. Jumping...' -ForegroundColor DarkGray
    Invoke-JumpTo -Path $target
}
