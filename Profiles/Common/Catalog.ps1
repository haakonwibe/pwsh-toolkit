# Toolkit command catalog: `toolkit` (Show-Toolkit) and `Get-ToolkitCommand`.
# ============================================================================
# The toolkit dot-sources its functions into the session rather than shipping a
# module, so there's no `Get-Command -Module pwsh-toolkit`. These two commands
# fill that gap by discovering the toolkit's own commands from its source files
# (AST-parsed, so the list stays current as functions are added) and annotating
# each with its Get-Help synopsis:
#   `toolkit`              - a grouped, colored overview (the "what can I do?" view)
#   `Get-ToolkitCommand`   - the same data as objects (pipe/filter, Get-Command-style)
#   add -All to either to include the internal helper functions too.

# Source file basename -> friendly group name. Files not listed fall back to the
# basename; anything under M365/ is grouped as 'Microsoft 365'.
$script:ToolkitGroups = [ordered]@{
    'Aliases'             = 'Shell & quick commands'
    'Clipboard'           = 'Shell & quick commands'
    'Navigation'          = 'Navigation'
    'Recent'              = 'Navigation'
    'Projects'            = 'Git projects'
    'Peek'                = 'Archive peek'
    'Json'                = 'JSON'
    'SystemUtilities'     = 'System'
    'InstalledApps'       = 'Installed apps'
    'PwshUpdate'          = 'PowerShell 7 updater'
    'PoshThemes'          = 'Oh My Posh themes'
    'Terminal'            = 'Windows Terminal'
    'SecretManagement'    = 'Secrets'
    'RemoteServers'       = 'Remote servers'
    'ScheduledTasks'      = 'Scheduled tasks'
    'Notes'               = 'Notes / journal'
    'Wtf'                 = 'Explain errors'
    'How'                 = 'How-to lookup'
    'Get-DirDescriptions' = 'Downloads viewer'
    'Catalog'             = 'Discovery'
    'Tips'                = 'Discovery'
}

# Functions that exist only to support the public commands — hidden unless -All.
$script:ToolkitInternalCommands = @(
    'Invoke-JumpTo', 'Get-JumpStarter'
    'Get-JumpBookmark', 'Save-JumpBookmark', 'Sync-JumpBookmark', 'Add-JumpBookmark', 'Remove-JumpBookmark'
    'Get-MgGraphAllPage', 'Get-IntuneOverviewData', 'Get-ComplianceBucket', 'Get-DeviceSyncAge', 'ConvertTo-IntuneDashboardHtml', 'Show-IntuneDashboard'
    'Get-CompliancePctBucket', 'Get-DeviceKey', 'Get-DeviceComplianceReason'
    'ConvertTo-Win32RuleSummary', 'Resolve-MobileAppAssignmentTarget'
    'Get-HowSchema', 'Get-HowSystemPrompt', 'Format-HowCatalogEntry', 'Get-HowCandidate', 'Invoke-HowRequest', 'Get-HowApiKey', 'Get-HowCommand', 'Format-HowRow', 'Format-HowDetail', 'Out-HowCommand'
    'Get-ToolkitDataPath', 'ConvertTo-ProfileLoadSummary'
    'Get-RecentFile', 'Format-FileAge', 'Get-FileDizDescription'
    'Convert-SnippetDate', 'ConvertTo-SnippetStamp', 'Format-SnippetPreview', 'Get-ClipSnippet', 'Save-ClipSnippet', 'Limit-ClipSnippet', 'Add-ClipSnippet', 'Remove-ClipSnippet'
    'Get-PeekRarExe', 'Get-Peek7zExe', 'Get-PeekTool'
    'Test-NativeSudoEnabled', 'Get-SudoExe', 'Import-DeferredTerminalIcon'
    'Test-ArpEntryVisible', 'Split-UninstallCommand', 'Resolve-UninstallCommand'
    'Get-ProjectRoot', 'Find-GitProject'
    'Get-PickerScrollTop', 'Split-PickerDetail', 'Get-PickerHotkey', 'Get-PickerHotkeyIndex', 'Get-PickerPlainText', 'Show-Picker'
    'Get-PoshThemePool', 'Test-NerdFontInstalled'
    'Get-TerminalSettingsPath', 'Update-FontFaceText'
    'Test-RemoteServersConfigured', 'Invoke-RemoteServerPicker', 'Get-RemoteServerByMatch'
    'Resolve-RemoteServer', 'Format-RemoteServerDisplay', 'Format-PsRemotingError'
    'Get-PwshUpdateWarning', 'Get-PwshupInvocation', 'Read-PwshUpdateState'
    'Get-ObsidianVault', 'Resolve-NotesRoot', 'Get-NotesRoot', 'Get-NoteFile', 'ConvertTo-NotePlainLine', 'Get-NoteSummary', 'Show-NoteFile'
    'Test-SecretStoreInteractive'
    'Test-ScheduledTaskAvailable', 'Test-ToolkitTaskVisible', 'Format-TaskResult'
    'Get-ToolkitScheduledTask', 'Resolve-ScheduledTask', 'Invoke-ScheduledTaskAction', 'Show-ScheduledTaskDetail'
    'prompt'   # the prompt function itself, not a command you invoke
)
# `function script:Foo` is the author explicitly marking Foo private — those are
# always treated as internal (the `script:` ones in Get-DirDescriptions.ps1).

function Get-ToolkitCommand {
    <#
    .SYNOPSIS
        List the toolkit's commands (the Get-Command-for-this-toolkit).
    .DESCRIPTION
        Discovers the commands the toolkit defines by parsing its own source files
        and returns one object per command: the name you'd type (an alias when the
        backing function isn't meant to be called directly, e.g. `winup`), the
        group, the Get-Help synopsis, the backing function, and any aliases.
        Internal helper functions are hidden unless -All is given.
    .PARAMETER All
        Include internal helper functions, not just the public commands.
    .EXAMPLE
        Get-ToolkitCommand | Where-Object Group -eq 'Oh My Posh themes'

        List just the theme commands.
    .EXAMPLE
        Get-ToolkitCommand | Format-Table Command, Synopsis -AutoSize

        A flat table of every command and what it does.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch] $All)

    $root = $script:ProfileRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) {
        Write-Host '  Could not locate the toolkit Profiles folder ($script:ProfileRoot).' -ForegroundColor Yellow
        return
    }

    $files = @()
    $files += Get-ChildItem -Path (Join-Path $root 'Common\*.ps1') -ErrorAction Ignore
    # M365/*.ps1 are only dot-sourced when Microsoft.Graph is installed and
    # Features.DisableM365 is off (see the loader). Mirror what actually loaded —
    # Connect-Tenant (GraphConnection.ps1) is the sentinel — so `toolkit` never
    # advertises commands that would throw CommandNotFoundException.
    if (Test-Path -LiteralPath 'Function:\Connect-Tenant') {
        $files += Get-ChildItem -Path (Join-Path $root 'M365\*.ps1') -ErrorAction Ignore
    }
    if ($script:Config.ToolkitRoot) {
        $dird = Join-Path $script:Config.ToolkitRoot 'DownloadsOrganizer\Get-DirDescriptions.ps1'
        if (Test-Path -LiteralPath $dird) { $files += Get-Item -LiteralPath $dird }
    }

    # Map backing function -> the alias(es) defined for it.
    $aliasOf = @{}
    foreach ($f in $files) {
        foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $f.FullName),
                '(?m)^\s*Set-Alias\s+(?:-Name\s+)?(\S+)\s+(?:-Value\s+)?(\S+)')) {
            $target = $m.Groups[2].Value
            $aliasOf[$target] = @($aliasOf[$target]) + $m.Groups[1].Value | Where-Object { $_ }
        }
    }

    foreach ($f in $files) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)

        $group = if ($f.FullName -match '[\\/]M365[\\/]') { 'Microsoft 365' }
                 elseif ($script:ToolkitGroups.Contains($f.BaseName)) { $script:ToolkitGroups[$f.BaseName] }
                 else { $f.BaseName }

        foreach ($fn in $fns) {
            $name = $fn.Name
            if (-not $All -and ($name -like 'script:*' -or $name -in $script:ToolkitInternalCommands)) { continue }

            $aliases = @($aliasOf[$name] | Where-Object { $_ })
            # The name you'd type: prefer the alias when the function name is a
            # Verb-Noun wrapper users don't call directly (Ask-ChAt -> ask).
            $display = if ($name -match '-' -and $aliases.Count -gt 0) { $aliases[0] } else { $name }

            # Read .SYNOPSIS straight from the source comment-based help via the
            # AST — not Get-Help, which executes lookups, errors on some names,
            # and returns the wrong (proxied) help for the M365 cmdlet wrappers.
            $help = $fn.GetHelpContent()
            $syn  = if ($help -and $help.Synopsis) { $help.Synopsis.Trim() } else { '' }

            [pscustomobject]@{
                Command  = $display
                Group    = $group
                Synopsis = $syn
                Function = $name
                Alias    = ($aliases | Where-Object { $_ -ne $display }) -join ', '
            }
        }
    }
}

function Show-Toolkit {
    <#
    .SYNOPSIS
        Show all toolkit commands grouped by area (alias: toolkit).
    .DESCRIPTION
        A colored, grouped overview of everything the toolkit adds, each with a
        one-line synopsis — the "what can I do here?" reference. Add -All to
        include internal helper functions.
    .PARAMETER All
        Include internal helper functions.
    .EXAMPLE
        toolkit

        Print the grouped command catalog.
    #>
    [CmdletBinding()]
    param([switch] $All)

    $cmds = @(Get-ToolkitCommand -All:$All)
    if ($cmds.Count -eq 0) { return }

    # Preserve the $script:ToolkitGroups order, then any extras alphabetically.
    $order = @{}; $i = 0
    foreach ($g in $script:ToolkitGroups.Values) { if (-not $order.Contains($g)) { $order[$g] = $i++ } }
    $order['Microsoft 365'] = $i++

    Write-Host ''
    Write-Host '  pwsh-toolkit commands' -ForegroundColor Cyan
    Write-Host "  $($cmds.Count) commands — Get-Help <name> -Examples for details" -ForegroundColor DarkGray
    Write-Host ''

    $width = ($cmds.Command | Measure-Object -Maximum -Property Length).Maximum
    foreach ($grp in ($cmds | Group-Object Group | Sort-Object { if ($order.Contains($_.Name)) { $order[$_.Name] } else { 999 } }, Name)) {
        Write-Host "  $($grp.Name)" -ForegroundColor Yellow
        foreach ($c in ($grp.Group | Sort-Object Command)) {
            Write-Host ('    {0}  ' -f $c.Command.PadRight($width)) -NoNewline -ForegroundColor Green
            Write-Host $c.Synopsis -ForegroundColor Gray
        }
        Write-Host ''
    }

    # When M365/ was not loaded, say so instead of omitting the group.
    # Otherwise there is no way to discover that these commands exist or
    # what enables them.
    if (-not (Test-Path -LiteralPath 'Function:\Connect-Tenant')) {
        $hint = if ($script:Config.Features.DisableM365) { 'Features.DisableM365 is set in config.psd1' }
                else { 'Install-Module Microsoft.Graph to enable' }
        Write-Host '  Microsoft 365' -ForegroundColor Yellow
        Write-Host "    Not loaded ($hint). Provides Connect-Tenant, Get-TenantOverview, Get-TeamsInfo, Connect-Exchange." -ForegroundColor DarkGray
        Write-Host ''
    }
}
Set-Alias toolkit Show-Toolkit

function ConvertTo-ProfileLoadSummary {
    <#
    .SYNOPSIS
        Median time per profile-load step across several timed runs.
    .DESCRIPTION
        Takes one list of { Name; Ms } marks per run (the loader's
        $script:ProfileLoadTimings) and returns a row per step with its median
        milliseconds and its share of the median total, largest first. A run
        that lacks a step counts 0 for it. Pure, so the arithmetic is
        unit-testable without spawning shells.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object[]] $Run)

    $median = {
        param([double[]] $Values)
        $s = @($Values | Sort-Object)
        if ($s.Count -eq 0) { return 0 }
        if ($s.Count % 2) { return $s[[int][math]::Floor($s.Count / 2)] }
        ($s[$s.Count / 2 - 1] + $s[$s.Count / 2]) / 2
    }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $Run) { foreach ($m in $r) { if (-not $names.Contains($m.Name)) { $names.Add($m.Name) } } }
    $total = & $median @(foreach ($r in $Run) { ($r | Measure-Object -Property Ms -Sum).Sum })

    $rows = foreach ($n in $names) {
        $values = foreach ($r in $Run) { (@($r | Where-Object Name -eq $n) | Measure-Object -Property Ms -Sum).Sum }
        $ms = & $median @($values | ForEach-Object { [double]$_ })
        [pscustomobject]@{
            Name     = $n
            MedianMs = [math]::Round($ms, 1)
            Share    = $(if ($total) { [math]::Round($ms / $total, 3) } else { 0 })
        }
    }
    $rows | Sort-Object -Property MedianMs -Descending
}

function Measure-ProfileLoad {
    <#
    .SYNOPSIS
        Time the profile's own load, phase by phase and file by file.
    .DESCRIPTION
        Loads the profile in fresh pwsh processes with timing switched on
        (PWSH_TOOLKIT_TIMING) and reports the median per step, largest first,
        beside how long a bare pwsh takes to start. The first run is reported on
        its own: it pays warm-up the later ones don't, the way the first shell
        after a reboot does. Work the profile defers until after the first
        prompt (the Terminal-Icons import) doesn't delay the prompt and isn't
        counted.
    .PARAMETER Runs
        How many timed loads (default 5). The first is reported separately; the
        medians come from the rest.
    .PARAMETER Top
        How many of the largest steps to list (default 12).
    .EXAMPLE
        Measure-ProfileLoad

        Where the profile's startup time goes, from 5 fresh shells.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(2, 50)][int] $Runs = 5,
        [ValidateRange(1, 200)][int] $Top = 12
    )

    $loader = Join-Path $script:ProfileRoot 'pwsh-toolkit-profile.ps1'
    if (-not (Test-Path -LiteralPath $loader)) {
        Write-Host "  Profile loader not found: $loader" -ForegroundColor Yellow
        return
    }
    $pwsh = (Get-Process -Id $PID).Path

    # Each child prints "name<TAB>ms" in invariant culture: no JSON (its own
    # warm-up would land in the child being measured) and no locale decimal
    # commas to misread on the way back.
    $child = "`$env:PWSH_TOOLKIT_TIMING = '1'; `$env:PSPROFILE_NO_TIPS = '1'; . '$($loader.Replace("'", "''"))' *> `$null; " +
             "foreach (`$m in `$script:ProfileLoadTimings) { `$m.Name + [char]9 + `$m.Ms.ToString([cultureinfo]::InvariantCulture) }"
    $all = [System.Collections.Generic.List[object]]::new()
    for ($i = 1; $i -le $Runs; $i++) {
        Write-Progress -Activity 'Measure-ProfileLoad' -Status "Timed load $i of $Runs" -PercentComplete (100 * ($i - 1) / $Runs)
        $marks = @(foreach ($line in (& $pwsh -NoProfile -NoLogo -NonInteractive -Command $child)) {
            $p = "$line" -split "`t"
            if ($p.Count -eq 2) { [pscustomobject]@{ Name = $p[0]; Ms = [double]::Parse($p[1], [cultureinfo]::InvariantCulture) } }
        })
        if ($marks.Count -eq 0) {
            Write-Progress -Activity 'Measure-ProfileLoad' -Completed
            Write-Host '  The timed load reported nothing - is PWSH_TOOLKIT_TIMING supported by this loader?' -ForegroundColor Yellow
            return
        }
        $all.Add($marks)
    }
    Write-Progress -Activity 'Measure-ProfileLoad' -Status 'Timing a bare pwsh start' -PercentComplete 100
    $bareRuns = @(foreach ($i in 1..3) { (Measure-Command { & $pwsh -NoProfile -NoLogo -NonInteractive -Command 'exit' }).TotalMilliseconds })
    $bare = @($bareRuns | Sort-Object)[1]
    Write-Progress -Activity 'Measure-ProfileLoad' -Completed

    $firstMs = ($all[0] | Measure-Object -Property Ms -Sum).Sum
    $warm    = @($all | Select-Object -Skip 1)
    $sums    = @($warm | ForEach-Object { ($_ | Measure-Object -Property Ms -Sum).Sum } | Sort-Object)
    $totalMs = $sums[[int][math]::Floor($sums.Count / 2)]
    $rows    = @(ConvertTo-ProfileLoadSummary -Run $warm)

    Write-Host ''
    Write-Host ('  Profile load   {0,6:N0} ms   median of {1} runs (spread {2:N0}-{3:N0}); the first took {4:N0} ms' -f $totalMs, $warm.Count, $sums[0], $sums[-1], $firstMs) -ForegroundColor Cyan
    # A busy machine moves both numbers together: under memory pressure a bare
    # pwsh start alone has been seen to go from ~240 ms to ~450 ms, which is
    # why the same profile can take twice as long twenty minutes later.
    Write-Host ('  Bare pwsh      {0,6:N0} ms   so the profile is {1:P0} of a new shell''s start' -f $bare, ($totalMs / ($totalMs + $bare))) -ForegroundColor DarkGray
    Write-Host ''
    $width = [Math]::Max(12, ($rows | Select-Object -First $Top | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
    foreach ($r in ($rows | Select-Object -First $Top)) {
        $bar = [string][char]0x2588 * [int][math]::Round(20 * $r.Share)
        $color = if ($r.Share -ge 0.25) { 'Yellow' } else { 'Gray' }
        Write-Host ('  {0}  {1,6:N1} ms  {2,4:P0}  ' -f $r.Name.PadRight($width), $r.MedianMs, $r.Share) -NoNewline -ForegroundColor $color
        Write-Host $bar -ForegroundColor DarkCyan
    }
    $common = @($rows | Where-Object { $_.Name -like 'Common\*' })
    if ($common.Count -gt 0) {
        Write-Host ''
        Write-Host ('  Common\ ({0} files) together: {1:N0} ms' -f $common.Count, ($common | Measure-Object -Property MedianMs -Sum).Sum) -ForegroundColor DarkGray
    }
    Write-Host ''
}
