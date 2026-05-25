# Navigation Shortcuts
# Quick directory navigation functions
#
# OneDrive org and extra jump destinations come from $script:Config (set by
# the loader from config.psd1). Per-machine tweaks belong in
# Machines/<COMPUTERNAME>.ps1 — see Machines/README.md for examples.

# OneDrive base path. $script:Config.OneDriveOrg can be:
#   ''        → personal OneDrive (no " - Org" suffix)
#   'Name'    → "$env:USERPROFILE\OneDrive - Name"
$script:OneDriveOrg  = if ($script:Config) { [string]$script:Config.OneDriveOrg } else { '' }
$script:OneDrivePath = if ($script:OneDriveOrg) {
    Join-Path $env:USERPROFILE "OneDrive - $script:OneDriveOrg"
} else {
    Join-Path $env:USERPROFILE 'OneDrive'
}

function docs      { Set-Location (Join-Path $script:OneDrivePath 'Documents') }
function desktop   { Set-Location (Join-Path $script:OneDrivePath 'Desktop') }
function downloads { Set-Location (Join-Path $env:USERPROFILE 'Downloads') }
function onedrive  { Set-Location $script:OneDrivePath }
function home      { Set-Location $env:USERPROFILE }

# ============================================================================
# Folder jumper: `j`, `jb`, `jf`
# ============================================================================
# `j`        - picker (digits 1-9 instant, Up/Down + Enter, Esc cancel)
# `j name`   - direct jump by partial label/path match (case-insensitive)
# `jb`       - back to previous location (browser-style history)
# `jf`       - forward after going back
#
# Built-in starter destinations below. Add more in config.psd1's
# ExtraJumpFolders, or for complex/conditional setup append in
# Machines/<COMPUTERNAME>.ps1:
#   $script:JumpFolders += [pscustomobject]@{ Label='VMs'; Path='D:\VMs' }

$script:JumpFolders = @(
    [pscustomobject]@{ Label = 'Home';         Path = $env:USERPROFILE }
    [pscustomobject]@{ Label = 'Downloads';    Path = "$env:USERPROFILE\Downloads" }
    [pscustomobject]@{ Label = 'OneDrive';     Path = $script:OneDrivePath }
    [pscustomobject]@{ Label = 'LocalAppData'; Path = $env:LOCALAPPDATA }
    [pscustomobject]@{ Label = 'ProgramData';  Path = $env:ProgramData }
)

# Append user-defined destinations from config.psd1's ExtraJumpFolders array.
# Each entry is a hashtable with Label and Path keys.
if ($script:Config -and $script:Config.ExtraJumpFolders) {
    foreach ($e in $script:Config.ExtraJumpFolders) {
        if ($e.Label -and $e.Path) {
            $script:JumpFolders += [pscustomobject]@{ Label = $e.Label; Path = $e.Path }
        }
    }
}

# Per-session navigation history. Reset on profile reload (acceptable).
$script:JumpBack    = New-Object 'System.Collections.Generic.Stack[string]'
$script:JumpForward = New-Object 'System.Collections.Generic.Stack[string]'

function Invoke-JumpTo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  Path does not exist: $Path" -ForegroundColor Yellow
        return
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $current  = (Get-Location).Path
    if ($current -ne $resolved) {
        $script:JumpBack.Push($current)
        $script:JumpForward.Clear()
    }
    Set-Location -LiteralPath $resolved
}

function jb {
    if ($script:JumpBack.Count -eq 0) {
        Write-Host '  No back history.' -ForegroundColor DarkGray
        return
    }
    $script:JumpForward.Push((Get-Location).Path)
    Set-Location -LiteralPath ($script:JumpBack.Pop())
}

function jf {
    if ($script:JumpForward.Count -eq 0) {
        Write-Host '  No forward history.' -ForegroundColor DarkGray
        return
    }
    $script:JumpBack.Push((Get-Location).Path)
    Set-Location -LiteralPath ($script:JumpForward.Pop())
}

function j {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string] $Match)

    $items = @($script:JumpFolders)
    if ($items.Count -eq 0) {
        Write-Host '  No jump destinations configured.' -ForegroundColor Yellow
        return
    }

    if ($Match) {
        $hit = $items | Where-Object { $_.Label -like "*$Match*" -or $_.Path -like "*$Match*" } | Select-Object -First 1
        if ($hit) { Invoke-JumpTo -Path $hit.Path; return }
        Write-Host "  No jump destination matching '$Match'." -ForegroundColor Yellow
        return
    }

    # Pre-compute column widths once.
    $labelWidth = ($items | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
    $cursor   = 0
    $selected = $null

    # Use the terminal's alternate screen buffer so the picker doesn't trash
    # scrollback. On exit, the prior screen (and scrollback) is restored
    # intact — same trick less/vim/fzf use.
    $esc = [char]27
    [Console]::Write("$esc[?1049h")
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            [Console]::SetCursorPosition(0, 0)
            Write-Host '  Jump' -ForegroundColor Cyan
            Write-Host '  Digits 1-9 jump  Up/Down + Enter  Esc cancel  |  Tip: j <text> jumps directly' -ForegroundColor DarkGray
            Write-Host ''

            $winW = [Math]::Max(20, [Console]::WindowWidth - 1)
            for ($i = 0; $i -lt $items.Count; $i++) {
                $isCursor = ($i -eq $cursor)
                $marker   = if ($isCursor) { '>' } else { ' ' }
                $numKey   = if ($i -lt 9) { ($i + 1).ToString() } else { ' ' }
                $line     = "  {0} {1}  {2}  {3}" -f $marker, $numKey, $items[$i].Label.PadRight($labelWidth), $items[$i].Path
                if ($line.Length -gt $winW) { $line = $line.Substring(0, $winW) }
                $line = $line.PadRight($winW)
                if ($isCursor) {
                    Write-Host $line -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    Write-Host $line
                }
            }

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($cursor -gt 0)              { $cursor-- }; continue }
                'DownArrow' { if ($cursor -lt $items.Count-1) { $cursor++ }; continue }
                'Home'      { $cursor = 0; continue }
                'End'       { $cursor = $items.Count - 1; continue }
                'Enter'     { $selected = $items[$cursor]; break }
                'Escape'    { break }
            }
            if ($selected -or $key.Key -eq 'Enter' -or $key.Key -eq 'Escape') { break }

            # Digit shortcut (1-9 → instant jump).
            if ($key.KeyChar -ge '1' -and $key.KeyChar -le '9') {
                $idx = [int][string]$key.KeyChar - 1
                if ($idx -lt $items.Count) { $selected = $items[$idx]; break }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
        [Console]::Write("$esc[?1049l")
    }

    if ($selected) { Invoke-JumpTo -Path $selected.Path }
}
