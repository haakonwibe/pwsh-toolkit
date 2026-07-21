# The toolkit's local data root — %LOCALAPPDATA%\pwsh-toolkit — in one place.
# Several features persist state there (jump bookmarks, clip snippets, the
# posh-themes cache, the Intune cockpit); call this instead of hand-rolling the
# path so a typo'd literal can't silently fork the data root. Ensures the
# directory exists, returns the root (or a path under it).
function Get-ToolkitDataPath {
    [OutputType([string])]
    param([string] $ChildPath)
    $dir = Join-Path $env:LOCALAPPDATA 'pwsh-toolkit'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ($ChildPath) { Join-Path $dir $ChildPath } else { $dir }
}
