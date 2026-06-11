# Git project picker: `prj`
# ============================================================================
# `prj`            - interactive picker over git repos under your ProjectRoots
#                    (digits 1-9 instant, Up/Down + Enter, Esc cancel)
# `prj name`       - direct jump by case-insensitive name/path substring match
# `prj -Refresh`   - rescan the roots (the repo list is cached per session)
#
# Roots come from $script:Config.ProjectRoots; when unset it falls back to
# C:\GitHub if that exists. The current branch is read straight from each
# repo's .git/HEAD (a cheap file read — no `git` subprocess), so the picker
# stays fast. Selecting a repo cd's into it via Invoke-JumpTo, so jb/jf history
# works just like the folder jumper `j`.

$script:ProjectsCache = $null

function Get-ProjectRoot {
    # Configured roots, else a sensible default. Returns a (possibly empty) array.
    $roots = @($script:Config.ProjectRoots | Where-Object { $_ })
    if ($roots.Count -eq 0 -and (Test-Path -LiteralPath 'C:\GitHub')) {
        $roots = @('C:\GitHub')
    }
    return $roots
}

function Find-GitProject {
    # Scan the roots for git repositories (cached). Each result: { Label; Path; Branch }.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Emits pscustomobject items; the analyzer infers the @()-wrapped return as Object[] and cannot see through it.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch] $Refresh)

    if ($script:ProjectsCache -and -not $Refresh) { return $script:ProjectsCache }

    $found = New-Object 'System.Collections.Generic.List[pscustomobject]'
    $seen  = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($root in (Get-ProjectRoot)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        # A repo is the parent of a `.git` directory. -Depth bounds the walk so a
        # deep tree (or node_modules) doesn't make the first call crawl; repos in
        # this layout live at root\[host\]org\repo (<= depth 4).
        Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 4 -Filter '.git' -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                $repo = $_.Parent
                if (-not $repo -or -not $seen.Add($repo.FullName)) { return }

                # Branch from .git/HEAD: "ref: refs/heads/<branch>" when on a
                # branch, or a raw SHA when detached. No git process needed.
                $branch   = ''
                $headFile = Join-Path $_.FullName 'HEAD'
                if (Test-Path -LiteralPath $headFile) {
                    $head = Get-Content -LiteralPath $headFile -TotalCount 1 -ErrorAction SilentlyContinue
                    if ($head -match 'ref:\s*refs/heads/(.+)$') { $branch = $Matches[1].Trim() }
                    elseif ($head) { $branch = $head.Trim().Substring(0, [Math]::Min(7, $head.Trim().Length)) }
                }

                $found.Add([pscustomobject]@{ Label = $repo.Name; Path = $repo.FullName; Branch = $branch })
            }
    }

    $script:ProjectsCache = @($found | Sort-Object Label)
    return $script:ProjectsCache
}

function prj {
    <#
    .SYNOPSIS
        Jump to a git repository — interactive picker, or direct by name.
    .DESCRIPTION
        Scans the git repositories under your configured ProjectRoots (set in
        config.psd1; defaults to C:\GitHub) and jumps into one. With no argument
        it opens a picker (digits 1-9 jump instantly, Up/Down + Enter, Esc
        cancels), rendered on the alternate screen buffer so scrollback is
        preserved. With an argument it jumps directly by case-insensitive
        name/path substring match. The repo list is cached for the session —
        pass -Refresh after cloning new repos. Integrates with jb/jf history.
    .PARAMETER Match
        Repo name/path substring to jump to directly.
    .PARAMETER Refresh
        Rescan the project roots, ignoring the cached list.
    .EXAMPLE
        prj

        Opens the scrollable picker over every git repo under your ProjectRoots,
        each with its current branch; pick one and it cd's you in.
    .EXAMPLE
        prj toolkit

        Skips the picker and jumps straight to the first repo whose name or path
        contains "toolkit".
    .EXAMPLE
        prj -Refresh

        Rescans the roots before showing the picker — run this after cloning a
        new repo, since the list is cached for the session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string] $Match,
        [switch] $Refresh
    )

    $projects = @(Find-GitProject -Refresh:$Refresh)

    if ($projects.Count -eq 0) {
        Write-Host ''
        Write-Host '  No git repositories found.' -ForegroundColor Yellow
        $roots = Get-ProjectRoot
        if ($roots.Count -eq 0) {
            Write-Host '  Set ProjectRoots in Profiles/config.psd1, e.g.:' -ForegroundColor DarkGray
            Write-Host "      ProjectRoots = @('C:\GitHub', 'D:\src')" -ForegroundColor DarkGray
        } else {
            Write-Host "  Searched: $($roots -join ', ')" -ForegroundColor DarkGray
            Write-Host '  (Run prj -Refresh after cloning new repos.)' -ForegroundColor DarkGray
        }
        Write-Host ''
        return
    }

    if ($Match) {
        # Escaped so wildcard metacharacters in the input match literally
        # instead of throwing (e.g. an unbalanced '[').
        $safe = [WildcardPattern]::Escape($Match)
        $hit = $projects | Where-Object { $_.Label -like "*$safe*" -or $_.Path -like "*$safe*" } | Select-Object -First 1
        if ($hit) { Invoke-JumpTo -Path $hit.Path; return }
        Write-Host "  No project matching '$Match'." -ForegroundColor Yellow
        return
    }

    # Interactive picker via the shared scrollable Show-Picker. The label column
    # is padded to a common width; GetNewClosure captures $labelWidth so the
    # render scriptblock keeps it when Show-Picker invokes it.
    $labelWidth = ($projects | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
    # Show-Picker truncates the full line to the window width, so the row body
    # doesn't need the width arg it's passed (it lands in $args, ignored).
    $render = {
        param($p)
        $branch = if ($p.Branch) { "  ($($p.Branch))" } else { '' }
        "{0}{1}  {2}" -f $p.Label.PadRight($labelWidth), $branch, $p.Path
    }.GetNewClosure()

    $selected = Show-Picker -Items $projects -RenderRow $render `
        -Title 'Projects' -Hint 'Up/Down + Enter  PgUp/PgDn  Esc cancel  |  prj <text> jumps directly'

    if ($selected) { Invoke-JumpTo -Path $selected.Path }
}
