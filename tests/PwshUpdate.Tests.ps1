#Requires -Version 7.0

# Coverage for PwshUpdate/Invoke-PwshUpdate.ps1, the systemwide PowerShell 7
# updater. It runs as SYSTEM under Windows PowerShell 5.1, so the checks that
# matter are the ones the rest of the suite can't make from pwsh:
#   - it (and its harness) stays ASCII-only, since 5.1 reads a BOM-less file
#     as ANSI and would mangle anything else;
#   - it parses under 5.1;
#   - its behaviour holds under BOTH hosts. assets/pwshupdate-harness.ps1
#     dot-sources the script (which stops before its main block), stubs the
#     network / Authenticode / machine-wide calls, and drives the real junction
#     switching, staging, config carry-over, pruning, repair, install and
#     uninstall against temp roots. It needs no admin rights.

BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:updater  = Join-Path $script:repoRoot 'PwshUpdate/Invoke-PwshUpdate.ps1'
    $script:harness  = Join-Path $PSScriptRoot 'assets/pwshupdate-harness.ps1'
    $script:ps51     = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
}

Describe 'PwshUpdate: Windows PowerShell 5.1 compatibility' {
    It 'keeps <Name> ASCII-only' -ForEach @(
        @{ Name = 'the updater'; Path = 'PwshUpdate/Invoke-PwshUpdate.ps1' }
        @{ Name = 'its harness'; Path = 'tests/assets/pwshupdate-harness.ps1' }
    ) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:repoRoot $Path))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'parses under Windows PowerShell 5.1' -Skip:(-not (Test-Path -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")) {
        $probe = "`$e = `$null; `$null = [Management.Automation.Language.Parser]::ParseFile('$script:updater', [ref]`$null, [ref]`$e); @(`$e).Count"
        & $script:ps51 -NoProfile -NonInteractive -Command $probe | Should -Be '0'
    }
}

Describe 'PwshUpdate: behaviour (isolated harness)' {
    It 'passes every harness check under Windows PowerShell 5.1 (the host the task uses)' -Skip:(-not (Test-Path -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")) {
        $output = & $script:ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:harness 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) { Write-Host ($output -join "`n") }
        $code | Should -Be 0
        ($output -join "`n") | Should -Match 'passed, 0 failed'
    }

    It 'passes every harness check under PowerShell 7' {
        $output = & pwsh -NoProfile -NonInteractive -File $script:harness 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) { Write-Host ($output -join "`n") }
        $code | Should -Be 0
        ($output -join "`n") | Should -Match 'passed, 0 failed'
    }
}

Describe 'PwshUpdate: guard rails that must not drift' {
    BeforeAll { $script:src = Get-Content -Raw -LiteralPath $script:updater }

    It 'never uses Remove-Item -Recurse on the file system' {
        # 5.1's Remove-Item -Recurse follows junctions. The only allowed use is
        # the App Paths registry key, which has none.
        $hits = [regex]::Matches($script:src, '(?m)^(?!\s*#).*Remove-Item[^\r\n]*-Recurse[^\r\n]*$') | ForEach-Object { $_.Value.Trim() }
        @($hits | Where-Object { $_ -notmatch "App Paths|-LiteralPath \`$k " }).Count | Should -Be 0
    }

    It 'registers the SYSTEM task against the installed copy, never the repo' {
        $script:src | Should -Match "-File `"\{0\}`" -Update -Scheduled -InstallRoot `"\{1\}`"' -f \`$Ctx\.Installed, \`$Ctx\.Root"
    }

    It 'refuses to run as SYSTEM from anywhere but the installed copy' {
        $script:src | Should -Match 'Test-PwshIsSystem\) -and \[IO\.Path\]::GetFullPath\(\$PSCommandPath\) -ne \[IO\.Path\]::GetFullPath\(\$ctx\.Installed\)'
    }
}
