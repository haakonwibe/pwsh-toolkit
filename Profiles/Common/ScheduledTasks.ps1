# Scheduled-task runner: `task`
# ============================================================================
# `task`            - picker over your scheduled tasks (everything outside
#                     \Microsoft\*), then a detail/action screen for the one you
#                     pick: run, stop, toggle enabled — with last-run detail.
# `task <name>`     - fuzzy-match a task by name and run it; falls back to an
#                     exact task name across all paths (so a \Microsoft\ task
#                     works by exact name even without -All).
# `task <name> -Info|-Stop|-Enable|-Disable` - act on the match without the picker.
# `task -All`       - include Windows' own \Microsoft\* tasks in the list/match.
#
# Built on the in-box ScheduledTasks CIM module (Get-ScheduledTask,
# Start-/Stop-/Enable-/Disable-ScheduledTask) and the shared Show-Picker. Tasks
# registered under a protected principal (SYSTEM, "highest privileges") can need
# elevation to control — the access-denied path prints the elevated command.

function Test-ScheduledTaskAvailable {
    # Guard: the ScheduledTasks module ships in-box on Windows 10/11 and Server,
    # but fail with a clear message rather than a CommandNotFound if it's absent.
    if (Get-Command Get-ScheduledTask -ErrorAction Ignore) { return $true }
    Write-Host '  ScheduledTasks module unavailable (Get-ScheduledTask missing) on this system.' -ForegroundColor Yellow
    return $false
}

function Test-ToolkitTaskVisible {
    <#
    .SYNOPSIS
        True when a task path belongs in the default `task` list.
    .DESCRIPTION
        Hides Windows' own tasks (\Microsoft\*) so the picker shows your tasks —
        root-level and custom-folder — not the hundreds of OS entries. -IncludeAll
        returns true for everything. Pure, so the filter is unit-testable.
    #>
    [OutputType([bool])]
    param([string] $TaskPath, [switch] $IncludeAll)
    if ($IncludeAll) { return $true }
    return ($TaskPath -notlike '\Microsoft\*')
}

function Format-TaskResult {
    <#
    .SYNOPSIS
        Decode a scheduled task's LastTaskResult code into a readable string.
    .DESCRIPTION
        Maps the common Task Scheduler codes — 0 (success), the 0x4130x status
        family, and a few generic Win32 errors — to plain text; unknown codes are
        shown as their unsigned 32-bit hex. Pure and unit-testable.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][long] $Code)
    $u = $Code -band 0xFFFFFFFFL   # normalize negative Int32 results (e.g. 0x80070002) to unsigned
    switch ($u) {
        0       { 'Success' }
        0x41300 { 'Ready (runs at next scheduled time)' }
        0x41301 { 'Currently running' }
        0x41302 { 'Disabled' }
        0x41303 { 'Has not yet run' }
        0x41304 { 'No more scheduled runs' }
        0x41306 { 'Last run terminated by user' }
        0x41307 { 'No triggers set (or all disabled)' }
        0x1     { 'Generic failure (incorrect function)' }
        0x2     { 'File not found' }
        0xA     { 'Environment is incorrect' }
        default { 'Exit code 0x{0:X8}' -f $u }
    }
}

function Get-ToolkitScheduledTask {
    <#
    .SYNOPSIS
        The scheduled tasks `task` shows — your tasks by default, all with -IncludeAll.
    #>
    [OutputType([object[]])]
    param([switch] $IncludeAll)
    @(Get-ScheduledTask -ErrorAction Stop |
        Where-Object { Test-ToolkitTaskVisible -TaskPath $_.TaskPath -IncludeAll:$IncludeAll } |
        Sort-Object TaskPath, TaskName)
}

function Resolve-ScheduledTask {
    # Fuzzy-match $Name against the visible task names (first hit), else fall back
    # to an exact task name across all paths (so a \Microsoft\ task resolves by
    # exact name even without -All). $null + a message when nothing matches.
    param([Parameter(Mandatory)][string] $Name, [switch] $IncludeAll)
    # Escape wildcard metacharacters so a '[' in the input matches literally
    # instead of throwing — same guard as rdp/prj fuzzy matching.
    $safe = [WildcardPattern]::Escape($Name)
    $hit = Get-ToolkitScheduledTask -IncludeAll:$IncludeAll |
        Where-Object { $_.TaskName -like "*$safe*" } | Select-Object -First 1
    if ($hit) { return $hit }
    $exact = Get-ScheduledTask -TaskName $Name -ErrorAction Ignore | Select-Object -First 1
    if ($exact) { return $exact }
    Write-Host "  No scheduled task matching '$Name'." -ForegroundColor Yellow
    return $null
}

function Invoke-ScheduledTaskAction {
    # Perform run/stop/enable/disable (or toggle, resolved from current State) on a
    # task. On access-denied — tasks under a protected principal — print the
    # elevated in-box command instead of failing opaquely.
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)][ValidateSet('run','stop','enable','disable','toggle')][string] $Action
    )
    if ($Action -eq 'toggle') { $Action = if ($Task.State -eq 'Disabled') { 'enable' } else { 'disable' } }
    try {
        switch ($Action) {
            'run'     { $Task | Start-ScheduledTask   -ErrorAction Stop;            Write-Host "  ▶  Started $($Task.TaskName)"  -ForegroundColor Green }
            'stop'    { $Task | Stop-ScheduledTask    -ErrorAction Stop;            Write-Host "  ■  Stopped $($Task.TaskName)"  -ForegroundColor Green }
            'enable'  { $Task | Enable-ScheduledTask  -ErrorAction Stop | Out-Null; Write-Host "  ✔  Enabled $($Task.TaskName)"  -ForegroundColor Green }
            'disable' { $Task | Disable-ScheduledTask -ErrorAction Stop | Out-Null; Write-Host "  ✔  Disabled $($Task.TaskName)" -ForegroundColor Green }
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'denied|UnauthorizedAccess|0x80070005') {
            $verb = switch ($Action) { 'run' { 'Start' } 'stop' { 'Stop' } 'enable' { 'Enable' } 'disable' { 'Disable' } }
            Write-Host "  Access denied — '$($Task.TaskName)' runs under a protected principal." -ForegroundColor Yellow
            Write-Host ("  Try elevated:  sudo {0}-ScheduledTask -TaskName '{1}' -TaskPath '{2}'" -f $verb, $Task.TaskName, $Task.TaskPath) -ForegroundColor DarkGray
        }
        else {
            Write-Host "  Failed to $Action '$($Task.TaskName)': $msg" -ForegroundColor Red
        }
    }
}

function Show-ScheduledTaskDetail {
    <#
    .SYNOPSIS
        Print a task's state + last-run detail; optionally read a single action key.
    #>
    param([Parameter(Mandatory)] $Task, [switch] $NoActions)

    $info       = $Task | Get-ScheduledTaskInfo -ErrorAction Ignore
    $stateColor = switch ($Task.State) { 'Running' { 'Cyan' } 'Disabled' { 'DarkGray' } 'Ready' { 'Green' } default { 'Gray' } }

    Write-Host ''
    Write-Host "  $($Task.TaskName)" -ForegroundColor Cyan
    if ($Task.TaskPath -and $Task.TaskPath -ne '\') { Write-Host "  path:        $($Task.TaskPath)" -ForegroundColor DarkGray }
    Write-Host '  state:       ' -NoNewline; Write-Host $Task.State -ForegroundColor $stateColor
    if ($info) {
        if ($info.LastRunTime) { Write-Host "  last run:    $($info.LastRunTime)" -ForegroundColor Gray }
        Write-Host "  last result: $(Format-TaskResult $info.LastTaskResult)" -ForegroundColor Gray
        if ($info.NextRunTime) { Write-Host "  next run:    $($info.NextRunTime)" -ForegroundColor Gray }
    }
    if ($Task.Principal.UserId) { Write-Host "  runs as:     $($Task.Principal.UserId)" -ForegroundColor DarkGray }

    if ($NoActions) { return }

    Write-Host ''
    Write-Host '  [R]un   [S]top   [T]oggle enabled   [B]ack   [Q]uit' -ForegroundColor Yellow
    $key = [Console]::ReadKey($true)
    switch ([char]::ToLower($key.KeyChar)) {
        'r'     { 'run' }
        's'     { 'stop' }
        't'     { 'toggle' }
        'q'     { 'quit' }
        default { 'back' }
    }
}

function task {
    <#
    .SYNOPSIS
        Run, stop, or manage a Windows scheduled task — by picker or by name.
    .DESCRIPTION
        With no argument, opens a picker over your scheduled tasks (everything
        outside \Microsoft\*), then a detail screen for the chosen task showing its
        state and last-run result, with single-key actions (run / stop / toggle
        enabled). With a name, fuzzy-matches a task and runs it; -Stop / -Enable /
        -Disable / -Info act without running, and -All includes Windows' own tasks.

        Tasks registered under a protected principal (SYSTEM, "highest privileges")
        can require elevation; the access-denied path prints the elevated command.
    .PARAMETER Name
        Task-name substring (fuzzy), or an exact task name.
    .PARAMETER Stop
        Stop the matched (running) task instead of starting it.
    .PARAMETER Enable
        Enable the matched task.
    .PARAMETER Disable
        Disable the matched task.
    .PARAMETER Info
        Show the matched task's detail (state, last run, last result, next run) only.
    .PARAMETER All
        Include Windows' own \Microsoft\* tasks in the picker and matching.
    .EXAMPLE
        task

        Pick from your tasks, then run / stop / toggle the chosen one from its detail screen.
    .EXAMPLE
        task PSModuleMaintenance

        Fuzzy-match and start the task whose name contains "PSModuleMaintenance".
    .EXAMPLE
        task PSModuleMaintenance -Info

        Show that task's state and last-run result without starting it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string] $Name,
        [switch] $Stop,
        [switch] $Enable,
        [switch] $Disable,
        [switch] $Info,
        [switch] $All
    )

    if (-not (Test-ScheduledTaskAvailable)) { return }

    if ($Name) {
        $t = Resolve-ScheduledTask -Name $Name -IncludeAll:$All
        if (-not $t) { return }
        if     ($Info)    { Show-ScheduledTaskDetail -Task $t -NoActions }
        elseif ($Stop)    { Invoke-ScheduledTaskAction -Task $t -Action 'stop' }
        elseif ($Enable)  { Invoke-ScheduledTaskAction -Task $t -Action 'enable' }
        elseif ($Disable) { Invoke-ScheduledTaskAction -Task $t -Action 'disable' }
        else              { Invoke-ScheduledTaskAction -Task $t -Action 'run' }
        return
    }

    # Picker → detail/action loop. Re-query each pass so State reflects actions.
    while ($true) {
        $tasks = @(Get-ToolkitScheduledTask -IncludeAll:$All)
        if ($tasks.Count -eq 0) {
            Write-Host ''
            $scope = if ($All) { 'any' } else { 'non-Microsoft' }
            Write-Host "  No $scope scheduled tasks found." -ForegroundColor Yellow
            if (-not $All) { Write-Host '  (Add -All to include Windows'' own \Microsoft\ tasks.)' -ForegroundColor DarkGray }
            return
        }

        $nameWidth = [Math]::Min(45, ($tasks | ForEach-Object { $_.TaskName.Length } | Measure-Object -Maximum).Maximum)
        $render = {
            param($t)
            $sub = if ($t.TaskPath -and $t.TaskPath -ne '\') { $t.TaskPath } else { '' }
            '{0}  {1,-8}  {2}' -f $t.TaskName.PadRight($nameWidth), $t.State, $sub
        }.GetNewClosure()

        $sel = Show-Picker -Items $tasks -RenderRow $render `
            -Title 'Scheduled tasks  ·  Enter for detail & actions' `
            -Hint 'Up/Down + Enter  digits 1-9 jump  Esc cancel'
        if (-not $sel) { return }

        $action = Show-ScheduledTaskDetail -Task $sel
        switch ($action) {
            'back' { continue }
            'quit' { return }
            default {
                Invoke-ScheduledTaskAction -Task $sel -Action $action
                Write-Host ''
                Write-Host '  (press a key to return to the list — Esc or Q to quit)' -ForegroundColor DarkGray
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Escape' -or [char]::ToLower($k.KeyChar) -eq 'q') { return }
            }
        }
    }
}
