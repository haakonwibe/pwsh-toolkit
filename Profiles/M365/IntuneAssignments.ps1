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
        page, Enrollment restriction or Windows Hello for Business. App rows
        carry their intent, so 'App (required)' and 'App (uninstall)' read
        apart at a glance. Filter names the assignment filter that narrows a
        row further.

        -Group lists direct assignments by default. -Inherited adds the
        assignments of every group this one belongs to, directly or further
        up, since those reach its members too. Such rows read
        'Include (via <parent>)' or 'Exclude (via <parent>)', and their Group
        and GroupId name the parent. All users and All devices reach members
        as well; -Inherited counts those in the summary line instead of
        listing them, because in most tenants they would crowd out everything
        else.

        -User and -Device list what reaches that user or device: the
        assignments of every group it belongs to, directly or further up,
        each read 'Include (via <group>)' or 'Exclude (via <group>)', plus
        whatever goes to All users (for a user) or All devices (for a device).
        That is targeting, not a verdict: an exclusion generally wins over an
        inclusion, and an assignment filter can still rule a device out.

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
        Get-IntuneAssignment -Device LAPTOP-1 | Where-Object Assignment -Like 'Exclude*'

        The exclusions that reach one device, and the groups they come through.
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
            $fields   = '$select=id,displayName,approximateLastSignInDateTime'
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
    # different place. Enrollment defaults are left out: they always target
    # All users or All devices, so they never make a row.
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
        windows10EnrollmentCompletionPageConfiguration = 'Enrollment status page'
        platformRestrictions                           = 'Enrollment restriction (platform)'
        singlePlatformRestriction                      = 'Enrollment restriction (platform)'
        limit                                          = 'Enrollment restriction (limit)'
        windowsHelloForBusiness                        = 'Windows Hello for Business'
        deviceComanagementAuthorityConfiguration       = 'Co-management settings'
        enrollmentNotificationsConfiguration           = 'Enrollment notification'
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
        @{ Type = 'App';                        Uri = 'beta/deviceAppManagement/mobileApps' }
        @{ Type = 'App configuration';          Uri = 'beta/deviceAppManagement/mobileAppConfigurations' }
        @{ Type = 'App configuration (MAM)';    Uri = 'beta/deviceAppManagement/targetedManagedAppConfigurations' }
        @{ Type = 'App protection (iOS)';       Uri = 'beta/deviceAppManagement/iosManagedAppProtections' }
        @{ Type = 'App protection (Android)';   Uri = 'beta/deviceAppManagement/androidManagedAppProtections' }
        @{ Type = 'App protection (Windows)';   Uri = 'beta/deviceAppManagement/windowsManagedAppProtections' }
    )

    $rows        = [System.Collections.Generic.List[object]]::new()
    $unread      = [System.Collections.Generic.List[string]]::new()
    $filterNames = $null   # assignment filter id -> name, fetched on first use
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
                        if ($via) { $how = "via $via"; $toName = $via; $toId = $tid }
                        else      { $how = $null;      $toName = $groupName; $toId = $groupId }
                    } elseif ($everyone -and $odataType -eq $everyone.Type) {
                        $mode = 'Include'; $via = $null; $how = $everyone.Name; $toName = $everyone.Name; $toId = $null
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
                        if ($null -eq $filterNames) {
                            $filterNames = @{}
                            try {
                                foreach ($f in Get-MgGraphAllPage -Uri 'beta/deviceManagement/assignmentFilters?$select=id,displayName') {
                                    $filterNames[$f.id] = $f.displayName
                                }
                            } catch { Write-Debug "assignment filter names unavailable: $($_.Exception.Message)" }
                        }
                        $filterText = "$($filterNames[$filterId] ?? $filterId) ($filterType)"
                    } else {
                        $filterId = $null
                    }

                    if ($via) { $viaParent++ }
                    $rows.Add([pscustomobject]@{
                        Type       = if ($a.intent) { "$type ($($a.intent))" } else { $type }
                        Name       = $item.displayName ?? $item.name   # Settings Catalog says `name`
                        Assignment = if ($how) { "$mode ($how)" } else { $mode }
                        Filter     = $filterText
                        Intent     = $a.intent
                        PolicyId   = $item.id
                        FilterId   = $filterId
                        Group      = $toName
                        GroupId    = $toId
                    })
                }
            }
        } catch {
            $unread.Add("$($src.Type) ($(($_.Exception.Message -split '\r?\n', 2)[0]))")
        }
    }
    Write-Progress -Activity 'Reading Intune assignments' -Completed

    if ($unread.Count) {
        Write-Warning ("Not every surface could be read, so assignments there may be missing: " + ($unread -join '; '))
    }

    # Summary before any row, so it lands above the table rather than inside it.
    $include = @($rows | Where-Object Assignment -Like 'Include*').Count
    $summary = if ($rows.Count) { "$include included, $($rows.Count - $include) excluded" }
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

    foreach ($r in $rows | Sort-Object Type, Name) {
        # Four columns, not five: PowerShell renders a display set of five or
        # more as a per-object list, which defeats the point of a table.
        $r | Add-Member -MemberType MemberSet -Name PSStandardMembers -PassThru -Value ([System.Management.Automation.PSMemberInfo[]]@(
            [System.Management.Automation.PSPropertySet]::new(
                'DefaultDisplayPropertySet', [string[]]@('Type', 'Name', 'Assignment', 'Filter'))
        ))
    }
}
