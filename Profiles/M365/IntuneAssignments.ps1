# Intune assignments seen from the target's side. The portal answers "who gets
# this policy?" one policy at a time; the reverse questions, "what does this
# group get?" and "what does this user or device get?", have no page at all.
# Same plumbing as the rest of M365/: Invoke-MgGraphRequest via
# Get-MgGraphAllPage, /beta for the surfaces that only live there, nothing
# extra to import.

function Get-IntuneAssignment {
    <#
    .SYNOPSIS
        Everything Intune assigns to a group, user or device, or excludes it from: profiles, policies, scripts, updates, enrollment, apps. Needs Connect-Tenant first.
    .DESCRIPTION
        The reverse of the portal's per-policy Assignments page: name a group,
        a user or a device, and every assignable Intune surface is checked for
        assignments that include or exclude it. Prints one summary line with
        the include and exclude counts, then emits one row per assignment.
        The table groups the rows under the group each one comes through,
        with All users or All devices last.

        Surfaces read: device configuration profiles (update rings included),
        Settings Catalog (which also holds current endpoint security policies
        and security baselines), administrative templates, compliance
        policies, legacy endpoint security intents, platform scripts,
        remediations, macOS shell scripts, feature, expedited quality and
        driver update profiles, quality update policies, Autopilot profiles,
        enrollment configurations (ESP, enrollment restrictions, Windows
        Hello), apps, app configuration (managed devices and managed apps),
        and iOS/Android/Windows app protection. Not read: terms and
        conditions, macOS custom attribute scripts, Windows Information
        Protection, Cloud PC, and RBAC.

        Type is finer than the surface where one surface holds several kinds
        of thing: a Settings Catalog row reads Security baseline, Endpoint
        security (Antivirus) or Endpoint Privilege Management when that's what
        it is, an update ring reads Update ring rather than Device
        configuration, and an enrollment configuration reads Enrollment status
        page, Enrollment restriction, Windows Hello for Business or Windows
        backup and restore. App rows name the app's kind and carry their
        intent, so 'Win32 app (required)' and 'Store app (uninstall)' read
        apart at a glance. Two apps that share a name, usually an old and a
        new package of the same app, get their version added to Name, or the
        date they were added where the versions match. Filter names the
        assignment filter that narrows a row: 'only <filter>' when it picks
        the devices that get the assignment, 'except <filter>' when it picks
        the ones that don't.

        -Group lists direct assignments by default. -Inherited adds the
        assignments of every group this one belongs to, directly or further
        up, since those reach its members too. Such rows sit under their
        parent's heading, and their Group and GroupId name the parent. All
        users and All devices reach members as well; -Inherited counts those
        in the summary line instead of listing them, because in most tenants
        they would crowd out everything else.

        -User and -Device list what reaches that user or device: the
        assignments of every group it belongs to, directly or further up,
        plus whatever goes to All users (for a user) or All devices (for a
        device). When one policy both includes and excludes them through
        different groups, the exclusion wins, and a second summary line names
        those policies, since their rows sit under different headings.

        -Device also checks each assignment filter against the device, the
        same check as Preview devices in the filter editor: it judges the
        properties Intune holds for the device now, not what was evaluated
        at its last check-in. A row whose filter rules the device out reads
        'Filtered out' in the Assignment column, and the summary line counts
        them. The Assignment property itself stays Include; FilteredOut says
        which rows are ruled out ($null where nothing was checked). Filters
        on managed-app assignments judge the app rather than the device, so
        they're left unchecked. -User doesn't check filters, since each of a
        user's devices can answer differently.

        A surface that can't be read (missing permission or license) is named
        in a warning rather than skipped silently, so an empty result means
        nothing was found, not that nothing could be checked. Read-only;
        covered by Connect-Tenant's default ReadOnly tier.
    .PARAMETER Group
        The group's display name (exact match) or object id. Display names
        aren't unique in Entra ID; when a name matches more than one group the
        command stops and lists their ids.
    .PARAMETER Inherited
        With -Group: also list what reaches the group through the groups it
        belongs to, and count All users / All devices assignments in the
        summary line. Costs one extra directory read.
    .PARAMETER User
        The user's principal name (UPN) or object id.
    .PARAMETER Device
        The device's name in Entra ID, or any one of its ids: the Entra object
        id, the Entra device id, or the Intune device id. Device names aren't
        unique (a reinstall can leave a stale record behind); when a name
        matches more than one device the command stops and lists their ids
        with each one's last sign-in.
    .EXAMPLE
        Get-IntuneAssignment 'Pilot Devices'

        Every profile, policy, script and app assigned to or excluding the
        group, with the include/exclude counts on top.
    .EXAMPLE
        Get-IntuneAssignment 'Pilot Devices' -Inherited

        Adds what the group gets through its parent groups, each such row
        marked with the parent it comes through.
    .EXAMPLE
        Get-IntuneAssignment -User pat@contoso.com

        What reaches one user: through each of their groups, and All users.
    .EXAMPLE
        Get-IntuneAssignment -Device LAPTOP-1 | Where-Object Assignment -EQ 'Exclude'

        The exclusions that reach one device, and the groups they come through.
    .EXAMPLE
        Get-IntuneAssignment -Device LAPTOP-1 | Where-Object FilteredOut

        The assignments that reach the device's groups but whose filter rules
        the device out.
    .EXAMPLE
        Get-IntuneAssignment 'Pilot Devices' | Format-List

        Every property per row, including the policy id, the app intent and
        the filter id.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Group')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Group')]
        [string] $Group,

        [Parameter(ParameterSetName = 'Group')]
        [switch] $Inherited,

        [Parameter(Mandatory, ParameterSetName = 'User')]
        [string] $User,

        [Parameter(Mandatory, ParameterSetName = 'Device')]
        [string] $Device
    )

    if (-not (Get-MgContext)) {
        Write-Warning "Not connected to Microsoft Graph. Run Connect-Tenant first."
        return
    }

    # Group id -> display name for every group a directory object belongs to,
    # directly or further up. No query options: an OData cast or $filter on
    # transitiveMemberOf needs the ConsistencyLevel header, which
    # Get-MgGraphAllPage doesn't send. The type check does the cast's job; the
    # list also holds directory roles and administrative units.
    $memberOf = {
        param([string] $Path, [string] $Who, [string] $Otherwise)
        $map = @{}
        try {
            foreach ($m in Get-MgGraphAllPage -Uri "v1.0/$Path/transitiveMemberOf") {
                if ($m.'@odata.type' -eq '#microsoft.graph.group') { $map[$m.id] = $m.displayName ?? $m.id }
            }
        } catch {
            Write-Warning "Couldn't read the groups $Who belongs to, so $Otherwise`: $(($_.Exception.Message -split '\r?\n', 2)[0])"
        }
        $map
    }

    # Who the rows are about. $targets maps group id -> the name to show as
    # 'via <name>', or $null for the -Group group itself. $everyone is the All
    # users / All devices target that reaches a -User / -Device subject.
    $isGroup   = $PSCmdlet.ParameterSetName -eq 'Group'
    $groupId   = $null
    $groupName = $null
    $everyone  = $null
    switch ($PSCmdlet.ParameterSetName) {
        'Group' {
            # Assignments reference groups by id only, so a name has to become one.
            if ($Group -as [guid]) {
                $groupId   = ([guid]$Group).ToString()
                $groupName = Resolve-GroupDisplayName -GroupId $groupId
                if ($groupName -eq $groupId) {
                    # Deleted, or no directory read on this session. Assignments can
                    # outlive their group, so matching on the id is still worth doing.
                    Write-Warning "Couldn't look up group $groupId in the directory; matching on the id anyway."
                }
            } else {
                # Escaped twice over: quotes doubled for OData, then the whole
                # expression for the query string, so a name containing & or #
                # can't cut the filter short.
                $filter = [uri]::EscapeDataString("displayName eq '$($Group -replace "'", "''")'")
                $found  = @(Get-MgGraphAllPage -Uri "v1.0/groups?`$filter=$filter&`$select=id,displayName")
                if ($found.Count -eq 0) {
                    Write-Error "No group is named '$Group'. The name must match exactly; an object id works too."
                    return
                }
                if ($found.Count -gt 1) {
                    Write-Error "$($found.Count) groups are named '$Group'. Pass one of their ids instead: $($found.id -join ', ')"
                    return
                }
                $groupId   = $found[0].id
                $groupName = $found[0].displayName
            }
            $label   = if ($groupName -ne $groupId) { "$groupName ($groupId)" } else { $groupId }
            $targets = @{ $groupId = $null }
            if ($Inherited) {
                $parents = & $memberOf "groups/$groupId" $groupName 'only its direct assignments are listed'
                foreach ($k in $parents.Keys) { $targets[$k] = $parents[$k] }
            }
        }
        'User' {
            try {
                $u = Invoke-MgGraphRequest -Method GET -ErrorAction Stop -Uri (
                    "v1.0/users/$([uri]::EscapeDataString($User))?`$select=id,displayName,userPrincipalName")
            } catch {
                Write-Error "Couldn't find user '$User' ($(($_.Exception.Message -split '\r?\n', 2)[0])). Pass a user principal name or an object id."
                return
            }
            $label    = "$($u.displayName) ($($u.userPrincipalName))"
            $targets  = & $memberOf "users/$($u.id)" $u.displayName 'only All users assignments are listed'
            $everyone = @{ Type = '#microsoft.graph.allLicensedUsersAssignmentTarget'; Name = 'All users' }
        }
        'Device' {
            # Groups hold the Entra device object, so whichever id or name
            # arrives has to become that object. Three ids name a device: the
            # Entra object id, the Entra device id, and the Intune device id.
            $fields   = '$select=id,deviceId,displayName,approximateLastSignInDateTime'
            $byDevice = { param($id) Get-MgGraphAllPage -Uri ("v1.0/devices?`$filter=" + [uri]::EscapeDataString("deviceId eq '$id'") + "&$fields") }
            $found = @(
                if ($Device -as [guid]) {
                    $g   = ([guid]$Device).ToString()
                    $hit = try { Invoke-MgGraphRequest -Method GET -Uri "v1.0/devices/$g`?$fields" -ErrorAction Stop } catch { $null }
                    if (-not $hit) { $hit = @(& $byDevice $g) }
                    if (-not $hit) {
                        $managed = try {
                            Invoke-MgGraphRequest -Method GET -Uri "beta/deviceManagement/managedDevices/$g`?`$select=azureADDeviceId" -ErrorAction Stop
                        } catch { $null }
                        $entraId = $managed.azureADDeviceId
                        if ($entraId -and $entraId -ne [guid]::Empty.ToString()) { $hit = @(& $byDevice $entraId) }
                    }
                    $hit
                } else {
                    $filter = [uri]::EscapeDataString("displayName eq '$($Device -replace "'", "''")'")
                    Get-MgGraphAllPage -Uri "v1.0/devices?`$filter=$filter&$fields"
                }
            )
            if ($found.Count -eq 0) {
                if ($Device -as [guid]) {
                    Write-Error "No device has the id '$Device', as an Entra object id, Entra device id or Intune device id."
                } else {
                    Write-Error "No device is named '$Device'. The name must match exactly; an id works too."
                }
                return
            }
            if ($found.Count -gt 1) {
                $ids = foreach ($f in $found) {
                    $seen = if ($f.approximateLastSignInDateTime) { ([datetime]$f.approximateLastSignInDateTime).ToString('yyyy-MM-dd') } else { 'never' }
                    "$($f.id) (last sign-in $seen)"
                }
                Write-Error "$($found.Count) devices are named '$Device'. Pass one of their ids instead: $($ids -join ', ')"
                return
            }
            $d        = $found[0]
            $label    = "$($d.displayName) ($($d.id))"
            $targets  = & $memberOf "devices/$($d.id)" $d.displayName 'only All devices assignments are listed'
            $everyone = @{ Type = '#microsoft.graph.allDevicesAssignmentTarget'; Name = 'All devices' }
        }
    }

    # Finer labels for surfaces that hold several kinds of thing; anything not
    # listed keeps the surface's own label. Each surface names the kind in a
    # different place.
    $catalogKinds = @{   # templateReference.templateFamily
        baseline                                     = 'Security baseline'
        endpointSecurityAntivirus                    = 'Endpoint security (Antivirus)'
        endpointSecurityDiskEncryption               = 'Endpoint security (Disk encryption)'
        endpointSecurityFirewall                     = 'Endpoint security (Firewall)'
        endpointSecurityEndpointDetectionAndResponse = 'Endpoint security (EDR)'
        endpointSecurityAttackSurfaceReduction       = 'Endpoint security (ASR)'
        endpointSecurityAccountProtection            = 'Endpoint security (Account protection)'
        endpointSecurityApplicationControl           = 'Endpoint security (App Control)'
        endpointSecurityEndpointPrivilegeManagement  = 'Endpoint Privilege Management'
        appQuietTime                                 = 'Quiet time'
    }
    $configKinds = @{   # @odata.type
        '#microsoft.graph.windowsUpdateForBusinessConfiguration' = 'Update ring'
        '#microsoft.graph.iosUpdateConfiguration'                = 'Update policy (iOS)'
        '#microsoft.graph.macOSSoftwareUpdateConfiguration'      = 'Update policy (macOS)'
    }
    $enrollmentKinds = @{   # deviceEnrollmentConfigurationType
        # The tenant defaults ('All users and all devices') usually report the
        # plain value; the default* values are in the enum too, so map those.
        windows10EnrollmentCompletionPageConfiguration        = 'Enrollment status page'
        defaultWindows10EnrollmentCompletionPageConfiguration = 'Enrollment status page'
        platformRestrictions                                  = 'Enrollment restriction (platform)'
        defaultPlatformRestrictions                           = 'Enrollment restriction (platform)'
        singlePlatformRestriction                             = 'Enrollment restriction (platform)'
        limit                                                 = 'Enrollment restriction (limit)'
        defaultLimit                                          = 'Enrollment restriction (limit)'
        windowsHelloForBusiness                               = 'Windows Hello for Business'
        defaultWindowsHelloForBusiness                        = 'Windows Hello for Business'
        deviceComanagementAuthorityConfiguration              = 'Co-management settings'
        enrollmentNotificationsConfiguration                  = 'Enrollment notification'
        windowsRestore                                        = 'Windows backup and restore'
    }
    # @odata.type. Without these, a Win32 app and the Store copy of the same
    # app are two identical rows. Windows kinds go unprefixed (Win32, MSI and
    # MSIX are Windows-only anyway); the other platforms say which they are.
    $appKinds = @{
        '#microsoft.graph.win32LobApp'                  = 'Win32 app'
        '#microsoft.graph.win32CatalogApp'              = 'Win32 app (catalog)'
        '#microsoft.graph.winGetApp'                    = 'Store app'
        '#microsoft.graph.windowsStoreApp'              = 'Store app (legacy)'
        '#microsoft.graph.microsoftStoreForBusinessApp' = 'Store for Business app'
        '#microsoft.graph.officeSuiteApp'               = 'Microsoft 365 Apps'
        '#microsoft.graph.windowsMicrosoftEdgeApp'      = 'Edge'
        '#microsoft.graph.windowsMobileMSI'             = 'MSI app'
        '#microsoft.graph.windowsUniversalAppX'         = 'MSIX app'
        '#microsoft.graph.windowsAppX'                  = 'AppX app'
        '#microsoft.graph.windowsWebApp'                = 'Web link'
        '#microsoft.graph.webApp'                       = 'Web link'
        '#microsoft.graph.iosStoreApp'                  = 'iOS store app'
        '#microsoft.graph.iosVppApp'                    = 'iOS VPP app'
        '#microsoft.graph.iosLobApp'                    = 'iOS LOB app'
        '#microsoft.graph.iosiPadOSWebClip'             = 'iOS web clip'
        '#microsoft.graph.macOSDmgApp'                  = 'macOS DMG app'
        '#microsoft.graph.macOSPkgApp'                  = 'macOS PKG app'
        '#microsoft.graph.macOSLobApp'                  = 'macOS LOB app'
        '#microsoft.graph.macOsVppApp'                  = 'macOS VPP app'
        '#microsoft.graph.macOSOfficeSuiteApp'          = 'Microsoft 365 Apps (macOS)'
        '#microsoft.graph.macOSMicrosoftEdgeApp'        = 'Edge (macOS)'
        '#microsoft.graph.macOSMicrosoftDefenderApp'    = 'Defender (macOS)'
        '#microsoft.graph.macOSWebClip'                 = 'macOS web clip'
        '#microsoft.graph.androidManagedStoreApp'       = 'Managed Google Play app'
        '#microsoft.graph.androidManagedStoreWebApp'    = 'Managed Google Play web link'
        '#microsoft.graph.androidStoreApp'              = 'Android store app'
        '#microsoft.graph.androidLobApp'                = 'Android LOB app'
    }

    # Every assignable surface, in the order they're read. NoExpand marks a
    # collection that doesn't take $expand=assignments; its items are read one
    # at a time, the same fallback used when a collection ignores the expand.
    # Kind, where present, picks the finer label for an item. Quality update
    # profiles are the expedite kind; quality update policies are the newer,
    # separate object (approvals, hotpatch).
    $sources = @(
        @{ Type = 'Device configuration';       Uri = 'beta/deviceManagement/deviceConfigurations'
           Kind = { param($i) $configKinds["$($i.'@odata.type')"] } }
        @{ Type = 'Settings catalog';           Uri = 'beta/deviceManagement/configurationPolicies'
           Kind = { param($i) $catalogKinds["$($i.templateReference.templateFamily)"] } }
        @{ Type = 'Administrative template';    Uri = 'beta/deviceManagement/groupPolicyConfigurations' }
        @{ Type = 'Compliance';                 Uri = 'beta/deviceManagement/deviceCompliancePolicies' }
        @{ Type = 'Endpoint security (legacy)'; Uri = 'beta/deviceManagement/intents'; NoExpand = $true }
        @{ Type = 'Platform script';            Uri = 'beta/deviceManagement/deviceManagementScripts' }
        @{ Type = 'Remediation';                Uri = 'beta/deviceManagement/deviceHealthScripts' }
        @{ Type = 'macOS shell script';         Uri = 'beta/deviceManagement/deviceShellScripts' }
        @{ Type = 'Feature update';             Uri = 'beta/deviceManagement/windowsFeatureUpdateProfiles' }
        @{ Type = 'Expedited quality update';   Uri = 'beta/deviceManagement/windowsQualityUpdateProfiles' }
        @{ Type = 'Quality update policy';      Uri = 'beta/deviceManagement/windowsQualityUpdatePolicies' }
        @{ Type = 'Driver update';              Uri = 'beta/deviceManagement/windowsDriverUpdateProfiles' }
        @{ Type = 'Autopilot profile';          Uri = 'beta/deviceManagement/windowsAutopilotDeploymentProfiles' }
        @{ Type = 'Enrollment configuration';   Uri = 'beta/deviceManagement/deviceEnrollmentConfigurations'
           Kind = { param($i) $enrollmentKinds["$($i.deviceEnrollmentConfigurationType)"] } }
        @{ Type = 'App';                        Uri = 'beta/deviceAppManagement/mobileApps'
           Kind = { param($i) $appKinds["$($i.'@odata.type')"] } }
        @{ Type = 'App configuration';          Uri = 'beta/deviceAppManagement/mobileAppConfigurations' }
        @{ Type = 'App configuration (MAM)';    Uri = 'beta/deviceAppManagement/targetedManagedAppConfigurations' }
        @{ Type = 'App protection (iOS)';       Uri = 'beta/deviceAppManagement/iosManagedAppProtections' }
        @{ Type = 'App protection (Android)';   Uri = 'beta/deviceAppManagement/androidManagedAppProtections' }
        @{ Type = 'App protection (Windows)';   Uri = 'beta/deviceAppManagement/windowsManagedAppProtections' }
    )

    $rows        = [System.Collections.Generic.List[object]]::new()
    $unread      = [System.Collections.Generic.List[string]]::new()
    $filters     = $null   # assignment filter id -> filter, fetched on first use
    $appInfo     = @{}     # app id -> version and date added, for same-named apps
    $viaParent   = 0       # -Group rows that reach the group through a parent
    $allUsers    = 0       # All users / All devices assignments, counted
    $allDevices  = 0       # under -Group -Inherited
    $done        = 0
    foreach ($src in $sources) {
        Write-Progress -Activity 'Reading Intune assignments' -Status $src.Type -PercentComplete (100 * $done++ / $sources.Count)
        try {
            $uri = if ($src.NoExpand) { $src.Uri } else { "$($src.Uri)?`$expand=assignments" }
            foreach ($item in Get-MgGraphAllPage -Uri $uri) {
                # An expanded item carries the key even with no assignments
                # (an empty array); a missing key means it wasn't expanded.
                $assignments = $item.assignments
                if ($null -eq $assignments) {
                    $assignments = Get-MgGraphAllPage -Uri "$($src.Uri)/$($item.id)/assignments"
                }
                $type = $src.Type
                if ($src.Kind) { $type = (& $src.Kind $item) ?? $type }
                if ($src.Type -eq 'App') {
                    $appInfo[$item.id] = [pscustomobject]@{
                        Version = $item.displayVersion
                        Added   = if ($item.createdDateTime) { ([datetime]$item.createdDateTime).ToString('yyyy-MM-dd') }
                    }
                }

                foreach ($a in $assignments) {
                    $t         = $a.target
                    $odataType = "$($t.'@odata.type')"
                    $tid       = "$($t.groupId)"   # '' for targets without a group
                    if ($tid -and $targets.ContainsKey($tid)) {
                        # Exact types, not a '*groupAssignmentTarget' wildcard:
                        # scopeTagGroupAssignmentTarget would match that too, and
                        # it isn't an assignment to the group.
                        $mode = switch ($odataType) {
                            '#microsoft.graph.groupAssignmentTarget'          { 'Include' }
                            '#microsoft.graph.exclusionGroupAssignmentTarget' { 'Exclude' }
                        }
                        if (-not $mode) { continue }
                        $via = $targets[$tid]   # $null: the -Group group itself
                        if ($via) { $toName = $via;       $toId = $tid }
                        else      { $toName = $groupName; $toId = $groupId }
                    } elseif ($everyone -and $odataType -eq $everyone.Type) {
                        $mode = 'Include'; $via = $null; $toName = $everyone.Name; $toId = $null
                    } else {
                        if ($Inherited) {
                            switch ($odataType) {
                                '#microsoft.graph.allLicensedUsersAssignmentTarget' { $allUsers++ }
                                '#microsoft.graph.allDevicesAssignmentTarget'       { $allDevices++ }
                            }
                        }
                        continue
                    }

                    $filterId   = $t.deviceAndAppManagementAssignmentFilterId
                    $filterType = $t.deviceAndAppManagementAssignmentFilterType
                    $filterText = $null
                    if ($filterId -and $filterType -in 'include', 'exclude') {
                        if ($null -eq $filters) {
                            # The rule and platform come along for -Device,
                            # which checks each filter against the device.
                            $filters = @{}
                            try {
                                foreach ($f in Get-MgGraphAllPage -Uri 'beta/deviceManagement/assignmentFilters?$select=id,displayName,platform,rule,assignmentFilterManagementType') {
                                    $filters[$f.id] = $f
                                }
                            } catch { Write-Debug "assignment filters unavailable: $($_.Exception.Message)" }
                        }
                        # The mode leads, so a narrow console cuts the filter's
                        # name rather than whether it lets devices in or out.
                        $narrows    = if ($filterType -eq 'include') { 'only' } else { 'except' }
                        $filterText = "$narrows $($filters[$filterId].displayName ?? $filterId)"
                    } else {
                        $filterId   = $null
                        $filterType = $null
                    }

                    if ($via) { $viaParent++ }
                    # Every profile assignment says 'apply'; only the other
                    # intents (an app's required/available/uninstall, a
                    # profile's rare 'remove') tell the reader something.
                    $intent = if ($a.intent -and $a.intent -ne 'apply') { $a.intent }
                    $rows.Add([pscustomobject]@{
                        PSTypeName  = 'PwshToolkit.IntuneAssignment'   # the grouped table view
                        Type        = if ($intent) { "$type ($intent)" } else { $type }
                        Name        = $item.displayName ?? $item.name   # Settings Catalog says `name`
                        Assignment  = $mode
                        Filter      = $filterText
                        FilteredOut = $null   # -Device fills it in below
                        Intent      = $a.intent
                        PolicyId    = $item.id
                        FilterId    = $filterId
                        FilterType  = $filterType
                        Group       = $toName
                        GroupId     = $toId
                    })
                }
            }
        } catch {
            $unread.Add("$($src.Type) ($(($_.Exception.Message -split '\r?\n', 2)[0]))")
        }
    }
    Write-Progress -Activity 'Reading Intune assignments' -Completed

    # Two apps with one name are usually an old and a new package of the same
    # app (an Enterprise App Catalog update adds a new one), and their rows
    # would look identical. The version tells them apart; where the versions
    # match, the date each was added does.
    $sameName = $rows | Where-Object { $appInfo.ContainsKey($_.PolicyId) } | Group-Object Name |
        Where-Object { @($_.Group.PolicyId | Select-Object -Unique).Count -gt 1 }
    foreach ($set in $sameName) {
        $ids       = @($set.Group.PolicyId | Select-Object -Unique)
        $byVersion = @($ids | ForEach-Object { $appInfo[$_].Version } | Where-Object { $_ } | Select-Object -Unique).Count -eq $ids.Count
        foreach ($r in $set.Group) {
            $info   = $appInfo[$r.PolicyId]
            $r.Name = if ($byVersion) { "$($r.Name) $($info.Version)" } else { "$($r.Name) (added $($info.Added))" }
        }
    }

    if ($unread.Count) {
        Write-Warning ("Not every surface could be read, so assignments there may be missing: " + ($unread -join '; '))
    }

    # -Device: whether each assignment filter matches the device. This is the
    # filter editor's Preview devices (evaluateAssignmentFilter), so it judges
    # the properties Intune holds for the device now; the per-device record of
    # what was evaluated at check-in (getAssignmentFiltersStatusDetails) came
    # back empty when tried against a live tenant. Filters for managed apps
    # judge the app, not the device, so they're skipped.
    if ($PSCmdlet.ParameterSetName -eq 'Device') {
        $toCheck = @($rows | Where-Object FilterId | ForEach-Object FilterId | Select-Object -Unique |
            Where-Object { $filters[$_].rule -and $filters[$_].assignmentFilterManagementType -ne 'apps' })
        $managed = $null
        if ($toCheck.Count) {
            try {
                # Several Intune records can share one Entra device after a
                # re-enrollment; the one that synced last is the live one.
                $managed = @(Get-MgGraphAllPage -Uri ("beta/deviceManagement/managedDevices?`$filter=" +
                        [uri]::EscapeDataString("azureADDeviceId eq '$($d.deviceId)'") + '&$select=id,deviceName,lastSyncDateTime')) |
                    Sort-Object { $_.lastSyncDateTime } -Descending | Select-Object -First 1
                if (-not $managed) { Write-Warning "$($d.displayName) has no Intune record, so its assignment filters weren't checked." }
            } catch {
                Write-Warning "Couldn't find $($d.displayName) in Intune, so its assignment filters weren't checked: $(($_.Exception.Message -split '\r?\n', 2)[0])"
            }
        }
        if ($managed) {
            # The response is a report: Columns, then Values as rows. The name
            # search can also hit other devices (LAPTOP-1 finds LAPTOP-10), so
            # the match is on the Intune device id.
            $matchesFilter = {
                param($Filter)
                $skip = 0
                do {
                    $body = @{ data = @{ platform = $Filter.platform; rule = $Filter.rule; search = $managed.deviceName; top = 100; skip = $skip } } |
                        ConvertTo-Json -Depth 4 -Compress
                    $response = Invoke-MgGraphRequest -Method POST -Uri 'beta/deviceManagement/evaluateAssignmentFilter' -Body $body `
                        -ContentType 'application/json' -OutputType HttpResponseMessage -ErrorAction Stop
                    try { $page = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json }
                    finally { $response.Dispose() }
                    $column = @($page.Columns.Name).IndexOf('deviceId')
                    if ($column -lt 0) { throw 'the response has no deviceId column' }
                    $batch = @($page.Values)
                    foreach ($v in $batch) { if ($v[$column] -eq $managed.id) { return $true } }
                    $skip += $batch.Count
                } while ($batch.Count -and $skip -lt $page.TotalRowCount)
                $false
            }
            $matchOf = @{}   # filter id -> whether the device matches it
            $unknown = [System.Collections.Generic.List[string]]::new()
            foreach ($id in $toCheck) {
                try { $matchOf[$id] = & $matchesFilter $filters[$id] }
                catch { $unknown.Add("$($filters[$id].displayName) ($(($_.Exception.Message -split '\r?\n', 2)[0]))") }
            }
            if ($unknown.Count) {
                Write-Warning ("Couldn't check these assignment filters against $($d.displayName), so their rows aren't marked: " + ($unknown -join '; '))
            }
            foreach ($r in $rows) {
                if ($r.FilterId -and $matchOf.ContainsKey($r.FilterId)) {
                    # 'only' rules the device out when it doesn't match,
                    # 'except' when it does.
                    $r.FilteredOut = if ($r.FilterType -eq 'include') { -not $matchOf[$r.FilterId] } else { $matchOf[$r.FilterId] }
                }
            }
        }
    }

    # Summary before any row, so it lands above the table rather than inside it.
    $include  = @($rows | Where-Object Assignment -EQ 'Include').Count
    $filtered = @($rows | Where-Object FilteredOut).Count
    $ruledOut = if ($filtered) { " ($filtered filtered out)" }
    $summary  = if ($rows.Count) { "$include included$ruledOut, $($rows.Count - $include) excluded" }
                elseif (-not $isGroup) { 'no Intune assignments found' }
                elseif ($Inherited) { 'no direct or inherited Intune assignments found' }
                else { 'no direct Intune assignments found' }
    if ($isGroup) {
        if ($viaParent) { $summary += " ($viaParent inherited)" }
        if ($allUsers -or $allDevices) { $summary += "; not listed: $allUsers to All users, $allDevices to All devices" }
    } else {
        $summary += " (member of $($targets.Count) group$(if ($targets.Count -ne 1) { 's' }))"
    }
    Write-Host "${label}: $summary" -ForegroundColor Cyan

    # A policy that includes and excludes the subject through different
    # groups: the exclusion wins, but the table puts the two rows under
    # different headings, so say so here. Keyed on intent as well, because an
    # app's exclusions belong to one intent (excluded from required says
    # nothing about available). An include its filter already rules out
    # doesn't count: its row says so itself.
    $both = @($rows | Group-Object PolicyId, Intent |
        Where-Object { @($_.Group | Where-Object { $_.Assignment -eq 'Include' -and -not $_.FilteredOut }).Count -and
                       $_.Group.Assignment -contains 'Exclude' } |
        ForEach-Object { $first = $_.Group[0]; if ($first.Intent -and $first.Intent -ne 'apply') { "$($first.Name) ($($first.Intent))" } else { $first.Name } } |
        Sort-Object -Unique)
    if ($both.Count) {
        Write-Host "Both included and excluded, so the exclusion wins: $($both -join ', ')" -ForegroundColor Cyan
    }

    # The grouped table lives in a format file next to this one, loaded on
    # first use rather than at profile load.
    if (-not (Get-FormatData -TypeName 'PwshToolkit.IntuneAssignment' -ErrorAction Ignore)) {
        Update-FormatData -PrependPath (Join-Path $PSScriptRoot 'IntuneAssignments.format.ps1xml')
    }

    # Sorted the way the table groups them: the -Group group's own rows, then
    # each group they come through, then All users / All devices, the long
    # tail in most tenants, so what's specific to the subject comes first.
    # GroupId keeps two same-named groups apart.
    $rank = { if ($_.GroupId -and $_.GroupId -eq $groupId) { 0 } elseif ($_.GroupId) { 1 } else { 2 } }
    $rows | Sort-Object $rank, Group, GroupId, Type, Name
}
