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
        Connect to Microsoft Graph with the toolkit's preset admin scopes.
    #>
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan

    $scopes = @(
        "User.ReadWrite.All", "Group.ReadWrite.All", "Directory.ReadWrite.All",
        "Application.ReadWrite.All", "Reports.Read.All", "AuditLog.Read.All",
        "Organization.Read.All", "Team.ReadBasic.All", "Channel.ReadBasic.All",
        "Directory.Read.All", "Policy.Read.All"  # Added for Conditional Access
    )

    try {
        Connect-MgGraph -Scopes $scopes -NoWelcome
        Write-Host "✅ Microsoft Graph connected" -ForegroundColor Green

        # Show current context
        $context = Get-MgContext
        Write-Host "Tenant: $($context.TenantId)" -ForegroundColor Yellow
        Write-Host "Account: $($context.Account)" -ForegroundColor Yellow
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
