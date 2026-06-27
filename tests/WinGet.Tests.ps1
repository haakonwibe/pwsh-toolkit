#Requires -Version 7.0

# Unit coverage for WingetUpgrade/Invoke-WingetUpgrade.ps1's upgrade-listing
# dispatch (module vs. console-text path, channel labelling, pinned-package
# exclusion) and the Microsoft.WinGet.Client bootstrap decisions.
#
# The script under test is a monolithic top-to-bottom script, not a module, so we
# can't dot-source it without running the whole interactive flow. The work is done
# by assets/winget-listing-harness.ps1, which AST-extracts just the functions
# under test and drives them with stubbed dependencies. We run that harness in an
# isolated child pwsh (so the cmdlet-shadowing stubs can't leak) and assert it
# reports every check passing. It needs no real winget or module, so it runs the
# same everywhere.

BeforeAll {
    $script:harness = Join-Path $PSScriptRoot 'assets/winget-listing-harness.ps1'
}

Describe 'winup upgrade-listing dispatch & module bootstrap' {
    It 'ships the isolated harness asset' {
        Test-Path -LiteralPath $script:harness | Should -BeTrue
    }

    It 'passes every harness assertion (isolated child pwsh)' {
        $output = & pwsh -NoProfile -NoLogo -File $script:harness 2>&1
        $code   = $LASTEXITCODE
        if ($code -ne 0) { Write-Host ($output -join "`n") }
        $code | Should -Be 0
        ($output -join "`n") | Should -Match 'passed, 0 failed'
    }
}
