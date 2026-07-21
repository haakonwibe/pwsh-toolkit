# Intune Win32 app content visibility (IDEAS.md §7, the in-toolkit seed).
# Read-only commands surfacing what the portal doesn't: which content version
# devices actually download, per-file real vs. encrypted sizes, upload state,
# and stale never-committed upload attempts. Same plumbing as the rest of
# M365/ — Invoke-MgGraphRequest via Get-MgGraphAllPage, no extra modules, and
# Win32 app objects live under /beta (which Connect-Tenant sessions reach).

function Get-IntuneWin32App {
    <#
    .SYNOPSIS
        List the tenant's Intune Win32 apps with their content-relevant fields. Needs Connect-Tenant first.
    .DESCRIPTION
        Read-only inventory of Win32 (Win32LobApp) applications with the fields
        the portal scatters or hides: the package file name, total size, and
        the committed content version driving delivery. Pipe to
        Get-IntuneWin32AppContentInfo for per-version file detail. Covered by
        Connect-Tenant's default ReadOnly tier.
    .PARAMETER Name
        Case-insensitive display-name substring filter.
    .PARAMETER Id
        A specific app id (skips the list call).
    .EXAMPLE
        Get-IntuneWin32App

        Every Win32 app: id, name, publisher, version, package file, size,
        committed content version.
    .EXAMPLE
        Get-IntuneWin32App -Name 'reader' | Get-IntuneWin32AppContentInfo

        Content-version and file detail for every app matching 'reader'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Name,
        [string] $Id
    )

    if (-not (Get-MgContext)) {
        Write-Warning "Not connected to Microsoft Graph. Run Connect-Tenant first."
        return
    }

    $apps = if ($Id) {
        @(Invoke-MgGraphRequest -Method GET -Uri "beta/deviceAppManagement/mobileApps/$Id" -ErrorAction Stop)
    } else {
        Get-MgGraphAllPage -Uri ("beta/deviceAppManagement/mobileApps?" +
            '$filter=isof(''microsoft.graph.win32LobApp'')&$top=999')
    }

    foreach ($app in $apps) {
        if ($Name -and $app.displayName -notlike "*$Name*") { continue }
        [pscustomobject]@{
            Id                      = $app.id
            DisplayName             = $app.displayName
            Publisher               = $app.publisher
            Version                 = $app.displayVersion
            FileName                = $app.fileName
            SizeMB                  = if ($null -ne $app.size) { [math]::Round($app.size / 1MB, 2) } else { $null }
            CommittedContentVersion = $app.committedContentVersion
            LastModified            = $app.lastModifiedDateTime
        }
    }
}

# Render one detection/requirement rule as a readable one-liner. Handles both
# the unified `rules` shapes (win32LobAppRegistryRule, …) and the legacy
# detectionRules shapes (win32LobAppRegistryDetection, …) — same fields, the
# @odata.type family name differs.
function ConvertTo-Win32RuleSummary {
    [OutputType([string])]
    param($Rule)
    $cmp = if ($Rule.operator -and $Rule.operator -ne 'notConfigured') { " $($Rule.operator) $($Rule.comparisonValue)" } else { '' }
    switch -Wildcard ("$($Rule.'@odata.type')") {
        '*Registry*'    {
            $probe = if ($Rule.valueName) { "$($Rule.keyPath)\$($Rule.valueName)" } else { $Rule.keyPath }
            "registry: $probe ($($Rule.operationType))$cmp"; break }
        '*FileSystem*'  { "file: $(Join-Path "$($Rule.path)" "$($Rule.fileOrFolderName)") ($($Rule.operationType))$cmp"; break }
        '*ProductCode*' {
            $ver = if ($Rule.productVersionOperator -and $Rule.productVersionOperator -ne 'notConfigured') { " version $($Rule.productVersionOperator) $($Rule.productVersion)" } else { '' }
            "msi: $($Rule.productCode)$ver"; break }
        '*PowerShellScript*' { "script: $(if ($Rule.displayName) { $Rule.displayName } else { 'PowerShell detection script' })"; break }
        default         { "$($Rule.'@odata.type')" -replace '#microsoft\.graph\.', '' }
    }
}

# Render an assignment target as a readable name, resolving group ids through
# a per-invocation cache (one directory lookup per distinct group).
function Resolve-MobileAppAssignmentTarget {
    [OutputType([string])]
    param($Target, [hashtable] $GroupNameCache)
    # Resolve the group name up front when the target carries one, so both the
    # include and exclude branches share the cache lookup.
    $groupName = $null
    if ($Target.groupId) {
        if (-not $GroupNameCache.ContainsKey($Target.groupId)) {
            $GroupNameCache[$Target.groupId] = try {
                (Invoke-MgGraphRequest -Method GET -Uri "v1.0/groups/$($Target.groupId)`?`$select=displayName" -ErrorAction Stop).displayName
            } catch { $Target.groupId }   # no directory read on this session — the id still identifies it
        }
        $groupName = $GroupNameCache[$Target.groupId]
    }
    # Order matters: exclusionGroupAssignmentTarget also matches '*groupAssignmentTarget'.
    switch -Wildcard ("$($Target.'@odata.type')") {
        '*exclusionGroupAssignmentTarget'   { "NOT $groupName"; break }
        '*groupAssignmentTarget'            { $groupName; break }
        '*allDevicesAssignmentTarget'       { 'All devices'; break }
        '*allLicensedUsersAssignmentTarget' { 'All users'; break }
        default                             { "$($Target.'@odata.type')" -replace '#microsoft\.graph\.', '' }
    }
}

function Get-IntuneWin32AppDetail {
    <#
    .SYNOPSIS
        The full delivery picture for an Intune Win32 app in one object. Needs Connect-Tenant first.
    .DESCRIPTION
        Everything the portal scatters across half a dozen blades, or doesn't
        show at all: install mechanics (system/user context, restart behavior,
        max run time, install/uninstall command lines, the return-code map),
        MSI internals (product/upgrade codes, per-machine vs per-user),
        applicability gates (architectures, minimum Windows release, disk and
        memory floors), the detection and requirement rules as readable
        one-liners, delivery outcome counts (installed/failed/pending devices),
        dependency and supersedence relationships with app names, and
        assignments with group names resolved.

        Emits one object per app — pipe to Format-List. The install summary,
        relationships, and assignments are separate best-effort reads: if a
        narrower role can't see one, that section comes back empty and the
        rest still renders. Read-only; covered by Connect-Tenant's default
        ReadOnly tier.
    .PARAMETER Id
        The Win32 app id. Accepts pipeline input from Get-IntuneWin32App.
    .EXAMPLE
        Get-IntuneWin32App -Name '7-zip' | Get-IntuneWin32AppDetail | Format-List

        The whole story for one app: how it installs, how Intune detects it,
        where it's assigned, and how the rollout is going.
    .EXAMPLE
        Get-IntuneWin32App | Get-IntuneWin32AppDetail | Where-Object FailedDevices -gt 0

        Every Win32 app with install failures, detail in hand.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $Id
    )

    begin {
        $connected = [bool](Get-MgContext)
        if (-not $connected) {
            Write-Warning "Not connected to Microsoft Graph. Run Connect-Tenant first."
        }
        $groupNames = @{}   # shared across the pipeline: one lookup per distinct group
    }

    process {
        if (-not $connected) { return }

        $app = Invoke-MgGraphRequest -Method GET -Uri "beta/deviceAppManagement/mobileApps/$Id" -ErrorAction Stop

        # Best-effort side reads — each can 403 independently under narrow roles.
        $summary = $null
        try { $summary = Invoke-MgGraphRequest -Method GET -Uri "beta/deviceAppManagement/mobileApps/$Id/installSummary" -ErrorAction Stop }
        catch { Write-Debug "installSummary unavailable: $($_.Exception.Message)" }
        $relationships = @()
        try { $relationships = @((Invoke-MgGraphRequest -Method GET -Uri "beta/deviceAppManagement/mobileApps/$Id/relationships" -ErrorAction Stop).value) }
        catch { Write-Debug "relationships unavailable: $($_.Exception.Message)" }
        $assignments = @()
        try { $assignments = @((Invoke-MgGraphRequest -Method GET -Uri "beta/deviceAppManagement/mobileApps/$Id/assignments" -ErrorAction Stop).value) }
        catch { Write-Debug "assignments unavailable: $($_.Exception.Message)" }

        # Rules: prefer the unified `rules` collection (ruleType detection/
        # requirement); fall back to the legacy split collections.
        # The outer @( ) wraps the WHOLE if: assigning an if-statement's output
        # enumerates it, so a 1-element inner array would collapse to a string.
        $rules = @($app.rules)
        $detection = @(if ($rules) { $rules | Where-Object ruleType -EQ 'detection' | ForEach-Object { ConvertTo-Win32RuleSummary $_ } }
                       else        { $app.detectionRules                            | ForEach-Object { ConvertTo-Win32RuleSummary $_ } })
        $requirement = @(if ($rules) { $rules | Where-Object ruleType -EQ 'requirement' | ForEach-Object { ConvertTo-Win32RuleSummary $_ } }
                         else        { $app.requirementRules                            | ForEach-Object { ConvertTo-Win32RuleSummary $_ } })

        # Relationships: phrase each edge from this app's point of view.
        # targetType 'child' = the target hangs off this app (its dependency /
        # the app it supersedes); 'parent' = the target points at this app.
        $edges = @(foreach ($r in $relationships) {
            $kind = "$($r.'@odata.type')"
            if ($kind -like '*Dependency*') {
                if ($r.targetType -eq 'parent') { "required by $([char]0x2190) $($r.targetDisplayName)" }
                else { "depends on ($($r.dependencyType)) $([char]0x2192) $($r.targetDisplayName)" }
            } elseif ($kind -like '*Supersedence*') {
                if ($r.targetType -eq 'parent') { "superseded by $([char]0x2190) $($r.targetDisplayName)" }
                else { "supersedes ($($r.supersedenceType)) $([char]0x2192) $($r.targetDisplayName)" }
            } else { "$kind $([char]0x2192) $($r.targetDisplayName)" }
        })

        $assigned = @(foreach ($a in $assignments) {
            "$($a.intent) $([char]0x2192) $(Resolve-MobileAppAssignmentTarget -Target $a.target -GroupNameCache $groupNames)"
        })

        # allowedArchitectures (newer, incl. arm64) wins over applicableArchitectures.
        $arch = if ($app.allowedArchitectures -and $app.allowedArchitectures -ne 'none') { $app.allowedArchitectures } else { $app.applicableArchitectures }

        [pscustomobject]@{
            Id                      = $app.id
            App                     = $app.displayName
            Publisher               = $app.publisher
            Version                 = $app.displayVersion
            PublishingState         = $app.publishingState
            IsAssigned              = $app.isAssigned
            FileName                = $app.fileName
            SetupFile               = $app.setupFilePath
            SizeMB                  = if ($null -ne $app.size) { [math]::Round($app.size / 1MB, 2) } else { $null }
            CommittedContentVersion = $app.committedContentVersion
            InstallContext          = $app.installExperience.runAsAccount
            RestartBehavior         = $app.installExperience.deviceRestartBehavior
            MaxRunTimeMin           = $app.installExperience.maxRunTimeInMinutes
            InstallCommand          = $app.installCommandLine
            UninstallCommand        = $app.uninstallCommandLine
            ReturnCodes             = @($app.returnCodes | ForEach-Object { "$($_.returnCode) $($_.type)" })
            MsiProductCode          = $app.msiInformation.productCode
            MsiProductVersion       = $app.msiInformation.productVersion
            MsiUpgradeCode          = $app.msiInformation.upgradeCode
            MsiPackageType          = $app.msiInformation.packageType
            Architectures           = $arch
            MinWindowsRelease       = $app.minimumSupportedWindowsRelease
            MinDiskSpaceMB          = $app.minimumFreeDiskSpaceInMB
            MinMemoryMB             = $app.minimumMemoryInMB
            DetectionRules          = $detection
            RequirementRules        = $requirement
            InstalledDevices        = $summary.installedDeviceCount
            FailedDevices           = $summary.failedDeviceCount
            PendingDevices          = $summary.pendingInstallDeviceCount
            NotInstalledDevices     = $summary.notInstalledDeviceCount
            NotApplicableDevices    = $summary.notApplicableDeviceCount
            Relationships           = $edges
            Assignments             = $assigned
            Created                 = $app.createdDateTime
            LastModified            = $app.lastModifiedDateTime
        }
    }
}

function Get-IntuneWin32AppContentInfo {
    <#
    .SYNOPSIS
        Content-version and file detail for an Intune Win32 app — the delivery payload the portal doesn't show. Needs Connect-Tenant first.
    .DESCRIPTION
        For each app: its content versions and, per version, the actual content
        files Intune delivers — name, unencrypted and encrypted sizes, upload
        state, and whether the file is committed. By default only the committed
        content version (the one devices actually download) is expanded;
        -AllVersions walks the full history, which is how orphaned or
        never-committed upload attempts become visible. Read-only; covered by
        Connect-Tenant's default ReadOnly tier.
    .PARAMETER Id
        The Win32 app id. Accepts pipeline input from Get-IntuneWin32App.
    .PARAMETER AllVersions
        Expand every content version, not just the committed one.
    .EXAMPLE
        Get-IntuneWin32App -Name '7-zip' | Get-IntuneWin32AppContentInfo

        The committed content version's files with real and encrypted sizes.
    .EXAMPLE
        Get-IntuneWin32AppContentInfo -Id $appId -AllVersions

        Every content version ever uploaded for the app — stale upload
        attempts included.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $Id,
        [switch] $AllVersions
    )

    begin {
        $connected = [bool](Get-MgContext)
        if (-not $connected) {
            Write-Warning "Not connected to Microsoft Graph. Run Connect-Tenant first."
        }
    }

    process {
        if (-not $connected) { return }

        $app  = Invoke-MgGraphRequest -Method GET -Uri "beta/deviceAppManagement/mobileApps/$Id" -ErrorAction Stop
        $base = "beta/deviceAppManagement/mobileApps/$Id/microsoft.graph.win32LobApp/contentVersions"

        $versions = @(Get-MgGraphAllPage -Uri "$base`?`$top=999")
        if (-not $AllVersions) {
            $versions = @($versions | Where-Object { $_.id -eq $app.committedContentVersion })
        }

        foreach ($v in $versions) {
            $files = @(Get-MgGraphAllPage -Uri "$base/$($v.id)/files?`$top=999")
            foreach ($f in $files) {
                [pscustomobject]@{
                    AppId              = $app.id
                    App                = $app.displayName
                    ContentVersion     = $v.id
                    IsCommittedVersion = ($v.id -eq $app.committedContentVersion)
                    FileName           = $f.name
                    SizeMB             = if ($null -ne $f.size) { [math]::Round($f.size / 1MB, 2) } else { $null }
                    EncryptedSizeMB    = if ($null -ne $f.sizeEncrypted) { [math]::Round($f.sizeEncrypted / 1MB, 2) } else { $null }
                    UploadState        = $f.uploadState
                    IsCommittedFile    = $f.isCommitted
                    Created            = $f.createdDateTime
                }
            }
        }
    }
}
