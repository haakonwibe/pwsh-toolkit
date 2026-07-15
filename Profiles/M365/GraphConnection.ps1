# Microsoft Graph Connection Functions
# Provides easy connectivity to Microsoft Graph for M365 administration
# Requires: Microsoft.Graph PowerShell module

# Core Graph connection for most M365 work.
# Named Connect-Tenant (not Connect-Graph) on purpose: Microsoft.Graph.Authentication
# exports a Connect-Graph ALIAS for Connect-MgGraph, and aliases outrank functions,
# so a Connect-Graph function here would be silently shadowed once that module loads.
function Connect-Tenant {
    <#
    .SYNOPSIS
        Connect to Microsoft Graph with preset scopes. Read-only by default.
    .DESCRIPTION
        Wraps Connect-MgGraph with predefined scope sets, so you do not have
        to remember the Graph permission names. Each tier is everything at
        that level — directory AND Intune — one knob, no per-workload switches:

          ReadOnly (default)  Read-only scopes covering all toolkit M365
                              commands (Get-TenantOverview, Get-TeamsInfo),
                              general reporting, and the Intune reads:
                              devices, configuration/compliance policies,
                              apps, scripts, RBAC.
          Write               Adds user and group management plus the
                              day-to-day Intune writes: devices,
                              configuration/compliance policies, apps,
                              scripts.
          Full                Adds directory-wide and app-registration
                              writes, Intune service-config and RBAC writes,
                              and the privileged device actions (wipe,
                              passcode reset) that Graph keeps out of the
                              ReadWrite scopes.

        Run the command again with a higher tier when you need to modify
        something. Connect-MgGraph consents the extra scopes incrementally.
        All Intune scopes require admin consent, so the first connection per
        tier after an upgrade re-prompts once.

        Note: Microsoft Entra remembers consent per app and user. After a
        write tier has been granted once, later tokens can still include
        those scopes even if you reconnect with ReadOnly. The tiers control
        what you consent to, not what each session can do.

        Intune's Graph surface is largely /beta. The session these scopes
        create works for beta too — use Invoke-MgGraphRequest against
        beta/deviceManagement/... rather than installing the huge
        Microsoft.Graph.Beta module.
    .PARAMETER Access
        Scope tier: ReadOnly (default), Write, or Full.
    .EXAMPLE
        Connect-Tenant

        Read-only session. The safe default for reporting and inspection.
    .EXAMPLE
        Connect-Tenant -Access Write

        Reconnect with user/group and day-to-day Intune write scopes to
        make changes.
    .EXAMPLE
        Connect-Tenant -Access Full

        Everything: directory and app-registration writes, Intune RBAC and
        service-config writes, and privileged device actions (wipe,
        passcode reset).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('ReadOnly', 'Write', 'Full')]
        [string] $Access = 'ReadOnly'
    )

    $scopes = @(
        "User.Read.All", "Group.Read.All", "Directory.Read.All",
        "Application.Read.All", "Reports.Read.All", "AuditLog.Read.All",
        "Organization.Read.All", "Team.ReadBasic.All", "Channel.ReadBasic.All",
        "Policy.Read.All",  # Conditional Access
        # Intune reads. Scripts is its own scope on purpose: since July 2025
        # the script endpoints (remediation/platform/shell scripts) require
        # DeviceManagementScripts.* instead of DeviceManagementConfiguration.*.
        "DeviceManagementManagedDevices.Read.All", "DeviceManagementConfiguration.Read.All",
        "DeviceManagementApps.Read.All", "DeviceManagementServiceConfig.Read.All",
        "DeviceManagementScripts.Read.All", "DeviceManagementRBAC.Read.All"
    )
    if ($Access -in @('Write', 'Full')) {
        $scopes += "User.ReadWrite.All", "Group.ReadWrite.All",
                   "DeviceManagementManagedDevices.ReadWrite.All", "DeviceManagementConfiguration.ReadWrite.All",
                   "DeviceManagementApps.ReadWrite.All", "DeviceManagementScripts.ReadWrite.All"
    }
    if ($Access -eq 'Full') {
        # PrivilegedOperations is the wipe/passcode-reset scope — Graph keeps
        # those out of ManagedDevices.ReadWrite.All, so they are Full-only here,
        # same as the destructive directory scopes.
        $scopes += "Directory.ReadWrite.All", "Application.ReadWrite.All",
                   "DeviceManagementServiceConfig.ReadWrite.All", "DeviceManagementRBAC.ReadWrite.All",
                   "DeviceManagementManagedDevices.PrivilegedOperations.All"
    }

    Write-Host "Connecting to Microsoft Graph ($Access scopes)..." -ForegroundColor Cyan

    try {
        # -ErrorAction Stop: Connect-MgGraph surfaces auth failures as
        # NON-terminating errors, which try/catch ignores. Without this the
        # function marches past the failure and prints a false "connected"
        # banner over an empty context.
        Connect-MgGraph -Scopes $scopes -NoWelcome -ErrorAction Stop

        # Belt-and-suspenders: even a "successful" call should leave a context
        # with an account. If not, treat it as a failure rather than reporting
        # a connection that isn't there.
        $context = Get-MgContext
        if (-not $context -or -not $context.Account) {
            throw "Connect-MgGraph returned no active context."
        }

        Write-Host "✅ Microsoft Graph connected ($Access)" -ForegroundColor Green
        Write-Host "Tenant: $($context.TenantId)" -ForegroundColor Yellow
        Write-Host "Account: $($context.Account)" -ForegroundColor Yellow
        if ($Access -eq 'ReadOnly') {
            Write-Host "Read-only session. Use Connect-Tenant -Access Write (or Full) to make changes." -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Warning "Failed to connect to Microsoft Graph: $_"
    }
}

# Clean disconnect for Graph (same shadowing caveat as Connect-Tenant above)
function Disconnect-Tenant {
    <#
    .SYNOPSIS
        Disconnect the current Microsoft Graph session.
    #>
    try {
        Disconnect-MgGraph
        Write-Host "✅ Microsoft Graph disconnected" -ForegroundColor Green
    } catch {
        Write-Warning "Error disconnecting from Graph: $_"
    }
}
