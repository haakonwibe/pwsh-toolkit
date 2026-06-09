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

function docs {
    <#
    .SYNOPSIS
        Jump to your OneDrive Documents folder.
    #>
    Set-Location (Join-Path $script:OneDrivePath 'Documents')
}
function desktop {
    <#
    .SYNOPSIS
        Jump to your OneDrive Desktop folder.
    #>
    Set-Location (Join-Path $script:OneDrivePath 'Desktop')
}
function downloads {
    <#
    .SYNOPSIS
        Jump to your Downloads folder.
    #>
    Set-Location (Join-Path $env:USERPROFILE 'Downloads')
}
function onedrive {
    <#
    .SYNOPSIS
        Jump to your OneDrive root.
    #>
    Set-Location $script:OneDrivePath
}
function home {
    <#
    .SYNOPSIS
        Jump to your user-profile folder.
    #>
    Set-Location $env:USERPROFILE
}

function mkcd {
    <#
    .SYNOPSIS
        Create a directory (and any missing parents) and change into it.
    .PARAMETER Path
        The directory to create and enter.
    .EXAMPLE
        mkcd src\feature\widget

        Creates src\feature\widget (including the src and feature folders if they
        don't exist yet) and changes into it — the common "make a folder and start
        working in it" step in one move.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string] $Path)
    $dir = New-Item -ItemType Directory -Path $Path -Force
    Set-Location -LiteralPath $dir.FullName
}

function up {
    <#
    .SYNOPSIS
        Move up one or more parent directories.
    .PARAMETER Levels
        How many directories to ascend (default 1).
    .EXAMPLE
        up

        Goes up one directory — same as `cd ..`, but `..`/`...` shortcuts exist too.
    .EXAMPLE
        up 3

        Goes up three directories at once (..\..\..) without typing each level.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][int] $Levels = 1)
    if ($Levels -lt 1) { $Levels = 1 }
    $target = (@('..') * $Levels) -join [IO.Path]::DirectorySeparatorChar
    Set-Location $target
}

function .. {
    <#
    .SYNOPSIS
        Go up one directory.
    #>
    up 1
}

function ... {
    <#
    .SYNOPSIS
        Go up two directories.
    #>
    up 2
}

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
    <#
    .SYNOPSIS
        Jump back to the previous location (browser-style history).
    .DESCRIPTION
        Pops the last location pushed by `j` or `jb`/`jf` and returns there.
        Pairs with `jf` to go forward again. History is per-session.
    #>
    if ($script:JumpBack.Count -eq 0) {
        Write-Host '  No back history.' -ForegroundColor DarkGray
        return
    }
    $script:JumpForward.Push((Get-Location).Path)
    Set-Location -LiteralPath ($script:JumpBack.Pop())
}

function jf {
    <#
    .SYNOPSIS
        Jump forward again after `jb` (browser-style history).
    #>
    if ($script:JumpForward.Count -eq 0) {
        Write-Host '  No forward history.' -ForegroundColor DarkGray
        return
    }
    $script:JumpBack.Push((Get-Location).Path)
    Set-Location -LiteralPath ($script:JumpForward.Pop())
}

function j {
    <#
    .SYNOPSIS
        Jump to a bookmarked folder — interactive picker, or direct by name.
    .DESCRIPTION
        With no argument, opens an interactive picker over the configured jump
        destinations (digits 1-9 jump instantly; Up/Down + Enter; Esc cancels),
        rendered on the alternate screen buffer so scrollback is preserved.
        With an argument, jumps directly: first by case-insensitive substring
        match against bookmark labels/paths, then falling back to treating the
        argument as a literal directory path. Integrates with `jb`/`jf` history.
    .PARAMETER Match
        Optional substring (label or path) or a literal directory to jump to.
    .EXAMPLE
        j

        Opens the interactive picker over your bookmarked folders — arrow keys or
        the single-key labels to choose, Enter to jump.
    .EXAMPLE
        j down

        Skips the picker and jumps straight to the first bookmark (or path)
        matching "down" — e.g. Downloads. A minimal unique prefix is enough.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string] $Match)

    $items = @($script:JumpFolders)

    if ($Match) {
        # 1) Try the configured bookmark list first — fuzzy match against label or path.
        $hit = $items | Where-Object { $_.Label -like "*$Match*" -or $_.Path -like "*$Match*" } | Select-Object -First 1
        if ($hit) { Invoke-JumpTo -Path $hit.Path; return }

        # 2) No bookmark match — try the argument as a literal directory path.
        #    -PathType Container ensures files don't sneak through and trip
        #    Set-Location (which only accepts containers).
        if (Test-Path -LiteralPath $Match -PathType Container) {
            Invoke-JumpTo -Path $Match
            return
        }

        # 3) Neither — give a clear "what we tried" message.
        Write-Host "  No jump destination matching '$Match' and no such directory exists." -ForegroundColor Yellow
        return
    }

    # No-arg path: picker needs at least one bookmark.
    if ($items.Count -eq 0) {
        Write-Host '  No jump destinations configured.' -ForegroundColor Yellow
        return
    }

    # Interactive picker via the shared scrollable Show-Picker. GetNewClosure
    # captures $labelWidth so the render scriptblock keeps it across the call.
    $labelWidth = ($items | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
    $render = {
        param($f)
        "{0}  {1}" -f $f.Label.PadRight($labelWidth), $f.Path
    }.GetNewClosure()

    $selected = Show-Picker -Items $items -RenderRow $render `
        -Title 'Jump' -Hint 'Up/Down + Enter  PgUp/PgDn  Esc cancel  |  j <text> jumps directly'

    if ($selected) { Invoke-JumpTo -Path $selected.Path }
}
