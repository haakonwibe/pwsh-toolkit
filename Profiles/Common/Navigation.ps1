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
    Set-Location -LiteralPath (Join-Path $script:OneDrivePath 'Documents')
}
function desktop {
    <#
    .SYNOPSIS
        Jump to your OneDrive Desktop folder.
    #>
    Set-Location -LiteralPath (Join-Path $script:OneDrivePath 'Desktop')
}
function downloads {
    <#
    .SYNOPSIS
        Jump to your Downloads folder.
    #>
    Set-Location -LiteralPath (Join-Path $env:USERPROFILE 'Downloads')
}
function onedrive {
    <#
    .SYNOPSIS
        Jump to your OneDrive root.
    #>
    Set-Location -LiteralPath $script:OneDrivePath
}
function home {
    <#
    .SYNOPSIS
        Jump to your user-profile folder.
    #>
    Set-Location -LiteralPath $env:USERPROFILE
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
    Set-Location -LiteralPath $target
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
# `j`         - picker (digits 1-9 instant, Up/Down + Enter, Esc cancel)
# `j name`    - direct jump by partial label/path match (case-insensitive)
# `j -Add`    - bookmark the current dir (or `j -Add <path>`; -Label to name it)
# `j -Remove` - drop a bookmark you added, by label
# `jb`        - back to previous location (browser-style history)
# `jf`        - forward after going back
#
# Destinations come from three sources, appended in this order:
#   1. Built-in starters (below).
#   2. config.psd1's ExtraJumpFolders (literals) and, for anything needing
#      evaluation, Machines/<COMPUTERNAME>.ps1:
#        $script:JumpFolders += [pscustomobject]@{ Label='VMs'; Path='D:\VMs' }
#   3. Bookmarks you add live with `j -Add` — persisted as JSON under
#      %LOCALAPPDATA%\pwsh-toolkit and tagged Source='user', so `j -Remove` can
#      manage them without touching the built-ins or your config. The LOADER
#      appends these (Sync-JumpBookmark), after Machines/ and Hosts/ files have
#      run — bookmarks always sit at the END of the list, so first-match lookup
#      (`j <text>`) can never be shadowed-FROM by a bookmark, only shadowed-TO.

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

# ============================================================================
# User bookmarks: `j -Add` / `j -Remove`
# ============================================================================
# A self-service favorites list so you never have to hand-edit config.psd1 or a
# machine file just to remember a folder. Stored as JSON (not PowerShell) so it's
# safe to rewrite from code, under %LOCALAPPDATA% alongside the other per-machine
# toolkit state (the PoshThemes cache) rather than in the repo tree.
$script:JumpBookmarkFile = Join-Path $env:LOCALAPPDATA 'pwsh-toolkit\jump-bookmarks.json'

function Get-JumpBookmark {
    # Read the saved bookmarks. A missing, empty, or corrupt file yields an empty
    # list and never throws — a bad file must not break profile load or `j`.
    # Exception: -ThrowOnError, for callers about to REWRITE the store (j -Add).
    # There a failed read must abort the operation instead of masquerading as an
    # empty list, or the save would clobber every bookmark the file still holds.
    param([switch] $ThrowOnError)
    if (-not (Test-Path -LiteralPath $script:JumpBookmarkFile)) { return @() }
    try {
        $raw = Get-Content -Raw -LiteralPath $script:JumpBookmarkFile -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        if ($ThrowOnError) { throw }
        Write-Warning "pwsh-toolkit: couldn't read jump bookmarks ($script:JumpBookmarkFile): $($_.Exception.Message)"
        return @()
    }
    @($data) |
        Where-Object { $_ -and $_.Label -and $_.Path } |
        ForEach-Object { [pscustomobject]@{ Label = [string]$_.Label; Path = [string]$_.Path } }
}

function Save-JumpBookmark {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Bookmark)

    $dir = Split-Path -Parent $script:JumpBookmarkFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Normalize to plain Label/Path objects, then serialize as a JSON array.
    # -AsArray (piped, so it enumerates) keeps a single bookmark as a one-element
    # array; the empty case is written literally, because piping nothing to
    # ConvertTo-Json emits nothing and would leave the old file untouched (which
    # would silently resurrect the last bookmark you just removed).
    $clean = @($Bookmark | ForEach-Object { [pscustomobject]@{ Label = $_.Label; Path = $_.Path } })
    $json  = if ($clean.Count -eq 0) { '[]' } else { $clean | ConvertTo-Json -Depth 3 -AsArray }
    Set-Content -LiteralPath $script:JumpBookmarkFile -Value $json -Encoding utf8
}

function Sync-JumpBookmark {
    # Rebuild the user-bookmark slice of the live jump list — from the store
    # file, or from -Bookmark when the caller already holds the list (add/remove
    # just wrote it; re-reading the file would be a wasted read and a window for
    # divergence). Idempotent: drops any existing Source='user' entries first,
    # and appends at the END so a bookmark never shadows a built-in/config/
    # machine destination in first-match lookup. Called by the LOADER after
    # Machines/ and Hosts/ files have appended their entries — deliberately not
    # at this file's dot-source time, both for that ordering and so loading this
    # file has no side effects (the unit tests dot-source it in-process).
    param([object[]] $Bookmark)
    if ($null -eq $Bookmark) { $Bookmark = @(Get-JumpBookmark) }
    $script:JumpFolders = @($script:JumpFolders | Where-Object { $_.Source -ne 'user' })
    foreach ($b in $Bookmark) {
        $script:JumpFolders += [pscustomobject]@{ Label = $b.Label; Path = $b.Path; Source = 'user' }
    }
}

function Add-JumpBookmark {
    param([string] $Path, [string] $Label)

    # Target: an explicit directory, or the current location. Either way, store
    # the PROVIDER path: (Get-Location).Path / (Resolve-Path).Path stay drive-
    # qualified for a mapped PSDrive (W:\proj), which dies with the session that
    # defined the drive — bookmarks must survive into shells that don't have it.
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Host "  Not a directory: $Path" -ForegroundColor Yellow
            return
        }
        $target = Resolve-Path -LiteralPath $Path
        if ($target.Provider.Name -ne 'FileSystem') {
            # Registry keys etc. are containers too — same rule as the branch below.
            Write-Host "  Not a file-system path: $Path — j bookmarks folders only." -ForegroundColor Yellow
            return
        }
        $resolved = $target.ProviderPath
    } else {
        $loc = Get-Location
        if ($loc.Provider.Name -ne 'FileSystem') {
            Write-Host '  Current location is not a file-system path — pass one: j -Add <dir>' -ForegroundColor Yellow
            return
        }
        $resolved = $loc.ProviderPath
    }

    # Default label: the leaf folder name, slash-trimmed so a drive root gives
    # 'C:' not 'C:\' (Split-Path -Leaf returns a root path unchanged).
    if (-not $Label) {
        $Label = (Split-Path -Leaf $resolved).TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($Label)) { $Label = $resolved.TrimEnd('\', '/') }
    }

    # Don't shadow a built-in/config/machine label: `j <label>` returns the first
    # match, so a duplicate user entry would be unreachable. Ask them to rename it.
    $clash = @($script:JumpFolders | Where-Object { $_.Source -ne 'user' -and $_.Label -ieq $Label })
    if ($clash) {
        Write-Host "  '$Label' already maps to $($clash[0].Path) (a built-in/config/machine destination) — name this one differently: j -Add '$resolved' -Label <name>" -ForegroundColor Yellow
        return
    }

    # Upsert by label (case-insensitive): re-adding a label repoints it. If the
    # store exists but can't be read, ABORT — saving over an unreadable file
    # would silently destroy every bookmark it still holds.
    try {
        $store = @(Get-JumpBookmark -ThrowOnError | Where-Object { $_.Label -ine $Label })
    } catch {
        Write-Host "  Couldn't read the bookmark store, so not overwriting it: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Fix or delete $script:JumpBookmarkFile and retry." -ForegroundColor Yellow
        return
    }
    $store += [pscustomobject]@{ Label = $Label; Path = $resolved }
    Save-JumpBookmark -Bookmark $store
    Sync-JumpBookmark -Bookmark $store
    Write-Host "  Bookmarked '$Label' -> $resolved" -ForegroundColor Green
}

function Remove-JumpBookmark {
    param([string] $Name)

    if (-not $Name) {
        Write-Host '  Which bookmark? Usage: j -Remove <label>   (list them with: j)' -ForegroundColor Yellow
        return
    }

    $store = @(Get-JumpBookmark)
    $hit   = @($store | Where-Object { $_.Label -ieq $Name })
    if (-not $hit) {
        $builtin = @($script:JumpFolders | Where-Object { $_.Source -ne 'user' -and $_.Label -ieq $Name })
        if ($builtin) {
            # Don't send them to config.psd1: the starters are hard-coded above.
            Write-Host "  '$Name' is a built-in/config/machine destination, not a bookmark — j -Remove only manages bookmarks added with j -Add." -ForegroundColor Yellow
        } else {
            Write-Host "  No bookmark labeled '$Name'." -ForegroundColor Yellow
        }
        return
    }

    $keep = @($store | Where-Object { $_.Label -ine $Name })
    Save-JumpBookmark -Bookmark $keep
    Sync-JumpBookmark -Bookmark $keep
    Write-Host "  Removed bookmark '$($hit[0].Label)'" -ForegroundColor Green
}

# NOTE: saved bookmarks are loaded by the LOADER calling Sync-JumpBookmark after
# Machines/ and Hosts/ files run — not here. See the Sync-JumpBookmark comment.

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
        Jump to a bookmarked folder — picker, direct by name, or manage bookmarks.
    .DESCRIPTION
        With no argument, opens an interactive picker over the configured jump
        destinations (digits 1-9 jump instantly; Up/Down + Enter; Esc cancels),
        rendered on the alternate screen buffer so scrollback is preserved.
        With an argument, jumps directly: first by case-insensitive substring
        match against bookmark labels/paths, then falling back to treating the
        argument as a literal directory path. Integrates with `jb`/`jf` history.

        Use -Add to bookmark a folder and -Remove to drop one. These persist to a
        JSON file under %LOCALAPPDATA%\pwsh-toolkit and survive restarts, so you
        never have to hand-edit config.psd1 or a machine file for a simple favorite.
    .PARAMETER Match
        Optional substring (label or path) or a literal directory to jump to.
    .PARAMETER Add
        Bookmark a folder — the current directory, or the one given as -Path.
    .PARAMETER Path
        With -Add, the directory to bookmark. Defaults to the current location.
    .PARAMETER Label
        With -Add, the name shown in the picker and matched by `j <label>`.
        Defaults to the target folder's leaf name.
    .PARAMETER Remove
        Remove a bookmark you added, identified by its label.
    .PARAMETER Name
        With -Remove, the label of the bookmark to drop.
    .EXAMPLE
        j

        Opens the interactive picker over your bookmarked folders — arrow keys or
        the single-key labels to choose, Enter to jump.
    .EXAMPLE
        j down

        Skips the picker and jumps straight to the first bookmark (or path)
        matching "down" — e.g. Downloads. A minimal unique prefix is enough.
    .EXAMPLE
        j -Add

        Bookmarks the current directory under its folder name, so the picker and
        `j <name>` can reach it from now on — no config editing.
    .EXAMPLE
        j -Add D:\VMs -Label vms

        Bookmarks D:\VMs as "vms". Later just: j vms.
    .EXAMPLE
        j -Remove vms

        Drops the "vms" bookmark.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Jump')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Jump')]
        [string] $Match,

        [Parameter(ParameterSetName = 'Add')]
        [switch] $Add,

        [Parameter(Position = 0, ParameterSetName = 'Add')]
        [string] $Path,

        [Parameter(ParameterSetName = 'Add')]
        [string] $Label,

        [Parameter(ParameterSetName = 'Remove')]
        [switch] $Remove,

        [Parameter(Position = 0, ParameterSetName = 'Remove')]
        [string] $Name
    )

    # Dispatch on the bound parameter set, not the switches alone: `j -Label x`
    # or `j -Path x` selects the Add set without -Add (and `j -Name x` the Remove
    # set without -Remove). The switches are deliberately NOT Mandatory — that
    # would stall those typos on a bare 'Add:' mandatory-parameter prompt — but
    # they still gate the action, so a typo gets usage help, never a write.
    if ($PSCmdlet.ParameterSetName -eq 'Add') {
        if (-not $Add) {
            Write-Host '  -Path/-Label go with -Add. Usage: j -Add [<path>] [-Label <name>]' -ForegroundColor Yellow
            return
        }
        Add-JumpBookmark -Path $Path -Label $Label
        return
    }
    if ($PSCmdlet.ParameterSetName -eq 'Remove') {
        if (-not $Remove) {
            Write-Host '  -Name goes with -Remove. Usage: j -Remove <label>' -ForegroundColor Yellow
            return
        }
        Remove-JumpBookmark -Name $Name
        return
    }

    $items = @($script:JumpFolders)

    if ($Match) {
        # 1) Try the configured bookmark list first — fuzzy match against label or path.
        #    Escape the input so wildcard metacharacters (an unbalanced '[' throws
        #    in -like) are matched literally instead of crashing the command.
        $safe = [WildcardPattern]::Escape($Match)
        $hit = $items | Where-Object { $_.Label -like "*$safe*" -or $_.Path -like "*$safe*" } | Select-Object -First 1
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
