# PowerShell 7 updater: `pwshup`
# ============================================================================
# Front end for PwshUpdate/Invoke-PwshUpdate.ps1, which keeps a systemwide
# PowerShell 7 current from the official ZIP packages (there is no MSI from 7.7
# on, and the Store build is per-user only). See PwshUpdate/README.md.
#
# `pwshup`             - status: version, latest Stable, task health, tasks to re-point
# `pwshup -Install`    - one-time setup (elevates)
# `pwshup -Update`     - update now instead of waiting for the nightly run (elevates)
# `pwshup -Rollback`   - back to the previous version (elevates)
# `pwshup -Uninstall`  - remove what -Install added (elevates)
#
# Everything that changes the machine runs in Windows PowerShell 5.1, never in
# the pwsh being replaced. -Install and -Uninstall run the repo's script;
# -Update and -Rollback run the installed copy under Program Files - the same
# file the SYSTEM task runs.

$script:PwshUpdateScript = Join-Path $script:Config.ToolkitRoot 'PwshUpdate\Invoke-PwshUpdate.ps1'
$script:PwshUpdateRoot   = Join-Path ($env:ProgramW6432 ?? $env:ProgramFiles) 'PowerShell'

function Get-PwshUpdateWarning {
    <#
    .SYNOPSIS
        The one-line startup warning for a stalled updater, or $null.
    .DESCRIPTION
        An unattended updater fails silently: nobody reads the log of a task
        that runs at 03:00. Warn when the last successful check is more than
        -Days old, or when an update has been staged that long - it waits for
        every pwsh window to close, which a machine that never reboots and
        never closes its terminal may not do. Pure, so it's unit-testable.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $State,
        [datetime] $Now = (Get-Date),
        [int] $Days = 7
    )
    # Stamps arrive as ISO strings (written by 5.1) or, once pwsh's
    # ConvertFrom-Json has seen them, as DateTime - [datetime] takes both.
    $age = {
        param($stamp, $reference)
        if (-not $stamp) { return $null }
        try { ($reference - ([datetime]$stamp).ToLocalTime()).TotalDays } catch { $null }
    }
    $staged = & $age $State.StagedAt $Now
    if ($State.Staged -and $null -ne $staged -and $staged -gt $Days) {
        return "PowerShell $($State.Staged) has waited $([int]$staged) days for all pwsh windows to close - pwshup -Update -Force applies it."
    }
    $success = & $age $State.LastSuccess $Now
    if ($null -ne $success -and $success -gt $Days) {
        return "The PowerShell updater hasn't completed a check in $([int]$success) days - run pwshup to see why."
    }
    return $null
}

function pwshup {
    <#
    .SYNOPSIS
        Keep a systemwide PowerShell 7 current from the ZIP packages (status, install, update, rollback).
    .DESCRIPTION
        With no switch, shows the installed version, the latest Stable release,
        the updater task's last run, and any scheduled tasks still running the
        Store build. The switches change the machine and elevate (gsudo /
        Windows sudo in this window when available, else a new elevated one).

        The install lives in C:\Program Files\PowerShell\7, a junction to a
        versioned folder, so every shortcut and task keeps one path across
        updates. A SYSTEM task checks nightly and at startup; a release is
        verified (SHA-256, Authenticode on every binary, a smoke run) before 7
        moves, and the switch waits until no pwsh is running from it.
    .PARAMETER Install
        One-time setup: install the latest Stable, add PATH / App Paths / a
        Start Menu shortcut, register the \pwsh-toolkit\PwshUpdate task.
    .PARAMETER Update
        Check for and apply a newer Stable release now.
    .PARAMETER Rollback
        Return to the previous version and mark the current one bad.
    .PARAMETER Uninstall
        Remove exactly what -Install added. The all-users Modules stay.
    .PARAMETER Version
        With -Install/-Update: install this exact version, e.g. 7.6.5.
    .PARAMETER AllowMajor
        With -Install/-Update: accept a new major version (8.x).
    .PARAMETER Force
        With -Update/-Rollback/-Uninstall: go ahead even while pwsh windows run
        from 7 (restart them afterwards).
    .PARAMETER HealthcheckUrl
        With -Install: a Healthchecks-style URL the nightly run pings.
    .PARAMETER Offline
        Status without looking up the latest release.
    .EXAMPLE
        pwshup

        Status: which PowerShell is active, whether an update is waiting, and
        when the updater last ran.
    .EXAMPLE
        pwshup -Install

        One-time setup (one UAC prompt). Afterwards open a new terminal.
    .EXAMPLE
        pwshup -Update -Force

        Apply a new release right now, even with pwsh windows open (restart them).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Status')]
    param(
        [Parameter(ParameterSetName = 'Install', Mandatory)]   [switch] $Install,
        [Parameter(ParameterSetName = 'Update', Mandatory)]    [switch] $Update,
        [Parameter(ParameterSetName = 'Rollback', Mandatory)]  [switch] $Rollback,
        [Parameter(ParameterSetName = 'Uninstall', Mandatory)] [switch] $Uninstall,
        [Parameter(ParameterSetName = 'Install')][Parameter(ParameterSetName = 'Update')] [string] $Version,
        [Parameter(ParameterSetName = 'Install')][Parameter(ParameterSetName = 'Update')] [switch] $AllowMajor,
        [Parameter(ParameterSetName = 'Update')][Parameter(ParameterSetName = 'Rollback')][Parameter(ParameterSetName = 'Uninstall')] [switch] $Force,
        [Parameter(ParameterSetName = 'Install')] [string] $HealthcheckUrl,
        [Parameter(ParameterSetName = 'Status')] [switch] $Offline
    )

    if (-not (Test-Path -LiteralPath $script:PwshUpdateScript)) {
        Write-Host "  Updater script not found: $script:PwshUpdateScript" -ForegroundColor Yellow
        return
    }
    $mode = $PSCmdlet.ParameterSetName
    if ($mode -eq 'Status') {
        & $script:PwshUpdateScript -InstallRoot $script:PwshUpdateRoot -Offline:$Offline
        return
    }

    $invocation = Get-PwshupInvocation -Mode $mode -Parameters $PSBoundParameters
    if (-not $invocation) { return }

    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        & $ps51 @invocation
        return
    }
    $sudo = Get-SudoExe
    if ($sudo) {
        & $sudo $ps51 @invocation
    } else {
        # No sudo: a new elevated window, left open so the result stays readable.
        # Start-Process joins -ArgumentList with spaces and quotes nothing, so
        # quote each argument that needs it here.
        $quoted = @('-NoExit') + $invocation | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }
        Start-Process $ps51 -Verb RunAs -ArgumentList $quoted
    }
}

function Get-PwshupInvocation {
    <#
    .SYNOPSIS
        The powershell.exe argument list for one pwshup mode.
    .DESCRIPTION
        -Install and -Uninstall run the repo's script (Install copies itself into
        place). -Update and -Rollback run the installed copy, so what runs
        elevated is exactly what the SYSTEM task runs. Pure apart from the file
        checks, and unit-tested.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string] $Mode,
        [Parameter(Mandatory)][hashtable] $Parameters,
        [string] $RepoScript = $script:PwshUpdateScript,
        [string] $Root = $script:PwshUpdateRoot
    )
    $installed = Join-Path $Root 'pwshup\updater\Invoke-PwshUpdate.ps1'
    $target = if ($Mode -in 'Install', 'Uninstall') { $RepoScript } else { $installed }
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host '  pwshup is not installed on this machine yet - run: pwshup -Install' -ForegroundColor Yellow
        return
    }
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target, "-$Mode", '-InstallRoot', $Root)
    if ($Parameters['Version'])        { $argv += @('-Version', [string]$Parameters['Version']) }
    if ($Parameters['HealthcheckUrl']) { $argv += @('-HealthcheckUrl', [string]$Parameters['HealthcheckUrl']) }
    if ($Parameters['AllowMajor'])     { $argv += '-AllowMajor' }
    if ($Parameters['Force'])          { $argv += '-Force' }
    , $argv
}

# Startup: one line, only when the unattended updater has stalled. Reading a
# small JSON file costs about a millisecond, and nothing at all when pwshup
# isn't installed.
$pwshupStateFile = Join-Path $script:PwshUpdateRoot 'pwshup\state\state.json'
if (Test-Path -LiteralPath $pwshupStateFile) {
    try {
        $pwshupWarning = Get-PwshUpdateWarning -State (Get-Content -Raw -LiteralPath $pwshupStateFile | ConvertFrom-Json)
        if ($pwshupWarning) { Write-Host "  $pwshupWarning" -ForegroundColor DarkYellow }
    } catch { Write-Verbose "pwshup: couldn't read $pwshupStateFile ($_)" }
}
Remove-Variable pwshupStateFile, pwshupWarning -ErrorAction Ignore
