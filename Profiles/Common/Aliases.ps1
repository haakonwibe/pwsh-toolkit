# Aliases and Quick Shortcuts
# Provides quick command aliases and helper functions for common operations

# Quick reference via ch.at API
function Ask-ChAt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Question,
        [switch]$Brief  # adds "Be brief." to the prompt
    )

    $payload = @{
        messages = @(
            @{ role = "user"; content = ($Brief ? "$Question (Be brief.)" : $Question) }
        )
    } | ConvertTo-Json -Depth 5

    try {
        $r = Invoke-RestMethod -Method Post `
            -Uri "https://ch.at/v1/chat/completions" `
            -ContentType "application/json" `
            -Body $payload
        $text = $r.choices[0].message.content
        if ($text) { return $text.Trim() }
        else { throw "Empty response." }
    }
    catch {
        throw "Ask-ChAt failed (API): $($_.Exception.Message)"
    }
}
Set-Alias ask Ask-ChAt

# Better ls with colors and formatting
function ll { Get-ChildItem -Force | Format-Table -AutoSize }
function la { Get-ChildItem -Force -Hidden | Format-Table -AutoSize }

# Clear screen with style
function Cls-Fancy {
    Clear-Host
    Write-Host "PowerShell ready! 🚀" -ForegroundColor Cyan
    Get-Location
}

# Quick file operations
function touch($file) { New-Item -ItemType File -Name $file -Force }
function which($command) { Get-Command $command -ErrorAction SilentlyContinue | Select-Object Source }

# Wrapper script paths are resolved from $script:Config.ToolkitRoot once at
# profile-load time and captured into $script: vars. Function bodies reference
# the captured paths so they don't need $PSScriptRoot (which is empty when a
# function body is evaluated interactively).
$script:WingetUpgradeScript   = Join-Path $script:Config.ToolkitRoot 'WingetUpgrade\Invoke-WingetUpgrade.ps1'
$script:DownloadsTagScript    = Join-Path $script:Config.ToolkitRoot 'DownloadsOrganizer\Invoke-DownloadsTag.ps1'
$script:DirDescriptionsScript = Join-Path $script:Config.ToolkitRoot 'DownloadsOrganizer\Get-DirDescriptions.ps1'

# Interactive winget upgrade picker (see WingetUpgrade/Invoke-WingetUpgrade.ps1)
# Uses $args (not ValueFromRemainingArguments) so `-Name value` pairs splat by name, not positionally.
function Invoke-WingetUpgradeMenu { & $script:WingetUpgradeScript @args }
Set-Alias winup Invoke-WingetUpgradeMenu

# Tag Downloads with FILE_ID.DIZ-style AI descriptions (see DownloadsOrganizer/)
function Invoke-DownloadsTagger { & $script:DownloadsTagScript @args }
Set-Alias tagdl Invoke-DownloadsTagger

# Load `dird` (dir-with-descriptions viewer). Skip silently if the toolkit
# layout doesn't include DownloadsOrganizer/ — the wrapper functions above
# will still error visibly on first call, which is the right signal.
if (Test-Path -LiteralPath $script:DirDescriptionsScript) {
    . $script:DirDescriptionsScript
}
