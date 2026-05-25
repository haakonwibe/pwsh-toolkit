# PowerShell Profile - Modular Configuration

A modular PowerShell profile system designed for portability, maintainability, and easy customization across different machines and environments.

Behavior is driven by [`config.psd1`](config.example.psd1) — a single config file that picks the prompt (custom, Oh My Posh, or PowerShell's default), points the wrapper helpers at the toolkit root, sets the OneDrive org, and lets you append extra folder-jumper destinations. Every Common/M365 helper loads identically regardless of which prompt you pick. See [LOADING.md](LOADING.md) for the full rationale, load order, and rules for changing startup behavior without breaking things.

> **Touching profile-load behavior? Read [LOADING.md](LOADING.md) first.**

## Structure

```
Profiles/
├── pwsh-toolkit-profile.ps1            # Config-driven loader (the file $PROFILE points at)
├── config.example.psd1                 # Default configuration (committed)
├── config.psd1                         # Your overrides (gitignored — copy from example)
├── LOADING.md                          # Loader internals — read before touching the loader
├── Common/                             # Universal functions (work everywhere)
│   ├── Aliases.ps1                    # Quick shortcuts and aliases (winup, tagdl, ask, ...)
│   ├── DefaultParameters.ps1          # Default parameter values for cmdlets
│   ├── Navigation.ps1                 # Directory navigation + folder jumper (j/jb/jf)
│   ├── Peek.ps1                       # Archive previewer (peek)
│   ├── SystemUtilities.ps1            # System info and utility functions (df, Get-PubIP, ...)
│   ├── SecretManagement.ps1           # SecretStore helpers
│   ├── Tips.ps1                       # Rotating tip shown at profile load
│   ├── Prompt.ps1                     # In-repo custom prompt (used when Prompt = 'Custom')
│   └── PSReadLine.ps1                 # PSReadLine configuration
├── M365/                               # Microsoft 365 admin tools (loaded if Microsoft.Graph is installed)
│   ├── GraphConnection.ps1
│   ├── ExchangeConnection.ps1
│   └── TenantManagement.ps1
├── OhMyPosh/                           # Theme files for Prompt = 'OhMyPosh'
│   ├── default.omp.json
│   └── README.md
├── Machines/                           # Machine-specific overrides
│   ├── <COMPUTERNAME>.ps1              # Optional, dot-sourced if present
│   └── README.md
└── Hosts/                              # Host-specific overrides
    ├── <HostName>.ps1                  # Optional, dot-sourced if present
    └── README.md
```

## Installation

The repo's `install.ps1` (at repo root) handles this end-to-end: it detects whether you can create a symlink (admin or Developer Mode), creates one if you can or writes a dot-source stub if you can't, then copies `config.example.psd1` → `config.psd1` and prompts you to edit it.

If you'd rather wire it up by hand, the loader (`pwsh-toolkit-profile.ps1`) expects the `Common/`, `M365/`, `Machines/`, `Hosts/`, and `OhMyPosh/` directories to live next to it. It resolves its own path at runtime, so you can either symlink or dot-source from `$PROFILE`:

### Option 1: Symlink (recommended)

```powershell
# Requires admin OR Windows Developer Mode (Settings → Privacy & security → For developers → On)
$target = Join-Path $PSScriptRoot 'pwsh-toolkit-profile.ps1'   # run from the Profiles/ folder
if (Test-Path $PROFILE) { Remove-Item $PROFILE -Force }
New-Item -ItemType SymbolicLink -Path $PROFILE -Target $target -Force
```

### Option 2: Dot-source stub (no admin required)

```powershell
# Replace <repo-path> with the full path to where you cloned this repo
$loader = '<repo-path>\Profiles\pwsh-toolkit-profile.ps1'
@"
# pwsh-toolkit loader
. '$loader'
"@ | Set-Content -Path $PROFILE -Encoding utf8
```

### Reload

```powershell
. $PROFILE
```

### Understanding `$PROFILE` Locations

PowerShell has four profile paths. See all of them with `$PROFILE | Format-List -Force`:

| Variable | Scope | Typical Path (PowerShell 7) |
|----------|-------|----------------------------|
| `$PROFILE.CurrentUserCurrentHost` | You + this host | `~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1` |
| `$PROFILE.CurrentUserAllHosts` | You + all hosts | `~\Documents\PowerShell\profile.ps1` |
| `$PROFILE.AllUsersCurrentHost` | All users + this host | `$PSHOME\Microsoft.PowerShell_profile.ps1` |
| `$PROFILE.AllUsersAllHosts` | All users + all hosts | `$PSHOME\profile.ps1` |

`$PROFILE` alone is shorthand for `CurrentUserCurrentHost`. For PowerShell 5.1, the paths use `WindowsPowerShell` instead of `PowerShell`.

> **Tip:** This profile uses symlinks to `CurrentUserCurrentHost`. If you use both PowerShell 7 and 5.1, create a symlink for each version's `$PROFILE`.

## Features

### Common Functions (Always Loaded)

**Aliases:**
- `ask <question>` - Quick reference via ch.at
- `ll` - List files with details
- `la` - List all files including hidden
- `touch <file>` - Create new file
- `which <command>` - Find command location

**Navigation:**
- `docs` - Jump to OneDrive Documents
- `desktop` - Jump to OneDrive Desktop
- `downloads` - Jump to Downloads folder
- `onedrive` - Jump to OneDrive root
- `home` - Jump to user profile

OneDrive paths use `$Config.OneDriveOrg` (auto-detected from `$env:OneDriveCommercial` when unset). Set `OneDriveOrg = ''` in `config.psd1` to force personal OneDrive.

**Folder Jumper:**
- `j` - Interactive picker with digits 1-9 for instant jump, Up/Down + Enter to navigate, Esc to cancel. Renders on the terminal's alternate screen buffer so scrollback is preserved on exit
- `j <substring>` - Skip the picker entirely. Case-insensitive substring match against both label *and* path, takes the first hit. The minimum unique prefix works — e.g. `j d` → Downloads (first match), `j prog` → ProgramData, `j local` → LocalAppData, `j main` → main repo, `j github` → GitHub root (matches the path, not the label)
- `jb` / `jf` - Browser-style back/forward through visited folders (per-session)
- Built-in destinations: Home, Downloads, OneDrive, LocalAppData, ProgramData. Append more via `config.psd1`'s `ExtraJumpFolders`, or for complex/conditional setup append in `Machines/<COMPUTERNAME>.ps1`: `$script:JumpFolders += [pscustomobject]@{ Label='VMs'; Path='D:\VMs' }`

**Archive Peek:**
- `peek <archive>` - Extract to `$env:TEMP\peek\<name>-<timestamp>` and `Set-Location` there. If the archive unpacks to a single top-level folder, jumps directly into that folder
- `peek -List <archive>` - Show contents without extracting
- `peek -Active` - List currently-extracted peeks (name, size, when, path)
- `peek -Clean` - Wipe the peek temp tree (walks you out first if you're standing inside it)
- `jb` - Jump back to where you peeked from (integrates with the folder jumper)
- Tool dispatch: `.rar` → WinRAR's `Rar.exe`/`UnRAR.exe` (RAR-only by design); everything else → 7-Zip (`7z.exe`) which handles ZIP, 7Z, TAR.GZ, ISO, CAB, WIM, etc. Falls back to built-in `Expand-Archive` for `.zip` if neither tool is present. Auto-finds both in their default install dirs (`C:\Program Files\WinRAR\`, `C:\Program Files\7-Zip\`) if not on PATH

**System Utilities:**
- `Get-PubIP` - Show public IP addresses (IPv4 & IPv6)
- `Get-Uptime` - Show system uptime
- `Get-SysInfo` - Show system information
- `Find-File <name>` - Recursive file search
- `Start-AdminTerminal` - Launch new admin terminal
- `df` - Disk free overview with colored usage bars (green ≤70%, yellow 71-89%, red ≥90%). Fixed drives only by default; `df -All` adds removable, network, and CD-ROM. Sorted by drive letter

**Secret Management:**
- `Get-OrCreateSecret -Name "API-Key" [-AsPlainText]` - Get or create secure secret
- `Get-StoredSecrets` - List all stored secrets
- `Remove-StoredSecret -Name "API-Key"` - Remove a secret

**Profile Tip:**
- A rotating two-line tip is shown at every shell startup, reminding you of one of the helpers in this profile. Catalog lives in `Common/Tips.ps1` (~23 entries covering jumper, peek, df, winup, tagdl, system utils, secret management, M365, etc.)
- `tip` - Re-roll for a different tip mid-session
- Last-shown index is cached in `%LOCALAPPDATA%\PSProfile\last-tip.txt` so the same tip doesn't appear twice in a row when spawning multiple shells
- Set `$env:PSPROFILE_NO_TIPS = '1'` to silence at startup (the older `✅ PowerShell profile loaded!` line is the fallback message when tips are off)

**Custom Prompt** (used when `Prompt = 'Custom'` in `config.psd1`):
- Shows admin status (🔴 ADMIN)
- Shows M365 Graph connectivity (🌐 M365)
- Smart path truncation
- OneDrive path simplification

Set `Prompt = 'OhMyPosh'` for the polished Oh My Posh variant (requires `oh-my-posh` on PATH + a Nerd Font; see `OhMyPosh/README.md`), or `Prompt = 'Default'` to leave PowerShell's built-in prompt alone.

### M365 Functions (Loaded if Microsoft.Graph module is available)

**Graph Connection:**
- `Connect-Graph` - Connect to Microsoft Graph with comprehensive scopes
- `Disconnect-Graph` - Disconnect from Microsoft Graph

**Exchange Connection:**
- `Connect-Exchange` - Connect to Exchange Online
- `Disconnect-Exchange` - Disconnect from Exchange Online

**Tenant Management:**
- `Get-TenantOverview` - Comprehensive tenant statistics and overview
- `Get-TeamsInfo [TeamName]` - Get Teams information

## Customization

### Machine-Specific Configuration

Create a file in `Machines/{COMPUTERNAME}.ps1` to override settings per machine:

```powershell
# Example: Machines/WORKSTATION01.ps1

# Override OneDrive organization
$script:OneDriveOrg = "Different Organization"

# Add machine-specific navigation shortcuts
function vmware { Set-Location "D:\VMs" }

# Machine-specific environment variables
$env:SOME_VARIABLE = "value"
```

### Host-Specific Configuration

Create a file in `Hosts/{HostName}.ps1` for PowerShell host-specific settings:

```powershell
# Example: Hosts/ConsoleHost.ps1 (regular PowerShell console)

# Different PSReadLine settings for console
Set-PSReadLineOption -EditMode Emacs

# Console-specific aliases
Set-Alias -Name np -Value notepad.exe
```

Common host names:
- `ConsoleHost` - Regular PowerShell console
- `VisualStudioCode` - VS Code integrated terminal
- `WindowsTerminal` - Windows Terminal

## Debugging

To see verbose loading messages:
```powershell
$VerbosePreference = "Continue"
. $PROFILE
```

## Prerequisites

### Required Modules
All common functions work without additional modules.

### Optional Modules (for M365 functions)
```powershell
# Microsoft Graph (for M365 administration)
Install-Module -Name Microsoft.Graph -Force

# Exchange Online Management
Install-Module -Name ExchangeOnlineManagement -Force

# Secret Management (for Get-OrCreateSecret)
Install-Module -Name Microsoft.PowerShell.SecretManagement -Force
Install-Module -Name Microsoft.PowerShell.SecretStore -Force
```

## Troubleshooting

**Profile not loading:**
- Verify symlink or copy location: `Test-Path $PROFILE`
- Check execution policy: `Get-ExecutionPolicy` (should be RemoteSigned or Unrestricted)

**Functions not available:**
- Check if module files exist: `Get-ChildItem (Split-Path $PROFILE)\Common\`
- Run with verbose: `$VerbosePreference = "Continue"; . $PROFILE`

**M365 functions not loading:**
- Verify Microsoft.Graph module: `Get-Module -ListAvailable -Name Microsoft.Graph`
- Install if missing: `Install-Module -Name Microsoft.Graph -Force`
