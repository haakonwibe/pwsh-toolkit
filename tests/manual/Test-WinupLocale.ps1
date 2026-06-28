#Requires -Version 7.0
<#
.SYNOPSIS
    Manual locale test for winup (Invoke-WingetUpgrade.ps1).

.DESCRIPTION
    CI runs on English-only Windows, so winup's locale-proof upgrade listing
    (the headline 0.3.0 fix) cannot be exercised there. Run this on a non-English
    display-language box (e.g. Norsk bokmål) to confirm:

      1. `winget upgrade`'s console header is localized — so the text-parsing
         path (Get-WingetUpgradeText) goes blind, exactly as designed-around.
      2. The Microsoft.WinGet.Client module path (Get-WingetUpgradeObject) still
         lists upgrades correctly, because it reads structured COM objects.

    The two together = bug reproduced AND the module fix validated on real metal.

    Note: winget localizes to the WINDOWS DISPLAY LANGUAGE and reads it at process
    start. If the verdict says the header is still English, set the display
    language (Settings > Time & language > Language) and SIGN OUT/IN, then re-run.

.EXAMPLE
    .\tests\manual\Test-WinupLocale.ps1
#>
[CmdletBinding()]
param()

Write-Host ''
Write-Host '== Environment ==' -ForegroundColor Cyan
$culture = Get-Culture
$langTag = try { (Get-WinUserLanguageList -ErrorAction Stop)[0].LanguageTag } catch { '(n/a)' }
[pscustomobject]@{
    UserLanguageTag  = $langTag
    UICulture        = (Get-UICulture).Name          # winget keys off the display language
    Culture          = $culture.Name
    TimeSeparator    = $culture.DateTimeFormat.TimeSeparator       # not ':' => the pre-0.3.0 CMTrace stamp broke
    DecimalSeparator = $culture.NumberFormat.NumberDecimalSeparator
    WingetVersion    = (& winget --version 2>&1)
    PSVersion        = $PSVersionTable.PSVersion.ToString()
} | Format-List

Write-Host '== Raw "winget upgrade" output (the text path scrapes this) ==' -ForegroundColor Cyan
$prev = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try   { $raw = (& winget upgrade --accept-source-agreements 2>&1 | Out-String) }
finally { [Console]::OutputEncoding = $prev }
$lines = $raw -split "`r?`n"
($lines | Where-Object { $_ -match '\S' } | Select-Object -First 6) | ForEach-Object { Write-Host "  $_" }

# The exact header match winup's text parser uses (Invoke-WingetUpgrade.ps1:226).
$englishHeader = [bool]($lines | Where-Object {
    $_ -match '^\s*Name\s+' -and $_ -match '\bId\b' -and $_ -match '\bAvailable\b' })
Write-Host ''
Write-Host ("  Text parser can find the (English) header: {0}" -f $englishHeader) `
    -ForegroundColor $(if ($englishHeader) { 'Yellow' } else { 'Green' })

Write-Host ''
Write-Host '== Module path (Microsoft.WinGet.Client, COM — locale-proof) ==' -ForegroundColor Cyan
$moduleCount = $null
if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {
    Import-Module Microsoft.WinGet.Client
    $moduleCount = @(Get-WinGetPackage -ErrorAction SilentlyContinue | Where-Object IsUpdateAvailable).Count
    Write-Host ("  Module reports {0} upgradable package(s)." -f $moduleCount) -ForegroundColor Green
} else {
    Write-Host '  Module NOT installed — install: Install-Module Microsoft.WinGet.Client -Scope CurrentUser' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '== Verdict ==' -ForegroundColor Cyan
if ($englishHeader) {
    Write-Host '  This box is emitting ENGLISH winget headers, so the text path still works and' -ForegroundColor Yellow
    Write-Host '  the locale bug is NOT reproduced here. Set the Windows display language to a' -ForegroundColor Yellow
    Write-Host '  non-English locale, SIGN OUT/IN, and re-run. (UICulture should read e.g. nb-NO.)' -ForegroundColor Yellow
}
elseif ($null -ne $moduleCount -and $moduleCount -gt 0) {
    Write-Host '  REPRODUCED + FIXED: text path is blind to the localized header, but the module' -ForegroundColor Green
    Write-Host '  path still lists upgrades. This is exactly what winup 0.3.0 relies on. Now run' -ForegroundColor Green
    Write-Host '  `winup` and confirm the picker title reads "source: WinGet module".' -ForegroundColor Green
}
else {
    Write-Host '  Localized header (good) but the module reports 0 / is absent, so we cannot yet' -ForegroundColor Yellow
    Write-Host '  confirm the module path lists anything. Install the module and ensure at least' -ForegroundColor Yellow
    Write-Host '  one upgrade is pending, then re-run.' -ForegroundColor Yellow
}
Write-Host ''
