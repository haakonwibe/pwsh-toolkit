# Remote server shortcuts: `rdp` and `rps`
# ============================================================================
# `rdp`        - picker over $Config.RemoteServers (alt-screen-buffer like j)
# `rdp name`   - direct fuzzy match against Label/Address (case-insensitive)
# `rps`        - same picker but launches Enter-PSSession instead of mstsc
# `rps name`   - same fuzzy match
#
# Servers come from $script:Config.RemoteServers. Each entry has Label,
# Address, and optional User. v1 has NO credential helpers — mstsc and
# Enter-PSSession prompt natively when needed. When a server entry has a
# User set, `rps` calls Get-Credential pre-filled with that name; `rdp`
# always lets Windows handle the credential prompt.

function Invoke-RemoteServerPicker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][array]  $Servers
    )

    if ($Servers.Count -eq 0) {
        Write-Host '  No remote servers configured. Add entries to RemoteServers in config.psd1.' -ForegroundColor Yellow
        return $null
    }

    $labelWidth   = ($Servers | ForEach-Object { $_.Label.Length }   | Measure-Object -Maximum).Maximum
    $cursor   = 0
    $selected = $null

    # Alternate screen buffer — same trick the folder jumper uses, so the
    # picker doesn't trash scrollback on exit.
    $esc = [char]27
    [Console]::Write("$esc[?1049h")
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            [Console]::SetCursorPosition(0, 0)
            Write-Host "  $Title" -ForegroundColor Cyan
            Write-Host '  Digits 1-9 jump  Up/Down + Enter  Esc cancel' -ForegroundColor DarkGray
            Write-Host ''

            $winW = [Math]::Max(40, [Console]::WindowWidth - 1)
            for ($i = 0; $i -lt $Servers.Count; $i++) {
                $isCursor = ($i -eq $cursor)
                $marker   = if ($isCursor) { '>' } else { ' ' }
                $numKey   = if ($i -lt 9) { ($i + 1).ToString() } else { ' ' }
                $userTag  = if ($Servers[$i].User) { "  as $($Servers[$i].User)" } else { '' }
                $line     = "  {0} {1}  {2}  {3}{4}" -f $marker, $numKey, $Servers[$i].Label.PadRight($labelWidth), $Servers[$i].Address, $userTag
                if ($line.Length -gt $winW) { $line = $line.Substring(0, $winW) }
                $line = $line.PadRight($winW)
                if ($isCursor) {
                    Write-Host $line -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    Write-Host $line
                }
            }

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($cursor -gt 0)                { $cursor-- }; continue }
                'DownArrow' { if ($cursor -lt $Servers.Count-1) { $cursor++ }; continue }
                'Home'      { $cursor = 0; continue }
                'End'       { $cursor = $Servers.Count - 1; continue }
                'Enter'     { $selected = $Servers[$cursor]; break }
                'Escape'    { break }
            }
            if ($selected -or $key.Key -eq 'Enter' -or $key.Key -eq 'Escape') { break }

            if ($key.KeyChar -ge '1' -and $key.KeyChar -le '9') {
                $idx = [int][string]$key.KeyChar - 1
                if ($idx -lt $Servers.Count) { $selected = $Servers[$idx]; break }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
        [Console]::Write("$esc[?1049l")
    }

    return $selected
}

function Get-RemoteServerByMatch {
    [CmdletBinding()]
    param([string] $Match)
    if (-not $Match) { return $null }
    $servers = @($script:Config.RemoteServers)
    $servers | Where-Object { $_.Label -like "*$Match*" -or $_.Address -like "*$Match*" } | Select-Object -First 1
}

function rdp {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string] $Match)

    $server = $null
    if ($Match) {
        $server = Get-RemoteServerByMatch -Match $Match
        if (-not $server) {
            Write-Host "  No remote server matching '$Match'." -ForegroundColor Yellow
            return
        }
    } else {
        $server = Invoke-RemoteServerPicker -Title 'Remote Desktop (mstsc)' -Servers @($script:Config.RemoteServers)
    }
    if (-not $server) { return }

    Write-Host "  RDP → $($server.Label) ($($server.Address))" -ForegroundColor DarkGray
    Start-Process mstsc -ArgumentList "/v:$($server.Address)"
}

function rps {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string] $Match)

    $server = $null
    if ($Match) {
        $server = Get-RemoteServerByMatch -Match $Match
        if (-not $server) {
            Write-Host "  No remote server matching '$Match'." -ForegroundColor Yellow
            return
        }
    } else {
        $server = Invoke-RemoteServerPicker -Title 'PowerShell Remoting (Enter-PSSession)' -Servers @($script:Config.RemoteServers)
    }
    if (-not $server) { return }

    # Use splatting because we add -Credential conditionally.
    $sessionArgs = @{ ComputerName = $server.Address }
    if ($server.User) {
        Write-Host "  PSRemoting → $($server.Label) ($($server.Address)) as $($server.User)" -ForegroundColor DarkGray
        $cred = Get-Credential -UserName $server.User -Message "Credentials for $($server.Label)"
        if (-not $cred) { Write-Host '  Cancelled.' -ForegroundColor DarkGray; return }
        $sessionArgs.Credential = $cred
    } else {
        Write-Host "  PSRemoting → $($server.Label) ($($server.Address))" -ForegroundColor DarkGray
    }
    Enter-PSSession @sessionArgs
}
