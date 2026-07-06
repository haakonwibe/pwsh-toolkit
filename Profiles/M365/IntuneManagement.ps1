# Microsoft Intune Management Functions
# Device-management overview via Graph — the payoff for Connect-Tenant's Intune
# scopes. Requires: Microsoft.Graph PowerShell module and an active connection.
#
# Everything here goes through Invoke-MgGraphRequest (ships in
# Microsoft.Graph.Authentication, present in every connected session) instead of
# the Microsoft.Graph.DeviceManagement cmdlets, so nothing extra ever needs
# importing — and the same pattern extends to Intune's /beta endpoints when a
# future helper needs one.

# Page through a Graph collection and return every item. $top on the first URI
# keeps round-trips down; @odata.nextLink is followed until exhausted.
function Get-MgGraphAllPage {
    param([Parameter(Mandatory)][string] $Uri)
    $items = New-Object System.Collections.Generic.List[object]
    while ($Uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
        foreach ($v in @($page.value)) { $items.Add($v) }
        $Uri = $page.'@odata.nextLink'
    }
    return $items
}

function Get-IntuneOverview {
    <#
    .SYNOPSIS
        Print an Intune device-management overview in one shot. Needs Connect-Tenant first.
    .DESCRIPTION
        Devices by compliance state and OS, sync health (recently synced vs
        stale), and the configuration surface (device configuration profiles,
        compliance policies, managed apps). Read-only — everything is covered by
        Connect-Tenant's default ReadOnly tier.
    #>
    if (-not (Get-MgContext)) {
        Write-Warning "Not connected to Microsoft Graph. Run Connect-Tenant first."
        return
    }

    Write-Host "`n📱 INTUNE OVERVIEW" -ForegroundColor Cyan
    Write-Host "==================" -ForegroundColor Cyan

    # Managed devices — one paged fetch feeds every device-derived section.
    try {
        $devices = Get-MgGraphAllPage -Uri ("v1.0/deviceManagement/managedDevices?" +
            '$select=deviceName,operatingSystem,complianceState,lastSyncDateTime,managementAgent&$top=999')
    }
    catch {
        # Typical causes: scopes consented before the Intune tiers (reconnect),
        # or no Intune license on the tenant.
        Write-Warning "Couldn't read managed devices: $(($_.Exception.Message -split '\r?\n', 2)[0])"
        Write-Host '  If this is a 403, reconnect to pick up the Intune scopes: Connect-Tenant' -ForegroundColor Yellow
        return
    }

    Write-Host "`n💻 Managed Devices:" -ForegroundColor Yellow
    Write-Host "  Total: $($devices.Count)" -ForegroundColor White

    # Compliance: green when everything is compliant; name the exceptions.
    $byCompliance = $devices | Group-Object complianceState | Sort-Object Count -Descending
    foreach ($g in $byCompliance) {
        $color = switch ($g.Name) {
            'compliant'    { 'Green' }
            'noncompliant' { 'Red' }
            default        { 'Yellow' }   # inGracePeriod, unknown, error, conflict
        }
        Write-Host "  $($g.Name): $($g.Count)" -ForegroundColor $color
    }
    $problem = @($devices | Where-Object { $_.complianceState -ne 'compliant' })
    foreach ($d in $problem) {
        Write-Host "    - $($d.deviceName)  [$($d.complianceState)]" -ForegroundColor DarkYellow
    }

    Write-Host "`n🖥️  By OS:" -ForegroundColor Yellow
    $devices | Group-Object operatingSystem | Sort-Object Count -Descending | ForEach-Object {
        Write-Host "  $($_.Name): $($_.Count)" -ForegroundColor White
    }

    # Sync health: a device that hasn't checked in for 30+ days is drifting out
    # of management — policies, apps, and compliance data are all stale with it.
    Write-Host "`n🔄 Sync Health:" -ForegroundColor Yellow
    $now     = Get-Date
    $recent  = @($devices | Where-Object { $_.lastSyncDateTime -and ([datetime]$_.lastSyncDateTime) -gt $now.AddDays(-7) })
    $stale   = @($devices | Where-Object { -not $_.lastSyncDateTime -or ([datetime]$_.lastSyncDateTime) -lt $now.AddDays(-30) })
    Write-Host "  Synced within 7 days: $($recent.Count) of $($devices.Count)" -ForegroundColor White
    if ($stale.Count -gt 0) {
        Write-Host "  Stale (30+ days): $($stale.Count)" -ForegroundColor Red
        foreach ($d in $stale) {
            $last = if ($d.lastSyncDateTime) { ([datetime]$d.lastSyncDateTime).ToString('yyyy-MM-dd') } else { 'never' }
            Write-Host "    - $($d.deviceName)  (last sync: $last)" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host '  Stale (30+ days): 0' -ForegroundColor Green
    }

    # Configuration surface. v1.0 covers classic profiles and compliance
    # policies; Settings Catalog policies live under /beta only, so they're
    # counted separately and best-effort.
    Write-Host "`n📋 Configuration:" -ForegroundColor Yellow
    try {
        $configs    = Get-MgGraphAllPage -Uri 'v1.0/deviceManagement/deviceConfigurations?$select=id&$top=999'
        $compliance = Get-MgGraphAllPage -Uri 'v1.0/deviceManagement/deviceCompliancePolicies?$select=id&$top=999'
        Write-Host "  Device configuration profiles: $($configs.Count)" -ForegroundColor White
        Write-Host "  Compliance policies: $($compliance.Count)" -ForegroundColor White
    }
    catch {
        Write-Host '  Configuration counts unavailable (insufficient permissions)' -ForegroundColor Gray
    }
    try {
        $catalog = Get-MgGraphAllPage -Uri 'beta/deviceManagement/configurationPolicies?$select=id&$top=999'
        Write-Host "  Settings Catalog policies: $($catalog.Count)" -ForegroundColor White
    }
    catch {
        Write-Host '  Settings Catalog count unavailable (beta endpoint)' -ForegroundColor Gray
    }

    # Managed apps.
    Write-Host "`n📦 Apps:" -ForegroundColor Yellow
    try {
        $apps = Get-MgGraphAllPage -Uri 'v1.0/deviceAppManagement/mobileApps?$select=id&$top=999'
        Write-Host "  Managed apps: $($apps.Count)" -ForegroundColor White
    }
    catch {
        Write-Host '  App count unavailable (insufficient permissions)' -ForegroundColor Gray
    }

    Write-Host "`n✅ Overview complete!" -ForegroundColor Green
}
