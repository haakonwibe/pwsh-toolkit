#Requires -Version 7.0

# Isolated harness for WingetUpgrade/Invoke-WingetUpgrade.ps1's listing-dispatch
# and module-bootstrap logic. Run it directly (`pwsh -File`) or via the Pester
# wrapper in tests/WinGet.Tests.ps1; exit code 0 means every assertion passed.
#
# The script under test is a top-to-bottom script (not a module), so it can't be
# dot-sourced without running the whole interactive flow. Instead we AST-extract
# just the functions under test and drive them with the stubbed dependencies
# below — no real winget, no Microsoft.WinGet.Client module, no installs, no
# upgrades — so the harness behaves identically with or without the module
# installed, on any machine.

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'WingetUpgrade/Invoke-WingetUpgrade.ps1'
$ast  = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
$want = 'Get-WingetUpgrades', 'Get-WingetUpgradeObject', 'Initialize-WinGetModule'
$defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)
foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

# ---- Stubbed dependencies (named to shadow the real cmdlets the extracted
#      functions call; toggled via the $script: switches below) ---------------
$script:logged = New-Object System.Collections.Generic.List[string]
function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Deliberate test double for the isolated harness.')]
    param([string] $Message, [string] $Level = 'INFO')
    $script:logged.Add("[$Level] $Message")
}

$script:moduleInstalled = $true
function Get-Module {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Deliberate test double for the isolated harness.')]
    param([switch] $ListAvailable, [string] $Name)
    if ($script:moduleInstalled -and $ListAvailable) { [pscustomobject]@{ Name = $Name } }
}
function Import-Module {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Deliberate test double for the isolated harness.')]
    [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)] $Rest)
    $null = $Rest
}
$script:installCalled = $false
function Install-Module {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Deliberate test double for the isolated harness.')]
    [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)] $Rest)
    $null = $Rest; $script:installCalled = $true
}
$script:readHostResponse = 'n'
function Read-Host {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Deliberate test double for the isolated harness.')]
    [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)] $Rest)
    $null = $Rest; $script:readHostResponse
}
$script:pinnedSet = @()
function Get-WinGetPin { [CmdletBinding()] param() $script:pinnedSet | ForEach-Object { [pscustomobject]@{ Id = $_ } } }
function Get-WingetUpgradeText { param([switch] $IncludeUnknown) $null = $IncludeUnknown; [pscustomobject]@{ Name = 'TEXTPATH'; Id = 'text.sentinel'; Version = '0'; Available = '1'; Source = 'winget' } }
$script:throwInModule = $false
function Get-WinGetPackage {
    [CmdletBinding()] param()
    if ($script:throwInModule) { throw "COM init failed`nsecond line" }
    [pscustomobject]@{ Name = 'Git';        Id = 'Git.Git';               InstalledVersion = '2.40.0'; AvailableVersions = @('2.45.1', '2.45.0'); Source = 'winget'; IsUpdateAvailable = $true }
    [pscustomobject]@{ Name = 'UpToDate';   Id = 'Foo.Bar';               InstalledVersion = '1.0.0';  AvailableVersions = @();                   Source = 'winget'; IsUpdateAvailable = $false }
    [pscustomobject]@{ Name = 'PowerShell'; Id = 'Microsoft.PowerShell';  InstalledVersion = '7.4.0';  AvailableVersions = @('7.5.0');            Source = 'winget'; IsUpdateAvailable = $true }
}

# ---- assert ----
$script:pass = 0; $script:fail = 0
function Check($label, $cond) { if ($cond) { $script:pass++; Write-Host "  PASS  $label" -ForegroundColor Green } else { $script:fail++; Write-Host "  FAIL  $label" -ForegroundColor Red } }

# ==== Listing dispatch =====================================================
Write-Host "`nA) module present, default run" -ForegroundColor Cyan
$script:moduleInstalled = $true; $script:throwInModule = $false; $script:pinnedSet = @(); $script:logged.Clear()
$r = @(Get-WingetUpgrades)
Check 'filters to IsUpdateAvailable (2 of 3)'     ($r.Count -eq 2)
Check 'maps Available = newest AvailableVersions' ((($r | Where-Object Id -eq 'Git.Git').Available) -eq '2.45.1')
Check 'carries Version/Source through'            (((($r | Where-Object Id -eq 'Git.Git').Version) -eq '2.40.0') -and ((($r | Where-Object Id -eq 'Git.Git').Source) -eq 'winget'))
Check "channel label = 'WinGet module'"           ($script:ListingChannel -eq 'WinGet module')

Write-Host "`nA2) pinned package excluded (matches winget upgrade default)" -ForegroundColor Cyan
$script:moduleInstalled = $true; $script:pinnedSet = @('Git.Git'); $script:logged.Clear()
$r = @(Get-WingetUpgrades)
Check 'pinned Git.Git dropped; only PowerShell remains' (($r.Count -eq 1) -and ($r[0].Id -eq 'Microsoft.PowerShell'))
$script:pinnedSet = @()

Write-Host "`nB) module not installed -> text fallback" -ForegroundColor Cyan
$script:moduleInstalled = $false; $script:logged.Clear()
$r = @(Get-WingetUpgrades)
Check 'uses text path (sentinel)'    ($r[0].Id -eq 'text.sentinel')
Check "channel label = 'winget CLI'" ($script:ListingChannel -eq 'winget CLI')

Write-Host "`nC) -IncludeUnknown forces text path" -ForegroundColor Cyan
$script:moduleInstalled = $true; $script:logged.Clear()
$r = @(Get-WingetUpgrades -IncludeUnknown)
Check 'uses text path for -IncludeUnknown' ($r[0].Id -eq 'text.sentinel')

Write-Host "`nD) module path throws -> WARN + fallback" -ForegroundColor Cyan
$script:moduleInstalled = $true; $script:throwInModule = $true; $script:logged.Clear()
$r = @(Get-WingetUpgrades)
Check 'falls back to text path'              ($r[0].Id -eq 'text.sentinel')
Check 'WARN keeps only the first error line' (([bool]($script:logged -match 'module listing failed')) -and (-not [bool]($script:logged -match 'second line')))
$script:throwInModule = $false

# ==== Initialize-WinGetModule decisions ====================================
Write-Host "`nE) Initialize-WinGetModule" -ForegroundColor Cyan

$script:moduleInstalled = $true; $script:installCalled = $false
Initialize-WinGetModule -Install -Unattended:$false -SkipModule:$false
Check 'module present: no install attempted' (-not $script:installCalled)

$script:moduleInstalled = $false; $script:installCalled = $false
Initialize-WinGetModule -SkipModule
Check '-SkipModule (IncludeUnknown): no install' (-not $script:installCalled)

$script:moduleInstalled = $false; $script:installCalled = $false
Initialize-WinGetModule -Install
Check '-Install + absent: installs' ($script:installCalled)

$script:moduleInstalled = $false; $script:installCalled = $false; $script:logged.Clear()
Initialize-WinGetModule -Unattended
Check '-Unattended + absent: suggests, no install' ((-not $script:installCalled) -and [bool]($script:logged -match 'Tip: Install-Module'))

$script:moduleInstalled = $false; $script:installCalled = $false; $script:readHostResponse = 'y'
Initialize-WinGetModule
Check "interactive 'y': installs" ($script:installCalled)

$script:moduleInstalled = $false; $script:installCalled = $false; $script:readHostResponse = 'n'; $script:logged.Clear()
Initialize-WinGetModule
Check "interactive 'n': declines, no install" ((-not $script:installCalled) -and [bool]($script:logged -match 'declined'))

Write-Host "`n==== $($script:pass) passed, $($script:fail) failed ====" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
