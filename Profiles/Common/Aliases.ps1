# Aliases and Quick Shortcuts
# Provides quick command aliases and helper functions for common operations

# Quick reference via ch.at API
function Ask-ChAt {
    <#
    .SYNOPSIS
        Ask the ch.at API a quick question from the terminal.
    .DESCRIPTION
        Sends a single prompt to the free ch.at chat-completions API and returns
        the trimmed text response. Has a 30-second timeout. Aliased as `ask`.
    .PARAMETER Question
        The question to ask.
    .PARAMETER Brief
        Append "Be brief." to the prompt to nudge a one-line answer.
    .EXAMPLE
        ask "regex to match an IPv4 address"

        Sends the question to ch.at and prints the answer inline — a quick
        reference lookup without leaving the terminal or opening a browser.
    .EXAMPLE
        ask -Brief "difference between WMI and CIM?"

        Same, but -Brief appends "Be brief." so you get a one-liner instead of
        a few paragraphs.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Public surface is the `ask` alias; renaming the backing function would churn muscle memory for no behavior gain. PSGallery publishing is v2.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Question,
        [switch]$Brief  # adds "Be brief." to the prompt
    )

    $payload = @{
        messages = @(
            @{ role = "user"; content = ($Brief ? "$Question (Be brief.)" : $Question) }
        )
    } | ConvertTo-Json -Depth 5

    try {
        $r = Invoke-RestMethod -Method Post `
            -Uri "https://ch.at/v1/chat/completions" `
            -ContentType "application/json" `
            -TimeoutSec 30 `
            -Body $payload
        $text = $r.choices[0].message.content
        if ($text) { return $text.Trim() }
        else { throw "Empty response." }
    }
    catch {
        throw "Ask-ChAt failed (API): $($_.Exception.Message)"
    }
}
Set-Alias ask Ask-ChAt

# Better ls with formatting. `ll` is a normal listing; `la` adds hidden/system
# entries. NOTE: -Force already includes hidden items — the previous `la` used
# `-Force -Hidden`, but -Hidden *filters to only* hidden entries, so it showed
# nothing in a normal directory. -Force alone is the "show everything" switch.
function ll {
    <#
    .SYNOPSIS
        List the current directory in a detailed table (like `ls -l`).
    .DESCRIPTION
        A plain `Get-ChildItem` in table form — normal (non-hidden) entries only.
        Use `la` to include hidden/system entries, or `lh` to see only those.
    .EXAMPLE
        ll

        Lists the visible files and folders in the current directory as a table.
    #>
    Get-ChildItem | Format-Table -AutoSize
}
function la {
    <#
    .SYNOPSIS
        List the current directory including hidden and system entries (like `ls -la`).
    .DESCRIPTION
        Like `ll`, but `-Force` so hidden and system entries are included alongside
        the normal ones. Use `lh` to see only the hidden/system entries.
    .EXAMPLE
        la

        Lists everything in the current directory — normal, hidden, and system.
    #>
    Get-ChildItem -Force | Format-Table -AutoSize
}
function lh {
    <#
    .SYNOPSIS
        List ONLY the hidden and system entries in the current directory.
    .DESCRIPTION
        The inverse of a normal listing: shows just the entries carrying the
        Hidden or System attribute (the ones `ll` omits and `la` mixes in),
        which is handy for spotting dotfiles, desktop.ini, $Recycle.Bin, etc.
    .EXAMPLE
        lh

        Lists only the hidden/system entries, filtering out the normal files —
        e.g. surfaces a stray .gitignore or desktop.ini without the noise.
    #>
    $mask = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    Get-ChildItem -Force | Where-Object { ($_.Attributes -band $mask) -ne 0 } | Format-Table -AutoSize
}

# Unix-style touch: create the file(s) if absent, otherwise bump the
# last-write/-access time WITHOUT destroying content. The old one-liner used
# `New-Item -ItemType File -Force`, which truncates an existing file to empty —
# a nasty surprise for `touch existing-notes.md`. It also passed the argument
# via -Name, which only accepts a leaf name, so any path with a separator
# (`touch src\foo.txt`) errored. Now uses -Path and accepts multiple targets.
function touch {
    <#
    .SYNOPSIS
        Create file(s), or bump the timestamp of existing ones — never truncates.
    .DESCRIPTION
        Unix-style touch. For each path: if it exists, updates the last-write and
        last-access times without altering content; if it doesn't, creates an
        empty file (along with any missing parent directories).
    .PARAMETER Path
        One or more file paths (relative or absolute).
    .EXAMPLE
        touch notes.md

        Creates notes.md if it doesn't exist; if it does, just bumps its
        timestamp — the content is left untouched (unlike New-Item -Force).
    .EXAMPLE
        touch src\a.cs src\b.cs README.md

        Touches several files at once, creating the src\ folder if it's missing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]] $Path)
    $now = Get-Date
    foreach ($p in $Path) {
        if (Test-Path -LiteralPath $p) {
            $item = Get-Item -LiteralPath $p
            $item.LastWriteTime  = $now
            $item.LastAccessTime = $now
        }
        else {
            # -Force here creates any missing parent directories; it can't
            # truncate because we've already established the file is absent.
            New-Item -ItemType File -Path $p -Force | Out-Null
        }
    }
}

# Unix-style which: print the path/definition backing a command. The old
# version emitted `Select-Object Source`, which renders a one-column table and
# is blank for aliases and functions (they have no .Source). This resolves
# aliases to their target and labels cmdlets/functions instead of going silent.
function which {
    <#
    .SYNOPSIS
        Show what backs a command: path, alias target, or kind.
    .DESCRIPTION
        Unix-style which. Prints the on-disk path for applications and scripts,
        resolves aliases through to the command they ultimately run, and labels
        cmdlets and functions. Prints a "not found" message for unknown names.
    .PARAMETER Command
        The command name to resolve.
    .EXAMPLE
        which pwsh

        Prints the full path to the pwsh executable that would run — the classic
        "where does this command live?" lookup.
    .EXAMPLE
        which ls

        Resolves the alias to its target and labels it, e.g.
        "ls -> Get-ChildItem  [cmdlet in Microsoft.PowerShell.Management]".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Command)

    # Describe a single resolved command: the on-disk path for apps/scripts,
    # or a name + kind label for cmdlets/functions (which have no file path).
    $describe = {
        param($x)
        switch ($x.CommandType) {
            'Application'    { $x.Source }                               # exe on PATH — the classic case
            'ExternalScript' { $x.Source }
            'Cmdlet'         { "$($x.Name)  [cmdlet in $($x.ModuleName)]" }
            'Function'       { "$($x.Name)  [function]" }
            default          { if ($x.Source) { $x.Source } else { $x.Name } }
        }
    }

    # Resolve via the parameter form inside try/catch. An invalid wildcard
    # pattern (e.g. the unbalanced bracket in `which 'no[such'`) throws during
    # pattern compilation, which -ErrorAction Ignore does NOT suppress — so the
    # catch turns it into a clean "not found" instead of a red error. A valid
    # wildcard still globs by design (`which Get-*` → first match).
    $resolve = {
        param([string] $n)
        try { Get-Command -Name $n -ErrorAction Ignore | Select-Object -First 1 }
        catch { $null }
    }

    $c = & $resolve $Command
    if (-not $c) {
        Write-Host "  which: '$Command' not found" -ForegroundColor Yellow
        return
    }

    if ($c.CommandType -eq 'Alias') {
        # Walk the alias chain to whatever ultimately runs, then describe that.
        # .ResolvedCommand is unreliable (can be $null depending on runspace
        # state), so fall back to re-resolving the .Definition target name.
        # Cap the hops so a circular alias (Set-Alias a b; Set-Alias b a) can't
        # spin forever — .Definition re-resolution removes the natural terminator.
        $r = $c
        $hops = 0
        while ($r -and $r.CommandType -eq 'Alias' -and $hops -lt 20) {
            $next = $r.ResolvedCommand
            if (-not $next -and $r.Definition) {
                $next = & $resolve $r.Definition
            }
            $r = $next
            $hops++
        }
        $tail = if ($r -and $r.CommandType -eq 'Alias') { '(circular)' }
                elseif ($r)                              { & $describe $r }
                else                                     { '(unresolved)' }
        "$($c.Name) -> $tail"
    }
    else {
        & $describe $c
    }
}

# Wrapper script paths are resolved from $script:Config.ToolkitRoot once at
# profile-load time and captured into $script: vars. Function bodies reference
# the captured paths so they don't need $PSScriptRoot (which is empty when a
# function body is evaluated interactively).
$script:WingetUpgradeScript   = Join-Path $script:Config.ToolkitRoot 'WingetUpgrade\Invoke-WingetUpgrade.ps1'
$script:DownloadsTagScript    = Join-Path $script:Config.ToolkitRoot 'DownloadsOrganizer\Invoke-DownloadsTag.ps1'
$script:DirDescriptionsScript = Join-Path $script:Config.ToolkitRoot 'DownloadsOrganizer\Get-DirDescriptions.ps1'

# Interactive winget upgrade picker (see WingetUpgrade/Invoke-WingetUpgrade.ps1)
function Invoke-WingetUpgradeMenu {
    <#
    .SYNOPSIS
        Interactive winget upgrade picker (alias: winup).
    .DESCRIPTION
        Runs the WingetUpgrade script: lists packages with an available upgrade,
        lets you pick which to install, then upgrades only those. Passes any extra
        arguments straight through to the script (e.g. -All, -IncludeUnknown,
        -InstallWinGetModule, -LogDirectory). With -Elevated, re-runs the script
        elevated via a real sudo so winget doesn't prompt for elevation per package
        — see the note below.
    .PARAMETER Elevated
        Run elevated. Re-launches the script through gsudo / Windows' built-in sudo
        if available (one UAC prompt up front, in the current window when sudo is in
        Inline mode), or in a new elevated window otherwise. NB: no real verb here,
        so $args still forwards -Name value pairs to the script unchanged.
    .EXAMPLE
        winup

        Opens the picker, choose packages, upgrades them (winget prompts to elevate
        per package as needed).
    .EXAMPLE
        winup -Elevated

        Same, but elevated up front — approve one UAC prompt and the upgrades run
        without winget re-prompting for each package.
    .EXAMPLE
        winup -Elevated -All

        Elevated, and -All skips the picker to upgrade everything. Extra args after
        -Elevated pass straight through to the script.
    #>
    param([switch] $Elevated)   # NOTE: no [CmdletBinding] — so unrecognized args still land in $args

    if ($Elevated) {
        # Re-run the SCRIPT elevated (it's self-contained). -NoProfile keeps the
        # elevated shell clean (no profile/tips reload); args after -File go to the
        # script. $args holds everything except -Elevated.
        $passthru = @('-NoProfile', '-File', $script:WingetUpgradeScript) + $args
        $exe = Get-SudoExe
        if ($exe) {
            & $exe pwsh @passthru
        } else {
            # No gsudo/native sudo available — fall back to a new elevated window
            # (-NoExit so the summary stays readable after it finishes).
            Start-Process pwsh -Verb RunAs -ArgumentList (@('-NoExit') + $passthru)
        }
        return
    }

    & $script:WingetUpgradeScript @args
}
Set-Alias winup Invoke-WingetUpgradeMenu

# Tag Downloads with FILE_ID.DIZ-style AI descriptions (see DownloadsOrganizer/)
function Invoke-DownloadsTagger {
    <#
    .SYNOPSIS
        Tag files in Downloads with FILE_ID.DIZ-style AI descriptions (alias: tagdl).
    #>
    & $script:DownloadsTagScript @args
}
Set-Alias tagdl Invoke-DownloadsTagger

# Load `dird` (dir-with-descriptions viewer). Skip silently if the toolkit
# layout doesn't include DownloadsOrganizer/ — the wrapper functions above
# will still error visibly on first call, which is the right signal.
if (Test-Path -LiteralPath $script:DirDescriptionsScript) {
    . $script:DirDescriptionsScript
}
