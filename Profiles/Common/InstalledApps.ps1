# Installed-application inventory and removal: `apps` and `uninst`.
# ============================================================================
# Control Panel's "Programs and Features" has no database of its own — it is a
# VIEW over three registry keys (64-bit, 32-bit, per-user "Uninstall" hives).
# Reproducing its list is therefore a registry read plus the visibility rules
# the shell applies, which is what Get-InstalledApp does. On a normal machine
# the raw keys are roughly twice the size of what the UI shows (327 -> 148 on
# the author's box): patches, driver sub-entries and system components make up
# the difference, and skipping the filter is why most "list installed apps"
# snippets on the internet return obvious junk.
#
# Deliberately NOT used here:
#   * Win32_Product (CIM) — enumerating it triggers an MSI consistency check
#     (self-repair) on every installed product. It is slow, it writes MsiInstaller
#     events, and it only ever sees MSI installs. Never enumerate it.
#   * Get-Package -ProviderName Programs — the PackageManagement providers are
#     Windows PowerShell-only; under PS7 this returns 0 items after ~35 seconds.
#   * Get-AppxPackage — MSIX/Store apps are a separate world. They appear in
#     Settings > Apps but NEVER in Programs and Features, so they are out of
#     scope for a command whose contract is "what appwiz.cpl shows".
#
# Removal is the messier half. An app's UninstallString is a raw command line
# with famously inconsistent quoting, so it needs real parsing (see
# Split-UninstallCommand) rather than a naive split on the first space —
# `C:\Program Files\WinRAR\uninstall.exe` is a real, unquoted, argument-less
# uninstall string that a first-space split turns into `C:\Program`.

# The three hives Programs and Features reads. WOW6432Node is absent on 32-bit
# Windows and HKCU's key is absent on a fresh profile — callers use
# -ErrorAction Ignore so neither case leaves anything in $Error.
$script:ArpRegistryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# ReleaseType values that mark an entry as an update rather than a product.
# These are the ones the shell hides; anything else (including an absent value)
# is a normal application.
$script:ArpUpdateReleaseTypes = @('Security Update', 'Update Rollup', 'Hotfix', 'ServicePack')

function Test-ArpEntryVisible {
    <#
    .SYNOPSIS
        True if an Uninstall registry entry is one Programs and Features shows.
    .DESCRIPTION
        The visibility rules appwiz.cpl applies, in one pure predicate so they
        can be unit-tested without touching the registry:

          * DisplayName must be present    — nameless keys are install metadata.
          * SystemComponent must not be 1  — the explicit "hide me" flag.
          * No ParentKeyName/ParentDisplayName — this is how patches and
            language packs nest under their parent product instead of listing
            separately.
          * ReleaseType must not be an update type (see $script:ArpUpdateReleaseTypes).
          * Some way to uninstall must exist — an entry with neither an
            UninstallString nor a QuietUninstallString is a leftover record.

        -IncludeHidden relaxes everything except the DisplayName requirement,
        which is what Get-InstalledApp -All passes.
    .PARAMETER Entry
        One object as returned by Get-ItemProperty over an Uninstall key.
    .PARAMETER IncludeHidden
        Keep system components, child entries and updates.
    #>
    [OutputType([bool])]
    param(
        $Entry,
        [switch] $IncludeHidden
    )

    if (-not $Entry -or -not $Entry.DisplayName) { return $false }
    if ($IncludeHidden) { return $true }

    if ($Entry.SystemComponent -eq 1)      { return $false }
    if ($Entry.ParentKeyName)              { return $false }
    if ($Entry.ParentDisplayName)          { return $false }
    if ($Entry.ReleaseType -in $script:ArpUpdateReleaseTypes) { return $false }
    if (-not $Entry.UninstallString -and -not $Entry.QuietUninstallString) { return $false }

    return $true
}

function Split-UninstallCommand {
    <#
    .SYNOPSIS
        Split a raw uninstall command line into an executable and its arguments.
    .DESCRIPTION
        Registry uninstall strings come in three shapes, and the unquoted one is
        genuinely ambiguous:

          "C:\Program Files\ShareX\unins000.exe" /SILENT   quoted   — easy
          MsiExec.exe /X{GUID}                             PATH exe — easy
          C:\Program Files\WinRAR\uninstall.exe            unquoted with spaces
                                                           and NO arguments

        The last one defeats a split on the first space (`C:\Program`), and
        there is no syntax that distinguishes it from an executable followed by
        an argument. The only reliable disambiguator is the filesystem, so:

          1. Leading quote  -> take up to the closing quote.
          2. Rooted path    -> walk the token boundaries left to right and keep
                               the LONGEST prefix that names a file that exists
                               (with or without an implicit .exe).
          3. Otherwise      -> first token is the executable; it is a bare name
                               resolved from PATH (rundll32.exe, msiexec, winget).

        Step 2 is restricted to rooted candidates on purpose: testing a relative
        prefix would resolve against the current directory and could match an
        unrelated file that happens to share the name.

        Returns a PSCustomObject with FilePath and Arguments (Arguments is ''
        when there are none), or $null for empty input.
    .PARAMETER CommandLine
        The raw UninstallString / QuietUninstallString value.
    .EXAMPLE
        Split-UninstallCommand 'MsiExec.exe /X{0DDC55F3-E24B-40CC-A90D-B1E89C5DB035}'

        FilePath 'MsiExec.exe', Arguments '/X{0DDC55F3-E24B-40CC-A90D-B1E89C5DB035}'.
    .EXAMPLE
        Split-UninstallCommand '"C:\Program Files\Git\unins000.exe" /SILENT'

        FilePath 'C:\Program Files\Git\unins000.exe', Arguments '/SILENT'.
    #>
    [OutputType([pscustomobject])]
    param([string] $CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $line = $CommandLine.Trim()

    # 1. Quoted executable — the author already told us where it ends.
    if ($line.StartsWith('"')) {
        $close = $line.IndexOf('"', 1)
        if ($close -gt 1) {
            return [pscustomobject]@{
                FilePath  = $line.Substring(1, $close - 1)
                Arguments = $line.Substring($close + 1).Trim()
            }
        }
        # Unbalanced quote: strip it and fall through to the heuristics.
        $line = $line.TrimStart('"').Trim()
    }

    # 2. Unquoted but rooted — let the filesystem resolve the ambiguity.
    if ([IO.Path]::IsPathRooted($line)) {
        $tokens = $line.Split(' ')
        $best   = $null
        $bestAt = -1
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            $candidate = ($tokens[0..$i] -join ' ')
            foreach ($probe in @($candidate, "$candidate.exe")) {
                if (Test-Path -LiteralPath $probe -PathType Leaf -ErrorAction Ignore) {
                    $best   = $probe
                    $bestAt = $i
                }
            }
        }
        if ($best) {
            # The executable can be the LAST token (the argument-less
            # `C:\Program Files\WinRAR\uninstall.exe` case). Slicing
            # $tokens[$n..($n-1)] there would count DOWNWARD and hand back a
            # token that is part of the path as though it were an argument, so
            # the empty tail is handled explicitly rather than by a range.
            $rest = if ($bestAt -lt $tokens.Count - 1) {
                ($tokens[($bestAt + 1)..($tokens.Count - 1)] -join ' ').Trim()
            } else { '' }
            return [pscustomobject]@{ FilePath = $best; Arguments = $rest }
        }
    }

    # 3. Bare command name (PATH-resolved) or a rooted path that no longer
    #    exists — the first token is the best available answer either way.
    $split = $line -split '\s+', 2
    return [pscustomobject]@{
        FilePath  = $split[0]
        Arguments = if ($split.Count -gt 1) { $split[1].Trim() } else { '' }
    }
}

function Resolve-UninstallCommand {
    <#
    .SYNOPSIS
        Work out the exact command that removes one installed app.
    .DESCRIPTION
        Turns an app object from Get-InstalledApp into the executable and
        arguments to run, honouring the caller's choice of a silent or an
        interactive removal.

        Interactive: use UninstallString as published.

        Silent, in preference order:
          1. QuietUninstallString — the publisher's own unattended command.
          2. An MSI product code — Windows Installer's silent syntax is
             universal, so `/x {code} /qn /norestart` can be synthesised even
             when the publisher never advertised one.
          3. Nothing. A silent flag is NOT guessed: /S, /SILENT, /VERYSILENT
             and --uninstall-silent all belong to different installer toolkits,
             and handing an installer a switch it does not understand can make
             it fall back to interactive, or worse, treat it as a different
             instruction entirely. The caller is told instead.

        MSI entries also get /I rewritten to /X. A published `MsiExec.exe /I{code}`
        opens the maintenance (repair/modify) dialog rather than uninstalling —
        one of the more surprising ways a scripted removal turns into a GUI.

        Returns FilePath, Arguments, Silent and Reason (why a silent removal was
        not possible, when Silent is requested and unavailable).
    .PARAMETER App
        An object from Get-InstalledApp.
    .PARAMETER Silent
        Resolve an unattended command instead of the interactive one.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $App,
        [switch] $Silent
    )

    if (-not $Silent) {
        $parsed = Split-UninstallCommand $App.UninstallString
        if (-not $parsed) {
            return [pscustomobject]@{ FilePath = $null; Arguments = $null; Silent = $false
                                      Reason   = 'No UninstallString is registered for this app.' }
        }
        # /I opens the MSI maintenance dialog; /X is the uninstall we were asked for.
        if ($App.ProductCode -and $parsed.FilePath -match 'msiexec') {
            return [pscustomobject]@{
                FilePath = $parsed.FilePath
                Arguments = "/x $($App.ProductCode)"
                Silent = $false; Reason = $null
            }
        }
        return [pscustomobject]@{ FilePath = $parsed.FilePath; Arguments = $parsed.Arguments
                                  Silent   = $false; Reason = $null }
    }

    if ($App.QuietUninstallString) {
        $parsed = Split-UninstallCommand $App.QuietUninstallString
        if ($parsed) {
            return [pscustomobject]@{ FilePath = $parsed.FilePath; Arguments = $parsed.Arguments
                                      Silent   = $true; Reason = $null }
        }
    }

    if ($App.ProductCode) {
        return [pscustomobject]@{
            FilePath  = 'msiexec.exe'
            Arguments = "/x $($App.ProductCode) /qn /norestart"
            Silent    = $true; Reason = $null
        }
    }

    return [pscustomobject]@{
        FilePath = $null; Arguments = $null; Silent = $false
        Reason   = "'$($App.Name)' publishes no quiet uninstall command and is not an MSI, so it cannot be removed unattended. Run without -Silent to use its own uninstaller."
    }
}

function Get-InstalledApp {
    <#
    .SYNOPSIS
        List installed applications exactly as Programs and Features shows them (alias: apps).
    .DESCRIPTION
        Reads the 64-bit, 32-bit and per-user Uninstall registry hives and applies
        the same visibility rules as Control Panel, so the result matches what
        appwiz.cpl lists — no patches, no driver sub-entries, no system components.

        This is a pure registry read: it is fast, it needs no elevation, and it
        does not disturb Windows Installer (unlike Win32_Product, which triggers
        an MSI self-repair on every product just to enumerate).

        MSIX/Store apps are intentionally absent — Windows keeps them out of
        Programs and Features too. Use Get-AppxPackage for those.

        Each app carries a Silent flag: whether it can be removed unattended,
        either because the publisher registered a quiet command or because it is
        an MSI (whose silent syntax is universal). Roughly a third of a typical
        machine's apps cannot.
    .PARAMETER Name
        Match on display name. A plain string matches as a substring; anything
        containing * or ? is treated as a wildcard pattern.
    .PARAMETER Publisher
        Match on publisher, with the same substring/wildcard handling as -Name.
    .PARAMETER SilentOnly
        Only apps that can be uninstalled unattended.
    .PARAMETER All
        Include the entries Programs and Features hides: system components,
        updates, and child entries nested under a parent product.
    .EXAMPLE
        apps

        Every application Programs and Features would list, newest install first
        is not implied — pipe to Sort-Object for a specific order.
    .EXAMPLE
        apps firefox

        The apps whose name contains "firefox".
    .EXAMPLE
        apps -Publisher Mozilla | Format-Table Name, Version, Scope

        Everything published by Mozilla, as a table.
    .EXAMPLE
        apps | Where-Object { -not $_.Silent } | Select-Object Name

        The apps that will insist on showing their own uninstaller UI — the ones
        you cannot script away.
    .EXAMPLE
        apps | Sort-Object SizeMB -Descending | Select-Object -First 10 Name, SizeMB

        The ten biggest installs, by the size the publisher reported.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)] [string] $Name,
        [string] $Publisher,
        [switch] $SilentOnly,
        [switch] $All
    )

    # A bare string is meant as a substring; an explicit pattern is honoured as
    # one. Escaping the plain case keeps a stray '[' from throwing (ARCHITECTURE
    # convention 10's lookup helpers do the same).
    $toPattern = {
        param([string] $Text)
        if ($Text -match '[\*\?]') { $Text } else { "*$([WildcardPattern]::Escape($Text))*" }
    }

    $entries = Get-ItemProperty -Path $script:ArpRegistryPaths -ErrorAction Ignore

    foreach ($e in $entries) {
        if (-not (Test-ArpEntryVisible -Entry $e -IncludeHidden:$All)) { continue }
        if ($Name      -and $e.DisplayName -notlike (& $toPattern $Name))      { continue }
        if ($Publisher -and $e.Publisher   -notlike (& $toPattern $Publisher)) { continue }

        # The key name IS the MSI product code for Windows Installer packages —
        # more reliable than regexing a GUID back out of the uninstall string.
        $productCode = if ($e.PSChildName -match '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$') { $e.PSChildName } else { $null }
        $silent      = [bool]($e.QuietUninstallString -or $productCode)
        if ($SilentOnly -and -not $silent) { continue }

        $app = [pscustomobject]@{
            Name                 = $e.DisplayName
            Version              = $e.DisplayVersion
            Publisher            = $e.Publisher
            Scope                = if ($e.PSPath -match 'HKEY_CURRENT_USER') { 'User' } else { 'Machine' }
            Silent               = $silent
            SizeMB               = if ($e.EstimatedSize) { [math]::Round($e.EstimatedSize / 1KB, 1) } else { $null }
            InstallDate          = if ($e.InstallDate -match '^\d{8}$') { [datetime]::ParseExact($e.InstallDate, 'yyyyMMdd', $null) } else { $null }
            ProductCode          = $productCode
            InstallLocation      = $e.InstallLocation
            UninstallString      = $e.UninstallString
            QuietUninstallString = $e.QuietUninstallString
            RegistryKey          = $e.PSChildName
        }

        # Without this the console renders 12 properties as a per-object List,
        # which is unreadable across ~150 apps. A default display set keeps the
        # object rich for scripting while `apps` alone stays a legible table.
        $app | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value ([System.Management.Automation.PSMemberInfo[]]@(
            [System.Management.Automation.PSPropertySet]::new(
                'DefaultDisplayPropertySet', [string[]]@('Name', 'Version', 'Publisher', 'Scope', 'Silent'))
        ))
        $app
    }
}
Set-Alias apps Get-InstalledApp

function Uninstall-App {
    <#
    .SYNOPSIS
        Uninstall an application from the terminal, with a picker (alias: uninst).
    .DESCRIPTION
        Runs an installed app's own uninstaller. With no name it opens the shared
        scrollable picker over everything Programs and Features lists; with a name
        it matches on substring, falling back to a picker over the candidates when
        more than one app matches.

        -Silent runs the unattended command where one exists (the publisher's
        QuietUninstallString, or MSI's /qn), and tells you when one does not
        rather than guessing a silent switch that the installer may not
        understand. Without -Silent the app's normal uninstaller runs, which for
        most non-MSI apps means a GUI.

        Removing an app is irreversible, so this confirms before acting; -WhatIf
        prints the exact command line it would run without running anything, and
        -Confirm:$false suppresses the prompt for scripted use.

        Machine-scope apps need elevation. The uninstaller itself raises the UAC
        prompt (its manifest asks for it), so this does not pre-empt that.
    .PARAMETER Name
        Substring (or wildcard pattern) matched against the app's display name.
        Omit it to pick from the full list.
    .PARAMETER App
        An app object from Get-InstalledApp — lets you filter with the full power
        of the pipeline and remove the result.
    .PARAMETER Silent
        Use the unattended uninstall command. Fails with an explanation for apps
        that publish no quiet command and are not MSI packages.
    .EXAMPLE
        uninst

        Pick from every installed app, then confirm the removal.
    .EXAMPLE
        uninst 'cpu-z'

        Uninstall CPU-Z, prompting for confirmation first.
    .EXAMPLE
        uninst 'cpu-z' -Silent -Confirm:$false

        Remove it unattended and without a prompt — the scripted form.
    .EXAMPLE
        uninst notepad -WhatIf

        Show the exact command that would run, and run nothing.
    .EXAMPLE
        apps -Publisher 'Oracle' | Uninstall-App -Silent

        Pipe a filtered set in; each is confirmed in turn.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'ByName')] [string] $Name,
        [Parameter(ValueFromPipeline, Mandatory, ParameterSetName = 'ByObject')] $App,
        [switch] $Silent
    )

    process {
        $target = $App

        if (-not $target) {
            $candidates = @(Get-InstalledApp -Name $Name)

            if ($candidates.Count -eq 0) {
                if ($Name) { Write-Host "  No installed app matching '$Name'." -ForegroundColor Yellow }
                else       { Write-Host '  No installed applications found.' -ForegroundColor Yellow }
                return
            }

            if ($candidates.Count -eq 1 -and $Name) {
                $target = $candidates[0]
            } else {
                # Shared picker (ARCHITECTURE convention 6) — never a hand-rolled
                # menu loop. Name column padded to a common width, captured by
                # GetNewClosure so the render block keeps it.
                # Both columns are sized from the candidates actually on screen and
                # capped, so one long value can't shove every publisher out of
                # alignment. A fixed version pad did exactly that: four-segment
                # builds like OneDrive's 26.139.0720.0007 overflow 14 characters,
                # and only that row's publisher shifted right.
                $nameWidth    = [Math]::Min(48, ($candidates | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
                $versionWidth = [Math]::Min(16, ($candidates | ForEach-Object { ([string]$_.Version).Length } | Measure-Object -Maximum).Maximum)
                $render = {
                    param($a)
                    $label = if ($a.Name.Length -gt $nameWidth) { $a.Name.Substring(0, $nameWidth) } else { $a.Name.PadRight($nameWidth) }
                    # [string] rather than ?? '': DisplayVersion is occasionally a
                    # REG_DWORD, and an [int] has no PadRight to call.
                    $version = [string]$a.Version
                    $version = if ($version.Length -gt $versionWidth) { $version.Substring(0, $versionWidth) } else { $version.PadRight($versionWidth) }
                    # Version dark gray, publisher dimmer still; a red dot marks
                    # the apps that will force their own UI on you.
                    $mark = if ($a.Silent) { "`e[32m*`e[0m" } else { "`e[31m!`e[0m" }
                    "{0} {1}  `e[90m{2}`e[0m  `e[90m{3}`e[0m" -f $mark, $label, $version, $a.Publisher
                }.GetNewClosure()

                $title = if ($Name) { "Uninstall — $($candidates.Count) apps matching '$Name'" }
                         else       { "Uninstall — $($candidates.Count) installed apps" }
                $target = Show-Picker -Items $candidates -RenderRow $render -Title $title `
                    -Hint 'Up/Down + Enter  PgUp/PgDn  Esc cancel  |  * = silent capable, ! = opens its own UI'
                if (-not $target) { return }
            }
        }

        $cmd = Resolve-UninstallCommand -App $target -Silent:$Silent
        if (-not $cmd.FilePath) {
            Write-Error $cmd.Reason
            return
        }

        $display = if ($cmd.Arguments) { "$($cmd.FilePath) $($cmd.Arguments)" } else { $cmd.FilePath }
        # Plenty of ARP display names already carry the version ("CPUID CPU-Z 2.20"),
        # so only append it when it isn't there already — otherwise every prompt
        # reads "CPU-Z 2.20 2.20".
        $label = if ($target.Version -and $target.Name -notlike "*$($target.Version)*") {
            "$($target.Name) $($target.Version)"
        } else { $target.Name }

        if (-not $PSCmdlet.ShouldProcess($label, "Uninstall (runs: $display)")) { return }

        if (-not $cmd.Silent -and -not $Silent) {
            Write-Host "  Starting the uninstaller for $label — it may open its own window." -ForegroundColor DarkGray
        }

        try {
            $proc = if ($cmd.Arguments) {
                Start-Process -FilePath $cmd.FilePath -ArgumentList $cmd.Arguments -Wait -PassThru -ErrorAction Stop
            } else {
                Start-Process -FilePath $cmd.FilePath -Wait -PassThru -ErrorAction Stop
            }
        } catch {
            Write-Error "Failed to launch the uninstaller for '$($target.Name)': $($_.Exception.Message)"
            return
        }

        # Windows Installer's documented result codes; bespoke uninstallers vary,
        # but 0 is universal and 3010 is worth surfacing rather than swallowing.
        switch ($proc.ExitCode) {
            0     { Write-Host "  Uninstalled $label." -ForegroundColor Green }
            3010  { Write-Host "  Uninstalled $label — a reboot is required to finish." -ForegroundColor Yellow }
            1602  { Write-Host "  Cancelled — $label was not removed." -ForegroundColor Yellow }
            1605  { Write-Host "  $label was already gone (the registry entry was stale)." -ForegroundColor Yellow }
            default {
                Write-Host "  The uninstaller for $label exited with code $($proc.ExitCode)." -ForegroundColor Yellow
                Write-Host '  Some uninstallers hand off to a background process and report this even on success — re-run `apps` to check.' -ForegroundColor DarkGray
            }
        }
    }
}
Set-Alias uninst Uninstall-App
