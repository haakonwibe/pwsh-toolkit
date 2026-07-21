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

# Gather the whole Intune snapshot in one place so the console overview and the
# -AsDashboard render read the SAME data (no double-fetch, no drift). A fatal
# failure (the managed-device read) comes back as an object with Error set —
# no console output here, so interactive and headless callers each decide how
# to present it. The configuration/app counts are best-effort and come back
# $null when unavailable.
function Get-IntuneOverviewData {
    try {
        $devices = Get-MgGraphAllPage -Uri ("v1.0/deviceManagement/managedDevices?" +
            '$select=deviceName,operatingSystem,complianceState,lastSyncDateTime,managementAgent&$top=999')
    }
    catch {
        # Typical causes: scopes consented before the Intune tiers (reconnect),
        # or no Intune license on the tenant.
        return [pscustomobject]@{ Error = ($_.Exception.Message -split '\r?\n', 2)[0] }
    }

    # Configuration surface — best-effort. v1.0 covers classic profiles and
    # compliance policies; Settings Catalog lives under /beta only. A failure
    # (permissions, beta shape) leaves the count $null so consumers can say so.
    $configs = $compliance = $catalog = $apps = $null
    try { $configs = @(Get-MgGraphAllPage -Uri 'v1.0/deviceManagement/deviceConfigurations?$select=id&$top=999').Count }
    catch { Write-Debug "config count unavailable: $($_.Exception.Message)" }
    try { $compliance = @(Get-MgGraphAllPage -Uri 'v1.0/deviceManagement/deviceCompliancePolicies?$select=id&$top=999').Count }
    catch { Write-Debug "compliance-policy count unavailable: $($_.Exception.Message)" }
    try { $catalog = @(Get-MgGraphAllPage -Uri 'beta/deviceManagement/configurationPolicies?$select=id&$top=999').Count }
    catch { Write-Debug "Settings Catalog count unavailable: $($_.Exception.Message)" }
    try { $apps = @(Get-MgGraphAllPage -Uri 'v1.0/deviceAppManagement/mobileApps?$select=id&$top=999').Count }
    catch { Write-Debug "app count unavailable: $($_.Exception.Message)" }

    # Friendly tenant label: the signed-in account's domain beats a raw GUID.
    $ctx = Get-MgContext
    $tenant = if ($ctx.Account -and $ctx.Account -match '@(.+)$') { $Matches[1] } else { $ctx.TenantId }

    [pscustomobject]@{
        Error              = $null
        Devices            = @($devices)
        Configs            = $configs
        CompliancePolicies = $compliance
        Catalog            = $catalog
        Apps               = $apps
        Tenant             = $tenant
        Generated          = Get-Date
    }
}

# Bucket a Graph complianceState into a semantic status the dashboard colors by.
function Get-ComplianceBucket {
    [OutputType([string])]
    param([string] $State)
    switch ($State) {
        'compliant'     { 'good' }
        'inGracePeriod' { 'warn' }
        'noncompliant'  { 'crit' }
        'error'         { 'crit' }
        'conflict'      { 'crit' }
        default         { 'unknown' }   # unknown, notApplicable, configManager, …
    }
}

# The staleness policy, in one place: a device that hasn't checked in for
# IntuneStaleDays is stale; IntuneStaleCritDays (or never having synced) reads
# as critical. The console, the dashboard payload, and the cockpit's labels
# all derive from these.
$script:IntuneStaleDays     = 30
$script:IntuneStaleCritDays = 60

# Whole days since a device's last check-in as of $AsOf; $null when it has
# never synced. Floor, not round — a device is "30 days stale" only once 30
# full days have passed, and every renderer must agree at the boundary.
function Get-DeviceSyncAge {
    [OutputType([int])]
    param($Device, [Parameter(Mandatory)][datetime] $AsOf)
    if (-not $Device.lastSyncDateTime) { return $null }
    [int][math]::Floor(($AsOf - [datetime]$Device.lastSyncDateTime).TotalDays)
}

# Shape a Get-IntuneOverviewData object into the self-contained cockpit HTML by
# injecting a JSON snapshot into the template. Pure (data + template file ->
# string), so it's unit-testable without Graph or a browser.
function ConvertTo-IntuneDashboardHtml {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Data,
        [string] $TemplatePath
    )
    if (-not $TemplatePath) { $TemplatePath = Join-Path $PSScriptRoot 'IntuneCockpit.template.html' }
    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Cockpit template not found: $TemplatePath"
    }

    # @() alone would turn a bare $null Devices property into one phantom
    # device (@($null).Count is 1) — filter, so a malformed $Data renders empty.
    $devices = @($Data.Devices | Where-Object { $null -ne $_ })
    $total   = $devices.Count
    $now     = $Data.Generated

    # One classification pass groups every device into the four buckets the
    # donut understands; the crit group doubles as the non-compliant list.
    $count       = @{ good = 0; warn = 0; crit = 0; unknown = 0 }
    $critDevices = @()
    foreach ($g in ($devices | Group-Object { Get-ComplianceBucket $_.complianceState })) {
        $count[$g.Name] = $g.Count
        if ($g.Name -eq 'crit') { $critDevices = @($g.Group) }
    }
    $segments = @()
    if ($count.good)    { $segments += [pscustomobject]@{ label = 'Compliant';       value = $count.good;    bucket = 'good' } }
    if ($count.warn)    { $segments += [pscustomobject]@{ label = 'In grace period';  value = $count.warn;    bucket = 'warn' } }
    if ($count.crit)    { $segments += [pscustomobject]@{ label = 'Non-compliant';    value = $count.crit;    bucket = 'crit' } }
    if ($count.unknown) { $segments += [pscustomobject]@{ label = 'Not evaluated';    value = $count.unknown; bucket = 'unknown' } }
    $pct = if ($total) { [int][math]::Round($count.good / $total * 100, [System.MidpointRounding]::AwayFromZero) } else { 0 }

    $os = @($devices | Group-Object operatingSystem | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{ label = if ($_.Name) { $_.Name } else { 'Unknown' }; value = $_.Count }
    })

    # Stale: no check-in for IntuneStaleDays+ (or never); crit past the crit cutoff.
    $staleTmp = foreach ($d in $devices) {
        $age   = Get-DeviceSyncAge -Device $d -AsOf $now
        $never = $null -eq $age
        if ($never -or $age -ge $script:IntuneStaleDays) {
            [pscustomobject]@{
                dev   = $d.deviceName
                why   = "$($d.operatingSystem) · last sync $(if ($never) { 'never' } else { ([datetime]$d.lastSyncDateTime).ToString('yyyy-MM-dd') })"
                sev   = if ($never -or $age -ge $script:IntuneStaleCritDays) { 'crit' } else { 'warn' }
                state = if ($never) { 'never' } else { "$age d" }
                ic    = "$([char]0x25CB)"   # ○
                _age  = if ($never) { [int]::MaxValue } else { $age }
            }
        }
    }
    $stale = @($staleTmp | Sort-Object _age -Descending | Select-Object dev, why, sev, state, ic)

    # Non-compliant list = the crit bucket (needs remediation); grace shows in
    # the donut only. Basic $select carries no failure reason, so the state is
    # the "why" — a per-device reason lookup is a future add.
    $nonCompliant = @($critDevices | ForEach-Object {
        [pscustomobject]@{
            dev = $_.deviceName; why = "$($_.operatingSystem) · $($_.complianceState)"
            sev = 'crit'; state = $_.complianceState; ic = "$([char]0x2715)"   # ✕
        }
    })

    $payload = [pscustomobject]@{
        meta    = [pscustomobject]@{ tenant = $Data.Tenant; generated = $now.ToString('yyyy-MM-dd HH:mm')
                                     staleDays = $script:IntuneStaleDays }
        kpis    = [pscustomobject]@{ total = $total; compliant = $count.good; compliancePct = $pct
                                     nonCompliant = $count.crit; stale = @($stale).Count }
        compliance   = @($segments)
        os           = @($os)
        stale        = @($stale)
        nonCompliant = @($nonCompliant)
        config       = @(
            [pscustomobject]@{ label = 'Config profiles';     value = $Data.Configs;            beta = $false }
            [pscustomobject]@{ label = 'Compliance policies'; value = $Data.CompliancePolicies; beta = $false }
            [pscustomobject]@{ label = 'Settings Catalog';    value = $Data.Catalog;            beta = $true  }
            [pscustomobject]@{ label = 'Managed apps';        value = $Data.Apps;               beta = $false }
        )
    }

    # Escape < so a device name containing '</script>' can't break out of the
    # data block. < is valid JSON and JSON.parse turns it back into '<'.
    $json = ($payload | ConvertTo-Json -Depth 6).Replace('<', ([char]0x5C + 'u003c'))
    $tpl  = Get-Content -Raw -LiteralPath $TemplatePath
    # Swap the payload into the one #cockpit-data element. Anchoring on the
    # full element — not the bare token, which .Replace would also hit inside
    # comments or prose — keeps the injection to exactly one place.
    $anchor = '<script id="cockpit-data" type="application/json">__COCKPIT_DATA__</script>'
    if (-not $tpl.Contains($anchor)) {
        throw "Cockpit template has no #cockpit-data placeholder: $TemplatePath"
    }
    return $tpl.Replace($anchor, $anchor.Replace('__COCKPIT_DATA__', $json))
}

# Render the dashboard to a stable file under %LOCALAPPDATA% and open it.
function Show-IntuneDashboard {
    param([Parameter(Mandatory)] $Data)
    $html = ConvertTo-IntuneDashboardHtml -Data $Data
    $out  = Get-ToolkitDataPath 'intune-cockpit.html'
    Set-Content -LiteralPath $out -Value $html -Encoding utf8
    Write-Host "  Dashboard written: $out" -ForegroundColor Green
    try {
        Write-Host '  Opening in your browser…' -ForegroundColor DarkGray
        Invoke-Item -LiteralPath $out -ErrorAction Stop
    }
    catch {
        # The dashboard itself is fine — only the auto-open failed.
        Write-Host "  Couldn't open it automatically — open the file above manually." -ForegroundColor Yellow
    }
}

function Get-IntuneOverview {
    <#
    .SYNOPSIS
        Intune device-management overview in one shot. Needs Connect-Tenant first.
    .DESCRIPTION
        Devices by compliance state and OS, sync health (recently synced vs
        stale), and the configuration surface (device configuration profiles,
        compliance policies, Settings Catalog, managed apps). Read-only —
        everything is covered by Connect-Tenant's default ReadOnly tier.

        -AsDashboard renders the same snapshot as a visual cockpit: an HTML file
        written under %LOCALAPPDATA%\pwsh-toolkit and opened in your browser.
        The file is self-contained (inline styles/scripts, no network), so it's
        a local snapshot that shares nothing externally.
    .PARAMETER AsDashboard
        Render the overview as a visual HTML cockpit and open it, instead of
        printing to the console.
    .EXAMPLE
        Get-IntuneOverview

        The console overview — compliance, OS, sync health, configuration.
    .EXAMPLE
        Get-IntuneOverview -AsDashboard

        The same snapshot as a visual dashboard, opened in your browser.
    #>
    [CmdletBinding()]
    param([switch] $AsDashboard)

    if (-not (Get-MgContext)) {
        Write-Warning "Not connected to Microsoft Graph. Run Connect-Tenant first."
        return
    }

    # Console mode banners before the fetch, so a fetch failure still appears
    # under the command's usual header rather than as a bare warning.
    if (-not $AsDashboard) {
        Write-Host "`n📱 INTUNE OVERVIEW" -ForegroundColor Cyan
        Write-Host "==================" -ForegroundColor Cyan
    }

    $data = Get-IntuneOverviewData
    if ($data.Error) {
        Write-Warning "Couldn't read managed devices: $($data.Error)"
        Write-Host '  If this is a 403, reconnect to pick up the Intune scopes: Connect-Tenant' -ForegroundColor Yellow
        return
    }

    if ($AsDashboard) { Show-IntuneDashboard -Data $data; return }

    # ---- console overview ----
    $devices = @($data.Devices)
    Write-Host "`n💻 Managed Devices:" -ForegroundColor Yellow
    Write-Host "  Total: $($devices.Count)" -ForegroundColor White

    # Compliance: green when everything is compliant; name the exceptions.
    # Severity comes from Get-ComplianceBucket so console and dashboard agree —
    # error/conflict are remediation-red in both, not a softer yellow.
    $byCompliance = $devices | Group-Object complianceState | Sort-Object Count -Descending
    foreach ($g in $byCompliance) {
        $color = switch (Get-ComplianceBucket $g.Name) {
            'good'  { 'Green' }
            'crit'  { 'Red' }
            default { 'Yellow' }   # warn (inGracePeriod), unknown
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
    $now    = $data.Generated
    $recent = @($devices | Where-Object { $age = Get-DeviceSyncAge -Device $_ -AsOf $now
                                          ($null -ne $age) -and $age -lt 7 })
    $stale  = @($devices | Where-Object { $age = Get-DeviceSyncAge -Device $_ -AsOf $now
                                          ($null -eq $age) -or $age -ge $script:IntuneStaleDays })
    Write-Host "  Synced within 7 days: $($recent.Count) of $($devices.Count)" -ForegroundColor White
    if ($stale.Count -gt 0) {
        Write-Host "  Stale ($($script:IntuneStaleDays)+ days): $($stale.Count)" -ForegroundColor Red
        foreach ($d in $stale) {
            $last = if ($d.lastSyncDateTime) { ([datetime]$d.lastSyncDateTime).ToString('yyyy-MM-dd') } else { 'never' }
            Write-Host "    - $($d.deviceName)  (last sync: $last)" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  Stale ($($script:IntuneStaleDays)+ days): 0" -ForegroundColor Green
    }

    # Configuration surface — counts gathered above; $null means that count was
    # unavailable. Each is best-effort and can fail independently, so each gets
    # its own line rather than one all-or-nothing gate.
    Write-Host "`n📋 Configuration:" -ForegroundColor Yellow
    if ($null -ne $data.Configs) {
        Write-Host "  Device configuration profiles: $($data.Configs)" -ForegroundColor White
    } else {
        Write-Host '  Device configuration profile count unavailable (insufficient permissions)' -ForegroundColor Gray
    }
    if ($null -ne $data.CompliancePolicies) {
        Write-Host "  Compliance policies: $($data.CompliancePolicies)" -ForegroundColor White
    } else {
        Write-Host '  Compliance policy count unavailable (insufficient permissions)' -ForegroundColor Gray
    }
    if ($null -ne $data.Catalog) {
        Write-Host "  Settings Catalog policies: $($data.Catalog)" -ForegroundColor White
    } else {
        Write-Host '  Settings Catalog count unavailable (beta endpoint)' -ForegroundColor Gray
    }

    Write-Host "`n📦 Apps:" -ForegroundColor Yellow
    if ($null -ne $data.Apps) {
        Write-Host "  Managed apps: $($data.Apps)" -ForegroundColor White
    } else {
        Write-Host '  App count unavailable (insufficient permissions)' -ForegroundColor Gray
    }

    Write-Host "`n✅ Overview complete!" -ForegroundColor Green
    Write-Host '   Tip: Get-IntuneOverview -AsDashboard for the visual cockpit.' -ForegroundColor DarkGray
}
