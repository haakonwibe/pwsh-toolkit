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

function Test-RemoteServersConfigured {
    # Returns $false (after writing a helpful "how to configure" message) when
    # $script:Config.RemoteServers is empty. Called at the top of rdp/rps so
    # users get useful guidance instead of a parameter-binding error.
    if (@($script:Config.RemoteServers).Count -gt 0) { return $true }

    Write-Host ''
    Write-Host '  No remote servers configured.' -ForegroundColor Yellow
    Write-Host "  Add entries to Profiles/config.psd1's RemoteServers list, e.g.:" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '      RemoteServers = @(' -ForegroundColor DarkGray
    Write-Host "          @{ Label = 'Lab DC';   Address = 'dc01.lab.local';   User = 'lab\admin' }" -ForegroundColor DarkGray
    Write-Host "          @{ Label = 'Build';    Address = 'build.contoso.com' }" -ForegroundColor DarkGray
    Write-Host '      )' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Open a new shell after editing, or run: . $PROFILE' -ForegroundColor DarkGray
    Write-Host ''
    return $false
}

function Invoke-RemoteServerPicker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Title,
        # Not Mandatory — empty arrays fail parameter binding before the
        # function body runs, so an upfront check in the callers is the
        # right place to handle "no servers configured."
        [array] $Servers = @()
    )

    if ($Servers.Count -eq 0) {
        # Defense-in-depth — callers already check via Test-RemoteServersConfigured,
        # but if anyone calls this picker directly with an empty list, bail
        # cleanly instead of trying to draw an empty menu.
        return $null
    }

    # Interactive picker via the shared scrollable Show-Picker. GetNewClosure
    # captures $labelWidth for the render scriptblock.
    $labelWidth = ($Servers | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
    $render = {
        param($s)
        # Address recedes to dark gray; a non-default user is worth noticing.
        $userTag = if ($s.User) { "  `e[33mas $($s.User)`e[0m" } else { '' }
        "{0}  `e[90m{1}`e[0m{2}" -f $s.Label.PadRight($labelWidth), $s.Address, $userTag
    }.GetNewClosure()

    return Show-Picker -Items $Servers -RenderRow $render `
        -Title $Title -Hint 'Up/Down + Enter  PgUp/PgDn  Esc cancel'
}

function Get-RemoteServerByMatch {
    [CmdletBinding()]
    param([string] $Match)
    if (-not $Match) { return $null }
    $servers = @($script:Config.RemoteServers)
    # Escaped so wildcard metacharacters in the input match literally
    # instead of throwing (e.g. an unbalanced '[').
    $safe = [WildcardPattern]::Escape($Match)
    $servers | Where-Object { $_.Label -like "*$safe*" -or $_.Address -like "*$safe*" } | Select-Object -First 1
}

function Resolve-RemoteServer {
    # Resolves $Match into a server object — first trying the configured
    # RemoteServers list, then falling back to treating $Match as a literal
    # address. With no $Match, opens the picker (which needs a non-empty
    # config). Returns $null when the user cancels the picker or the empty-
    # config message fires.
    [CmdletBinding()]
    param(
        [string] $Match,
        [Parameter(Mandatory)][string] $PickerTitle
    )

    if ($Match) {
        $server = Get-RemoteServerByMatch -Match $Match
        if (-not $server) {
            # Not in config — treat the argument as a literal address so
            # `rps 10.0.0.2` and `rps somehost.lab` work without needing
            # to add an entry first.
            $server = [pscustomobject]@{ Label = $Match; Address = $Match }
        }
        return $server
    }

    # No-arg path needs the picker — and the picker needs configured servers.
    if (-not (Test-RemoteServersConfigured)) { return $null }
    return Invoke-RemoteServerPicker -Title $PickerTitle -Servers @($script:Config.RemoteServers)
}

function Format-RemoteServerDisplay {
    # "Label (Address)" for configured entries, just "Address" for ad-hoc
    # ones (where Label == Address from the literal-fallback path).
    param($Server)
    if ($Server.Label -and $Server.Label -ne $Server.Address) {
        return "$($Server.Label) ($($Server.Address))"
    }
    return $Server.Address
}

function rdp {
    <#
    .SYNOPSIS
        Open Remote Desktop (mstsc) to a configured or ad-hoc server.
    .DESCRIPTION
        With no argument, opens a picker over config.psd1's RemoteServers list.
        With an argument, fuzzy-matches the list by label/address first, then
        falls back to treating the argument as a literal address.
    .PARAMETER Match
        Server label/address substring, or a literal host/IP.
    .EXAMPLE
        rdp

        Opens the picker over your configured RemoteServers; choose one and it
        launches mstsc to that host.
    .EXAMPLE
        rdp dc

        Skips the picker and connects to the first configured server whose label
        or address matches "dc".
    .EXAMPLE
        rdp 10.0.0.5

        No match in the config? The argument is used as a literal address, so you
        can RDP to an ad-hoc host without adding a bookmark first.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string] $Match)

    $server = Resolve-RemoteServer -Match $Match -PickerTitle 'Remote Desktop (mstsc)'
    if (-not $server) { return }

    Write-Host "  RDP → $(Format-RemoteServerDisplay $server)" -ForegroundColor DarkGray
    Start-Process mstsc -ArgumentList "/v:$($server.Address)"
}

function Format-PsRemotingError {
    # Maps Enter-PSSession's noisy WinRM error messages to short, actionable
    # remediations. The three branches cover the bulk of first-time-setup
    # failures: TrustedHosts (cross-domain / workgroup), access denied (creds
    # or group membership), and unreachable / WinRM-not-running on target.
    # Unknown errors fall through to a "show the original" branch.
    param($Server, $Exception)

    $msg = $Exception.Exception.Message
    Write-Host ''

    if ($msg -match 'TrustedHosts') {
        Write-Host '  Connection failed: TrustedHosts not configured for this target.' -ForegroundColor Yellow
        Write-Host '  Required when the target is not in your AD domain.' -ForegroundColor DarkGray
        Write-Host '  Run on THIS client (elevated for the WSMan: drive) and retry:' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host "      Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$($Server.Address)' -Concatenate -Force" -ForegroundColor White
        Write-Host ''
        Write-Host '  See README → "Connecting to remote hosts" for the full setup.' -ForegroundColor DarkGray
        return
    }

    if ($msg -match 'Access is denied') {
        Write-Host "  Connection failed: access denied on $($Server.Address)." -ForegroundColor Yellow
        Write-Host '  Verify credentials and that your account is in Remote Management Users / Administrators on the target.' -ForegroundColor DarkGray
        return
    }

    if ($msg -match 'cannot find the computer|cannot complete the operation|network path was not found|No such host|WinRM service is not running') {
        Write-Host "  Connection failed: $($Server.Address) is unreachable or WinRM isn't responding." -ForegroundColor Yellow
        Write-Host '  Test reachability from this client:' -ForegroundColor DarkGray
        Write-Host "      Test-NetConnection $($Server.Address) -Port 5985" -ForegroundColor White
        Write-Host '  On the TARGET (elevated), enable PSRemoting if needed:' -ForegroundColor DarkGray
        Write-Host '      Enable-PSRemoting -Force' -ForegroundColor White
        return
    }

    # Unknown — surface the underlying message so the user can act on it.
    Write-Host "  Connection to $($Server.Address) failed:" -ForegroundColor Yellow
    Write-Host "    $msg" -ForegroundColor DarkGray
}

function rps {
    <#
    .SYNOPSIS
        Open a PowerShell remoting session (Enter-PSSession) to a server.
    .DESCRIPTION
        Same picker and matching as `rdp`, but starts an interactive PSSession.
        When the chosen server entry has a User set, Get-Credential is pre-filled
        with it. Connection failures are translated into actionable remediation
        hints (TrustedHosts, access denied, WinRM unreachable).
    .PARAMETER Match
        Server label/address substring, or a literal host/IP.
    .EXAMPLE
        rps

        Opens the picker and starts an interactive Enter-PSSession to the chosen
        server (prompting for credentials, pre-filled if the entry has a User).
    .EXAMPLE
        rps build

        Connects straight to the configured server matching "build". On failure
        you get a specific fix (TrustedHosts, access denied, or WinRM unreachable)
        rather than the raw WinRM error.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string] $Match)

    $server = Resolve-RemoteServer -Match $Match -PickerTitle 'PowerShell Remoting (Enter-PSSession)'
    if (-not $server) { return }

    $display = Format-RemoteServerDisplay $server

    # Use splatting because we add -Credential conditionally. -ErrorAction Stop
    # promotes non-terminating WinRM errors so the catch block can intercept
    # them and render a useful remediation message.
    $sessionArgs = @{ ComputerName = $server.Address; ErrorAction = 'Stop' }
    if ($server.User) {
        Write-Host "  PSRemoting → $display as $($server.User)" -ForegroundColor DarkGray
        $cred = Get-Credential -UserName $server.User -Message "Credentials for $($server.Label)"
        if (-not $cred) { Write-Host '  Cancelled.' -ForegroundColor DarkGray; return }
        $sessionArgs.Credential = $cred
    } else {
        Write-Host "  PSRemoting → $display" -ForegroundColor DarkGray
    }

    try {
        Enter-PSSession @sessionArgs
    }
    catch {
        Format-PsRemotingError -Server $server -Exception $_
    }
}
