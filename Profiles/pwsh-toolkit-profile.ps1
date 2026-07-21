# ============================================================================
# pwsh-toolkit profile loader
# ----------------------------------------------------------------------------
# Behavior is driven by config.psd1 (next to this file). If config.psd1 is
# absent, the loader falls back to config.example.psd1's defaults.
#
# Layout the loader expects:
#   Profiles/
#     pwsh-toolkit-profile.ps1   ← you are here
#     config.psd1                ← user copy (gitignored, optional)
#     config.example.psd1        ← defaults (committed)
#     Common/                ← always loaded
#     M365/                  ← loaded if Microsoft.Graph is installed
#     Machines/<NAME>.ps1    ← per-machine overrides (optional)
#     Hosts/<HostName>.ps1   ← per-host overrides (optional)
#     OhMyPosh/<theme>.json  ← theme files for Prompt = 'OhMyPosh'
#
# See LOADING.md for the full rationale on path resolution, load order, and
# cross-file dependencies. Touch profile-load behavior with that document open.
# ============================================================================

# ─── Resolve the profile root (symlink-aware) ───────────────────────────────
# Works for three install patterns:
#   1. $PROFILE is a symlink → follow .Target to the real file in the repo.
#   2. $PROFILE is a dot-source stub → $PSCommandPath is this file directly.
#   3. $PROFILE is this file (rare) → same as #2.
$script:ProfileRoot = Split-Path -Parent ([IO.Path]::GetFullPath(
    (Get-Item $PSCommandPath).Target ?? $PSCommandPath
))

$commonPath  = Join-Path $script:ProfileRoot 'Common'
$m365Path    = Join-Path $script:ProfileRoot 'M365'
$machinePath = Join-Path $script:ProfileRoot 'Machines'
$hostPath    = Join-Path $script:ProfileRoot 'Hosts'

# ─── Load configuration ─────────────────────────────────────────────────────
# Defaults from config.example.psd1; user's config.psd1 (if present) shallow-
# overrides any keys it defines.
$exampleConfig = Join-Path $script:ProfileRoot 'config.example.psd1'
$userConfig    = Join-Path $script:ProfileRoot 'config.psd1'

if (Test-Path -LiteralPath $exampleConfig) {
    try {
        $script:Config = Import-PowerShellDataFile -LiteralPath $exampleConfig
    } catch {
        Write-Warning "pwsh-toolkit: failed to parse config.example.psd1: $($_.Exception.Message)"
        $script:Config = @{}
    }
} else {
    Write-Warning "pwsh-toolkit: $exampleConfig is missing — using built-in defaults."
    $script:Config = @{}
}

if (Test-Path -LiteralPath $userConfig) {
    try {
        $userValues = Import-PowerShellDataFile -LiteralPath $userConfig
        foreach ($k in $userValues.Keys) { $script:Config[$k] = $userValues[$k] }
    } catch {
        Write-Warning "pwsh-toolkit: failed to parse config.psd1: $($_.Exception.Message)"
    }
}

# Hard defaults for keys neither file defined
if (-not $script:Config.ContainsKey('Prompt'))             { $script:Config.Prompt = 'Default' }
if (-not $script:Config.ContainsKey('OhMyPoshTheme'))      { $script:Config.OhMyPoshTheme = 'default.omp.json' }
if (-not $script:Config.ContainsKey('ExtraJumpFolders'))   { $script:Config.ExtraJumpFolders = @() }
if (-not $script:Config.ContainsKey('RemoteServers'))      { $script:Config.RemoteServers = @() }
if (-not $script:Config.ContainsKey('ProjectRoots'))       { $script:Config.ProjectRoots = @() }
if (-not $script:Config.ContainsKey('NotesRoot'))          { $script:Config.NotesRoot = $null }
if (-not $script:Config.ContainsKey('DisableStartupTips')) { $script:Config.DisableStartupTips = $false }
if (-not $script:Config.ContainsKey('Features'))           { $script:Config.Features = @{} }

# Auto-detect ToolkitRoot when unset: parent of Profiles/ is the repo root,
# which contains WingetUpgrade/, DownloadsOrganizer/, etc.
if (-not $script:Config.ToolkitRoot) {
    $script:Config.ToolkitRoot = Split-Path -Parent $script:ProfileRoot
}

# Auto-detect OneDriveOrg from the OneDrive client's env var. $null = detect,
# '' = force personal (no suffix), 'Name' = explicit override.
if ($null -eq $script:Config.OneDriveOrg) {
    $leaf = if ($env:OneDriveCommercial) { Split-Path -Leaf $env:OneDriveCommercial }
    $script:Config.OneDriveOrg = if ($leaf -like 'OneDrive - *') { $leaf.Substring(11) } else { '' }
}

# NotesRoot resolution is more involved (Obsidian config detection + OneDrive
# preference cascade) — it's done by Resolve-NotesRoot in Notes.ps1 at the
# end of that file's load, after Get-ObsidianVault and the cascade helpers
# are defined. The loader leaves NotesRoot as $null here; Notes.ps1 fills it.

# ─── Prompt setup (OhMyPosh branch) ─────────────────────────────────────────
if ($script:Config.Prompt -eq 'OhMyPosh') {
    # Theme sources: the downloaded gallery cache (Update-PoshThemes) and the
    # bundled Profiles/OhMyPosh/ folder. This runs before Common/ is dot-sourced,
    # so Get-ToolkitDataPath (Common/AppData.ps1) isn't defined yet — the cache
    # path is mirrored here as a literal. Keep in sync with AppData.ps1's root
    # and PoshThemes.ps1's 'PoshThemes' child.
    $themeName  = $script:Config.OhMyPoshTheme
    $bundledDir = Join-Path $script:ProfileRoot 'OhMyPosh'
    $cacheDir   = Join-Path $env:LOCALAPPDATA 'pwsh-toolkit\PoshThemes'
    $themePath  = $null

    if ($themeName -eq 'Random') {
        # Roll a random theme from the gallery + bundled set for this shell.
        $pool = @(
            (Get-ChildItem -Path (Join-Path $cacheDir '*.omp.json')   -ErrorAction Ignore)
            (Get-ChildItem -Path (Join-Path $bundledDir '*.omp.json') -ErrorAction Ignore)
        )
        if ($pool.Count -gt 0) {
            $pick = $pool | Get-Random
            $themePath = $pick.FullName
            $script:Config.OhMyPoshThemeActive = ($pick.BaseName -replace '\.omp$', '')
        }
    }
    elseif ($themeName -and -not ([IO.Path]::IsPathRooted($themeName)) -and -not ($themeName -match '[\\/]')) {
        # Bare name → bundled first, then the gallery cache.
        $leaf = if ($themeName -match '\.omp\.json$') { $themeName } else { "$themeName.omp.json" }
        $themePath = @((Join-Path $bundledDir $leaf), (Join-Path $cacheDir $leaf)) |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $themePath) { $themePath = Join-Path $bundledDir $leaf }   # original fallback behavior
        $script:Config.OhMyPoshThemeActive = ($themeName -replace '\.omp\.json$', '')
    }
    else {
        # Rooted path or one containing a separator — use as-is.
        $themePath = $themeName
        $script:Config.OhMyPoshThemeActive = if ($themeName) { ([IO.Path]::GetFileNameWithoutExtension($themeName) -replace '\.omp$', '') } else { '' }
    }

    if (Get-Command oh-my-posh -ErrorAction Ignore) {
        if ($themePath -and (Test-Path -LiteralPath $themePath)) {
            oh-my-posh init pwsh --config $themePath | Invoke-Expression
        } else {
            oh-my-posh init pwsh | Invoke-Expression   # built-in default (e.g. empty gallery)
        }
        # In Random mode, name the rolled theme so it can be pinned (quiet under
        # PSPROFILE_NO_TIPS, so CI / scripted shells stay clean).
        if ($themeName -eq 'Random' -and $script:Config.OhMyPoshThemeActive -and -not $env:PSPROFILE_NO_TIPS) {
            Write-Host "  prompt theme: $($script:Config.OhMyPoshThemeActive)   (pin it with: Set-PoshTheme)" -ForegroundColor DarkGray
        }
    } else {
        Write-Warning "Oh My Posh not found. Install it with: winget install JanDeDobbeleer.OhMyPosh"
        Write-Warning "Falling back to default prompt."
    }

    if (Get-Module -ListAvailable -Name Terminal-Icons) {
        Import-Module Terminal-Icons
    }
}

# ─── Load Common/ ───────────────────────────────────────────────────────────
# Skip Common/Prompt.ps1 when something else owns the prompt (OhMyPosh has
# already initialized; 'Default' means leave PowerShell's prompt alone).
$skipPrompt = $script:Config.Prompt -in @('OhMyPosh', 'Default')

if (Test-Path $commonPath) {
    Get-ChildItem "$commonPath\*.ps1" -ErrorAction SilentlyContinue |
        Where-Object { -not ($skipPrompt -and $_.Name -eq 'Prompt.ps1') } |
        ForEach-Object {
            # Per-file isolation: a load-time throw in one file must not kill
            # everything that loads after it (remaining Common, M365, Machines,
            # Hosts, the prompt tail). try/catch adds no scope, so dot-sourcing
            # still lands definitions in the profile scope as before. ($file,
            # not $_ — inside catch, $_ is the error record.)
            $file = $_
            Write-Verbose "  Loading: $($file.Name)"
            try { . $file.FullName }
            catch { Write-Warning "pwsh-toolkit: failed to load Common\$($file.Name): $_" }
        }
} else {
    Write-Warning "Common profile directory not found: $commonPath"
}

# ─── Load M365/ (if Microsoft.Graph is installed and not disabled) ──────────
$disableM365 = [bool]$script:Config.Features.DisableM365
if (-not $disableM365 -and (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    if (Test-Path $m365Path) {
        Get-ChildItem "$m365Path\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
            $file = $_
            Write-Verbose "  Loading: $($file.Name)"
            try { . $file.FullName }
            catch { Write-Warning "pwsh-toolkit: failed to load M365\$($file.Name): $_" }
        }
    }
} elseif ($disableM365) {
    Write-Verbose 'M365/ skipped: Features.DisableM365 is set in config.psd1.'
} else {
    # The gate requires the Microsoft.Graph meta-module by exact name;
    # individual submodules (e.g. Microsoft.Graph.Authentication) are not
    # enough. `toolkit` shows the same hint, so this is discoverable
    # without -Verbose too.
    Write-Verbose 'M365/ skipped: Microsoft.Graph module not installed. Install-Module Microsoft.Graph to enable.'
}

# ─── Per-machine overrides ──────────────────────────────────────────────────
$machineConfig = Join-Path $machinePath "$env:COMPUTERNAME.ps1"
if (Test-Path $machineConfig) {
    Write-Verbose "Loading machine-specific configuration: $env:COMPUTERNAME"
    try { . $machineConfig }
    catch { Write-Warning "pwsh-toolkit: failed to load Machines\$env:COMPUTERNAME.ps1: $_" }
}

# ─── Per-host overrides ─────────────────────────────────────────────────────
$hostName   = (Get-Host).Name -replace ' ', ''
$hostConfig = Join-Path $hostPath "$hostName.ps1"
if (Test-Path $hostConfig) {
    Write-Verbose "Loading host-specific configuration: $hostName"
    try { . $hostConfig }
    catch { Write-Warning "pwsh-toolkit: failed to load Hosts\$hostName.ps1: $_" }
}

# ─── Jump-folder bookmarks (`j -Add`) ───────────────────────────────────────
# Append saved user bookmarks to $script:JumpFolders HERE — after config,
# machine, and host files have all added their entries — so bookmarks always
# sit at the END of the list and can never shadow a built-in/config/machine
# destination in `j <text>` first-match lookup. (Navigation.ps1 defines
# Sync-JumpBookmark but deliberately doesn't call it at dot-source time; the
# Get-Command guard keeps this quiet if Navigation.ps1 failed to load.)
if (Get-Command Sync-JumpBookmark -ErrorAction Ignore) { Sync-JumpBookmark }

# ─── OhMyPosh tail: Graph indicator + transient prompt ─────────────────────
if ($script:Config.Prompt -eq 'OhMyPosh') {
    # Sync Microsoft.Graph connection state into $env:POSH_GRAPH for the OMP
    # envvar segment, hooked on the prompt's idle cycle.
    #
    # The guard is Get-Module (loaded modules only), NOT Get-Command: command
    # discovery would auto-import Microsoft.Graph.Authentication on every shell
    # start (hundreds of ms) just to read an empty context. Until something
    # loads that module (Connect-Tenant, Connect-MgGraph) this session cannot
    # be connected, so the only job is clearing a POSH_GRAPH value inherited
    # from a parent shell. Once the module IS loaded, Get-MgContext exists, so
    # the ARCHITECTURE.md convention-#8 command-not-found hazard doesn't apply.
    function Update-PoshGraphStatus {
        if (-not (Get-Module Microsoft.Graph.Authentication)) {
            Remove-Item Env:\POSH_GRAPH -ErrorAction Ignore
            return
        }
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($ctx) { $env:POSH_GRAPH = $ctx.Account ?? 'Connected' }
        else      { Remove-Item Env:\POSH_GRAPH -ErrorAction Ignore }
    }
    Update-PoshGraphStatus
    # The action runs in this session's state, so it can call the function
    # directly — one source of truth for the indicator logic.
    Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 0 -Action {
        Update-PoshGraphStatus
    } | Out-Null

    if (Get-Command Enable-PoshTransientPrompt -ErrorAction Ignore) {
        Enable-PoshTransientPrompt
    }
}

# ─── Rotating tip (or stay silent) ─────────────────────────────────────────
# Env var wins over config (handy for CI / scripts that source the profile).
$disableTips = $env:PSPROFILE_NO_TIPS -or $script:Config.DisableStartupTips
if (-not $disableTips -and (Get-Command Show-ProfileTip -ErrorAction Ignore)) {
    Show-ProfileTip
}
