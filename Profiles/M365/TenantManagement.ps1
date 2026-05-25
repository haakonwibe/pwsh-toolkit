# Microsoft 365 Tenant Management Functions
# Provides comprehensive tenant overview and reporting capabilities
# Requires: Microsoft.Graph PowerShell module and active Graph connection

# Teams operations via Graph (no separate module needed!)
function Get-TeamsInfo($TeamName) {
    if (-not (Get-MgContext)) {
        Write-Warning "Not connected to Microsoft Graph. Run Connect-Graph first."
        return
    }

    if ($TeamName) {
        Get-MgTeam -Filter "displayName eq '$TeamName'"
    } else {
        Get-MgTeam | Select-Object DisplayName, Id, Description | Format-Table -AutoSize
    }
}

function Get-TenantOverview {
    if (-not (Get-MgContext)) {
        Write-Warning "Not connected to Microsoft Graph. Run Connect-Graph first."
        return
    }

    Write-Host "`n🏢 TENANT OVERVIEW" -ForegroundColor Cyan
    Write-Host "==================" -ForegroundColor Cyan

    # Basic organization info
    $org = Get-MgOrganization
    Write-Host "`n📋 Organization Details:" -ForegroundColor Yellow
    Write-Host "  Name: $($org.DisplayName)" -ForegroundColor White
    Write-Host "  Tenant ID: $($org.Id)" -ForegroundColor White
    Write-Host "  Country: $($org.CountryLetterCode)" -ForegroundColor White
    Write-Host "  Created: $($org.CreatedDateTime)" -ForegroundColor White

    # Domain information
    Write-Host "`n🌐 Domains:" -ForegroundColor Yellow
    $domains = $org.VerifiedDomains
    $domains | ForEach-Object {
        $status = if ($_.IsDefault) { "(Default)" } else { "" }
        Write-Host "  $($_.Name) $status" -ForegroundColor White
    }

    # User statistics (fixed with proper properties)
    Write-Host "`n👥 User Statistics:" -ForegroundColor Yellow

    # Get users with the properties we actually need
    $users = Get-MgUser -Top 999 -CountVariable userCount -ConsistencyLevel eventual -Property "UserPrincipalName,UserType,AssignedLicenses,SignInActivity"

    $guestUsers = ($users | Where-Object { $_.UserType -eq "Guest" }).Count
    $memberUsers = $userCount - $guestUsers
    $licensedUsers = ($users | Where-Object { $_.AssignedLicenses -and $_.AssignedLicenses.Count -gt 0 }).Count
    $unlicensedUsers = $userCount - $licensedUsers

    Write-Host "  Total Users: $userCount" -ForegroundColor White
    Write-Host "  Members: $memberUsers | Guests: $guestUsers" -ForegroundColor Green
    Write-Host "  Licensed: $licensedUsers | Unlicensed: $unlicensedUsers" -ForegroundColor Yellow

    # Recent sign-in activity (with proper property)
    try {
        $thirtyDaysAgo = (Get-Date).AddDays(-30)
        $recentSignIns = ($users | Where-Object {
            $_.SignInActivity -and
            $_.SignInActivity.LastSignInDateTime -and
            [DateTime]$_.SignInActivity.LastSignInDateTime -gt $thirtyDaysAgo
        }).Count
        Write-Host "  Active (30 days): $recentSignIns" -ForegroundColor Cyan
    } catch {
        Write-Host "  Sign-in activity data unavailable" -ForegroundColor Gray
    }

    # Group statistics
    Write-Host "`n🔗 Group Statistics:" -ForegroundColor Yellow
    $groups = Get-MgGroup -Top 999 -CountVariable groupCount -ConsistencyLevel eventual
    $securityGroups = ($groups | Where-Object { $_.GroupTypes -notcontains "Unified" }).Count
    $m365Groups = ($groups | Where-Object { $_.GroupTypes -contains "Unified" }).Count

    Write-Host "  Total Groups: $groupCount" -ForegroundColor White
    Write-Host "  Security Groups: $securityGroups" -ForegroundColor White
    Write-Host "  Microsoft 365 Groups: $m365Groups" -ForegroundColor White

    # License information
    Write-Host "`n📜 License Overview:" -ForegroundColor Yellow
    try {
        $skus = Get-MgSubscribedSku
        foreach ($sku in $skus) {
            $available = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
            Write-Host "  $($sku.SkuPartNumber): $($sku.ConsumedUnits)/$($sku.PrepaidUnits.Enabled) used ($available available)" -ForegroundColor White
        }
    }
    catch {
        Write-Host "  License information unavailable (insufficient permissions)" -ForegroundColor Gray
    }

    # Application registrations
    Write-Host "`n🔧 Applications:" -ForegroundColor Yellow
    try {
        $apps = Get-MgApplication -Top 100
        Write-Host "  Registered Applications: $($apps.Count)" -ForegroundColor White
    }
    catch {
        Write-Host "  Application count unavailable (insufficient permissions)" -ForegroundColor Gray
    }

    # Security defaults / Conditional Access
    Write-Host "`n🔒 Security Overview:" -ForegroundColor Yellow
    try {
        $policies = Get-MgIdentityConditionalAccessPolicy
        $enabledPolicies = ($policies | Where-Object { $_.State -eq "enabled" }).Count
        Write-Host "  Conditional Access Policies: $($policies.Count) total, $enabledPolicies enabled" -ForegroundColor White
    }
    catch {
        Write-Host "  Security information unavailable (insufficient permissions)" -ForegroundColor Gray
    }

    Write-Host "`n✅ Overview complete!" -ForegroundColor Green
}
