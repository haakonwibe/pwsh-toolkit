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
    'j','jb','jf','peek','df','winup','tagdl','json','Show-Json',
    'home','docs','desktop','downloads','onedrive',
    'mkcd','up','..','...',
    'prj',
    'tip','Show-ProfileTip',
    'Get-ToolkitCommand','Show-Toolkit','toolkit',
    'Get-PubIP','Get-Uptime','Get-SysInfo','Find-File','Start-AdminTerminal','sudo','Format-ByteSize',
    'Update-PoshThemes','Set-PoshTheme','Get-PoshTheme',
    'Get-TerminalFont','Set-TerminalFont',
    'Get-OrCreateSecret','Get-StoredSecrets','Remove-StoredSecret',
    'rdp','rps',
    'wtf',
    'note','today','Find-Note','Set-NotesRoot',
    'ask','ll','la','lh','touch','which'
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

# Empty-state friendliness: rdp/rps with no args + empty RemoteServers should
# print a helpful "configure first" message, NOT produce a parameter-binding
# error. 6>`$null suppresses the informational stream so the message doesn't
# pollute the probe's stdout.
`$Error.Clear()
rdp 6>`$null
`$rdpErrors = @(`$Error | ForEach-Object { `$_.ToString() })
`$Error.Clear()
rps 6>`$null
`$rpsErrors = @(`$Error | ForEach-Object { `$_.ToString() })

# Ad-hoc address: rdp/rps with a name/IP that isn't in the configured list
# should fall through to using the argument as a literal address — bookmarks,
# not whitelist. Resolve-RemoteServer is the testable surface; rdp/rps would
# launch mstsc / Enter-PSSession against it.
`$Error.Clear()
`$adhoc = Resolve-RemoteServer -Match 'ad-hoc.example' -PickerTitle 'test'
`$adhocResolveErrors = @(`$Error | ForEach-Object { `$_.ToString() })
`$adhocResolvedAddress = `$adhoc.Address

# Folder jumper: same bookmark-vs-literal-path pattern as rdp/rps. j with
# a non-matching name that IS a real directory should Set-Location there;
# with a non-matching name that's NOT a path, it should print a friendly
# message and produce no `$Error entries.
Push-Location
`$Error.Clear()
j 'C:\Windows' 6>`$null
`$jLiteralErrors  = @(`$Error | ForEach-Object { `$_.ToString() })
`$jLiteralLanded  = ((Get-Location).Path -eq 'C:\Windows')
Pop-Location

Push-Location
`$Error.Clear()
j 'no-such-bookmark-or-path-xyz' 6>`$null
`$jBadMatchErrors = @(`$Error | ForEach-Object { `$_.ToString() })
`$jBadMatchMoved  = ((Get-Location).Path -ne (Get-Location).Path)  # always false; ensures we didn't move
Pop-Location

@{
    LoadErrors        = `$loadErrors
    MissingCommands   = `$missingCommands
    HasOurPrompt      = `$hasOurPrompt
    PromptIsString    = (`$promptOutput -is [string])
    PromptIsNonEmpty  = ([bool]`$promptOutput)
    PromptErrors      = `$promptErrors
    RdpErrors             = `$rdpErrors
    RpsErrors             = `$rpsErrors
    AdhocResolvedAddress  = `$adhocResolvedAddress
    AdhocResolveErrors    = `$adhocResolveErrors
    JLiteralLanded        = `$jLiteralLanded
    JLiteralErrors        = `$jLiteralErrors
    JBadMatchErrors       = `$jBadMatchErrors
    ConfigToolkitRoot = `$script:Config.ToolkitRoot
    ConfigPrompt      = `$script:Config.Prompt
    JumpFolderCount   = `$script:JumpFolders.Count
    WingetScript      = `$script:WingetUpgradeScript
    OnIdleCount       = @(Get-EventSubscriber -SourceIdentifier PowerShell.OnIdle -ErrorAction Ignore).Count
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

    # The probe child runs under the 'ConsoleHost' PowerShell host, so a per-host
    # override for it must be named Hosts/ConsoleHost.ps1.
    $script:hostOverride = Join-Path $script:repoRoot 'Profiles' 'Hosts' 'ConsoleHost.ps1'

    # If the dev's machine has a real config.psd1 / Hosts\ConsoleHost.ps1, move
    # them aside for the duration of the tests and restore in AfterAll. The
    # probes need a known, predictable state.
    $script:configBackup = $null
    if (Test-Path -LiteralPath $script:userConfig) {
        $script:configBackup = "$($script:userConfig).pester-backup-$([Guid]::NewGuid())"
        Move-Item -LiteralPath $script:userConfig -Destination $script:configBackup -Force
    }
    $script:hostBackup = $null
    if (Test-Path -LiteralPath $script:hostOverride) {
        $script:hostBackup = "$($script:hostOverride).pester-backup-$([Guid]::NewGuid())"
        Move-Item -LiteralPath $script:hostOverride -Destination $script:hostBackup -Force
    }

    try {
        # Probe 1: defaults from config.example.psd1 (Prompt = 'Custom').
        $script:CustomProbe = Invoke-LoaderProbe -LoaderPath $script:loader

        # Probe 2: write a tiny config.psd1 forcing OhMyPosh mode, then load.
        # Exercises Update-PoshGraphStatus + the OnIdle registration path —
        # guarded by Get-Module (loaded modules only) so profile load never
        # auto-imports Microsoft.Graph.Authentication just to read the context.
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

        # Probe 3: the documented per-host pattern — a Hosts/<host>.ps1 that
        # swaps Oh My Posh for the lightweight Custom prompt (the shape shipped in
        # Hosts/VisualStudioCodeHost.ps1.example). Config selects OhMyPosh; the host
        # file flips $script:Config.Prompt to 'Custom' (which also makes the OMP
        # tail skip itself) and dot-sources the Custom prompt.
        @"
@{
    Prompt = 'OhMyPosh'
}
"@ | Set-Content -LiteralPath $script:userConfig -Encoding utf8
        @'
$script:Config.Prompt = 'Custom'
. (Join-Path $script:ProfileRoot 'Common\Prompt.ps1')
'@ | Set-Content -LiteralPath $script:hostOverride -Encoding utf8
        try {
            $script:HostPromptProbe = Invoke-LoaderProbe -LoaderPath $script:loader
        } finally {
            Remove-Item -LiteralPath $script:userConfig   -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $script:hostOverride -ErrorAction SilentlyContinue
        }
    } catch {
        # If the run blew up, make sure we still restore the user's files
        if ($script:configBackup -and (Test-Path -LiteralPath $script:configBackup)) {
            Move-Item -LiteralPath $script:configBackup -Destination $script:userConfig -Force
        }
        if ($script:hostBackup -and (Test-Path -LiteralPath $script:hostBackup)) {
            Move-Item -LiteralPath $script:hostBackup -Destination $script:hostOverride -Force
        }
        throw
    }
}

AfterAll {
    if ($script:configBackup -and (Test-Path -LiteralPath $script:configBackup)) {
        Move-Item -LiteralPath $script:configBackup -Destination $script:userConfig -Force
    }
    if ($script:hostBackup -and (Test-Path -LiteralPath $script:hostBackup)) {
        Move-Item -LiteralPath $script:hostBackup -Destination $script:hostOverride -Force
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

Describe 'Per-host prompt override (a Hosts file swaps OMP for Custom)' {
    It 'leaves $script:Config.Prompt = "Custom" after the host file flips it' {
        $script:HostPromptProbe.ConfigPrompt | Should -Be 'Custom'
    }

    It 'has the Custom prompt function loaded (host file dot-sourced Prompt.ps1)' {
        $script:HostPromptProbe.HasOurPrompt | Should -BeTrue
    }

    It 'skips the Oh My Posh tail — no PowerShell.OnIdle subscriber registered' {
        # The flip to 'Custom' makes the OMP tail gate fail, so the Graph OnIdle
        # handler never registers. (The plain OhMyPosh probe DOES register it.)
        $script:HostPromptProbe.OnIdleCount | Should -Be 0
        $script:OmpProbe.OnIdleCount        | Should -BeGreaterThan 0
    }

    It 'loads cleanly' {
        $script:HostPromptProbe.LoadErrors | Should -BeNullOrEmpty
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
        foreach ($key in 'Prompt','OhMyPoshTheme','ToolkitRoot','OneDriveOrg','ExtraJumpFolders','ProjectRoots','DisableStartupTips','Features') {
            $cfg.ContainsKey($key) | Should -BeTrue -Because "key '$key' is missing"
        }
    }
}

Describe 'Remote server helpers (empty-state UX)' {
    It 'rdp with no args + no RemoteServers shows friendly message — no errors' {
        $script:CustomProbe.RdpErrors | Should -BeNullOrEmpty
    }

    It 'rps with no args + no RemoteServers shows friendly message — no errors' {
        $script:CustomProbe.RpsErrors | Should -BeNullOrEmpty
    }
}

Describe 'Remote server helpers (ad-hoc address fallthrough)' {
    It 'Resolve-RemoteServer returns the literal address when no config entry matches' {
        $script:CustomProbe.AdhocResolvedAddress | Should -Be 'ad-hoc.example'
    }

    It 'ad-hoc resolution produces no errors' {
        $script:CustomProbe.AdhocResolveErrors | Should -BeNullOrEmpty
    }
}

Describe 'Folder jumper (literal path fallthrough)' {
    It 'j with a non-matching name that IS a real directory jumps there' {
        $script:CustomProbe.JLiteralLanded | Should -BeTrue
    }

    It 'j with a real directory path produces no errors' {
        $script:CustomProbe.JLiteralErrors | Should -BeNullOrEmpty
    }

    It 'j with a non-matching name AND non-existent path produces no errors (friendly message only)' {
        $script:CustomProbe.JBadMatchErrors | Should -BeNullOrEmpty
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

    It '-Uninstall -WhatIf runs to completion and reports what it leaves' {
        $output = & pwsh -NoProfile -NoLogo -Command "& '$($script:installPath)' -Uninstall -WhatIf" 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'Left untouched'
    }
}
