#Requires -Version 7.0

# pwsh-toolkit smoke tests.
#
# Strategy: spawn `pwsh -NoProfile` children to load the profile in known
# config states, dump diagnostic state to a UTF-8 JSON file, then assert
# against the captured snapshots. Two probes:
#   - Custom prompt mode (default from config.example.psd1, no user config)
#   - OhMyPosh mode (temp config.psd1 with Prompt = 'OhMyPosh')
#
# JSON-file probe avoids stdout encoding pitfalls; one child per probe keeps
# the suite fast.

BeforeAll {
    # Helper defined here (not at file top) because Pester v5 isolates BeforeAll
    # from the file scope — top-level functions aren't visible inside it.
    function Invoke-LoaderProbe {
        param(
            [Parameter(Mandatory)][string] $LoaderPath
        )

        $probeScript = [IO.Path]::Combine([IO.Path]::GetTempPath(), "pwsh-toolkit-probe-$([Guid]::NewGuid()).ps1")
        $probeOutput = [IO.Path]::Combine([IO.Path]::GetTempPath(), "pwsh-toolkit-probe-$([Guid]::NewGuid()).json")

        $content = @"
`$env:PSPROFILE_NO_TIPS = '1'
`$Error.Clear()
. '$LoaderPath'
`$loadErrors = @(`$Error | ForEach-Object { `$_.ToString() })

`$expectedCommands = @(
    'j','jb','jf','peek','df','winup','tagdl',
    'home','docs','desktop','downloads','onedrive',
    'tip','Show-ProfileTip',
    'Get-PubIP','Get-Uptime','Get-SysInfo','Find-File','Start-AdminTerminal',
    'Get-OrCreateSecret','Get-StoredSecrets','Remove-StoredSecret',
    'rdp','rps',
    'ask','ll','la','touch','which'
)
`$missingCommands = @(`$expectedCommands | Where-Object { -not (Get-Command `$_ -ErrorAction Ignore) })

# `prompt` exists in Custom mode; in OhMyPosh/Default modes Common/Prompt.ps1
# is skipped so the function isn't ours. Capture availability separately.
`$hasOurPrompt = `$null -ne (Get-Command prompt -ErrorAction Ignore)
`$promptOutput = `$null
`$promptErrors = @()
if (`$hasOurPrompt -and `$script:Config.Prompt -eq 'Custom') {
    `$Error.Clear()
    `$promptOutput = prompt
    `$promptErrors = @(`$Error | ForEach-Object { `$_.ToString() })
}

@{
    LoadErrors        = `$loadErrors
    MissingCommands   = `$missingCommands
    HasOurPrompt      = `$hasOurPrompt
    PromptIsString    = (`$promptOutput -is [string])
    PromptIsNonEmpty  = ([bool]`$promptOutput)
    PromptErrors      = `$promptErrors
    ConfigToolkitRoot = `$script:Config.ToolkitRoot
    ConfigPrompt      = `$script:Config.Prompt
    JumpFolderCount   = `$script:JumpFolders.Count
    WingetScript      = `$script:WingetUpgradeScript
} | ConvertTo-Json -Compress | Set-Content -LiteralPath '$probeOutput' -Encoding utf8
"@

        Set-Content -LiteralPath $probeScript -Value $content -Encoding utf8
        & pwsh -NoProfile -NoLogo -File $probeScript | Out-Null
        if (-not (Test-Path -LiteralPath $probeOutput)) {
            throw "Probe failed: no output at $probeOutput. Loader likely errored before ConvertTo-Json."
        }
        $result = Get-Content -LiteralPath $probeOutput -Raw -Encoding utf8 | ConvertFrom-Json
        Remove-Item -LiteralPath $probeScript, $probeOutput -ErrorAction SilentlyContinue
        return $result
    }

    $script:repoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:loader      = Join-Path $script:repoRoot 'Profiles' 'pwsh-toolkit-profile.ps1'
    $script:exampleConf = Join-Path $script:repoRoot 'Profiles' 'config.example.psd1'
    $script:installPath = Join-Path $script:repoRoot 'install.ps1'
    $script:userConfig  = Join-Path $script:repoRoot 'Profiles' 'config.psd1'

    # If the dev's machine has a real config.psd1, move it aside for the
    # duration of the tests and restore it in AfterAll. Both probes need a
    # known, predictable config state.
    $script:configBackup = $null
    if (Test-Path -LiteralPath $script:userConfig) {
        $script:configBackup = "$($script:userConfig).pester-backup-$([Guid]::NewGuid())"
        Move-Item -LiteralPath $script:userConfig -Destination $script:configBackup -Force
    }

    try {
        # Probe 1: defaults from config.example.psd1 (Prompt = 'Custom').
        $script:CustomProbe = Invoke-LoaderProbe -LoaderPath $script:loader

        # Probe 2: write a tiny config.psd1 forcing OhMyPosh mode, then load.
        # Exercises Update-PoshGraphStatus + the OnIdle registration path —
        # both of which call Get-MgContext and need the Get-Command guard.
        @"
@{
    Prompt = 'OhMyPosh'
}
"@ | Set-Content -LiteralPath $script:userConfig -Encoding utf8
        try {
            $script:OmpProbe = Invoke-LoaderProbe -LoaderPath $script:loader
        } finally {
            Remove-Item -LiteralPath $script:userConfig -ErrorAction SilentlyContinue
        }
    } catch {
        # If the run blew up, make sure we still restore the user's config
        if ($script:configBackup -and (Test-Path -LiteralPath $script:configBackup)) {
            Move-Item -LiteralPath $script:configBackup -Destination $script:userConfig -Force
        }
        throw
    }
}

AfterAll {
    if ($script:configBackup -and (Test-Path -LiteralPath $script:configBackup)) {
        Move-Item -LiteralPath $script:configBackup -Destination $script:userConfig -Force
    }
}

Describe 'Profile loads cleanly (Custom prompt mode)' {
    It 'completes with zero errors' {
        $script:CustomProbe.LoadErrors | Should -BeNullOrEmpty
    }

    It 'auto-detects ToolkitRoot as the repo root' {
        $script:CustomProbe.ConfigToolkitRoot | Should -Be $script:repoRoot
    }

    It 'uses Prompt = "Custom"' {
        $script:CustomProbe.ConfigPrompt | Should -Be 'Custom'
    }
}

Describe 'Profile loads cleanly (OhMyPosh mode)' {
    It 'completes with zero errors (even without Microsoft.Graph)' {
        $script:OmpProbe.LoadErrors | Should -BeNullOrEmpty
    }

    It 'uses Prompt = "OhMyPosh"' {
        $script:OmpProbe.ConfigPrompt | Should -Be 'OhMyPosh'
    }
}

Describe 'Key commands are defined after profile load' {
    It 'has every expected command (Custom mode)' {
        $script:CustomProbe.MissingCommands | Should -BeNullOrEmpty
    }

    It 'has every expected command (OhMyPosh mode)' {
        $script:OmpProbe.MissingCommands | Should -BeNullOrEmpty
    }
}

Describe 'Custom prompt function' {
    It 'returns a string' {
        $script:CustomProbe.PromptIsString | Should -BeTrue
    }

    It 'returns a non-empty value' {
        $script:CustomProbe.PromptIsNonEmpty | Should -BeTrue
    }

    It 'invokes without errors (guards Microsoft.Graph absence)' {
        $script:CustomProbe.PromptErrors | Should -BeNullOrEmpty
    }
}

Describe 'Folder jumper' {
    It 'has at least the built-in starter destinations' {
        # Home, Downloads, OneDrive, LocalAppData, ProgramData = 5
        $script:CustomProbe.JumpFolderCount | Should -BeGreaterOrEqual 5
    }
}

Describe 'Wrapper script paths' {
    It 'WingetUpgradeScript resolves under ToolkitRoot' {
        $expected = Join-Path $script:repoRoot 'WingetUpgrade\Invoke-WingetUpgrade.ps1'
        $script:CustomProbe.WingetScript | Should -Be $expected
    }
}

Describe 'config.example.psd1' {
    It 'parses as a valid PowerShell data file' {
        { Import-PowerShellDataFile -LiteralPath $script:exampleConf } | Should -Not -Throw
    }

    It 'defines every documented top-level key' {
        $cfg = Import-PowerShellDataFile -LiteralPath $script:exampleConf
        foreach ($key in 'Prompt','OhMyPoshTheme','ToolkitRoot','OneDriveOrg','ExtraJumpFolders','DisableStartupTips','Features') {
            $cfg.ContainsKey($key) | Should -BeTrue -Because "key '$key' is missing"
        }
    }
}

Describe 'install.ps1' {
    It 'parses without errors' {
        { [scriptblock]::Create((Get-Content -Raw -LiteralPath $script:installPath)) } | Should -Not -Throw
    }

    It '-WhatIf -Force runs to completion' {
        $output = & pwsh -NoProfile -NoLogo -Command "& '$($script:installPath)' -WhatIf -Force" 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'Install complete'
    }
}
