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
