# Microsoft Graph Connection Functions
# Provides easy connectivity to Microsoft Graph for M365 administration
# Requires: Microsoft.Graph PowerShell module

# Core Graph connection for most M365 work
function Connect-Graph {
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

# Clean disconnect for Graph
function Disconnect-Graph {
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
