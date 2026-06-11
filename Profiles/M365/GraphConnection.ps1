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
        Connect to Microsoft Graph with preset scopes — read-only by default.
    .DESCRIPTION
        Wraps Connect-MgGraph with the scope sets the toolkit's M365 commands
        need, so you never have to remember Graph permission names:

          ReadOnly (default)  Inspect-everything scopes. Enough for
                              Get-TenantOverview, Get-TeamsInfo, and any
                              read-only reporting.
          Write               Adds day-to-day user and group management
                              (User.ReadWrite.All, Group.ReadWrite.All).
          Full                Adds directory-wide and app-registration writes
                              (Directory.ReadWrite.All, Application.ReadWrite.All).

        Re-run with a higher tier when you actually need to modify something —
        Connect-MgGraph consents the extra scopes incrementally.

        Note: Microsoft Entra remembers consent per app+user. Once a write tier
        has been granted, later tokens can still carry those scopes even when
        you reconnect ReadOnly — the tiers control what you CONSENT to, they
        are not per-session enforcement.
    .PARAMETER Access
        Scope tier: ReadOnly (default), Write, or Full.
    .EXAMPLE
        Connect-Tenant

        Read-only session — the safe default for reporting and inspection.
    .EXAMPLE
        Connect-Tenant -Access Write

        Reconnect with user/group write scopes to make changes.
    .EXAMPLE
        Connect-Tenant -Access Full

        Everything, including directory and app-registration writes.
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
        "Policy.Read.All"  # Conditional Access
    )
    if ($Access -in @('Write', 'Full')) {
        $scopes += "User.ReadWrite.All", "Group.ReadWrite.All"
    }
    if ($Access -eq 'Full') {
        $scopes += "Directory.ReadWrite.All", "Application.ReadWrite.All"
    }

    Write-Host "Connecting to Microsoft Graph ($Access scopes)..." -ForegroundColor Cyan

    try {
        Connect-MgGraph -Scopes $scopes -NoWelcome
        Write-Host "✅ Microsoft Graph connected ($Access)" -ForegroundColor Green

        # Show current context
        $context = Get-MgContext
        Write-Host "Tenant: $($context.TenantId)" -ForegroundColor Yellow
        Write-Host "Account: $($context.Account)" -ForegroundColor Yellow
        if ($Access -eq 'ReadOnly') {
            Write-Host "Read-only session — Connect-Tenant -Access Write (or Full) when you need to modify things." -ForegroundColor DarkGray
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
