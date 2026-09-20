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

# ─── Load timing (Measure-ProfileLoad) ──────────────────────────────────────
# Off unless PWSH_TOOLKIT_TIMING is set; then each phase and each file records
# how long it took into $script:ProfileLoadTimings, which Measure-ProfileLoad
# reads back from a child process. Off, a mark is one no-op scriptblock call.
$script:ProfileLoadTimings = $null
$markLoad = {}
if ($env:PWSH_TOOLKIT_TIMING) {
    $script:ProfileLoadTimings = [System.Collections.Generic.List[object]]::new()
    $script:ProfileLoadClock   = [System.Diagnostics.Stopwatch]::StartNew()
    $script:ProfileLoadLast    = 0.0
    $markLoad = {
        param([string] $Name)
        $now = $script:ProfileLoadClock.Elapsed.TotalMilliseconds
        $script:ProfileLoadTimings.Add([pscustomobject]@{ Name = $Name; Ms = $now - $script:ProfileLoadLast })
        $script:ProfileLoadLast = $now
    }
}

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
# preference cascade) — Notes.ps1's Get-NotesRoot does it on the first notes
# command, not at load: parsing Obsidian's config cost every shell more than
# the rest of Notes.ps1 together. The loader leaves NotesRoot as $null here.
& $markLoad 'config'

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
        # [IO.Directory]::GetFiles, not Get-ChildItem: this walks ~120 gallery
        # files in every shell, and returning paths rather than FileInfo objects
        # takes it from ~50 ms to a few.
        $pool = @(
            foreach ($dir in @($cacheDir, $bundledDir)) {
                if ([IO.Directory]::Exists($dir)) { [IO.Directory]::GetFiles($dir, '*.omp.json') }
            }
        )
        if ($pool.Count -gt 0) {
            $themePath = $pool | Get-Random
            $script:Config.OhMyPoshThemeActive = ([IO.Path]::GetFileNameWithoutExtension($themePath) -replace '\.omp$', '')
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

    & $markLoad 'Oh My Posh init'

    # Terminal-Icons costs ~0.5 s to find and import - more than all of Common/
    # together - and only matters once a folder is listed. Import it on the
    # first idle moment after the prompt is up instead of before it (-Global:
    # an event action has its own scope). ll/la/lh import it themselves if
    # they run first. No Get-Module -ListAvailable probe: a missing module is
    # just an ignored import.
    $script:DeferredTerminalIcons = $true
    $null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -Action {
        Import-Module Terminal-Icons -Global -ErrorAction Ignore
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
            & $markLoad "Common\$($file.Name)"
        }
} else {
    Write-Warning "Common profile directory not found: $commonPath"
}

# ─── Load M365/ (if Microsoft.Graph is installed and not disabled) ──────────
$disableM365 = [bool]$script:Config.Features.DisableM365
# A folder check on each PSModulePath entry, not Get-Module -ListAvailable:
# same answer for an installed module, at a fraction of the cost (~1 ms vs
# ~70 ms per shell).
$graphInstalled = -not $disableM365 -and @(
    $env:PSModulePath -split [IO.Path]::PathSeparator |
        Where-Object { $_ -and [IO.Directory]::Exists((Join-Path $_ 'Microsoft.Graph')) }
).Count -gt 0
& $markLoad 'M365 gate'
if ($graphInstalled) {
    if (Test-Path $m365Path) {
        Get-ChildItem "$m365Path\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
            $file = $_
            Write-Verbose "  Loading: $($file.Name)"
            try { . $file.FullName }
            catch { Write-Warning "pwsh-toolkit: failed to load M365\$($file.Name): $_" }
            & $markLoad "M365\$($file.Name)"
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
    & $markLoad "Machines\$env:COMPUTERNAME.ps1"
}

# ─── Per-host overrides ─────────────────────────────────────────────────────
$hostName   = (Get-Host).Name -replace ' ', ''
$hostConfig = Join-Path $hostPath "$hostName.ps1"
if (Test-Path $hostConfig) {
    Write-Verbose "Loading host-specific configuration: $hostName"
    try { . $hostConfig }
    catch { Write-Warning "pwsh-toolkit: failed to load Hosts\$hostName.ps1: $_" }
    & $markLoad "Hosts\$hostName.ps1"
}

# ─── Jump-folder bookmarks (`j -Add`) ───────────────────────────────────────
# Append saved user bookmarks to $script:JumpFolders HERE — after config,
# machine, and host files have all added their entries — so bookmarks always
# sit at the END of the list and can never shadow a built-in/config/machine
# destination in `j <text>` first-match lookup. (Navigation.ps1 defines
# Sync-JumpBookmark but deliberately doesn't call it at dot-source time; the
# guard keeps this quiet if Navigation.ps1 failed to load.)
#
# Guards in this tail test the Function: drive rather than Get-Command. For a
# name that isn't defined, Get-Command searches every module on PSModulePath
# (~70 ms per miss, every shell).
if (Test-Path Function:\Sync-JumpBookmark) { Sync-JumpBookmark }
& $markLoad 'bookmarks'

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

    # Oh My Posh 31 drives the transient prompt from the theme and no longer
    # defines this function; older versions still need the call.
    if (Test-Path Function:\Enable-PoshTransientPrompt) {
        Enable-PoshTransientPrompt
    }
    & $markLoad 'Oh My Posh tail'
}

# ─── Rotating tip (or stay silent) ─────────────────────────────────────────
# Env var wins over config (handy for CI / scripts that source the profile).
$disableTips = $env:PSPROFILE_NO_TIPS -or $script:Config.DisableStartupTips
if (-not $disableTips -and (Test-Path Function:\Show-ProfileTip)) {
    Show-ProfileTip
}
& $markLoad 'tip'
