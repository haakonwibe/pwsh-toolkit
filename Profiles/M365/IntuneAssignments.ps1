# Intune assignments seen from the group's side. The portal answers "who gets
# this policy?" one policy at a time; the reverse question, "what does this
# group get?", has no page at all. Same plumbing as the rest of M365/:
# Invoke-MgGraphRequest via Get-MgGraphAllPage, /beta for the surfaces that
# only live there, nothing extra to import.

function Get-IntuneGroupAssignment {
    <#
    .SYNOPSIS
        Everything Intune assigns to a group, or excludes it from: profiles, policies, scripts, updates, enrollment, apps. Needs Connect-Tenant first.
    .DESCRIPTION
        The reverse of the portal's per-policy Assignments page: name a group
        and every assignable Intune surface is checked for assignments that
        include or exclude it. Prints one summary line with the include and
        exclude counts, then emits one row per assignment.

        Surfaces read: device configuration profiles (update rings included),
        Settings Catalog (which also holds current endpoint security policies
        and security baselines), administrative templates, compliance
        policies, legacy endpoint security intents, platform scripts,
        remediations, macOS shell scripts, feature/quality/driver update
        profiles, Autopilot profiles, enrollment configurations (ESP,
        enrollment restrictions, Windows Hello), apps, app configuration
        (managed devices and managed apps), and iOS/Android/Windows app
        protection. Not read: terms and conditions, macOS custom attribute
        scripts, Windows Information Protection, Cloud PC, and RBAC.

        Direct assignments only. A policy assigned to a parent group that
        nests this one, or to All users / All devices, reaches this group's
        members too but isn't listed here. Filter names the assignment filter
        that narrows a row further. App rows carry their intent in Type, so
        'App (required)' and 'App (uninstall)' read apart at a glance.

        A surface that can't be read (missing permission or license) is named
        in a warning rather than skipped silently, so an empty result means
        nothing was found, not that nothing could be checked. Read-only;
        covered by Connect-Tenant's default ReadOnly tier.
    .PARAMETER Group
        The group's display name (exact match) or object id. Display names
        aren't unique in Entra ID; when a name matches more than one group the
        command stops and lists their ids.
    .EXAMPLE
        Get-IntuneGroupAssignment 'Pilot Devices'

        Every profile, policy, script and app assigned to or excluding the
        group, with the include/exclude counts on top.
    .EXAMPLE
        Get-IntuneGroupAssignment 'Pilot Devices' | Where-Object Assignment -EQ Exclude

        Only the exclusions.
    .EXAMPLE
        Get-IntuneGroupAssignment 'Pilot Devices' | Format-List

        Every property per row, including the policy id, the app intent and
        the filter id.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Group
    )

    if (-not (Get-MgContext)) {
        Write-Warning "Not connected to Microsoft Graph. Run Connect-Tenant first."
        return
    }

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
        # expression for the query string, so a name containing & or # can't
        # cut the filter short.
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

    # Every assignable surface, in the order they're read. NoExpand marks a
    # collection that doesn't take $expand=assignments; its items are read one
    # at a time, the same fallback used when a collection ignores the expand.
    $sources = @(
        @{ Type = 'Device configuration';       Uri = 'beta/deviceManagement/deviceConfigurations' }
        @{ Type = 'Settings catalog';           Uri = 'beta/deviceManagement/configurationPolicies' }
        @{ Type = 'Administrative template';    Uri = 'beta/deviceManagement/groupPolicyConfigurations' }
        @{ Type = 'Compliance';                 Uri = 'beta/deviceManagement/deviceCompliancePolicies' }
        @{ Type = 'Endpoint security (legacy)'; Uri = 'beta/deviceManagement/intents'; NoExpand = $true }
        @{ Type = 'Platform script';            Uri = 'beta/deviceManagement/deviceManagementScripts' }
        @{ Type = 'Remediation';                Uri = 'beta/deviceManagement/deviceHealthScripts' }
        @{ Type = 'macOS shell script';         Uri = 'beta/deviceManagement/deviceShellScripts' }
        @{ Type = 'Feature update';             Uri = 'beta/deviceManagement/windowsFeatureUpdateProfiles' }
        @{ Type = 'Quality update';             Uri = 'beta/deviceManagement/windowsQualityUpdateProfiles' }
        @{ Type = 'Driver update';              Uri = 'beta/deviceManagement/windowsDriverUpdateProfiles' }
        @{ Type = 'Autopilot profile';          Uri = 'beta/deviceManagement/windowsAutopilotDeploymentProfiles' }
        @{ Type = 'Enrollment configuration';   Uri = 'beta/deviceManagement/deviceEnrollmentConfigurations' }
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
                foreach ($a in $assignments) {
                    $t = $a.target
                    if ($t.groupId -ne $groupId) { continue }
                    # Exact types, not a '*groupAssignmentTarget' wildcard:
                    # scopeTagGroupAssignmentTarget would match that too, and
                    # it isn't an assignment to the group.
                    $mode = switch ("$($t.'@odata.type')") {
                        '#microsoft.graph.groupAssignmentTarget'          { 'Include' }
                        '#microsoft.graph.exclusionGroupAssignmentTarget' { 'Exclude' }
                    }
                    if (-not $mode) { continue }

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

                    $rows.Add([pscustomobject]@{
                        Type       = if ($a.intent) { "$($src.Type) ($($a.intent))" } else { $src.Type }
                        Name       = $item.displayName ?? $item.name   # Settings Catalog says `name`
                        Assignment = $mode
                        Filter     = $filterText
                        Intent     = $a.intent
                        PolicyId   = $item.id
                        FilterId   = $filterId
                        Group      = $groupName
                        GroupId    = $groupId
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
    $label   = if ($groupName -ne $groupId) { "$groupName ($groupId)" } else { $groupId }
    $include = @($rows | Where-Object Assignment -EQ 'Include').Count
    if ($rows.Count) {
        Write-Host "${label}: $include included, $($rows.Count - $include) excluded" -ForegroundColor Cyan
    } else {
        Write-Host "${label}: no direct Intune assignments found" -ForegroundColor Cyan
    }

    foreach ($r in $rows | Sort-Object Type, Name) {
        # Four columns, not five: PowerShell renders a display set of five or
        # more as a per-object list, which defeats the point of a table.
        $r | Add-Member -MemberType MemberSet -Name PSStandardMembers -PassThru -Value ([System.Management.Automation.PSMemberInfo[]]@(
            [System.Management.Automation.PSPropertySet]::new(
                'DefaultDisplayPropertySet', [string[]]@('Type', 'Name', 'Assignment', 'Filter'))
        ))
    }
}
