# Custom PowerShell Prompt
# Starship-inspired prompt showing admin status, M365 Graph connectivity, and smart path handling

function prompt {
    $isAdmin = ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # Get-MgContext lives in Microsoft.Graph.Authentication. -ErrorAction
    # SilentlyContinue does NOT swallow command-not-found, so guard with
    # Get-Command — otherwise the whole prompt function throws on every
    # keystroke and PowerShell silently falls back to the default 'PS>'.
    $graphConnected = if (Get-Command Get-MgContext -ErrorAction Ignore) {
        Get-MgContext -ErrorAction SilentlyContinue
    }

    # Build segments
    $segments = @()

    # Admin segment
    if ($isAdmin) {
        $segments += "🔴 ADMIN"
    }

    # Graph segment
    if ($graphConnected) {
        $segments += "🌐 M365"
    }

    # Smart path handling
    $location = Get-Location
    $path = $location.Path

    # Replace the home directory with ~ — prefix only, and with a path-separator
    # boundary so a sibling like C:\Users\Bobby isn't collapsed against
    # C:\Users\Bob (.StartsWith + .Replace would turn it into "~by").
    $sep = [IO.Path]::DirectorySeparatorChar
    if ($path -eq $HOME) {
        $path = "~"
    } elseif ($path.StartsWith($HOME + $sep)) {
        $path = "~" + $path.Substring($HOME.Length)
    }

    # Special handling for OneDrive
    if ($path -like "*OneDrive*") {
        $path = $path -replace "OneDrive - [^\\]*", "OneDrive"
    }

    # Truncate if still too long
    if ($path.Length -gt 50) {
        $pathParts = $path.Split('\')
        if ($pathParts.Count -gt 3) {
            $path = $pathParts[0] + "\...\" + $pathParts[-2] + "\" + $pathParts[-1]
        }
    }

    $segments += "📁 $path"

    # Join segments with separators
    Write-Host ($segments -join " | ") -ForegroundColor Cyan

    return "🚀 "
}
