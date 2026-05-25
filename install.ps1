<#
.SYNOPSIS
    Install the pwsh-toolkit profile into your $PROFILE.

.DESCRIPTION
    Wires your PowerShell $PROFILE to this repo's loader
    (Profiles/pwsh-toolkit-profile.ps1) using whichever pattern your machine
    supports:

      • Symlink — if you're running as admin OR have Windows Developer Mode on.
                  $PROFILE becomes a symlink directly to the loader.
      • Stub    — otherwise. $PROFILE becomes a two-line file that dot-sources
                  the loader. No admin needed. Functionally identical.

    Either way, edits inside this repo are picked up by every new shell — no
    re-install needed.

    Also seeds Profiles/config.psd1 from config.example.psd1 if missing.

.PARAMETER AllHosts
    Install to $PROFILE.CurrentUserAllHosts (loads in pwsh, VS Code, ISE, ...)
    instead of the default CurrentUserCurrentHost (just the host you ran the
    installer from).

.PARAMETER Stub
    Force the dot-source stub install pattern, even if symlinks would work.

.PARAMETER Force
    Overwrite any existing $PROFILE without prompting. Existing content is
    backed up to $PROFILE.backup-<timestamp> first unless it's already a
    pwsh-toolkit install.

.PARAMETER Uninstall
    Remove the $PROFILE entry. Does NOT touch the repo or your config.psd1.

.PARAMETER InstallOhMyPosh
    Skip the interactive prompt and set up Oh My Posh: install oh-my-posh via
    winget, install the Meslo Nerd Font, install the Terminal-Icons module,
    and flip Prompt = 'OhMyPosh' in your config.psd1. Each step is idempotent.

.PARAMETER SkipOhMyPosh
    Skip the interactive Oh My Posh prompt and leave the prompt alone. Use in
    scripted installs that don't want OMP.

.EXAMPLE
    .\install.ps1
    # Standard install — symlink if possible, stub otherwise. Prompts about OMP.

.EXAMPLE
    .\install.ps1 -InstallOhMyPosh
    # One-shot polished install: profile + OMP + Nerd Font + Terminal-Icons.

.EXAMPLE
    .\install.ps1 -AllHosts -SkipOhMyPosh
    # Load in every host, skip OMP setup non-interactively.

.EXAMPLE
    .\install.ps1 -Uninstall
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $AllHosts,
    [switch] $Stub,
    [switch] $Force,
    [switch] $Uninstall,
    [switch] $InstallOhMyPosh,
    [switch] $SkipOhMyPosh
)

if ($InstallOhMyPosh -and $SkipOhMyPosh) {
    throw "Cannot specify both -InstallOhMyPosh and -SkipOhMyPosh."
}

$ErrorActionPreference = 'Stop'

# ─── Pre-flight ─────────────────────────────────────────────────────────────
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "pwsh-toolkit requires PowerShell 7 or later. You're running $($PSVersionTable.PSVersion). Install: winget install Microsoft.PowerShell"
}

$repoRoot      = $PSScriptRoot
$loader        = Join-Path $repoRoot 'Profiles\pwsh-toolkit-profile.ps1'
$configExample = Join-Path $repoRoot 'Profiles\config.example.psd1'
$configUser    = Join-Path $repoRoot 'Profiles\config.psd1'

if (-not (Test-Path -LiteralPath $loader)) {
    throw "Loader not found at $loader. Run this script from the repo root."
}

$targetSlot = if ($AllHosts) { 'CurrentUserAllHosts' } else { 'CurrentUserCurrentHost' }
$profilePath = $PROFILE.$targetSlot

Write-Host ''
Write-Host "pwsh-toolkit installer" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────"
Write-Host "  Target slot : $targetSlot"
Write-Host "  Profile path: $profilePath"
Write-Host "  Loader      : $loader"
Write-Host ''

# ─── Uninstall branch ───────────────────────────────────────────────────────
if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "Nothing to remove — no profile at $profilePath." -ForegroundColor DarkGray
        return
    }
    if ($PSCmdlet.ShouldProcess($profilePath, 'Remove pwsh-toolkit profile')) {
        Remove-Item -LiteralPath $profilePath -Force
        Write-Host "✓ Removed $profilePath" -ForegroundColor Green
        Write-Host "  Repo and config.psd1 are untouched." -ForegroundColor DarkGray
    }
    return
}

# ─── Detect whether we can create symlinks ─────────────────────────────────
function Test-SymlinkCapability {
    # Bypass -WhatIf on the probe itself so the capability test runs even in
    # dry-runs — we need a real answer to decide whether to plan a symlink or
    # a stub install. The probe leaves no trace either way.
    $tempLink = Join-Path $env:TEMP "pwsh-toolkit-symlink-test-$([Guid]::NewGuid())"
    try {
        $null = New-Item -ItemType SymbolicLink -Path $tempLink -Target $env:USERPROFILE -ErrorAction Stop -WhatIf:$false
        Remove-Item -LiteralPath $tempLink -Force -ErrorAction SilentlyContinue -WhatIf:$false
        return $true
    } catch {
        return $false
    }
}

$canSymlink = -not $Stub -and (Test-SymlinkCapability)

if ($Stub) {
    Write-Host "  Method      : stub (forced via -Stub)" -ForegroundColor Yellow
} elseif ($canSymlink) {
    Write-Host "  Method      : symlink (admin or Developer Mode detected)" -ForegroundColor Green
} else {
    Write-Host "  Method      : stub (symlinks unavailable — admin not granted and Developer Mode off)" -ForegroundColor Yellow
    Write-Host "                Enable Developer Mode to use symlinks: Settings → Privacy & security → For developers → On" -ForegroundColor DarkGray
}
Write-Host ''

# ─── Detect existing install ───────────────────────────────────────────────
function Test-ExistingPwshToolkitInstall {
    if (-not (Test-Path -LiteralPath $profilePath)) { return $false }
    $item = Get-Item -LiteralPath $profilePath -Force
    if ($item.LinkType -and $item.Target -like '*pwsh-toolkit-profile.ps1') { return $true }
    $content = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
    return ($content -like '*pwsh-toolkit-profile.ps1*')
}

$alreadyInstalled = Test-ExistingPwshToolkitInstall

if ((Test-Path -LiteralPath $profilePath) -and -not $alreadyInstalled -and -not $Force) {
    $item = Get-Item -LiteralPath $profilePath -Force
    $what = if ($item.LinkType) { "symlink → $($item.Target)" } else { "regular file ($([Math]::Round($item.Length / 1KB, 1)) KB)" }
    Write-Host "Existing profile detected: $what" -ForegroundColor Yellow
    Write-Host "It will be backed up to ${profilePath}.backup-<timestamp> before being replaced." -ForegroundColor DarkGray
    $response = Read-Host "Continue? [y/N]"
    if ($response -notmatch '^[Yy]') {
        Write-Host "Cancelled." -ForegroundColor DarkGray
        return
    }
}

# ─── Make sure the profile directory exists ────────────────────────────────
$profileDir = Split-Path -Parent $profilePath
if (-not (Test-Path -LiteralPath $profileDir)) {
    if ($PSCmdlet.ShouldProcess($profileDir, 'Create profile directory')) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
}

# ─── Back up existing $PROFILE (unless it's already us) ────────────────────
if ((Test-Path -LiteralPath $profilePath) -and -not $alreadyInstalled) {
    $backup = "$profilePath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if ($PSCmdlet.ShouldProcess($profilePath, "Back up to $backup")) {
        Move-Item -LiteralPath $profilePath -Destination $backup
        Write-Host "  ↳ Backed up existing profile to $(Split-Path -Leaf $backup)" -ForegroundColor DarkGray
    }
} elseif ($alreadyInstalled) {
    # Remove the existing pwsh-toolkit install so we can re-create it cleanly
    # (handles symlink → stub or stub → symlink transitions).
    if ($PSCmdlet.ShouldProcess($profilePath, 'Replace existing pwsh-toolkit install')) {
        Remove-Item -LiteralPath $profilePath -Force
    }
}

# ─── Create the symlink or stub ────────────────────────────────────────────
if ($canSymlink) {
    if ($PSCmdlet.ShouldProcess($profilePath, "Create symlink → $loader")) {
        $null = New-Item -ItemType SymbolicLink -Path $profilePath -Target $loader -Force
        Write-Host "✓ Created symlink: $profilePath → $loader" -ForegroundColor Green
    }
} else {
    $stubContent = @"
# pwsh-toolkit loader stub (created by install.ps1)
. '$loader'
"@
    if ($PSCmdlet.ShouldProcess($profilePath, "Write dot-source stub → $loader")) {
        Set-Content -LiteralPath $profilePath -Value $stubContent -Encoding utf8
        Write-Host "✓ Wrote stub: $profilePath → $loader" -ForegroundColor Green
    }
}

# ─── Seed config.psd1 if absent ────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $configUser)) {
    if (Test-Path -LiteralPath $configExample) {
        if ($PSCmdlet.ShouldProcess($configUser, 'Seed from config.example.psd1')) {
            Copy-Item -LiteralPath $configExample -Destination $configUser
            Write-Host "✓ Created $configUser from config.example.psd1" -ForegroundColor Green
            Write-Host "  Edit it to customize prompt, OneDrive org, jump folders, etc." -ForegroundColor DarkGray
        }
    } else {
        Write-Warning "config.example.psd1 not found — skipped config seeding."
    }
} else {
    Write-Host "  Existing config.psd1 preserved (not overwritten)." -ForegroundColor DarkGray
}

# ─── Oh My Posh setup (optional, opt-in) ───────────────────────────────────
function Test-MesloNerdFontInstalled {
    foreach ($dir in @("$env:LOCALAPPDATA\Microsoft\Windows\Fonts", "$env:WINDIR\Fonts")) {
        if (Test-Path -LiteralPath $dir) {
            $hit = Get-ChildItem -LiteralPath $dir -ErrorAction SilentlyContinue |
                Where-Object Name -match 'MesloLG.*Nerd' |
                Select-Object -First 1
            if ($hit) { return $true }
        }
    }
    return $false
}

function Set-OhMyPoshEnvironment {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $ConfigPath)

    Write-Host ''
    Write-Host 'Setting up Oh My Posh...' -ForegroundColor Cyan

    # 1) Oh My Posh
    if (Get-Command oh-my-posh -ErrorAction Ignore) {
        Write-Host '  ✓ oh-my-posh already installed' -ForegroundColor DarkGray
    } elseif (-not (Get-Command winget -ErrorAction Ignore)) {
        Write-Warning '  winget not available — install Oh My Posh manually: https://ohmyposh.dev/docs/installation/windows'
    } else {
        if ($PSCmdlet.ShouldProcess('JanDeDobbeleer.OhMyPosh', 'winget install')) {
            Write-Host '  → Installing oh-my-posh via winget...' -ForegroundColor DarkGray
            winget install --id JanDeDobbeleer.OhMyPosh --silent --accept-source-agreements --accept-package-agreements | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host '  ✓ oh-my-posh installed' -ForegroundColor Green
                # PATH refresh: pull the Machine + User PATH into the current session
                # so subsequent `oh-my-posh font install` calls find the binary.
                $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                            [Environment]::GetEnvironmentVariable('Path', 'User')
            } else {
                Write-Warning "  winget install failed (exit $LASTEXITCODE)"
            }
        }
    }

    # 2) Meslo Nerd Font
    if (Test-MesloNerdFontInstalled) {
        Write-Host '  ✓ Meslo Nerd Font already installed' -ForegroundColor DarkGray
    } elseif (-not (Get-Command oh-my-posh -ErrorAction Ignore)) {
        Write-Warning '  oh-my-posh not on PATH — skipping font install. Open a new shell and re-run install.ps1 -InstallOhMyPosh.'
    } else {
        if ($PSCmdlet.ShouldProcess('Meslo Nerd Font', 'oh-my-posh font install')) {
            Write-Host '  → Installing Meslo Nerd Font (per-user, no admin needed)...' -ForegroundColor DarkGray
            # --headless skips the TUI font-family picker; per-user install is
            # the default for non-admin sessions (Windows 10 1809+).
            & oh-my-posh font install Meslo --headless
            if ($LASTEXITCODE -eq 0) {
                Write-Host '  ✓ Meslo Nerd Font installed' -ForegroundColor Green
            } else {
                Write-Warning "  Font install returned exit $LASTEXITCODE"
            }
        }
    }

    # 3) Terminal-Icons module
    if (Get-Module -ListAvailable -Name Terminal-Icons) {
        Write-Host '  ✓ Terminal-Icons module already installed' -ForegroundColor DarkGray
    } else {
        if ($PSCmdlet.ShouldProcess('Terminal-Icons', 'Install-Module')) {
            Write-Host '  → Installing Terminal-Icons module (CurrentUser scope)...' -ForegroundColor DarkGray
            Install-Module Terminal-Icons -Force -Scope CurrentUser -SkipPublisherCheck -ErrorAction Continue
            if (Get-Module -ListAvailable -Name Terminal-Icons) {
                Write-Host '  ✓ Terminal-Icons installed' -ForegroundColor Green
            } else {
                Write-Warning '  Terminal-Icons install failed'
            }
        }
    }

    # 4) Flip Prompt key in config.psd1. Regex-replace preserves any other
    # edits the user has made (comments, extra keys, etc.).
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Warning "  config.psd1 not found at $ConfigPath — skipping Prompt switch."
    } else {
        $content = Get-Content -Raw -LiteralPath $ConfigPath
        $pattern = "Prompt\s*=\s*['""][^'""]*['""]"
        if ($content -match $pattern) {
            $newContent = $content -replace $pattern, "Prompt = 'OhMyPosh'"
            if ($newContent -ne $content) {
                if ($PSCmdlet.ShouldProcess($ConfigPath, "Set Prompt = 'OhMyPosh'")) {
                    Set-Content -LiteralPath $ConfigPath -Value $newContent -Encoding utf8 -NoNewline
                    Write-Host "  ✓ Set Prompt = 'OhMyPosh' in config.psd1" -ForegroundColor Green
                }
            } else {
                Write-Host "  ✓ Prompt already set to 'OhMyPosh'" -ForegroundColor DarkGray
            }
        } else {
            Write-Warning "  Couldn't find Prompt = '...' line in $ConfigPath. Set it manually."
        }
    }

    Write-Host ''
    Write-Host '  After install: set your terminal font to a MesloLG Nerd Font variant.' -ForegroundColor Yellow
    Write-Host "  Recommended: ""MesloLGMDZ Nerd Font Mono"" (Windows Terminal:" -ForegroundColor Yellow
    Write-Host '  Settings → Profiles → Defaults → Appearance → Font face).' -ForegroundColor Yellow
}

# Decide whether to run OMP setup
if ($InstallOhMyPosh) {
    $setupOmp = $true
} elseif ($SkipOhMyPosh) {
    $setupOmp = $false
} elseif ($Force) {
    # Unattended mode: safest default is "don't touch the prompt config."
    $setupOmp = $false
} elseif ([Console]::IsInputRedirected) {
    # Non-TTY stdin (CI, piped): can't prompt; safest default is skip.
    $setupOmp = $false
} else {
    Write-Host ''
    Write-Host 'Set up Oh My Posh for the polished prompt experience?' -ForegroundColor Cyan
    Write-Host '  • Installs oh-my-posh (via winget)'
    Write-Host '  • Installs the Meslo Nerd Font (renders the icons)'
    Write-Host '  • Installs the Terminal-Icons PowerShell module'
    Write-Host "  • Sets Prompt = 'OhMyPosh' in Profiles/config.psd1"
    $response = Read-Host 'Continue? [Y/n]'
    $setupOmp = ($response -match '^[Yy]?$')  # empty = Yes
}

if ($setupOmp) {
    Set-OhMyPoshEnvironment -ConfigPath $configUser
}

# ─── Done ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host "Install complete." -ForegroundColor Cyan
Write-Host "Open a new PowerShell window — or run '. `$PROFILE' here — to load the profile."
Write-Host ''
