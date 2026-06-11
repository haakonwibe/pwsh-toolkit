# System Utility Functions
# Provides common system information and management functions

function Format-ByteSize {
    <#
    .SYNOPSIS
        Format a byte count as a human-readable size (e.g. 31.5 GB).
    .DESCRIPTION
        Picks the largest fitting unit (KB/MB/GB/TB) and formats the value. By
        default TB and GB get one decimal place while MB and KB are whole numbers;
        -DecimalUnits overrides which units get a decimal, and -Width right-aligns
        the number for table layouts. Shared by Get-SysInfo and df, which is why
        the precision and width are parameterized — df wants whole, width-aligned
        GB for its columns, Get-SysInfo wants a decimal on GB for the memory line.
    .PARAMETER Bytes
        The size in bytes.
    .PARAMETER DecimalUnits
        Units rendered with one decimal place; all others are whole numbers.
        Defaults to TB and GB.
    .PARAMETER Width
        Right-align the numeric part to this many characters (0 = no padding).
    .EXAMPLE
        Format-ByteSize 33855050752
        # 31.5 GB
    .EXAMPLE
        Format-ByteSize 274877906944 -DecimalUnits 'TB' -Width 4
        #  256 GB   (whole, right-aligned in a 4-char field — the df style)
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][double] $Bytes,
        [string[]] $DecimalUnits = @('TB', 'GB'),
        [int] $Width = 0
    )

    if     ($Bytes -ge 1TB) { $unit = 'TB'; $value = $Bytes / 1TB }
    elseif ($Bytes -ge 1GB) { $unit = 'GB'; $value = $Bytes / 1GB }
    elseif ($Bytes -ge 1MB) { $unit = 'MB'; $value = $Bytes / 1MB }
    else                    { $unit = 'KB'; $value = $Bytes / 1KB }

    $precision = if ($unit -in $DecimalUnits) { 'N1' } else { 'N0' }
    $numFmt    = if ($Width -gt 0) { '{0,' + $Width + ':' + $precision + '}' } else { '{0:' + $precision + '}' }
    '{0} {1}' -f ($numFmt -f $value), $unit
}

# Quick IP lookup (great for troubleshooting)
Function Get-PubIP {
    <#
    .SYNOPSIS
        Show your public IPv4 and IPv6 addresses.
    .DESCRIPTION
        Queries several public IP-echo services with fallback, printing the first
        successful answer for each protocol. Handy for quick troubleshooting.
    .EXAMPLE
        Get-PubIP

        Prints your public IPv4 and IPv6 addresses (whichever resolve), each
        labelled with the service that answered — useful when you need the
        address your traffic actually leaves from, e.g. for a firewall allowlist.
    #>
    $services = @{
        "IPv4" = @("https://ipv4.icanhazip.com", "https://api.ipify.org", "https://v4.ident.me")
        "IPv6" = @("https://ipv6.icanhazip.com", "https://api6.ipify.org", "https://v6.ident.me")
    }

    foreach ($protocol in $services.Keys) {
        Write-Host "$protocol addresses:" -ForegroundColor Cyan
        foreach ($service in $services[$protocol]) {
            try {
                $ip = (Invoke-WebRequest -Uri $service -UseBasicParsing -TimeoutSec 5).Content.Trim()
                Write-Host "  $ip (via $($service -replace 'https://',''))" -ForegroundColor Green
                break  # Stop after first successful response
            }
            catch {
                continue  # Try next service
            }
        }
    }
}

# System uptime (useful for server health checks)
function Get-Uptime {
    <#
    .SYNOPSIS
        Show how long since the last boot, in plain English.
    .EXAMPLE
        Get-Uptime

        Prints e.g. "System uptime: 4 days, 17 hours, 12 minutes". A readable
        alternative to the built-in Get-Uptime, which returns a raw TimeSpan.
    #>
    # PowerShell 6+ ships its own Get-Uptime (returns a TimeSpan); this toolkit
    # intentionally overrides it with a human-readable one-liner. Deliberate.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Intentional toolkit override of the built-in Get-Uptime with a human-readable string.')]
    param()
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $uptime = (Get-Date) - $bootTime
    Write-Output "System uptime: $($uptime.Days) days, $($uptime.Hours) hours, $($uptime.Minutes) minutes"
}

# Quick file search (very handy). Highlights the search term in matched paths
# when running interactively; falls back to plain string emission when piped
# or redirected, so `Find-File foo | Select-String bar` and `Find-File foo >
# out.txt` keep working.
function Find-File {
    <#
    .SYNOPSIS
        Recursively search for files by name from the current directory.
    .DESCRIPTION
        Wildcard substring match on the file name. When run interactively the
        matched term is highlighted; when piped or redirected, plain paths are
        emitted so downstream commands keep working.
    .PARAMETER Name
        Substring to match anywhere in the file name.
    .EXAMPLE
        Find-File config.json

        Recursively searches from the current directory for any file whose name
        contains "config.json", highlighting the match. Pipe it (e.g.
        `Find-File config | Select-String db`) and it emits plain paths instead.
    #>
    [CmdletBinding()]
    param([string] $Name)

    $highlight = $MyInvocation.PipelinePosition -eq $MyInvocation.PipelineLength -and
                 -not [Console]::IsOutputRedirected
    $pattern   = if ($highlight) { [regex]::new([regex]::Escape($Name), 'IgnoreCase') } else { $null }

    Get-ChildItem -Recurse -Filter "*$Name*" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $highlight) { $_.FullName; return }
        $path = $_.FullName; $i = 0
        foreach ($m in $pattern.Matches($path)) {
            Write-Host $path.Substring($i, $m.Index - $i) -NoNewline
            Write-Host $path.Substring($m.Index, $m.Length) -NoNewline -ForegroundColor Yellow
            $i = $m.Index + $m.Length
        }
        Write-Host $path.Substring($i)
    }
}

# At-a-glance system overview: OS, host, CPU, memory, GPU, uptime.
#
# Deliberately NOT Get-ComputerInfo, which the old one-liner used. Three
# problems with that cmdlet here:
#   1. It's slow — several seconds, because it aggregates dozens of CIM
#      classes plus registry/Win32 API calls we don't need.
#   2. TotalPhysicalMemory came back blank in practice (it surfaces the
#      Win32_ComputerSystem value, which is occasionally null/uninitialized
#      depending on driver/firmware reporting).
#   3. WindowsProductName reads registry `ProductName`, which Microsoft
#      famously froze at "Windows 10 …" on Windows 11 machines — so the old
#      output literally mislabeled the OS.
#
# Instead: a handful of targeted Win32_* CIM queries (fast) plus the
# CurrentVersion registry key for the accurate edition/display-version, and
# the build number as the source of truth for the 10-vs-11 split (>= 22000
# is Windows 11). Output mirrors `df`'s aligned, colored style.
function Get-SysInfo {
    <#
    .SYNOPSIS
        At-a-glance system panel: host, OS, uptime, CPU, memory, GPU, model.
    .DESCRIPTION
        Fast, targeted Win32_* CIM queries plus the CurrentVersion registry key,
        rendered in the same aligned/colored style as `df`. Reports the accurate
        Windows edition/build (not the frozen registry ProductName) and memory
        usage with a colored bar.
    .EXAMPLE
        Get-SysInfo

        Prints the one-screen panel — host/user, OS edition + display version +
        build, uptime, CPU cores/threads, memory used/total with a usage bar,
        GPU(s), and machine model. Faster and more accurate than Get-ComputerInfo.
    #>
    [CmdletBinding()]
    param()

    $os  = Get-CimInstance Win32_OperatingSystem  -ErrorAction SilentlyContinue
    $cs  = Get-CimInstance Win32_ComputerSystem    -ErrorAction SilentlyContinue
    $cpu = @(Get-CimInstance Win32_Processor       -ErrorAction SilentlyContinue)
    # Don't filter on AdapterRAM: it's a uint32 that wraps to 0 for any GPU
    # whose VRAM is an exact multiple of 4 GiB (8/16/24/32 GB cards), which
    # would drop a real discrete GPU. Just require a name.
    $gpu = @(Get-CimInstance Win32_VideoController  -ErrorAction SilentlyContinue |
             Where-Object { $_.Name })
    $cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

    # --- OS name -----------------------------------------------------------
    # Win32_OperatingSystem.Caption ("Microsoft Windows 11 Pro") reports the
    # generation correctly, unlike the registry ProductName. But fall back to
    # the build-number split if the caption is ever missing/wrong.
    $build   = [int]($os.BuildNumber)
    $caption = ($os.Caption -replace '^Microsoft\s+', '').Trim()
    if ($build -ge 22000 -and $caption -match 'Windows 10') {
        $caption = $caption -replace 'Windows 10', 'Windows 11'
    }
    $display = $cv.DisplayVersion          # e.g. 24H2  (was ReleaseId pre-20H2)
    if (-not $display) { $display = $cv.ReleaseId }
    $ubr     = $cv.UBR                      # update build revision (the .xxxx)
    $buildStr = if ($ubr) { "$build.$ubr" } else { "$build" }
    $osLine  = (@($caption, $display) | Where-Object { $_ }) -join ' '
    $osLine  = "$osLine (build $buildStr)"

    # --- Uptime ------------------------------------------------------------
    $uptimeStr = 'unknown'
    if ($os.LastBootUpTime) {
        $up = (Get-Date) - $os.LastBootUpTime
        $uptimeStr = '{0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes
    }

    # --- CPU ---------------------------------------------------------------
    $cpuStr = 'unknown'
    if ($cpu.Count -gt 0) {
        $name    = ($cpu[0].Name -replace '\s+', ' ').Trim()
        $cores   = ($cpu | Measure-Object NumberOfCores -Sum).Sum
        $threads = ($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum
        $cpuStr  = "$name  ($cores cores / $threads threads)"
        if ($cpu.Count -gt 1) { $cpuStr = "$($cpu.Count)x $cpuStr" }
    }

    # --- Memory ------------------------------------------------------------
    # FreePhysicalMemory / TotalVisibleMemorySize are in KiB. Require BOTH to be
    # present: a null FreePhysicalMemory would coerce to 0 and render a bogus
    # "100% used / full red bar" on an otherwise-fine machine.
    $memStr = 'unknown'; $memBar = ''; $memColor = 'Green'
    if ($os.TotalVisibleMemorySize -gt 0 -and $null -ne $os.FreePhysicalMemory) {
        $totalB = [double]$os.TotalVisibleMemorySize * 1KB
        $freeB  = [double]$os.FreePhysicalMemory     * 1KB
        $usedB  = $totalB - $freeB
        $pct    = [int][Math]::Round(($usedB / $totalB) * 100)
        $barW   = 17
        $filled = [Math]::Min($barW, [Math]::Max(0, [int][Math]::Round(($pct / 100.0) * $barW)))
        $memBar = ('█' * $filled) + ('░' * ($barW - $filled))
        $memColor = if ($pct -ge 90) { 'Red' } elseif ($pct -ge 70) { 'Yellow' } else { 'Green' }
        $memStr = '{0} used / {1} total  ({2}%)' -f (Format-ByteSize $usedB), (Format-ByteSize $totalB), $pct
    }

    # --- GPU ---------------------------------------------------------------
    $gpuStr = if ($gpu.Count -gt 0) {
        (($gpu | ForEach-Object { ($_.Name -replace '\s+', ' ').Trim() } | Select-Object -Unique) -join ', ')
    } else { 'unknown' }

    # --- Host / model ------------------------------------------------------
    $hostName = $cs.Name; if (-not $hostName) { $hostName = $env:COMPUTERNAME }
    $hostLine = "$hostName  ($($cs.UserName ?? $env:USERNAME))"
    $modelStr = (@($cs.Manufacturer, $cs.Model) |
                 ForEach-Object { ($_ -as [string]).Trim() } |
                 Where-Object { $_ }) -join ' '

    # --- Render ------------------------------------------------------------
    $emit = {
        param([string] $label, [string] $value, [string] $color)
        Write-Host ('  {0,-9}' -f $label) -ForegroundColor Cyan -NoNewline
        if ($color) { Write-Host " $value" -ForegroundColor $color }
        else        { Write-Host " $value" }
    }

    Write-Host ''
    & $emit 'Host'   $hostLine
    & $emit 'OS'     $osLine
    & $emit 'Uptime' $uptimeStr
    & $emit 'CPU'    $cpuStr
    if ($memBar) {
        Write-Host ('  {0,-9}' -f 'Memory') -ForegroundColor Cyan -NoNewline
        Write-Host " $memStr  " -NoNewline
        Write-Host $memBar -ForegroundColor $memColor
    } else {
        & $emit 'Memory' $memStr
    }
    & $emit 'GPU'    $gpuStr
    if ($modelStr) { & $emit 'Model' $modelStr }
    Write-Host ''
}

# Disk free overview with colored usage bars.
# Default: fixed drives only, sorted by drive letter. -All adds removable/network/CD-ROM.
function df {
    <#
    .SYNOPSIS
        Disk-free overview with colored usage bars.
    .DESCRIPTION
        Lists drives with used/free/total and a colored usage bar (green under
        70%, yellow 70-89%, red 90%+). Fixed drives only by default, sorted by
        drive letter.
    .PARAMETER All
        Also include removable, network, and CD-ROM drives.
    .EXAMPLE
        df

        Shows your fixed drives with used/free/total and a colored usage bar per
        drive (green/yellow/red as it fills) — a quick "how full is everything?".
    .EXAMPLE
        df -All

        Same, but also lists removable, network, and CD-ROM drives (which the
        default view skips).
    #>
    [CmdletBinding()]
    param([switch] $All)

    $filter = if ($All) { 'DriveType=2 OR DriveType=3 OR DriveType=4 OR DriveType=5' } else { 'DriveType=3' }
    $disks  = Get-CimInstance Win32_LogicalDisk -Filter $filter -ErrorAction SilentlyContinue | Sort-Object DeviceID
    if (-not $disks) { Write-Host '  No drives matched.' -ForegroundColor Yellow; return }

    $typeLabel = { param([int] $t)
        switch ($t) { 2 {'Removable'} 3 {'Fixed'} 4 {'Network'} 5 {'CD-ROM'} default {"Type$t"} }
    }
    $barWidth = 17

    # Label column width is dynamic: max of the actual labels in this run,
    # bounded by min='Label' header length (5) and max 30 to prevent any one
    # pathological label from blowing the column out. Replaces the previous
    # hardcoded 12 which was too narrow for any "Storage" / "Backup" / etc.
    # label longer than 11 characters.
    #
    # Caveat: emoji-prefixed labels still nudge alignment slightly — emoji
    # count as 1-2 .Length chars but render as 2 terminal cells. Fully
    # wcwidth-aware padding is a separate rabbit hole, left unfixed.
    $labelWidth = [Math]::Min(30, [Math]::Max(
        'Label'.Length,
        ($disks | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_.VolumeName)) {
                (& $typeLabel $_.DriveType).Length
            } else {
                $_.VolumeName.Length
            }
        } | Measure-Object -Maximum).Maximum
    ))

    $headerFmt = "  {0,-5} {1,-$labelWidth} {2,7} {3,7} {4,7} {5,5}  Usage"
    $rowFmt    = "  {0,-5} {1,-$labelWidth} {2,7} {3,7} {4,7} {5,4}%  "
    $emptyFmt  = "  {0,-5} {1,-$labelWidth} {2,7} {3,7} {4,7} {5,5}"

    Write-Host ($headerFmt -f 'Drive', 'Label', 'Used', 'Free', 'Total', 'Use%') -ForegroundColor Cyan

    foreach ($d in $disks) {
        $size = [double] $d.Size
        $free = [double] $d.FreeSpace

        if ($size -le 0) {
            # CD-ROM with no media, unplugged removable, disconnected network share, etc.
            $line = $emptyFmt -f $d.DeviceID, (& $typeLabel $d.DriveType), '-', '-', '-', '-'
            Write-Host $line -ForegroundColor DarkGray
            continue
        }

        $used   = $size - $free
        $pct    = [int][Math]::Round(($used / $size) * 100)
        $filled = [Math]::Min($barWidth, [Math]::Max(0, [int][Math]::Round(($pct / 100.0) * $barWidth)))
        $bar    = ('█' * $filled) + ('░' * ($barWidth - $filled))

        $label = if ([string]::IsNullOrWhiteSpace($d.VolumeName)) { & $typeLabel $d.DriveType } else { $d.VolumeName }
        if ($label.Length -gt $labelWidth) { $label = $label.Substring(0, $labelWidth - 1) + '…' }

        $color = if ($pct -ge 90) { 'Red' } elseif ($pct -ge 70) { 'Yellow' } else { 'Green' }
        $head  = $rowFmt -f $d.DeviceID, $label, (Format-ByteSize $used -DecimalUnits 'TB' -Width 4), (Format-ByteSize $free -DecimalUnits 'TB' -Width 4), (Format-ByteSize $size -DecimalUnits 'TB' -Width 4), $pct
        Write-Host -NoNewline $head
        Write-Host $bar -ForegroundColor $color
    }
}

function Start-AdminTerminal {
    <#
    .SYNOPSIS
        Starts a new Windows Terminal session with elevated rights
    .DESCRIPTION
        Launches Windows Terminal as Administrator (triggering a UAC prompt). If
        the current session is already elevated, it says so instead of opening a
        redundant window. Falls back to an elevated PowerShell if wt isn't found.
        For running a single command elevated rather than opening a whole shell,
        see `sudo`.
    .EXAMPLE
        Start-AdminTerminal

        Opens a new elevated Windows Terminal — handy right before a session of
        admin work (e.g. running `winup` to install upgrades).
    #>

    # Check if already running as admin
    $isAdmin = ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        Write-Host "Already running as Administrator! ✅" -ForegroundColor Green
        return
    }

    try {
        Start-Process wt -Verb RunAs
        Write-Host "Launching Windows Terminal as Administrator..." -ForegroundColor Cyan
    }
    catch {
        Write-Warning "Failed to launch Windows Terminal. Falling back to PowerShell..."
        Start-Process pwsh -Verb RunAs
    }
}

function Test-NativeSudoEnabled {
    <#
    .SYNOPSIS
        True if Windows' built-in sudo is present AND turned on.
    .DESCRIPTION
        The built-in sudo (Windows 11 24H2+) ships disabled; its enabled state and
        run-mode live in the registry. 0 or an absent value means disabled. Used by
        `sudo` to decide whether it can delegate to the native tool.
    #>
    [OutputType([bool])]
    param()
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' -ErrorAction SilentlyContinue
    return [bool]($reg -and $null -ne $reg.Enabled -and $reg.Enabled -ne 0)
}

function Get-SudoExe {
    <#
    .SYNOPSIS
        Path to a real sudo to delegate elevation to, or $null if none.
    .DESCRIPTION
        Prefers gsudo (which can also cache the UAC prompt), then Windows' built-in
        sudo when it's enabled. Returns $null when neither is available, so callers
        can fall back to launching a separate elevated window. The single source of
        truth for elevation backend selection — shared by `sudo` and `winup -Elevated`.
        Resolves the executable explicitly (`gsudo`/`sudo.exe`), never the bare name
        `sudo`, which is a session function.
    #>
    [OutputType([string])]
    param()
    $gsudo = Get-Command 'gsudo' -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if ($gsudo) { return $gsudo.Source }
    $native = Get-Command 'sudo.exe' -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if ($native -and (Test-NativeSudoEnabled)) { return $native.Source }
    return $null
}

function sudo {
    <#
    .SYNOPSIS
        Run a command elevated — delegating to a real sudo when one's available.
    .DESCRIPTION
        Prefers a genuine sudo so the command can elevate in the CURRENT window:
        first gsudo (which can also cache the UAC prompt), then Windows' built-in
        sudo if it's enabled (Settings → System → For developers → Enable sudo).
        Falls back to launching an elevated PowerShell in a NEW window (-NoExit, so
        output stays readable) when neither is available — which is all Windows
        offers without one of those tools. With no command, just opens an elevated
        shell (see also Start-AdminTerminal for a full elevated Windows Terminal).

        The backing executable is resolved explicitly (gsudo / sudo.exe), never the
        bare name `sudo` — which is this function — so it can't recurse into itself.
        Run with -Verbose to see which backend it picked.
    .PARAMETER Command
        The command and its arguments to run elevated.
    .EXAMPLE
        sudo winget upgrade --all

        Runs `winget upgrade --all` elevated. With native sudo (Inline mode) or
        gsudo enabled, it runs right here in the current window; otherwise it opens
        an elevated window that stays open.
    .EXAMPLE
        sudo -Verbose winget upgrade --all

        Same, but prints which backend it used (gsudo / native sudo / new-window
        fallback) — handy for confirming your setup.
    .EXAMPLE
        sudo

        With no arguments, opens an elevated PowerShell (a one-shot elevated shell).
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]] $Command)

    if (-not $Command -or $Command.Count -eq 0) {
        Write-Verbose 'sudo: no command — opening an elevated shell'
        Start-Process pwsh -Verb RunAs
        return
    }

    # Prefer a real sudo (elevates in the current window; gsudo can cache the
    # prompt). Get-SudoExe resolves the backing executable — never the bare name
    # `sudo`, which is THIS function, so we can't recurse into ourselves.
    $exe = Get-SudoExe
    if ($exe) {
        Write-Verbose "sudo: delegating to $exe"
        & $exe @Command
        return
    }

    # No enabled native sudo / gsudo: run the command in a new elevated window.
    # Re-quote each argument — PowerShell stripped the caller's quotes during
    # binding, so a bare -join ' ' would let the elevated pwsh re-split a path
    # like 'C:\Program Files\x.txt' into two arguments. The leading & makes the
    # (possibly quoted) first element invoke as a command.
    Write-Verbose 'sudo: no enabled native sudo or gsudo — using a new elevated window'
    $quoted = foreach ($arg in $Command) {
        if ($arg -match '[\s''"]') { "'{0}'" -f ($arg -replace "'", "''") } else { $arg }
    }
    $cmdline = '& ' + ($quoted -join ' ')
    Start-Process pwsh -Verb RunAs -ArgumentList '-NoExit', '-Command', $cmdline
}
