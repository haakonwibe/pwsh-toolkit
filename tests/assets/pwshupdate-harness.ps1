# Isolated harness for PwshUpdate/Invoke-PwshUpdate.ps1. Run it with either
# host - `powershell.exe -File` (5.1, what the scheduled task uses) or
# `pwsh -File` - or through tests/PwshUpdate.Tests.ps1, which runs it under
# both. Exit code 0 means every check passed.
#
# The script stops before its main block when dot-sourced, so this loads its
# functions directly, then replaces the parts that reach outside a temp folder
# (network, Authenticode, elevation, the machine PATH / App Paths / Start Menu /
# Task Scheduler) with stubs driven by $script:H. Everything else - junction
# switching, staging, config carry-over, pruning, repair, install, uninstall -
# runs for real against temp roots.
#
# ASCII-only and 5.1-compatible, like the script it tests.

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'PwshUpdate\Invoke-PwshUpdate.ps1'
. $scriptPath
$script:PwshQuiet = $true

$script:passed = 0
$script:failures = New-Object System.Collections.Generic.List[string]
function Check {
    param([string] $Name, [scriptblock] $Test)
    try {
        if (& $Test) { $script:passed++ } else { $script:failures.Add("$Name (returned false)") }
    } catch { $script:failures.Add("$Name (threw: $($_.Exception.Message))") }
}
function CheckThrows {
    param([string] $Name, [scriptblock] $Test, [string] $Like = '*')
    try { $null = & $Test; $script:failures.Add("$Name (did not throw)") }
    catch {
        if ($_.Exception.Message -like $Like) { $script:passed++ }
        else { $script:failures.Add("$Name (threw the wrong error: $($_.Exception.Message))") }
    }
}
# A setup step that throws outside a Check is recorded (with its line) and the
# run carries on, so a regression reports what broke instead of just dying.
trap {
    $script:failures.Add("setup step at line $($_.InvocationInfo.ScriptLineNumber) threw: $($_.Exception.Message)")
    continue
}
function New-TempRoot {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('pwshup-h-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $p
    $p
}

# ================= Pure helpers =================
Check 'version: v-prefixed tag' { (ConvertTo-PwshVersion 'v7.6.6') -eq [version]'7.6.6' }
Check 'version: preview tag is not a release' { $null -eq (ConvertTo-PwshVersion 'v7.7.0-preview.4') }
Check 'version: junk' { $null -eq (ConvertTo-PwshVersion 'latest') }

Check 'arch: OS wins over a 32-bit process' { (Get-PwshArchitecture -ArchW6432 'AMD64' -Arch 'x86') -eq 'x64' }
Check 'arch: arm64' { (Get-PwshArchitecture -ArchW6432 '' -Arch 'ARM64') -eq 'arm64' }
CheckThrows 'arch: unknown' { Get-PwshArchitecture -ArchW6432 '' -Arch 'MIPS' } '*Unsupported*'
Check 'asset name' { (Get-PwshAssetName -Version '7.6.6' -Arch 'x64') -eq 'PowerShell-7.6.6-win-x64.zip' }

$hx64 = '02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860'
$harm = 'bbde9dda31d148415eccb5fbe1638e6400a144187b006e5b3fd8ec2f39d781be'
$hashText = "$harm *PowerShell-7.6.6-win-arm64.zip`r`n$($hx64.ToUpper()) *PowerShell-7.6.6-win-x64.zip`r`n"
$utf16 = [Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes($hashText)
Check 'hashes: UTF-16 LE with BOM, as the release ships it' { (Read-PwshHashFile -Bytes $utf16 -FileName 'PowerShell-7.6.6-win-x64.zip') -eq $hx64 }
Check 'hashes: plain UTF-8 too' { (Read-PwshHashFile -Bytes ([Text.Encoding]::UTF8.GetBytes($hashText)) -FileName 'PowerShell-7.6.6-win-arm64.zip') -eq $harm }
CheckThrows 'hashes: missing entry' { Read-PwshHashFile -Bytes $utf16 -FileName 'PowerShell-7.6.6-win-x86.zip' } '*0 entries*'
CheckThrows 'hashes: near miss is not a match' { Read-PwshHashFile -Bytes ([Text.Encoding]::UTF8.GetBytes("$hx64 *PowerShell-7.6.6-win-x64.zip.bak")) -FileName 'PowerShell-7.6.6-win-x64.zip' } '*0 entries*'
CheckThrows 'hashes: duplicate entry' { Read-PwshHashFile -Bytes ([Text.Encoding]::UTF8.GetBytes("$hx64 *a.zip`n$harm *a.zip")) -FileName 'a.zip' } '*2 entries*'

$sel = { param($a, $c, $bad, [switch] $maj, [switch] $exp) (Select-PwshTarget -Available $a -Current $c -Bad $bad -AllowMajor:$maj -Explicit:$exp).Action }
Check 'select: first install' { (& $sel '7.6.6' $null @()) -eq 'Update' }
Check 'select: first install may be any major' { (& $sel '8.0.0' $null @()) -eq 'Update' }
Check 'select: up to date' { (& $sel '7.6.6' '7.6.6' @()) -eq 'None' }
Check 'select: newer patch' { (& $sel '7.6.7' '7.6.6' @()) -eq 'Update' }
Check 'select: newer minor (Stable, not LTS)' { (& $sel '7.7.0' '7.6.6' @()) -eq 'Update' }
Check 'select: never downgrades on its own' { (& $sel '7.6.5' '7.6.6' @()) -eq 'None' }
Check 'select: skips a bad version' { (& $sel '7.6.7' '7.6.6' @('7.6.7')) -eq 'Skip' }
Check 'select: new major needs opt-in' { (& $sel '8.0.0' '7.9.1' @()) -eq 'Blocked' }
Check 'select: new major with -AllowMajor' { (& $sel '8.0.0' '7.9.1' @() -maj) -eq 'Update' }
Check 'select: explicit request may downgrade and override bad' { (& $sel '7.6.5' '7.6.6' @('7.6.5') -exp) -eq 'Update' }
Check 'select: no release info' { (& $sel $null '7.6.6' @()) -eq 'None' }

$shippedA = '{"Microsoft.PowerShell:ExecutionPolicy":"RemoteSigned","WindowsPowerShellCompatibilityModuleDenyList":["PSScheduledJob"],"Old":1}'
$liveA    = '{"Microsoft.PowerShell:ExecutionPolicy":"AllSigned","WindowsPowerShellCompatibilityModuleDenyList":["PSScheduledJob"],"ExperimentalFeatures":["PSFeedbackProvider"]}'
$shippedB = '{"Microsoft.PowerShell:ExecutionPolicy":"RemoteSigned","WindowsPowerShellCompatibilityModuleDenyList":["PSScheduledJob","BestPractices"],"Old":1}'
$m = Merge-PwshConfigJson -OldShipped $shippedA -OldLive $liveA -NewShipped $shippedB
$mo = $m.Json | ConvertFrom-Json
Check 'config: carries a setting the machine changed' { $mo.'Microsoft.PowerShell:ExecutionPolicy' -eq 'AllSigned' }
Check 'config: carries a setting the machine added' { @($mo.ExperimentalFeatures) -contains 'PSFeedbackProvider' }
Check "config: keeps the new release's own defaults" { @($mo.WindowsPowerShellCompatibilityModuleDenyList) -contains 'BestPractices' }
Check 'config: a default the machine deleted stays deleted' { -not ($mo.PSObject.Properties | Where-Object { $_.Name -eq 'Old' }) }
Check 'config: reports what it carried' { ($m.Carried -contains 'Microsoft.PowerShell:ExecutionPolicy') -and ($m.Removed -contains 'Old') }
$m2 = Merge-PwshConfigJson -OldShipped $null -OldLive $liveA -NewShipped $shippedB
Check 'config: without a shipped record, differences from the new defaults carry' { ($m2.Json | ConvertFrom-Json).'Microsoft.PowerShell:ExecutionPolicy' -eq 'AllSigned' }
CheckThrows 'config: unreadable live file aborts' { Merge-PwshConfigJson -OldShipped $shippedA -OldLive '{ not json' -NewShipped $shippedB }

Check 'path: appends' { (Edit-PwshPathValue -Value 'C:\A;%SystemRoot%\x' -Entry 'C:\P\7') -eq 'C:\A;%SystemRoot%\x;C:\P\7' }
Check 'path: no duplicate (case, trailing slash)' { (Edit-PwshPathValue -Value 'C:\A;c:\p\7\' -Entry 'C:\P\7') -eq 'C:\A;c:\p\7\' }
Check 'path: after a trailing separator' { (Edit-PwshPathValue -Value 'C:\A;' -Entry 'C:\P\7') -eq 'C:\A;C:\P\7' }
Check 'path: removes only the entry' { (Edit-PwshPathValue -Value 'C:\A;;C:\P\7;%X%' -Entry 'C:\P\7' -Remove) -eq 'C:\A;;%X%' }
Check 'path: remove when absent is a no-op' { (Edit-PwshPathValue -Value 'C:\A' -Entry 'C:\P\7' -Remove) -eq 'C:\A' }
Check 'prune set' { ((Get-PwshPruneSet -Present @('7.6.5', '7.6.6', '7.6.7') -Keep @('7.6.7', '7.6.6', $null)) -join ',') -eq '7.6.5' }

$logProbe = Join-Path ([IO.Path]::GetTempPath()) ('pwshup-h-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
Set-Content -LiteralPath $logProbe -Value (Format-CMTraceLine -Message 'hello there' -Type 2)
Check 'log: CMTrace line reads back for status' { (@(Get-PwshLogTail -Ctx ([pscustomobject]@{ LogFile = $logProbe }))[0]) -like '*  hello there' }
Remove-Item -LiteralPath $logProbe

# ================= Machine PATH, for real, against a throwaway HKCU key =================
$regSub = 'Software\pwshup-harness-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$hk = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($regSub)
$hk.SetValue('Path', '%SystemRoot%\system32;C:\Tools', [Microsoft.Win32.RegistryValueKind]::ExpandString); $hk.Close()
$readReg = {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($regSub)
    try { [pscustomobject]@{ Kind = $k.GetValueKind('Path'); Value = $k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } } finally { $k.Close() }
}
Check 'PATH: adds the entry' { Set-PwshMachinePath -Entry 'C:\PS\7' -Hive CurrentUser -KeyPath $regSub }
Check 'PATH: keeps REG_EXPAND_SZ and %SystemRoot% unexpanded' { $r = & $readReg; $r.Kind -eq 'ExpandString' -and $r.Value -eq '%SystemRoot%\system32;C:\Tools;C:\PS\7' }
Check 'PATH: second add changes nothing' { -not (Set-PwshMachinePath -Entry 'C:\PS\7\' -Hive CurrentUser -KeyPath $regSub) }
Check 'PATH: removes exactly what it added' { $null = Set-PwshMachinePath -Entry 'C:\PS\7' -Remove -Hive CurrentUser -KeyPath $regSub; (& $readReg).Value -eq '%SystemRoot%\system32;C:\Tools' }
[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($regSub)

# ================= Link-safe filesystem =================
$fs = New-TempRoot
$null = New-Item -ItemType Directory -Path "$fs\outside\keep"
Set-Content -LiteralPath "$fs\outside\keep\marker.txt" -Value 'x'
$null = New-Item -ItemType Directory -Path "$fs\tree\a\b"
Set-Content -LiteralPath "$fs\tree\a\b\f.txt" -Value 'x'
Set-ItemProperty -LiteralPath "$fs\tree\a\b\f.txt" -Name IsReadOnly -Value $true
New-PwshJunction -Path "$fs\tree\a\link" -Target "$fs\outside"
Remove-PwshTree "$fs\tree"
Check 'tree removal does not follow a junction inside it' { (Test-Path -LiteralPath "$fs\outside\keep\marker.txt") -and -not (Test-Path -LiteralPath "$fs\tree") }
CheckThrows 'link removal refuses a real folder' { Remove-PwshLink "$fs\outside" } '*real folder*'
Check 'content count does not follow links' { New-PwshJunction -Path "$fs\outside\lnk" -Target "$fs\outside\keep"; $c = Get-PwshTreeContent "$fs\outside"; $c.Files -eq 1 -and $c.Links -eq 1 }

$lc = New-PwshContext -InstallRoot $fs
$null = New-Item -ItemType Directory -Path "$fs\v1", "$fs\v2"
Switch-PwshLink -Ctx $lc -Target "$fs\v1"
Check 'switch: creates 7' { (Get-PwshLinkTarget $lc.Link) -eq "$fs\v1" }
Switch-PwshLink -Ctx $lc -Target "$fs\v2"
Check 'switch: repoints 7 and leaves nothing behind' { (Get-PwshLinkTarget $lc.Link) -eq "$fs\v2" -and -not (Test-Path -LiteralPath ($lc.Link + '.next')) -and -not (Test-Path -LiteralPath ($lc.Link + '.prev')) -and (Test-Path -LiteralPath "$fs\v1") }
# Interrupted after "rename 7 -> 7.prev": 7 missing, 7.next and 7.prev present.
[IO.Directory]::Move($lc.Link, $lc.Link + '.prev'); New-PwshJunction -Path ($lc.Link + '.next') -Target "$fs\v1"
Repair-PwshLink $lc
Check 'repair: finishes an interrupted switch' { (Get-PwshLinkTarget $lc.Link) -eq "$fs\v1" -and -not (Test-Path -LiteralPath ($lc.Link + '.prev')) }
# Interrupted before the new link existed: only 7.prev.
[IO.Directory]::Move($lc.Link, $lc.Link + '.prev')
Repair-PwshLink $lc
Check 'repair: restores the previous link' { (Get-PwshLinkTarget $lc.Link) -eq "$fs\v1" }
Remove-PwshTree $fs

# ================= Stubs for everything outside the temp root =================
$script:H = @{ Stable = 'v7.6.6'; Offline = $false; Procs = @(); Msi = @(); BadHash = $false; BadSig = $false; FailSmokeFor = $null; Downloads = 0; Calls = New-Object System.Collections.Generic.List[string] }
$fakeCache = New-TempRoot
function New-FakeRelease {
    # A folder shaped like a release: a "pwsh.exe" plus the version it reports,
    # a powershell.config.json and a Modules folder.
    param([string] $Version)
    $zip = Join-Path $fakeCache "PowerShell-$Version-win-x64.zip"
    if (Test-Path -LiteralPath $zip) { return $zip }
    $src = Join-Path $fakeCache "src-$Version"
    $null = New-Item -ItemType Directory -Path "$src\Modules\Microsoft.PowerShell.Utility" -Force
    Set-Content -LiteralPath "$src\pwsh.exe" -Value 'fake'
    Set-Content -LiteralPath "$src\version.txt" -Value $Version
    $deny = if ([version]$Version -ge [version]'7.6.7') { '["PSScheduledJob","BestPractices"]' } else { '["PSScheduledJob"]' }
    Set-Content -LiteralPath "$src\powershell.config.json" -Value ('{"Microsoft.PowerShell:ExecutionPolicy":"RemoteSigned","WindowsPowerShellCompatibilityModuleDenyList":' + $deny + '}')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
    $zip
}
function Save-PwshFile {
    param([string] $Uri, [string] $OutFile)
    $v = ($Uri -split '/')[-2].TrimStart('v')
    $zip = New-FakeRelease $v
    if ($Uri -like '*.zip') { $script:H.Downloads++; Copy-Item -LiteralPath $zip -Destination $OutFile; return }
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($script:H.BadHash) { $hash = '0' * 64 }
    [IO.File]::WriteAllText($OutFile, "$hash *PowerShell-$v-win-x64.zip`r`n", [Text.Encoding]::Unicode)
}
function Get-PwshStableTag { if ($script:H.Offline) { throw 'offline' }; $script:H.Stable }
function Get-PwshArchitecture { 'x64' }
function Test-PwshSignature { param([string] $Directory) $null = $Directory; [pscustomobject]@{ Ok = -not $script:H.BadSig; Checked = 1; Failures = @('pwsh.exe: NotSigned') } }
function Invoke-PwshSmokeTest {
    param([string] $Exe, [string] $Expected)
    $got = (Get-Content -LiteralPath (Join-Path (Split-Path -Parent $Exe) 'version.txt')).Trim()
    if ($got -ne $Expected) { throw "smoke: $got <> $Expected" }
    if ($script:H.FailSmokeFor -eq $Expected -and $Exe -like '*\7\pwsh.exe') { throw "smoke: $Expected broke after the switch" }
}
function Get-PwshProcessUsing { param([string[]] $Prefix) $null = $Prefix; $script:H.Procs }
function Get-PwshMsiRegistration { $script:H.Msi }
function Test-PwshIsAdmin { $true }
function Set-PwshMachinePath { param([string] $Entry, [switch] $Remove) $script:H.Calls.Add("path:${Entry}:$Remove"); $true }
function Set-PwshAppPath { param([string] $Exe, [switch] $Remove) $script:H.Calls.Add("apppath:${Exe}:$Remove") }
function Set-PwshShortcut { param([string] $Exe, [switch] $Remove) $script:H.Calls.Add("shortcut:${Exe}:$Remove") }
function Register-PwshTask { param($Ctx) $null = $Ctx; $script:H.Calls.Add('task:register') }
function Unregister-PwshTask { $script:H.Calls.Add('task:unregister') }
function Get-PwshTaskReference { param($Ctx) $null = $Ctx; $script:H.TaskRefs }
function Get-PwshStorePackage { $script:H.StorePkg }
$script:H.TaskRefs = @(); $script:H.StorePkg = @()

# ================= Update transaction =================
$root = New-TempRoot
$ctx = New-PwshContext -InstallRoot $root
Initialize-PwshWorkspace $ctx
$state = { Read-PwshState $ctx }
$active = { $t = Get-PwshLinkTarget $ctx.Link; if ($t) { Split-Path -Leaf $t } }

Check 'first run installs the latest Stable' { (Invoke-PwshUpdateRun -Ctx $ctx) -eq 'Switched' -and (& $active) -eq '7.6.6' -and (& $state).Current -eq '7.6.6' }
Check 'first run records what the release shipped' { Test-Path -LiteralPath "$($ctx.State)\shipped\7.6.6\powershell.config.json" }
Check 'up to date: nothing downloaded' { $d = $script:H.Downloads; (Invoke-PwshUpdateRun -Ctx $ctx) -eq 'UpToDate' -and $script:H.Downloads -eq $d }

# The machine changes its own settings in the live version folder...
$live = "$($ctx.Versions)\7.6.6\powershell.config.json"
Set-Content -LiteralPath $live -Value '{"Microsoft.PowerShell:ExecutionPolicy":"AllSigned","WindowsPowerShellCompatibilityModuleDenyList":["PSScheduledJob"]}'
Set-Content -LiteralPath "$($ctx.Versions)\7.6.6\profile.ps1" -Value '# all users'
$script:H.Stable = 'v7.6.7'
Check 'update switches to the new release' { (Invoke-PwshUpdateRun -Ctx $ctx) -eq 'Switched' -and (& $active) -eq '7.6.7' -and (& $state).Previous -eq '7.6.6' }
$newCfg = Get-Content -Raw -LiteralPath "$($ctx.Versions)\7.6.7\powershell.config.json" | ConvertFrom-Json
Check "update carries the machine's execution policy" { $newCfg.'Microsoft.PowerShell:ExecutionPolicy' -eq 'AllSigned' }
Check "update keeps the new release's defaults" { @($newCfg.WindowsPowerShellCompatibilityModuleDenyList) -contains 'BestPractices' }
Check 'update carries the all-users profile' { Test-Path -LiteralPath "$($ctx.Versions)\7.6.7\profile.ps1" }

$script:H.Stable = 'v7.6.8'
$script:H.Procs = @([pscustomobject]@{ Id = 4242; Name = 'pwsh.exe'; Path = "$($ctx.Link)\pwsh.exe" })
Check 'a running pwsh defers the switch' { (Invoke-PwshUpdateRun -Ctx $ctx) -eq 'Deferred' -and (& $active) -eq '7.6.7' -and (& $state).Staged -eq '7.6.8' }
Check 'a deferred version is staged, not re-downloaded' { $d = $script:H.Downloads; $null = Invoke-PwshUpdateRun -Ctx $ctx; $script:H.Downloads -eq $d }
$script:H.Procs = @(); $script:H.Offline = $true
Check 'the boot run applies a staged version with no network' { (Invoke-PwshUpdateRun -Ctx $ctx) -eq 'Switched' -and (& $active) -eq '7.6.8' -and -not (& $state).Staged }
$script:H.Offline = $false
Check 'prune keeps current + previous only' { $n = @(Get-PwshVersionFolder $ctx | ForEach-Object { $_.Name } | Sort-Object); ($n -join ',') -eq '7.6.7,7.6.8' }
Check 'prune drops the shipped record with the version' { -not (Test-Path -LiteralPath "$($ctx.State)\shipped\7.6.6") }

$script:H.Stable = 'v7.6.9'; $script:H.FailSmokeFor = '7.6.9'
CheckThrows 'a release that fails after the switch throws' { Invoke-PwshUpdateRun -Ctx $ctx } '*broke after the switch*'
Check '...and 7 is switched back' { (& $active) -eq '7.6.8' }
Check '...and it is marked bad and unstaged' { $s = & $state; (@($s.Bad) -contains '7.6.9') -and -not $s.Staged }
$script:H.FailSmokeFor = $null
Check 'a bad version is not retried' { (Invoke-PwshUpdateRun -Ctx $ctx) -eq 'UpToDate' -and (& $active) -eq '7.6.8' }
Check '...and its folder is pruned' { -not (Test-Path -LiteralPath "$($ctx.Versions)\7.6.9") }

$script:H.Stable = 'v7.6.10'; $script:H.BadHash = $true
CheckThrows 'a hash mismatch stops the update' { Invoke-PwshUpdateRun -Ctx $ctx } '*SHA-256 mismatch*'
Check '...with 7 untouched and nothing half-built' { (& $active) -eq '7.6.8' -and -not (Test-Path -LiteralPath "$($ctx.Versions)\7.6.10") -and @(Get-ChildItem -LiteralPath $ctx.Versions -Filter '*.partial-*').Count -eq 0 }
$script:H.BadHash = $false; $script:H.Stable = 'v7.6.11'; $script:H.BadSig = $true
CheckThrows 'a signature failure stops the update' { Invoke-PwshUpdateRun -Ctx $ctx } '*Signature check failed*'
Check '...with 7 untouched' { (& $active) -eq '7.6.8' -and -not (Test-Path -LiteralPath "$($ctx.Versions)\7.6.11") }
$script:H.BadSig = $false

$script:H.Stable = 'v8.0.0'
Check 'a new major is held back' { (Invoke-PwshUpdateRun -Ctx $ctx) -eq 'UpToDate' -and (& $active) -eq '7.6.8' -and (& $state).BlockedMajor -eq '8.0.0' }
$script:H.Stable = 'v7.6.8'

Check 'an explicit older version reuses the kept folder' { $d = $script:H.Downloads; (Invoke-PwshUpdateRun -Ctx $ctx -Version '7.6.7') -eq 'Switched' -and (& $active) -eq '7.6.7' -and $script:H.Downloads -eq $d }
$null = Invoke-PwshUpdateRun -Ctx $ctx -Version '7.6.8'
Start-PwshLog $ctx
Invoke-PwshRollback -Ctx $ctx
Check 'rollback returns to the previous version' { (& $active) -eq '7.6.7' }
Check '...and marks the one it left bad' { @((& $state).Bad) -contains '7.6.8' }
Check 'the log recorded the run' { (Get-Content -Raw -LiteralPath $ctx.LogFile) -like '*Rolled back to 7.6.7*' }

Enter-PwshLock $ctx
CheckThrows 'only one run at a time' { Enter-PwshLock $ctx } '*in progress*'
Exit-PwshLock
$script:PwshLogFile = $null

# Status from a standard user: the SYSTEM task is invisible there, which must
# not read as "not registered".
function Get-ScheduledTask { [CmdletBinding()] param([string] $TaskPath, [string] $TaskName) $null = $TaskPath, $TaskName }
function Test-PwshIsAdmin { $script:H.Admin }
$script:H.Admin = $false
$statusText = (Show-PwshStatus -Ctx $ctx -Offline 6>&1 | Out-String)
Check 'status: a hidden SYSTEM task is not reported as missing' { $statusText -notlike '*not registered*' -and $statusText -like '*runs as SYSTEM*' }
$script:H.Admin = $true
$statusText = (Show-PwshStatus -Ctx $ctx -Offline 6>&1 | Out-String)
Check 'status: an elevated shell that sees no task says so' { $statusText -like '*not registered*' }
Check 'status: shows the active version' { $statusText -like '*7.6.7*' }

$script:H.Msi = @('PowerShell 7-x64 7.6.6')
CheckThrows 'an MSI install stops the updater' { Invoke-PwshUpdateRun -Ctx $ctx } '*MSI is installed*'
$script:H.Msi = @()

# ================= Install / uninstall =================
$root2 = New-TempRoot
$ctx2 = New-PwshContext -InstallRoot $root2
$null = New-Item -ItemType Directory -Path "$root2\7\Modules\Microsoft.PowerShell.Utility", "$root2\7\Scripts\InstalledScriptInfos", "$root2\Modules\Az"
Set-Content -LiteralPath "$root2\Modules\Az\keep.psd1" -Value '@{}'
$script:H.Stable = 'v7.6.6'; $script:H.Calls.Clear()
$script:H.StorePkg = @([pscustomobject]@{ Name = 'Microsoft.PowerShell' })
$script:H.TaskRefs = @([pscustomobject]@{ Task = '\iCloud Sync'; Kind = 'Store'; Execute = 'x' })
$installText = (Invoke-PwshInstall -Ctx $ctx2 -SourceScript $scriptPath 6>&1 | Out-String)
Check 'install lists the steps still left: tasks to re-point, the Store build to remove' { $installText -like '*Next steps*' -and $installText -like '*\iCloud Sync*' -and $installText -like '*Remove-AppxPackage*' }
$script:H.StorePkg = @(); $script:H.TaskRefs = @([pscustomobject]@{ Task = '\iCloud Sync'; Kind = 'Stable'; Execute = 'x' })
$installText = (Invoke-PwshInstall -Ctx $ctx2 -SourceScript $scriptPath 6>&1 | Out-String)
Check 're-running install says Done instead of repeating finished steps' { $installText -like '*Done - no scheduled task runs the Store build*' -and $installText -notlike '*Next steps*' -and $installText -notlike '*Remove-AppxPackage*' }
$script:H.TaskRefs = @()
Check 'install moves the empty leftover 7 aside' { @(Get-ChildItem -LiteralPath $root2 -Directory | Where-Object { $_.Name -like '7.debris-*' }).Count -eq 1 }
Check 'install activates the latest Stable' { (Get-PwshLinkTarget $ctx2.Link) -eq "$($ctx2.Versions)\7.6.6" }
Check 'install copies the updater into the admin-only folder' { (Get-FileHash -LiteralPath $ctx2.Installed).Hash -eq (Get-FileHash -LiteralPath $scriptPath).Hash }
Check 'install wires PATH, App Paths, the shortcut and the task' { $c = $script:H.Calls -join '|'; $c -like "*path:$($ctx2.Link):False*" -and $c -like '*apppath:*' -and $c -like '*shortcut:*' -and $c -like '*task:register*' }

$root3 = New-TempRoot
$null = New-Item -ItemType Directory -Path "$root3\7"
Set-Content -LiteralPath "$root3\7\pwsh.exe" -Value 'real'
CheckThrows 'install refuses a 7 folder with files in it' { Invoke-PwshInstall -Ctx (New-PwshContext -InstallRoot $root3) -SourceScript $scriptPath } '*file(s)*'
Check '...and leaves it alone' { Test-Path -LiteralPath "$root3\7\pwsh.exe" }
CheckThrows 'install refuses an over-long root' { Assert-PwshRoot (New-PwshContext -InstallRoot ('C:\' + ('x' * 120))) } '*longer than*'

# Plant a junction inside pwshup that points at the all-users modules: a
# careless recursive delete would take Modules with it.
New-PwshJunction -Path "$($ctx2.State)\trap" -Target "$root2\Modules"
$script:H.Calls.Clear()
Invoke-PwshUninstall -Ctx $ctx2
Check 'uninstall removes 7 and pwshup' { -not (Test-Path -LiteralPath $ctx2.Link) -and -not (Test-Path -LiteralPath $ctx2.Work) }
Check '...but never the all-users modules' { Test-Path -LiteralPath "$root2\Modules\Az\keep.psd1" }
Check '...and undoes PATH, App Paths, shortcut and task' { $c = $script:H.Calls -join '|'; $c -like "*path:$($ctx2.Link):True*" -and $c -like '*apppath:*:True*' -and $c -like '*shortcut:*:True*' -and $c -like '*task:unregister*' }
$script:H.Procs = @([pscustomobject]@{ Id = 1; Name = 'pwsh.exe'; Path = "$($ctx.Link)\pwsh.exe" })
CheckThrows 'uninstall refuses while pwsh runs from it' { Invoke-PwshUninstall -Ctx $ctx } '*still running*'
$script:H.Procs = @()

foreach ($r in @($root, $root2, $root3, $fakeCache)) { Remove-PwshTree $r }

# ================= Report =================
foreach ($f in $script:failures) { Write-Host "FAIL: $f" }
Write-Host ("PowerShell {0}: {1} passed, {2} failed" -f $PSVersionTable.PSVersion, $script:passed, $script:failures.Count)
if ($script:failures.Count -gt 0) { exit 1 }
exit 0
