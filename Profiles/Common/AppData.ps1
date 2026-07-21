# The toolkit's local data root — %LOCALAPPDATA%\pwsh-toolkit — in one place.
# Jump bookmarks, clip snippets, the posh-themes cache, and the Intune cockpit
# all persist here; call this instead of hand-rolling the path so a typo'd
# literal can't silently fork the data root.
#
# This file is named to sort FIRST among the Common/*.ps1 files that need it:
# the loader dot-sources Common/ alphabetically, and Clipboard.ps1,
# Navigation.ps1, and PoshThemes.ps1 call Get-ToolkitDataPath at load time to
# bind their store paths. Two places still carry the literal path because they
# run before Common/ loads: install.ps1 (PS 5.1, standalone) and the loader's
# OhMyPosh branch in pwsh-toolkit-profile.ps1 — keep those in sync by hand.
#
# Ensures the root directory exists, returns the root (or a path under it).
function Get-ToolkitDataPath {
    [OutputType([string])]
    param([string] $ChildPath)
    $dir = Join-Path $env:LOCALAPPDATA 'pwsh-toolkit'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ($ChildPath) { Join-Path $dir $ChildPath } else { $dir }
}
