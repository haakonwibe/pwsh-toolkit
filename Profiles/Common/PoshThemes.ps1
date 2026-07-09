# Oh My Posh theme management: download the gallery, switch themes, random startup.
# ============================================================================
# `Update-PoshThemes`  - download the full official theme gallery into a local
#                        cache (~120 themes). Run once (and after upgrades).
# `Set-PoshTheme`      - interactive picker over all themes (+ a Random entry);
#                        previews live on select and prints the config snippet.
# `Set-PoshTheme name` - apply a theme directly by name.
# `Get-PoshTheme`      - report the active theme (handy in Random mode).
#
# Themes live in a regenerable local cache, NOT the repo — the gallery is ~120
# JSON files and reproducible via Update-PoshThemes, so committing it would just
# bloat history. The bundled Profiles/OhMyPosh/default.omp.json is the always-
# present fallback. Set OhMyPoshTheme = 'Random' in config.psd1 to roll a
# different theme each shell (the loader announces which one so you can pin it).

# Mirror of the path the loader uses in pwsh-toolkit-profile.ps1's OhMyPosh
# branch (the loader runs before Common/ is dot-sourced, so it can't call into
# here — keep the two in sync).
$script:PoshThemeCache = Join-Path $env:LOCALAPPDATA 'pwsh-toolkit\PoshThemes'

function Get-PoshThemePool {
    <#
    .SYNOPSIS
        The available Oh My Posh themes: the downloaded gallery plus bundled themes.
    .DESCRIPTION
        Returns the .omp.json files from the local gallery cache and the repo's
        Profiles/OhMyPosh/ folder, de-duplicated by file name (cache wins). Empty
        until Update-PoshThemes has run (apart from the bundled default).
    #>
    [OutputType([System.IO.FileInfo])]
    param()
    $dirs = @($script:PoshThemeCache, (Join-Path $script:ProfileRoot 'OhMyPosh'))
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $dirs) {
        Get-ChildItem -Path (Join-Path $d '*.omp.json') -ErrorAction Ignore | ForEach-Object {
            if ($seen.Add($_.Name)) { $_ }
        }
    }
}

function Test-NerdFontInstalled {
    <#
    .SYNOPSIS
        True if a Nerd Font (or Powerline-patched font) appears to be installed.
    .DESCRIPTION
        Oh My Posh themes draw their glyphs — powerline separators, git/branch/
        folder icons, OS logos — from a Nerd Font. Without one, glyph-heavy themes
        render as "tofu" (□ boxes). Scans the machine + user font registries for a
        font whose registered name marks it as Nerd Font / Powerline-patched. This
        only confirms a Nerd Font is *installed*, not that your terminal is set to
        use it — that's a separate per-terminal setting.
    #>
    [OutputType([bool])]
    param()
    $pattern = 'Nerd Font|Powerline|\bNF\b|\bNFM\b'
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
                     'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
        $props = Get-ItemProperty -Path $key -ErrorAction Ignore
        if ($props) {
            foreach ($name in $props.PSObject.Properties.Name) {
                if ($name -match $pattern) { return $true }
            }
        }
    }
    return $false
}

function Update-PoshThemes {
    <#
    .SYNOPSIS
        Download the full Oh My Posh theme gallery into the local cache.
    .DESCRIPTION
        Fetches the official themes.zip from the latest oh-my-posh GitHub release
        (~120 themes, a small download) and extracts it to the local cache at
        %LOCALAPPDATA%\pwsh-toolkit\PoshThemes. Re-run after upgrading oh-my-posh
        to pick up new themes.
    .EXAMPLE
        Update-PoshThemes

        Downloads and extracts the gallery, then tells you how many themes are
        installed and how to use them (Set-PoshTheme, or OhMyPoshTheme = 'Random').
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Downloads the whole theme gallery (many themes); the plural reads naturally.')]
    [CmdletBinding()]
    param()

    $url = 'https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/themes.zip'
    $tmp = Join-Path $env:TEMP ('posh-themes-' + [Guid]::NewGuid().ToString('N') + '.zip')
    try {
        Write-Host '  Downloading the Oh My Posh theme gallery...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec 60 -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $script:PoshThemeCache)) {
            New-Item -ItemType Directory -Path $script:PoshThemeCache -Force | Out-Null
        }
        Expand-Archive -LiteralPath $tmp -DestinationPath $script:PoshThemeCache -Force
        $count = @(Get-ChildItem -Path (Join-Path $script:PoshThemeCache '*.omp.json') -ErrorAction Ignore).Count
        Write-Host "  Installed $count themes to $script:PoshThemeCache" -ForegroundColor Green
        Write-Host '  Pick one with  Set-PoshTheme , or set  OhMyPoshTheme = ''Random''  in config.psd1' -ForegroundColor DarkGray
        Write-Host '  for a different theme each shell.' -ForegroundColor DarkGray

        # The themes are only half the story — they need a Nerd Font to render
        # their glyphs. Warn now (at setup time) rather than leave you staring at
        # boxes after switching themes.
        if (-not (Test-NerdFontInstalled)) {
            Write-Host ''
            Write-Host '  Heads-up: no Nerd Font detected. Most themes use icon glyphs that need one,' -ForegroundColor Yellow
            Write-Host '  or they''ll show as boxes. Install one and set it as your terminal font:' -ForegroundColor Yellow
            Write-Host '      oh-my-posh font install Meslo' -ForegroundColor White
            Write-Host '  then: Windows Terminal → Settings → your profile → Appearance → Font face.' -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Error "Failed to download themes: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-PoshTheme {
    <#
    .SYNOPSIS
        Report the Oh My Posh theme currently active in this shell.
    .DESCRIPTION
        Especially useful in Random mode — tells you which theme this shell rolled
        so you can pin it with Set-PoshTheme if you like it.
    .EXAMPLE
        Get-PoshTheme

        Prints the active theme name (and, in Random mode, how to pin it).
    #>
    param()
    if ($script:Config.Prompt -ne 'OhMyPosh') {
        Write-Host "  Prompt is '$($script:Config.Prompt)', not OhMyPosh." -ForegroundColor DarkGray
        return
    }
    $active = $script:Config.OhMyPoshThemeActive
    if (-not $active) { $active = '(unknown)' }
    if ($script:Config.OhMyPoshTheme -eq 'Random') {
        Write-Host "  Random mode — this shell is showing: $active" -ForegroundColor Cyan
        Write-Host "  Pin it with:  Set-PoshTheme $active" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Theme: $active" -ForegroundColor Cyan
    }
}

function Set-PoshTheme {
    <#
    .SYNOPSIS
        Pick or set an Oh My Posh theme — interactive picker or by name.
    .DESCRIPTION
        With no argument, opens a picker over every available theme plus a Random
        entry; the chosen theme is applied live (this shell re-skins immediately)
        and the config.psd1 snippet to persist it is printed. With a name, applies
        that theme directly. 'Random' sets random-each-shell mode. Run
        Update-PoshThemes first to populate the gallery.
    .PARAMETER Name
        A theme name (e.g. 'atomic') or 'Random'. Omit to open the picker.
    .EXAMPLE
        Set-PoshTheme

        Opens the picker; select a theme to preview it live and get the snippet to
        make it your default.
    .EXAMPLE
        Set-PoshTheme atomic

        Applies the 'atomic' theme to this shell directly.
    .EXAMPLE
        Set-PoshTheme Random

        Switches to random-each-shell mode (and rolls one now).
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string] $Name)

    if ($script:Config.Prompt -ne 'OhMyPosh') {
        Write-Host "  Prompt isn't OhMyPosh (it's '$($script:Config.Prompt)'). Set Prompt = 'OhMyPosh' in config.psd1 first." -ForegroundColor Yellow
        return
    }
    if (-not (Get-Command oh-my-posh -ErrorAction Ignore)) {
        Write-Host '  oh-my-posh isn''t installed:  winget install JanDeDobbeleer.OhMyPosh' -ForegroundColor Yellow
        return
    }

    $pool = @(Get-PoshThemePool)
    if ($pool.Count -eq 0) {
        Write-Host '  No themes found. Run  Update-PoshThemes  to download the gallery.' -ForegroundColor Yellow
        return
    }

    # Resolve the selection to either the string 'Random' or a theme FileInfo.
    $chosen = $null
    if ($Name) {
        if ($Name -eq 'Random') {
            $chosen = 'Random'
        }
        else {
            $chosen = $pool | Where-Object { ($_.BaseName -replace '\.omp$', '') -eq $Name -or $_.Name -eq $Name } | Select-Object -First 1
            if (-not $chosen) { Write-Host "  No theme named '$Name'. Try Set-PoshTheme (no args) to browse." -ForegroundColor Yellow; return }
        }
    }
    else {
        # Picker: a Random pseudo-entry first, then every theme by name.
        $items  = @([pscustomobject]@{ Name = 'Random'; File = $null }) +
                  ($pool | ForEach-Object { [pscustomobject]@{ Name = ($_.BaseName -replace '\.omp$', ''); File = $_ } })
        # The Random pseudo-entry in cyan so it reads as an action, not a theme.
        $render = { param($t) if ($t.File) { $t.Name } else { "`e[36m$($t.Name)`e[0m" } }
        $sel = Show-Picker -Items $items -RenderRow $render -Title 'Oh My Posh themes' `
            -Hint 'Up/Down + Enter  PgUp/PgDn  Esc cancel  |  applies on select'
        if (-not $sel) { return }
        $chosen = if ($sel.Name -eq 'Random') { 'Random' } else { $sel.File }
    }

    # Apply live and figure out the value to persist.
    if ($chosen -eq 'Random') {
        $pick = $pool | Get-Random
        oh-my-posh init pwsh --config $pick.FullName | Invoke-Expression
        $active = ($pick.BaseName -replace '\.omp$', '')
        $script:Config.OhMyPoshThemeActive = $active
        $script:Config.OhMyPoshTheme = 'Random'

        Write-Host "  Random mode on — this shell rolled '$active'." -ForegroundColor Green
        Write-Host '  To get a fresh theme every shell, set in Profiles/config.psd1:' -ForegroundColor DarkGray
        Write-Host "      OhMyPoshTheme = 'Random'" -ForegroundColor White
        Write-Host "  Or pin just this one with:  Set-PoshTheme $active" -ForegroundColor DarkGray
    }
    else {
        $configValue = ($chosen.BaseName -replace '\.omp$', '')
        oh-my-posh init pwsh --config $chosen.FullName | Invoke-Expression
        $script:Config.OhMyPoshThemeActive = $configValue
        $script:Config.OhMyPoshTheme = $configValue

        Write-Host "  Applied theme '$configValue'." -ForegroundColor Green
        Write-Host '  To make it your default, set in Profiles/config.psd1:' -ForegroundColor DarkGray
        Write-Host "      OhMyPoshTheme = '$configValue'" -ForegroundColor White
    }
}
