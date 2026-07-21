#Requires -Version 7.0

# pwsh-toolkit UNIT tests.
#
# Complements Smoke.Tests.ps1, which verifies the profile *loads* and every
# command *exists*. These tests verify what those can't: the actual BEHAVIOR of
# the pure-logic functions. Every bug fixed in 0.1.25/0.1.26 (touch truncating
# files, `la` showing nothing, `which` returning blank for aliases, `which`
# hanging on circular aliases / erroring on bad wildcards) loaded fine and the
# commands all existed — they were behavioral bugs the smoke suite is blind to.
# Each of those failure modes now has a guard here.
#
# Strategy: dot-source individual Common/*.ps1 files in-process with a minimal
# mocked $script:Config (cheaper and more direct than the smoke suite's child
# processes — these functions don't need a real loaded profile). The files have
# no problematic load-time side effects given a Config whose ToolkitRoot points
# nowhere real (so Aliases.ps1's optional DownloadsOrganizer dot-source is
# skipped) and a preset NotesRoot (so Notes.ps1 skips its resolution cascade).

BeforeAll {
    $repoRoot  = Split-Path $PSScriptRoot -Parent
    $commonDir = Join-Path $repoRoot 'Profiles/Common'

    # Minimal Config so files with load-time references resolve cleanly without
    # triggering side effects (no DownloadsOrganizer load, no notes I/O).
    $script:Config = @{
        ToolkitRoot   = Join-Path ([IO.Path]::GetTempPath()) 'pwsh-toolkit-unit-nonexistent'
        NotesRoot     = Join-Path ([IO.Path]::GetTempPath()) 'pwsh-toolkit-unit-notes'
        RemoteServers = @()
        ProjectRoots  = @()
    }

    . (Join-Path $commonDir 'Aliases.ps1')        # touch, which, ll, la, ask
    . (Join-Path $commonDir 'Navigation.ps1')     # mkcd, up
    . (Join-Path $commonDir 'Recent.ps1')         # Get-RecentFile, Format-FileAge (needs Navigation's $script:OneDrivePath)
    . (Join-Path $commonDir 'Clipboard.ps1')      # cb + snippet helpers (renders age via Recent's Format-FileAge)
    . (Join-Path $commonDir 'Peek.ps1')           # Get-PeekTool + exe finders
    . (Join-Path $commonDir 'RemoteServers.ps1')  # Format-RemoteServerDisplay, Get-RemoteServerByMatch
    . (Join-Path $commonDir 'Picker.ps1')         # Get-PickerScrollTop
    . (Join-Path $commonDir 'Projects.ps1')       # Find-GitProject, Get-ProjectRoot
    . (Join-Path $commonDir 'SystemUtilities.ps1') # Test-NativeSudoEnabled
    . (Join-Path $commonDir 'PoshThemes.ps1')      # Get-PoshThemePool
    . (Join-Path $commonDir 'Terminal.ps1')        # Update-FontFaceText
    . (Join-Path $commonDir 'Catalog.ps1')         # Get-ToolkitCommand
    . (Join-Path $commonDir 'Json.ps1')            # Show-Json + Format-JsonColor
    . (Join-Path $commonDir 'ScheduledTasks.ps1')  # Format-TaskResult, Test-ToolkitTaskVisible
    . (Join-Path $repoRoot 'Profiles/M365/IntuneManagement.ps1')  # Get-ComplianceBucket, ConvertTo-IntuneDashboardHtml (defining these needs no Graph)
}

Describe 'touch' {

    BeforeEach {
        # Fresh isolated working directory per test so relative paths are clean.
        $script:tdir = Join-Path ([IO.Path]::GetTempPath()) ("touch-ut-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tdir | Out-Null
        Push-Location $tdir
    }
    AfterEach {
        Pop-Location
        Remove-Item -LiteralPath $tdir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates a new empty file when absent' {
        touch 'new.txt'
        'new.txt'           | Should -Exist
        (Get-Item 'new.txt').Length | Should -Be 0
    }

    It 'does NOT truncate an existing file (the 0.1.25 data-loss bug)' {
        Set-Content -LiteralPath 'keep.txt' -Value 'IMPORTANT CONTENT' -NoNewline
        touch 'keep.txt'
        Get-Content -Raw -LiteralPath 'keep.txt' | Should -Be 'IMPORTANT CONTENT'
    }

    It 'bumps the last-write time of an existing file' {
        Set-Content -LiteralPath 'stamp.txt' -Value 'x'
        $old = (Get-Date).AddDays(-2)
        (Get-Item 'stamp.txt').LastWriteTime = $old
        touch 'stamp.txt'
        (Get-Item 'stamp.txt').LastWriteTime | Should -BeGreaterThan $old
    }

    It 'creates missing parent directories for a nested path' {
        touch 'sub\deeper\file.txt'
        'sub\deeper\file.txt' | Should -Exist
    }

    It 'accepts multiple targets in one call' {
        touch 'a.txt' 'b.txt' 'c.txt'
        'a.txt' | Should -Exist
        'b.txt' | Should -Exist
        'c.txt' | Should -Exist
    }

    It 'works with an absolute path' {
        $abs = Join-Path $tdir 'abs.txt'
        touch $abs
        $abs | Should -Exist
    }
}

Describe 'lh' {

    BeforeEach {
        $script:ldir = Join-Path ([IO.Path]::GetTempPath()) ("lh-ut-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $ldir | Out-Null
        Set-Content -LiteralPath (Join-Path $ldir 'visible.txt') -Value 'x'
        (New-Item -ItemType File -Path (Join-Path $ldir 'secret.txt')).Attributes = 'Hidden'
        (New-Item -ItemType File -Path (Join-Path $ldir 'sysfile.txt')).Attributes = 'System'
        Push-Location $ldir
    }
    AfterEach {
        Pop-Location
        Remove-Item -LiteralPath $ldir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'shows hidden and system entries and hides normal ones' {
        $out = lh | Out-String
        $out | Should -Match 'secret.txt'    # hidden
        $out | Should -Match 'sysfile.txt'   # system
        $out | Should -Not -Match 'visible.txt'
    }
}

Describe 'which' {

    It 'returns the on-disk path for an application' {
        # pwsh is guaranteed present (we are running under it).
        which pwsh | Should -Match 'pwsh(\.exe)?$'
    }

    It 'resolves an alias to the command it ultimately runs' {
        Set-Alias _ut_alias Get-ChildItem -Scope Global -Force
        try   { which _ut_alias | Should -Match 'Get-ChildItem' }
        finally { Remove-Item Alias:_ut_alias -Force -ErrorAction SilentlyContinue }
    }

    It 'labels a cmdlet with its module' {
        which Get-ChildItem | Should -Match '\[cmdlet in'
    }

    It 'labels a function' {
        function _ut_fn { }
        which _ut_fn | Should -Match '\[function\]'
    }

    It 'prints a not-found message and returns nothing for an unknown command' {
        # Write-Host goes to the information stream (6); suppress it so we can
        # assert on the (empty) return value.
        $result = which _ut_definitely_not_a_command_zzz 6>$null
        $result | Should -BeNullOrEmpty
    }

    It 'does NOT hang on a circular alias (the 0.1.26 infinite-loop bug)' {
        Set-Alias _ut_circA _ut_circB -Scope Global -Force
        Set-Alias _ut_circB _ut_circA -Scope Global -Force
        try {
            # The 20-hop cap guarantees termination; assert the sentinel.
            which _ut_circA | Should -Match '\(circular\)'
        }
        finally {
            Remove-Item Alias:_ut_circA, Alias:_ut_circB -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does NOT throw on an invalid wildcard pattern (the 0.1.26 red-error bug)' {
        # `no[such` is an unbalanced bracket — Get-Command throws during pattern
        # compilation, which -ErrorAction Ignore does not suppress.
        { which 'no[such' 6>$null } | Should -Not -Throw
    }

    It 'still globs a valid wildcard to a single match' {
        which 'Get-Childit*' | Should -Match 'Get-ChildItem'
    }
}

Describe 'Get-PeekTool (archive tool dispatch)' {

    Context 'WinRAR and 7-Zip both present' {
        BeforeEach {
            Mock Get-PeekRarExe { 'C:\WinRAR\Rar.exe' }
            Mock Get-Peek7zExe  { 'C:\7-Zip\7z.exe' }
        }
        It '.rar uses WinRAR' { (Get-PeekTool '.rar').Kind | Should -Be 'rar' }
        It '.zip uses 7-Zip'  { (Get-PeekTool '.zip').Kind | Should -Be '7z' }
        It 'is case-insensitive on the extension' { (Get-PeekTool '.RAR').Kind | Should -Be 'rar' }
    }

    Context 'only 7-Zip present' {
        BeforeEach {
            Mock Get-PeekRarExe { $null }
            Mock Get-Peek7zExe  { 'C:\7-Zip\7z.exe' }
        }
        It '.rar falls back to 7-Zip' { (Get-PeekTool '.rar').Kind | Should -Be '7z' }
        It '.7z uses 7-Zip'          { (Get-PeekTool '.7z').Kind  | Should -Be '7z' }
    }

    Context 'neither tool present' {
        BeforeEach {
            Mock Get-PeekRarExe { $null }
            Mock Get-Peek7zExe  { $null }
        }
        It '.zip falls back to the built-in extractor' { (Get-PeekTool '.zip').Kind | Should -Be 'builtin-zip' }
        It '.rar has no available tool' { Get-PeekTool '.rar' | Should -BeNullOrEmpty }
        It '.7z has no available tool'  { Get-PeekTool '.7z'  | Should -BeNullOrEmpty }
    }
}

Describe 'winup -Elevated' {

    It 'relaunches the winget script elevated, forwarding args, with -Elevated stripped' {
        Mock Get-SudoExe { $null }   # force the new-elevated-window fallback (no real sudo)
        Mock Start-Process { }       # don't actually launch anything
        Invoke-WingetUpgradeMenu -Elevated -All
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $Verb -eq 'RunAs' -and
            $ArgumentList -contains '-NoExit' -and
            $ArgumentList -contains '-NoProfile' -and
            $ArgumentList -contains '-File' -and
            $ArgumentList -contains '-All' -and          # extra arg forwarded to the script
            $ArgumentList -notcontains '-Elevated'        # the switch itself is consumed, not forwarded
        }
    }
}

Describe 'Get-ToolkitCommand' {

    BeforeAll {
        $script:savedRoot = $script:ProfileRoot
        $script:ProfileRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Profiles'
    }
    AfterAll { $script:ProfileRoot = $script:savedRoot }

    It 'discovers the public commands with synopses' {
        $cmds = @(Get-ToolkitCommand)
        $cmds.Count            | Should -BeGreaterThan 30
        $cmds.Command          | Should -Contain 'prj'
        $cmds.Command          | Should -Contain 'toolkit'
        # display name uses the alias for wrapper functions
        $cmds.Command          | Should -Contain 'winup'
    }

    It 'hides internal helpers by default but -All reveals them' {
        @(Get-ToolkitCommand).Command       | Should -Not -Contain 'Show-Picker'
        @(Get-ToolkitCommand -All).Function | Should -Contain 'Show-Picker'
    }

    It 'excludes script-scoped (private) functions' {
        @(Get-ToolkitCommand).Function | Should -Not -Contain 'script:Wrap-Text'
    }
}

Describe 'Update-FontFaceText (Windows Terminal font edit)' {

    It 'replaces the face value and preserves the rest of the JSON' {
        $json = '{ "profiles": { "list": [ { "name": "PowerShell", "font": { "face": "Old Font" }, "guid": "{abc}" } ] } }'
        $out  = Update-FontFaceText -Json $json -Font 'MesloLGM Nerd Font'
        $out | Should -Match '"face"\s*:\s*"MesloLGM Nerd Font"'
        $out | Should -Not -Match 'Old Font'
        $out | Should -Match '"guid": "\{abc\}"'          # untouched
        $out | Should -Match '"name": "PowerShell"'       # untouched
    }

    It 'produces valid JSON' {
        $json = '{ "profiles": { "defaults": { "font": { "face": "Consolas" } } } }'
        $out  = Update-FontFaceText -Json $json -Font 'Cascadia Code'
        { $out | ConvertFrom-Json } | Should -Not -Throw
        ($out | ConvertFrom-Json).profiles.defaults.font.face | Should -Be 'Cascadia Code'
    }

    It 'only changes the first face when several exist' {
        $json = '{ "a": { "face": "One" }, "b": { "face": "Two" } }'
        $out  = Update-FontFaceText -Json $json -Font 'X'
        ($out | ConvertFrom-Json).a.face | Should -Be 'X'
        ($out | ConvertFrom-Json).b.face | Should -Be 'Two'
    }
}

Describe 'Get-PoshThemePool' {

    BeforeAll {
        $script:savedCache = $script:PoshThemeCache
        $script:savedRoot  = $script:ProfileRoot
        $script:tCache = Join-Path ([IO.Path]::GetTempPath()) ("posh-cache-" + [Guid]::NewGuid().ToString('N'))
        $script:tRoot  = Join-Path ([IO.Path]::GetTempPath()) ("posh-root-"  + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tCache | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tRoot 'OhMyPosh') -Force | Out-Null
        # Gallery cache: atomic + shared. Bundled: default + shared (a duplicate name).
        'x' | Set-Content (Join-Path $tCache 'atomic.omp.json')
        'x' | Set-Content (Join-Path $tCache 'shared.omp.json')
        'x' | Set-Content (Join-Path $tRoot 'OhMyPosh\default.omp.json')
        'x' | Set-Content (Join-Path $tRoot 'OhMyPosh\shared.omp.json')
        $script:PoshThemeCache = $tCache
        $script:ProfileRoot    = $tRoot
    }
    AfterAll {
        $script:PoshThemeCache = $script:savedCache
        $script:ProfileRoot    = $script:savedRoot
        Remove-Item -LiteralPath $tCache -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tRoot  -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'merges the gallery cache and bundled themes' {
        $names = @(Get-PoshThemePool).Name
        $names | Should -Contain 'atomic.omp.json'    # from cache
        $names | Should -Contain 'default.omp.json'   # from bundled
    }

    It 'de-duplicates by file name' {
        $names = @(Get-PoshThemePool).Name
        @($names | Where-Object { $_ -eq 'shared.omp.json' }).Count | Should -Be 1
    }
}

Describe 'Format-ByteSize' {

    It 'selects the right unit and renders MB/KB as whole numbers' {
        Format-ByteSize 0     | Should -Be '0 KB'
        Format-ByteSize 512KB | Should -Be '512 KB'
        Format-ByteSize 250MB | Should -Be '250 MB'
        Format-ByteSize 16MB  | Should -Be '16 MB'
    }

    It 'gives TB and GB one decimal by default (separator is culture-dependent)' {
        Format-ByteSize 4GB | Should -Match '^4[.,]0 GB$'
        Format-ByteSize 2TB | Should -Match '^2[.,]0 TB$'
    }

    It 'honors -DecimalUnits — the df style renders whole GB' {
        Format-ByteSize 256GB -DecimalUnits 'TB' | Should -Be '256 GB'
    }

    It 'right-aligns the number to -Width' {
        Format-ByteSize 256GB -DecimalUnits 'TB' -Width 5 | Should -Be '  256 GB'
    }
}

Describe 'Test-NerdFontInstalled' {

    It 'is true when a Nerd Font is registered' {
        Mock Get-ItemProperty { [pscustomobject]@{ 'MesloLGM Nerd Font Regular (TrueType)' = 'meslo.ttf' } }
        Test-NerdFontInstalled | Should -BeTrue
    }

    It 'is true for a Powerline-patched or abbreviated NF name' {
        Mock Get-ItemProperty { [pscustomobject]@{ 'CaskaydiaCove NF (TrueType)' = 'caskaydia.ttf' } }
        Test-NerdFontInstalled | Should -BeTrue
    }

    It 'is false when only ordinary fonts are present' {
        Mock Get-ItemProperty { [pscustomobject]@{ 'Arial (TrueType)' = 'arial.ttf'; 'Consolas (TrueType)' = 'consola.ttf' } }
        Test-NerdFontInstalled | Should -BeFalse
    }
}

Describe 'Test-NativeSudoEnabled' {

    It 'is true when the Sudo Enabled value is a non-zero mode' {
        Mock Get-ItemProperty { [pscustomobject]@{ Enabled = 3 } }
        Test-NativeSudoEnabled | Should -BeTrue
    }

    It 'is false when Enabled is 0 (disabled)' {
        Mock Get-ItemProperty { [pscustomobject]@{ Enabled = 0 } }
        Test-NativeSudoEnabled | Should -BeFalse
    }

    It 'is false when the key or value is absent' {
        Mock Get-ItemProperty { $null }
        Test-NativeSudoEnabled | Should -BeFalse
    }
}

Describe 'peek -Clean' {

    It 'deletes the peek tree even when run from inside it (8.3-path safe)' {
        # Regression guard: $env:TEMP is the 8.3 short form but Get-Location is
        # the long form, so the old `-like "$PeekRoot*"` inside-check missed and
        # Remove-Item failed on the cwd ("in use"). Point PeekRoot at an isolated
        # temp dir so we never touch a real peek, jump inside, then -Clean.
        $startLoc  = (Get-Location).Path
        $savedRoot = $script:PeekRoot
        try {
            $script:PeekRoot = Join-Path ([IO.Path]::GetTempPath()) ("peek-ut-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $script:PeekRoot 'inner') -Force | Out-Null
            Invoke-JumpTo -Path (Join-Path $script:PeekRoot 'inner')   # cd in (long form), pushes jb history

            peek -Clean 6>$null   # 6>$null swallows the Write-Host status stream

            Test-Path -LiteralPath $script:PeekRoot | Should -BeFalse   # tree gone, no "in use"
        }
        finally {
            Set-Location -LiteralPath $startLoc
            if (Test-Path -LiteralPath $script:PeekRoot) {
                Remove-Item -LiteralPath $script:PeekRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            $script:PeekRoot = $savedRoot
        }
    }
}

Describe 'Show-Json' {

    It 'reflows minified JSON to indented form' {
        $out = '{"a":1,"b":[2,3]}' | Show-Json -NoColor | Out-String
        $out | Should -Match '(?m)^\s+"a": 1'   # key indented onto its own line
        $out | Should -Match '(?m)^\s+2,?\s*$'   # array element on its own line
    }

    It 'serializes piped objects to JSON' {
        $out = [pscustomobject]@{ x = 5; y = 'hi' } | Show-Json -NoColor | Out-String
        ($out | ConvertFrom-Json).x | Should -Be 5
        ($out | ConvertFrom-Json).y | Should -Be 'hi'
    }

    It 'drops comments when reflowing without -Raw, but keeps the data' {
        $src = "{`n  // a note`n  `"n`": 1`n}"
        $out = $src | Show-Json -NoColor | Out-String
        $out | Should -Not -Match 'a note'
        ($out | ConvertFrom-Json).n | Should -Be 1
    }

    It 'preserves comments and layout verbatim with -Raw' {
        $src = "{`n  // a note`n  `"n`": 1`n}"
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("sj-" + [Guid]::NewGuid().ToString('N') + '.jsonc')
        Set-Content -LiteralPath $tmp -Value $src -Encoding utf8
        try {
            $out = Show-Json -Path $tmp -Raw -NoColor | Out-String
            $out | Should -Match 'a note'
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'does not throw on input that is not JSON — shows it as-is (the no-data-loss guard)' {
        { '{ not valid json' | Show-Json -NoColor 3>$null } | Should -Not -Throw
        ('{ not valid json' | Show-Json -NoColor 3>$null) | Out-String | Should -Match 'not valid json'
    }

    It 'errors on a missing file path' {
        { Show-Json -Path (Join-Path ([IO.Path]::GetTempPath()) 'no-such-file-xyz.json') -ErrorAction Stop } |
            Should -Throw
    }
}

Describe 'Format-JsonColor (token highlighting)' {

    It 'wraps each token kind in its own ANSI color code' {
        $esc = [char]27
        $colored = Format-JsonColor '{"k":"v","n":1,"b":true,"z":null}'
        $colored | Should -Match ([regex]::Escape("$esc[96m"))   # key      -> cyan
        $colored | Should -Match ([regex]::Escape("$esc[92m"))   # string   -> green
        $colored | Should -Match ([regex]::Escape("$esc[93m"))   # number   -> yellow
        $colored | Should -Match ([regex]::Escape("$esc[95m"))   # literal  -> magenta
        $colored | Should -Match ([regex]::Escape("$esc[90m"))   # punct    -> gray
    }

    It 'colors a property name (key) differently from a string value' {
        $esc = [char]27
        # "k" is a key (cyan 96); "v" is a value (green 92)
        $colored = Format-JsonColor '{"k":"v"}'
        $colored | Should -Match ([regex]::Escape("$esc[96m`"k`"$esc[0m"))
        $colored | Should -Match ([regex]::Escape("$esc[92m`"v`"$esc[0m"))
    }

    It 'does NOT treat a // inside a quoted string as a comment' {
        $esc     = [char]27
        $slashes = [char]47 + [char]47
        $colored = Format-JsonColor ('{"u":"a' + $slashes + 'b"}')
        # the whole "a//b" must be one green string, not split by a gray comment
        $colored | Should -Match ([regex]::Escape("$esc[92m`"a${slashes}b`"$esc[0m"))
    }
}

Describe 'Format-RemoteServerDisplay' {

    It 'formats a configured entry as "Label (Address)"' {
        $s = [pscustomobject]@{ Label = 'Lab DC'; Address = 'dc01.lab.local' }
        Format-RemoteServerDisplay $s | Should -Be 'Lab DC (dc01.lab.local)'
    }

    It 'formats an ad-hoc entry (Label == Address) as just the address' {
        $s = [pscustomobject]@{ Label = '10.0.0.2'; Address = '10.0.0.2' }
        Format-RemoteServerDisplay $s | Should -Be '10.0.0.2'
    }
}

Describe 'Get-RemoteServerByMatch' {

    BeforeEach {
        $script:Config.RemoteServers = @(
            [pscustomobject]@{ Label = 'Lab DC'; Address = 'dc01.lab.local'; User = 'lab\admin' }
            [pscustomobject]@{ Label = 'Build';  Address = 'build.contoso.com' }
        )
    }
    AfterEach { $script:Config.RemoteServers = @() }

    It 'matches on a label substring (case-insensitive)' {
        (Get-RemoteServerByMatch -Match 'build').Address | Should -Be 'build.contoso.com'
    }

    It 'matches on an address substring' {
        (Get-RemoteServerByMatch -Match 'lab.local').Label | Should -Be 'Lab DC'
    }

    It 'returns nothing when no entry matches' {
        Get-RemoteServerByMatch -Match 'nope-no-such-host' | Should -BeNullOrEmpty
    }

    It 'returns nothing for an empty match' {
        Get-RemoteServerByMatch -Match '' | Should -BeNullOrEmpty
    }
}

Describe 'mkcd' {

    BeforeEach {
        $script:base = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("mkcd-ut-" + [Guid]::NewGuid().ToString('N')))).FullName
        Push-Location $base
    }
    AfterEach {
        Pop-Location
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates a nested directory (with parents) and changes into it' {
        mkcd 'a\b\c'
        (Get-Location).Path | Should -Be (Get-Item (Join-Path $base 'a\b\c')).FullName
    }
}

Describe 'up' {

    BeforeEach {
        $script:base = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("up-ut-" + [Guid]::NewGuid().ToString('N')))).FullName
        New-Item -ItemType Directory -Path (Join-Path $base 'x\y\z') | Out-Null
        Push-Location (Join-Path $base 'x\y\z')
    }
    AfterEach {
        Pop-Location
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'goes up one level by default' {
        up
        (Get-Location).Path | Should -Be (Get-Item (Join-Path $base 'x\y')).FullName
    }

    It 'goes up N levels' {
        up 2
        (Get-Location).Path | Should -Be (Get-Item (Join-Path $base 'x')).FullName
    }
}

Describe 'recent (Get-RecentFile)' {

    BeforeEach {
        # Two source folders with files at staggered ages, plus noise a correct
        # implementation must skip: a subdirectory and a nonexistent folder.
        $script:rdir1 = Join-Path ([IO.Path]::GetTempPath()) ("rf-ut1-" + [Guid]::NewGuid().ToString('N'))
        $script:rdir2 = Join-Path ([IO.Path]::GetTempPath()) ("rf-ut2-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $rdir1, $rdir2 | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $rdir1 'subdir') | Out-Null
        Set-Content -LiteralPath (Join-Path $rdir1 'old.txt')    -Value 'x'
        Set-Content -LiteralPath (Join-Path $rdir1 'newest.txt') -Value 'x'
        Set-Content -LiteralPath (Join-Path $rdir2 'middle.txt') -Value 'x'
        (Get-Item (Join-Path $rdir1 'old.txt')).LastWriteTime    = (Get-Date).AddDays(-3)
        (Get-Item (Join-Path $rdir2 'middle.txt')).LastWriteTime = (Get-Date).AddHours(-2)
    }
    AfterEach {
        Remove-Item -LiteralPath $rdir1, $rdir2 -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns files newest-first across folders' {
        (Get-RecentFile -Folder $rdir1, $rdir2).Name | Should -Be @('newest.txt', 'middle.txt', 'old.txt')
    }

    It 'honors -Limit' {
        @(Get-RecentFile -Folder $rdir1, $rdir2 -Limit 2).Count | Should -Be 2
    }

    It 'skips nonexistent folders without error' {
        $ghost = Join-Path ([IO.Path]::GetTempPath()) 'rf-ut-no-such-dir'
        { Get-RecentFile -Folder $rdir1, $ghost } | Should -Not -Throw
        @(Get-RecentFile -Folder $rdir1, $ghost).Count | Should -Be 2
    }

    It 'lists files only, not directories' {
        (Get-RecentFile -Folder $rdir1).Name | Should -Not -Contain 'subdir'
    }

    It 'defaults to $script:RecentFolders' {
        $saved = $script:RecentFolders
        try {
            $script:RecentFolders = @($rdir2)
            (Get-RecentFile).Name | Should -Be @('middle.txt')
        } finally { $script:RecentFolders = $saved }
    }
}

Describe 'Format-FileAge' {

    It 'says now for fresh (and future) timestamps' {
        Format-FileAge (Get-Date)              | Should -Be 'now'
        Format-FileAge (Get-Date).AddHours(1)  | Should -Be 'now'
    }

    It 'uses minutes under an hour' {
        Format-FileAge (Get-Date).AddMinutes(-5) | Should -Be '5m'
    }

    It 'uses hours under a day' {
        Format-FileAge (Get-Date).AddHours(-3) | Should -Be '3h'
    }

    It 'uses days under 30' {
        Format-FileAge (Get-Date).AddDays(-12) | Should -Be '12d'
    }

    It 'falls back to a date at 30+ days' {
        $t = (Get-Date).AddDays(-45)
        Format-FileAge $t | Should -Be $t.ToString('yyyy-MM-dd')
    }
}

Describe 'j bookmarks (-Add / -Remove)' {

    BeforeEach {
        # Isolate the store to a temp file and start from a known jump list, so
        # the dev's real %LOCALAPPDATA% bookmarks are never read or written.
        $script:savedBookmarkFile = $script:JumpBookmarkFile
        $script:JumpBookmarkFile  = Join-Path ([IO.Path]::GetTempPath()) ("jb-ut-" + [Guid]::NewGuid().ToString('N') + '.json')
        $script:savedJumpFolders  = $script:JumpFolders
        $script:JumpFolders = @(
            [pscustomobject]@{ Label = 'Home';      Path = $env:USERPROFILE }
            [pscustomobject]@{ Label = 'Downloads'; Path = (Join-Path $env:USERPROFILE 'Downloads') }
        )
        $script:bmdir = Join-Path ([IO.Path]::GetTempPath()) ("jb-dir-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bmdir | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:JumpBookmarkFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bmdir -Recurse -Force -ErrorAction SilentlyContinue
        $script:JumpBookmarkFile = $script:savedBookmarkFile
        $script:JumpFolders      = $script:savedJumpFolders
    }

    It 'adds the current directory, tagged as a user bookmark' {
        Push-Location $bmdir
        $expected = (Get-Location).Path        # Add uses Get-Location; compare like-for-like (8.3-safe)
        try { j -Add 6>$null } finally { Pop-Location }

        $leaf = Split-Path -Leaf $bmdir
        $hit  = @($script:JumpFolders | Where-Object { $_.Label -eq $leaf })
        $hit.Count     | Should -Be 1
        $hit[0].Source | Should -Be 'user'
        $hit[0].Path   | Should -Be $expected
    }

    It 'persists the bookmark so it reloads from disk on Sync' {
        j -Add $bmdir -Label vms 6>$null
        # Drop the in-memory user slice, then reload purely from the file.
        $script:JumpFolders = @($script:JumpFolders | Where-Object { $_.Source -ne 'user' })
        Sync-JumpBookmark
        (@($script:JumpFolders | Where-Object Label -EQ 'vms')).Path | Should -Be (Resolve-Path -LiteralPath $bmdir).Path
    }

    It 'uses a custom -Label when given' {
        j -Add $bmdir -Label myplace 6>$null
        @($script:JumpFolders).Label | Should -Contain 'myplace'
    }

    It 'rejects a path that is not a directory' {
        $file = Join-Path $bmdir 'a.txt'; Set-Content -LiteralPath $file -Value 'x'
        j -Add $file -Label nope 6>$null
        @(Get-JumpBookmark).Label | Should -Not -Contain 'nope'
    }

    It 'refuses to shadow a built-in label, and names the folder it clashes with' {
        Push-Location $bmdir
        try { $msg = (j -Add -Label Home 6>&1 | Out-String) } finally { Pop-Location }
        @(Get-JumpBookmark).Count | Should -Be 0                                     # nothing stored
        @($script:JumpFolders | Where-Object Label -EQ 'Home').Count | Should -Be 1  # built-in untouched
        $msg | Should -Match ([regex]::Escape($env:USERPROFILE))                     # message points at the existing target
    }

    It 're-adding a label repoints it (upsert, no duplicate)' {
        $other = Join-Path ([IO.Path]::GetTempPath()) ("jb-dir2-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $other | Out-Null
        try {
            j -Add $bmdir -Label spot 6>$null
            j -Add $other -Label spot 6>$null
            $hit = @(Get-JumpBookmark | Where-Object Label -EQ 'spot')
            $hit.Count   | Should -Be 1
            $hit[0].Path | Should -Be (Resolve-Path -LiteralPath $other).Path
        } finally { Remove-Item -LiteralPath $other -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'removes a bookmark by label' {
        j -Add $bmdir -Label gone 6>$null
        j -Remove gone 6>$null
        @(Get-JumpBookmark).Label                                    | Should -Not -Contain 'gone'
        @($script:JumpFolders | Where-Object Label -EQ 'gone').Count | Should -Be 0
    }

    It 'does not throw when removing an unknown label' {
        { j -Remove no-such-bookmark 6>$null } | Should -Not -Throw
    }

    It 'will not remove a built-in destination via -Remove' {
        j -Remove Home 6>$null
        @($script:JumpFolders | Where-Object Label -EQ 'Home').Count | Should -Be 1
    }

    It 'stores a single bookmark as a JSON array (stable on-disk shape)' {
        j -Add $bmdir -Label solo 6>$null
        $raw = Get-Content -Raw -LiteralPath $script:JumpBookmarkFile
        $raw.TrimStart()[0]              | Should -Be '['     # array, not a bare object
        @($raw | ConvertFrom-Json).Count | Should -Be 1
    }

    It 'refuses to overwrite an unreadable store on -Add (the no-clobber guard)' {
        # A corrupt (or locked) store must ABORT the add: reading it as an empty
        # list and saving would silently destroy every bookmark it still holds.
        Set-Content -LiteralPath $script:JumpBookmarkFile -Value '{ this is not json ]'
        j -Add $bmdir -Label newone 6>$null
        Get-Content -Raw -LiteralPath $script:JumpBookmarkFile | Should -Match 'this is not json'  # original bytes intact
    }

    It 'stores the provider path, not a PSDrive-qualified path' {
        # A bookmark taken inside a mapped PSDrive must survive into sessions
        # that don't have the drive.
        New-PSDrive -Name JBUT -PSProvider FileSystem -Root $bmdir | Out-Null
        try {
            Push-Location JBUT:\
            try { j -Add -Label psd 6>$null } finally { Pop-Location }
            $stored = (@(Get-JumpBookmark | Where-Object Label -EQ 'psd')).Path
            $stored.TrimEnd('\') | Should -Be ((Resolve-Path -LiteralPath $bmdir).Path.TrimEnd('\'))
        } finally { Remove-PSDrive JBUT -ErrorAction SilentlyContinue }
    }

    It 'rejects a non-filesystem container path (registry keys are containers too)' {
        j -Add HKCU:\Software -Label reg 6>$null
        @(Get-JumpBookmark).Label | Should -Not -Contain 'reg'
    }

    It 'labels a drive root without the trailing slash' {
        j -Add C:\ 6>$null
        @(Get-JumpBookmark).Label | Should -Contain 'C:'
    }

    It 'gives usage help instead of stalling when -Label is used without -Add' {
        { j -Label orphan 6>$null } | Should -Not -Throw     # was: mandatory-parameter prompt/binding error
        @(Get-JumpBookmark).Count | Should -Be 0
    }

    It 'appends user bookmarks after existing entries (never shadows in first-match)' {
        j -Add $bmdir -Label zzz-last 6>$null
        (@($script:JumpFolders).Label)[-1] | Should -Be 'zzz-last'
    }
}

Describe 'Format-SnippetPreview' {

    It 'takes the first non-blank line' {
        Format-SnippetPreview "  `n`nfirst real line`nsecond" | Should -Be 'first real line'
    }

    It 'collapses inner whitespace runs to single spaces' {
        Format-SnippetPreview "a`t`tb    c" | Should -Be 'a b c'
    }

    It 'returns empty for null/whitespace' {
        Format-SnippetPreview '' | Should -Be ''
        Format-SnippetPreview "   `n  " | Should -Be ''
    }
}

Describe 'Limit-ClipSnippet (trim policy)' {

    BeforeAll {
        # Build a snippet with a monotonic timestamp (higher index = newer), some
        # labeled. Defined in BeforeAll, not the Describe body, so it survives
        # Pester's discovery→run boundary and is visible to the It blocks.
        function New-Snip {
            param([int] $Index, [string] $Label)
            [pscustomobject]@{
                Label = $Label
                Text  = "text-$Index"
                Added = (Get-Date).AddMinutes($Index).ToString('o')
            }
        }
    }

    It 'keeps everything when under the cap, newest first' {
        $s = @(New-Snip 1; New-Snip 2; New-Snip 3)
        $r = @(Limit-ClipSnippet -Snippet $s -Max 100)
        $r.Count     | Should -Be 3
        $r[0].Text   | Should -Be 'text-3'   # newest first
        $r[-1].Text  | Should -Be 'text-1'
    }

    It 'drops the oldest UNLABELED entries past the cap' {
        $s = @(1..5 | ForEach-Object { New-Snip $_ })   # all unlabeled, 1 oldest .. 5 newest
        $r = @(Limit-ClipSnippet -Snippet $s -Max 3)
        $r.Count            | Should -Be 3
        @($r.Text)          | Should -Be @('text-5', 'text-4', 'text-3')   # kept newest 3
    }

    It 'never drops labeled favorites, even past the cap' {
        # Two labeled (old) + three unlabeled (newer); cap 3 must keep both labels.
        $s = @(
            (New-Snip 1 'keep-a'), (New-Snip 2 'keep-b'),
            (New-Snip 3), (New-Snip 4), (New-Snip 5)
        )
        $r = @(Limit-ClipSnippet -Snippet $s -Max 3)
        @($r | Where-Object Label).Label | Should -Be @('keep-b', 'keep-a')  # both survive (newest-first)
        $r.Count | Should -Be 3                                              # labels + newest 1 unlabeled
        @($r | Where-Object { -not $_.Label }).Text | Should -Be @('text-5')
    }
}

Describe 'cb snippet stash (-Add / -Remove / lookup)' {

    BeforeEach {
        # Isolate the store to a temp file so the dev's real snippets are untouched.
        $script:savedClipFile   = $script:ClipSnippetFile
        $script:ClipSnippetFile = Join-Path ([IO.Path]::GetTempPath()) ("cb-ut-" + [Guid]::NewGuid().ToString('N') + '.json')
    }
    AfterEach {
        Remove-Item -LiteralPath $script:ClipSnippetFile -Force -ErrorAction SilentlyContinue
        $script:ClipSnippetFile = $script:savedClipFile
    }

    It 'saves a labeled snippet' {
        Add-ClipSnippet -Text 'my signature' -Label sig 6>$null
        $hit = @(Get-ClipSnippet | Where-Object Label -EQ 'sig')
        $hit.Count   | Should -Be 1
        $hit[0].Text | Should -Be 'my signature'
    }

    It 're-using a label repoints it (upsert, no duplicate)' {
        Add-ClipSnippet -Text 'v1' -Label sig 6>$null
        Add-ClipSnippet -Text 'v2' -Label sig 6>$null
        $hit = @(Get-ClipSnippet | Where-Object Label -EQ 'sig')
        $hit.Count   | Should -Be 1
        $hit[0].Text | Should -Be 'v2'
    }

    It 'dedupes identical text instead of storing it twice' {
        Add-ClipSnippet -Text 'same words' 6>$null
        Add-ClipSnippet -Text 'same words' 6>$null
        @(Get-ClipSnippet | Where-Object Text -EQ 'same words').Count | Should -Be 1
    }

    It 'does not save empty/whitespace clipboard text' {
        Add-ClipSnippet -Text "   `n  " 6>$null
        @(Get-ClipSnippet).Count | Should -Be 0
    }

    It 'removes a snippet by label' {
        Add-ClipSnippet -Text 'x' -Label gone 6>$null
        Remove-ClipSnippet -Name gone 6>$null
        @(Get-ClipSnippet).Label | Should -Not -Contain 'gone'
    }

    It 'removes an UNLABELED snippet by content substring' {
        Add-ClipSnippet -Text 'the quick brown fox' 6>$null
        Remove-ClipSnippet -Name brown 6>$null
        @(Get-ClipSnippet).Count | Should -Be 0
    }

    It 'does not throw when removing an unknown snippet' {
        { Remove-ClipSnippet -Name nope 6>$null } | Should -Not -Throw
    }

    It 'stores a single snippet as a JSON array (stable on-disk shape)' {
        Add-ClipSnippet -Text 'solo' -Label one 6>$null
        $raw = Get-Content -Raw -LiteralPath $script:ClipSnippetFile
        $raw.TrimStart()[0]              | Should -Be '['
        @($raw | ConvertFrom-Json).Count | Should -Be 1
    }

    It 'refuses to overwrite an unreadable store on -Add (no-clobber guard)' {
        Set-Content -LiteralPath $script:ClipSnippetFile -Value '{ this is not json ]'
        Add-ClipSnippet -Text 'newone' -Label n 6>$null
        Get-Content -Raw -LiteralPath $script:ClipSnippetFile | Should -Match 'this is not json'
    }

    It 'tolerates a corrupt store on read (empty list, no throw)' {
        Set-Content -LiteralPath $script:ClipSnippetFile -Value 'not json at all'
        @(Get-ClipSnippet 3>$null).Count | Should -Be 0
    }

    It 'copies the first label/content match to the clipboard via cb <text>' {
        Add-ClipSnippet -Text 'you@example.com' -Label email 6>$null
        cb email 6>$null
        Get-Clipboard -Raw | Should -Be 'you@example.com'
    }

    It 'gives usage help instead of stalling when -Label is used without -Add' {
        { cb -Label orphan 6>$null } | Should -Not -Throw
        @(Get-ClipSnippet).Count | Should -Be 0
    }

    It 'keeps timestamps invariant-ISO across a read/save cycle under a comma-decimal culture' {
        # Regression: ConvertFrom-Json rehydrates our stored ISO stamp as a
        # [datetime]; a culture-formatted re-serialize (e.g. nb-NO "19.07.2026")
        # would then be unparseable and sort as MinValue. Run the whole cycle
        # under nb-NO to prove the stamp stays invariant ISO regardless.
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]'nb-NO'
            Add-ClipSnippet -Text 'first'  -Label a 6>$null    # write
            Add-ClipSnippet -Text 'second' -Label b 6>$null    # read-back + re-save
            $raw = Get-Content -Raw -LiteralPath $script:ClipSnippetFile
            # Every Added value is ISO 8601 (yyyy-MM-ddT...), never dd.MM.yyyy.
            @([regex]::Matches($raw, '"Added":\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) |
                ForEach-Object { $_ | Should -Match '^\d{4}-\d{2}-\d{2}T' }
            # And they still parse (not MinValue) so ordering/age survive.
            @(Get-ClipSnippet | ForEach-Object { Convert-SnippetDate $_.Added }) |
                ForEach-Object { $_ | Should -BeGreaterThan ([datetime]::MinValue) }
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig
        }
    }
}

Describe 'cb tab completion' {

    BeforeEach {
        $script:savedClipFile   = $script:ClipSnippetFile
        $script:ClipSnippetFile = Join-Path ([IO.Path]::GetTempPath()) ("cbtc-ut-" + [Guid]::NewGuid().ToString('N') + '.json')
        Add-ClipSnippet -Text 'my signature block' -Label sig 6>$null
        Add-ClipSnippet -Text '123 Example St'     -Label 'home addr' 6>$null
        Add-ClipSnippet -Text 'an unlabeled blob'  6>$null   # no label -> not completed
    }
    AfterEach {
        Remove-Item -LiteralPath $script:ClipSnippetFile -Force -ErrorAction SilentlyContinue
        $script:ClipSnippetFile = $script:savedClipFile
    }

    It 'offers only labeled snippets on an empty word' {
        $r = @(& $script:ClipLabelCompleter 'cb' 'Match' '' $null @{})
        $r.Count           | Should -Be 2
        $r.ListItemText    | Should -Contain 'sig'
        $r.ListItemText    | Should -Contain 'home addr'
    }

    It 'matches labels by substring' {
        (& $script:ClipLabelCompleter 'cb' 'Match' 'addr' $null @{}).ListItemText | Should -Be 'home addr'
    }

    It 'shows the snippet preview as the tooltip' {
        (& $script:ClipLabelCompleter 'cb' 'Match' 'sig' $null @{}).ToolTip | Should -Be 'my signature block'
    }

    It 'quotes labels containing spaces so they bind as one argument' {
        (& $script:ClipLabelCompleter 'cb' 'Name' 'home' $null @{}).CompletionText | Should -Be "'home addr'"
    }

    It 'does not throw on wildcard metacharacters in the word' {
        { & $script:ClipLabelCompleter 'cb' 'Match' '[' $null @{} } | Should -Not -Throw
    }
}

Describe 'Get-IntuneOverview dashboard render' {

    BeforeAll {
        $script:mock = [pscustomobject]@{
            Devices = @(
                [pscustomobject]@{ deviceName='PC-1'; operatingSystem='Windows'; complianceState='compliant';     lastSyncDateTime=(Get-Date).AddHours(-2) }
                [pscustomobject]@{ deviceName='PC-2'; operatingSystem='Windows'; complianceState='noncompliant';  lastSyncDateTime=(Get-Date).AddDays(-1) }
                [pscustomobject]@{ deviceName='PH-1'; operatingSystem='iOS';     complianceState='inGracePeriod'; lastSyncDateTime=(Get-Date).AddDays(-3) }
                [pscustomobject]@{ deviceName='PC-3'; operatingSystem='Windows'; complianceState='compliant';     lastSyncDateTime=(Get-Date).AddDays(-45) }
                [pscustomobject]@{ deviceName='MAC-1';operatingSystem='macOS';   complianceState='compliant';     lastSyncDateTime=$null }
            )
            Configs=3; CompliancePolicies=2; Catalog=$null; Apps=7; Tenant='contoso.com'; Generated=Get-Date
        }
        $script:html = ConvertTo-IntuneDashboardHtml -Data $script:mock
        $m = [regex]::Match($script:html,'(?s)<script id="cockpit-data"[^>]*>(.*?)</script>')
        $script:payload = $m.Groups[1].Value | ConvertFrom-Json
    }

    It 'maps compliance states to status buckets' {
        Get-ComplianceBucket 'compliant'     | Should -Be 'good'
        Get-ComplianceBucket 'inGracePeriod' | Should -Be 'warn'
        Get-ComplianceBucket 'noncompliant'  | Should -Be 'crit'
        Get-ComplianceBucket 'error'         | Should -Be 'crit'
        Get-ComplianceBucket 'somethingNew'  | Should -Be 'unknown'
    }

    It 'replaces the data placeholder' { $script:html | Should -Not -Match '__COCKPIT_DATA__' }

    It 'injects parseable JSON' { $script:payload | Should -Not -BeNullOrEmpty }

    It 'computes KPIs from the device set' {
        $script:payload.kpis.total         | Should -Be 5
        $script:payload.kpis.compliancePct | Should -Be 60   # 3 compliant of 5
        $script:payload.kpis.nonCompliant  | Should -Be 1
        $script:payload.kpis.stale         | Should -Be 2    # the 45-day + the never-synced
    }

    It 'aggregates compliance into ordered good/warn/crit buckets' {
        @($script:payload.compliance | ForEach-Object { $_.bucket }) | Should -Be @('good','warn','crit')
    }

    It 'passes an unavailable config count through as null' {
        ($script:payload.config | Where-Object label -EQ 'Settings Catalog').value | Should -BeNullOrEmpty
    }

    It 'neutralizes a script-tag breakout in a device name' {
        # Build the closing tag from char codes so no literal appears in the
        # test source (a literal one confuses Pester's block instrumentation).
        $lt = [char]0x3C; $gt = [char]0x3E
        $evil = 'X' + $lt + '/script' + $gt                     # X</script>
        $data2 = [pscustomobject]@{
            Devices=@([pscustomobject]@{ deviceName=$evil; operatingSystem='Windows'; complianceState='noncompliant'; lastSyncDateTime=(Get-Date) })
            Configs=$null;CompliancePolicies=$null;Catalog=$null;Apps=$null;Tenant='t';Generated=Get-Date }
        $h = ConvertTo-IntuneDashboardHtml -Data $data2
        # The raw breakout sequence must not survive; the escaped form must.
        $rawSurvived = $h.Contains($evil)
        $escSurvived = $h.Contains('X' + [char]0x5C + 'u003c')  # X< present
        $rawSurvived | Should -Be $false
        $escSurvived | Should -Be $true
    }

    It 'does not throw on an empty device set' {
        $empty = [pscustomobject]@{ Devices=@(); Configs=$null;CompliancePolicies=$null;Catalog=$null;Apps=$null;Tenant='t';Generated=Get-Date }
        { ConvertTo-IntuneDashboardHtml -Data $empty } | Should -Not -Throw
    }

    It 'injects the snapshot exactly once' {
        # The template mentions the placeholder token in its prose comment too;
        # a bare .Replace once duplicated the whole payload into that comment.
        # "compliancePct" (quoted) exists only in the JSON, never in the markup/JS.
        [regex]::Matches($script:html, [regex]::Escape('"compliancePct"')).Count | Should -Be 1
    }

    It 'does not mark a device stale before 30 full days' {
        # 29 days 18 h: a nearest-int rounding of TotalDays says 30, the floor
        # says 29 — the device is not yet stale, and console/dashboard agree.
        $d = [pscustomobject]@{
            Devices=@([pscustomobject]@{ deviceName='EDGE-1'; operatingSystem='Windows'; complianceState='compliant'; lastSyncDateTime=(Get-Date).AddDays(-29).AddHours(-18) })
            Configs=$null;CompliancePolicies=$null;Catalog=$null;Apps=$null;Tenant='t';Generated=Get-Date }
        $h = ConvertTo-IntuneDashboardHtml -Data $d
        $p = [regex]::Match($h,'(?s)<script id="cockpit-data"[^>]*>(.*?)</script>').Groups[1].Value | ConvertFrom-Json
        $p.kpis.stale | Should -Be 0
    }

    It 'renders a bare-null Devices property as zero devices, not one phantom' {
        $broken = [pscustomobject]@{ Devices=$null; Configs=$null;CompliancePolicies=$null;Catalog=$null;Apps=$null;Tenant='t';Generated=Get-Date }
        $h = ConvertTo-IntuneDashboardHtml -Data $broken
        $p = [regex]::Match($h,'(?s)<script id="cockpit-data"[^>]*>(.*?)</script>').Groups[1].Value | ConvertFrom-Json
        $p.kpis.total | Should -Be 0
    }

    It 'carries the stale threshold in the payload for the template labels' {
        $script:payload.meta.staleDays | Should -Be 30
    }
}

Describe 'j tab completion' {

    BeforeEach {
        $script:savedJumpFolders = $script:JumpFolders
        $script:JumpFolders = @(
            [pscustomobject]@{ Label = 'Home';         Path = $env:USERPROFILE }
            [pscustomobject]@{ Label = 'Downloads';    Path = (Join-Path $env:USERPROFILE 'Downloads') }
            [pscustomobject]@{ Label = 'LocalAppData'; Path = $env:LOCALAPPDATA }
            [pscustomobject]@{ Label = 'My Repo';      Path = 'C:\GitHub\repo'; Source = 'user' }
        )
    }
    AfterEach { $script:JumpFolders = $script:savedJumpFolders }

    It 'offers every label on an empty word' {
        @(& $script:JumpLabelCompleter 'j' 'Match' '' $null @{}).Count | Should -Be 4
    }

    It 'matches by substring, mirroring j''s own lookup' {
        $r = @(& $script:JumpLabelCompleter 'j' 'Match' 'lo' $null @{})   # down'lo'ads + 'lo'calappdata
        $r.ListItemText | Should -Contain 'Downloads'
        $r.ListItemText | Should -Contain 'LocalAppData'
        $r.ListItemText | Should -Not -Contain 'Home'
    }

    It 'shows the destination path as the tooltip' {
        (& $script:JumpLabelCompleter 'j' 'Match' 'Home' $null @{}).ToolTip | Should -Be $env:USERPROFILE
    }

    It 'completes only user bookmarks for -Remove (the Name parameter)' {
        $r = @(& $script:JumpLabelCompleter 'j' 'Name' '' $null @{})
        $r.Count            | Should -Be 1
        $r[0].ListItemText  | Should -Be 'My Repo'
    }

    It 'quotes labels containing spaces so they bind as one argument' {
        (& $script:JumpLabelCompleter 'j' 'Name' 'repo' $null @{}).CompletionText | Should -Be "'My Repo'"
    }

    It 'does not throw on wildcard metacharacters in the word' {
        { & $script:JumpLabelCompleter 'j' 'Match' '[' $null @{} } | Should -Not -Throw
    }

    It 'is wired into TabExpansion2 end-to-end' {
        $r = TabExpansion2 -inputScript 'j down' -cursorColumn 6
        @($r.CompletionMatches).ListItemText | Should -Contain 'Downloads'
    }
}

Describe 'Get-PickerPlainText (ANSI-aware width math)' {

    It 'strips SGR color sequences, keeping the visible text' {
        Get-PickerPlainText "`e[32mgreen`e[0m and `e[90mgray`e[0m" | Should -Be 'green and gray'
    }

    It 'strips multi-parameter sequences (the cursor-bar codes)' {
        Get-PickerPlainText "`e[30;46mhighlighted`e[0m" | Should -Be 'highlighted'
    }

    It 'returns plain strings unchanged' {
        Get-PickerPlainText 'no codes here' | Should -Be 'no codes here'
    }

    It 'handles empty and null input' {
        Get-PickerPlainText ''    | Should -Be ''
        Get-PickerPlainText $null | Should -Be ''
    }

    It 'visible length drives padding math (colored text is shorter than raw)' {
        $raw = "`e[33m(main)`e[0m"
        (Get-PickerPlainText $raw).Length | Should -Be 6
        $raw.Length                       | Should -BeGreaterThan 6
    }
}

Describe 'Get-PickerScrollTop (viewport scrolling math)' {

    It 'does not scroll when the cursor is already visible' {
        Get-PickerScrollTop -Cursor 2 -ScrollTop 0 -ViewRows 10 -Count 45 | Should -Be 0
    }

    It 'scrolls down so a cursor below the window becomes visible' {
        # cursor 15, window of 10 -> top must be 6 (rows 6..15)
        Get-PickerScrollTop -Cursor 15 -ScrollTop 0 -ViewRows 10 -Count 45 | Should -Be 6
    }

    It 'scrolls up so a cursor above the window becomes visible' {
        Get-PickerScrollTop -Cursor 3 -ScrollTop 6 -ViewRows 10 -Count 45 | Should -Be 3
    }

    It 'clamps the window to the end of the list (no blank rows past the end)' {
        # last item, window of 10, 45 items -> top = 35 (rows 35..44)
        Get-PickerScrollTop -Cursor 44 -ScrollTop 0 -ViewRows 10 -Count 45 | Should -Be 35
    }

    It 'stays at 0 when every item fits in the window' {
        Get-PickerScrollTop -Cursor 2 -ScrollTop 0 -ViewRows 10 -Count 5 | Should -Be 0
    }

    It 'never returns a negative offset' {
        Get-PickerScrollTop -Cursor 0 -ScrollTop 0 -ViewRows 10 -Count 45 | Should -Be 0
    }
}

Describe 'Picker hotkeys (1-9 then a-z)' {

    It 'maps indices 0-8 to digits 1-9' {
        Get-PickerHotkey 0 | Should -Be '1'
        Get-PickerHotkey 8 | Should -Be '9'
    }

    It 'maps indices 9-34 to letters a-z' {
        Get-PickerHotkey 9  | Should -Be 'a'
        Get-PickerHotkey 34 | Should -Be 'z'
    }

    It 'returns empty past the addressable range' {
        Get-PickerHotkey 35 | Should -BeNullOrEmpty
        Get-PickerHotkey -1 | Should -BeNullOrEmpty
    }

    It 'parses digit and letter keys back to indices (case-insensitive)' {
        Get-PickerHotkeyIndex '1' | Should -Be 0
        Get-PickerHotkeyIndex '9' | Should -Be 8
        Get-PickerHotkeyIndex 'a' | Should -Be 9
        Get-PickerHotkeyIndex 'z' | Should -Be 34
        Get-PickerHotkeyIndex 'A' | Should -Be 9
    }

    It 'returns -1 for non-hotkey characters' {
        Get-PickerHotkeyIndex '0' | Should -Be -1
        Get-PickerHotkeyIndex '!' | Should -Be -1
    }

    It 'round-trips index -> key -> index for every addressable slot' {
        foreach ($i in 0..34) {
            Get-PickerHotkeyIndex ([char](Get-PickerHotkey $i)) | Should -Be $i
        }
    }
}

Describe 'Find-GitProject' {

    BeforeAll {
        $script:projRoot = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("prj-ut-" + [Guid]::NewGuid().ToString('N')))).FullName
        # Two fake repos at different depths; each a .git dir with a HEAD on `main`.
        foreach ($r in 'alpha', 'org\beta') {
            $git = Join-Path (Join-Path $projRoot $r) '.git'
            New-Item -ItemType Directory -Path $git -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $git 'HEAD') -Value 'ref: refs/heads/main'
        }
        New-Item -ItemType Directory -Path (Join-Path $projRoot 'notarepo') -Force | Out-Null
        $script:Config.ProjectRoots = @($projRoot)
        $script:ProjectsCache = $null
    }
    AfterAll {
        $script:Config.ProjectRoots = @()
        $script:ProjectsCache = $null
        Remove-Item -LiteralPath $projRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'finds git repos at any depth under the root' {
        $found = @(Find-GitProject -Refresh)
        $found.Label | Should -Contain 'alpha'
        $found.Label | Should -Contain 'beta'
    }

    It 'reads the branch from .git/HEAD' {
        (@(Find-GitProject -Refresh) | Where-Object Label -EQ 'alpha').Branch | Should -Be 'main'
    }

    It 'ignores directories that are not repos' {
        (@(Find-GitProject -Refresh)).Label | Should -Not -Contain 'notarepo'
    }

    It 'caches the result until -Refresh' {
        $first = @(Find-GitProject -Refresh).Count
        # Add a repo, but a plain call should still return the cached list.
        $extra = Join-Path (Join-Path $projRoot 'gamma') '.git'
        New-Item -ItemType Directory -Path $extra -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $extra 'HEAD') -Value 'ref: refs/heads/main'
        @(Find-GitProject).Count        | Should -Be $first
        @(Find-GitProject -Refresh).Count | Should -Be ($first + 1)
    }
}

Describe 'Format-TaskResult (LastTaskResult decoding)' {
    It 'maps success to a clean word' {
        Format-TaskResult 0 | Should -Be 'Success'
    }
    It 'decodes the 0x4130x status family' {
        Format-TaskResult 267009 | Should -Be 'Currently running'   # 0x41301
        Format-TaskResult 267011 | Should -Be 'Has not yet run'     # 0x41303
    }
    It 'shows an unknown code as unsigned 32-bit hex (negative Int32 normalized)' {
        # 0x80070002 comes back from Get-ScheduledTaskInfo as the Int32 -2147024894.
        Format-TaskResult -2147024894 | Should -Be 'Exit code 0x80070002'
    }
}

Describe 'Test-ToolkitTaskVisible (default scope excludes \Microsoft)' {
    It 'shows root-level and custom-folder tasks' {
        Test-ToolkitTaskVisible -TaskPath '\'         | Should -BeTrue
        Test-ToolkitTaskVisible -TaskPath '\MyJobs\'  | Should -BeTrue
    }
    It "hides Windows' own \Microsoft\* tasks by default" {
        Test-ToolkitTaskVisible -TaskPath '\Microsoft\Windows\Defrag\' | Should -BeFalse
    }
    It '-IncludeAll shows everything, including \Microsoft\*' {
        Test-ToolkitTaskVisible -TaskPath '\Microsoft\Windows\Defrag\' -IncludeAll | Should -BeTrue
    }
}
