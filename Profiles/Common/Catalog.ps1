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
    'PoshThemes'          = 'Oh My Posh themes'
    'Terminal'            = 'Windows Terminal'
    'SecretManagement'    = 'Secrets'
    'RemoteServers'       = 'Remote servers'
    'ScheduledTasks'      = 'Scheduled tasks'
    'Notes'               = 'Notes / journal'
    'Wtf'                 = 'Explain errors'
    'Get-DirDescriptions' = 'Downloads viewer'
    'Catalog'             = 'Discovery'
    'Tips'                = 'Discovery'
}

# Functions that exist only to support the public commands — hidden unless -All.
$script:ToolkitInternalCommands = @(
    'Invoke-JumpTo'
    'Get-JumpBookmark', 'Save-JumpBookmark', 'Sync-JumpBookmark', 'Add-JumpBookmark', 'Remove-JumpBookmark'
    'Get-MgGraphAllPage', 'Get-IntuneOverviewData', 'Get-ComplianceBucket', 'Get-DeviceSyncAge', 'ConvertTo-IntuneDashboardHtml', 'Show-IntuneDashboard'
    'ConvertTo-Win32RuleSummary', 'Resolve-MobileAppAssignmentTarget'
    'Get-ToolkitDataPath'
    'Get-RecentFile', 'Format-FileAge', 'Get-FileDizDescription'
    'Convert-SnippetDate', 'ConvertTo-SnippetStamp', 'Format-SnippetPreview', 'Get-ClipSnippet', 'Save-ClipSnippet', 'Limit-ClipSnippet', 'Add-ClipSnippet', 'Remove-ClipSnippet'
    'Get-PeekRarExe', 'Get-Peek7zExe', 'Get-PeekTool'
    'Test-NativeSudoEnabled', 'Get-SudoExe'
    'Get-ProjectRoot', 'Find-GitProject'
    'Get-PickerScrollTop', 'Get-PickerHotkey', 'Get-PickerHotkeyIndex', 'Get-PickerPlainText', 'Show-Picker'
    'Get-PoshThemePool', 'Test-NerdFontInstalled'
    'Get-TerminalSettingsPath', 'Update-FontFaceText'
    'Test-RemoteServersConfigured', 'Invoke-RemoteServerPicker', 'Get-RemoteServerByMatch'
    'Resolve-RemoteServer', 'Format-RemoteServerDisplay', 'Format-PsRemotingError'
    'Get-ObsidianVault', 'Resolve-NotesRoot'
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
