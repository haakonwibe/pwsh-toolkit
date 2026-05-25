# System Utility Functions
# Provides common system information and management functions

# Quick IP lookup (great for troubleshooting)
Function Get-PubIP {
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
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $uptime = (Get-Date) - $bootTime
    Write-Output "System uptime: $($uptime.Days) days, $($uptime.Hours) hours, $($uptime.Minutes) minutes"
}

# Quick file search (very handy)
function Find-File($name) {
    Get-ChildItem -Recurse -Filter "*$name*" -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Output $_.FullName }
}

# System shortcuts
function Get-SysInfo {
    Get-ComputerInfo | Select-Object WindowsProductName, TotalPhysicalMemory, CsProcessors, WindowsVersion
}

# Disk free overview with colored usage bars.
# Default: fixed drives only, sorted by drive letter. -All adds removable/network/CD-ROM.
function df {
    [CmdletBinding()]
    param([switch] $All)

    $filter = if ($All) { 'DriveType=2 OR DriveType=3 OR DriveType=4 OR DriveType=5' } else { 'DriveType=3' }
    $disks  = Get-CimInstance Win32_LogicalDisk -Filter $filter -ErrorAction SilentlyContinue | Sort-Object DeviceID
    if (-not $disks) { Write-Host '  No drives matched.' -ForegroundColor Yellow; return }

    $fmtSize = {
        param([double] $b)
        if ($b -ge 1TB) { '{0,4:N1} TB' -f ($b / 1TB) }
        elseif ($b -ge 1GB) { '{0,4:N0} GB' -f ($b / 1GB) }
        elseif ($b -ge 1MB) { '{0,4:N0} MB' -f ($b / 1MB) }
        else { '{0,4:N0} KB' -f ($b / 1KB) }
    }
    $typeLabel = { param([int] $t)
        switch ($t) { 2 {'Removable'} 3 {'Fixed'} 4 {'Network'} 5 {'CD-ROM'} default {"Type$t"} }
    }
    $barWidth = 17

    Write-Host ('  {0,-5} {1,-12} {2,7} {3,7} {4,7} {5,5}  Usage' -f 'Drive','Label','Used','Free','Total','Use%') -ForegroundColor Cyan

    foreach ($d in $disks) {
        $size = [double] $d.Size
        $free = [double] $d.FreeSpace

        if ($size -le 0) {
            # CD-ROM with no media, unplugged removable, disconnected network share, etc.
            $line = '  {0,-5} {1,-12} {2,7} {3,7} {4,7} {5,5}' -f $d.DeviceID, (& $typeLabel $d.DriveType), '-', '-', '-', '-'
            Write-Host $line -ForegroundColor DarkGray
            continue
        }

        $used   = $size - $free
        $pct    = [int][Math]::Round(($used / $size) * 100)
        $filled = [Math]::Min($barWidth, [Math]::Max(0, [int][Math]::Round(($pct / 100.0) * $barWidth)))
        $bar    = ('█' * $filled) + ('░' * ($barWidth - $filled))

        $label = if ([string]::IsNullOrWhiteSpace($d.VolumeName)) { & $typeLabel $d.DriveType } else { $d.VolumeName }
        if ($label.Length -gt 12) { $label = $label.Substring(0, 11) + '…' }

        $color = if ($pct -ge 90) { 'Red' } elseif ($pct -ge 70) { 'Yellow' } else { 'Green' }
        $head  = '  {0,-5} {1,-12} {2,7} {3,7} {4,7} {5,4}%  ' -f $d.DeviceID, $label, (& $fmtSize $used), (& $fmtSize $free), (& $fmtSize $size), $pct
        Write-Host -NoNewline $head
        Write-Host $bar -ForegroundColor $color
    }
}

function Start-AdminTerminal {
    <#
    .SYNOPSIS
        Starts a new Windows Terminal session with elevated rights
    .DESCRIPTION
        Launches Windows Terminal as Administrator. If already running as admin, shows a message.
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
