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
│   ├── Json.ps1                       # JSON viewer with syntax highlighting (json)
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
- `ask <question>` - Quick reference via ch.at (30s request timeout)
- `ll` - List files with details
- `la` - List all files, including hidden and system entries
- `lh` - List *only* the hidden and system entries (the inverse of `ll`)
- `touch <file> [more...]` - Create the file(s) if absent, or bump the timestamp without truncating if they already exist. Accepts relative/absolute paths and creates missing parent directories
- `which <command>` - Show what backs a command: the on-disk path for executables/scripts, the resolved target for aliases (`ls -> Get-ChildItem`), or a kind label for cmdlets/functions

**Navigation:**
- `docs` - Jump to OneDrive Documents
- `desktop` - Jump to OneDrive Desktop
- `downloads` - Jump to Downloads folder
- `onedrive` - Jump to OneDrive root
- `home` - Jump to user profile
- `mkcd <dir>` - Create a directory (and any parents) and change into it
- `up [n]` - Move up `n` parent directories (default 1); `..` / `...` are one/two-level shortcuts

OneDrive paths use `$Config.OneDriveOrg` (auto-detected from `$env:OneDriveCommercial` when unset). Set `OneDriveOrg = ''` in `config.psd1` to force personal OneDrive.

**Folder Jumper:**
- `j` - Interactive picker with digits 1-9 for instant jump, Up/Down + Enter to navigate, Esc to cancel. Renders on the terminal's alternate screen buffer so scrollback is preserved on exit
- `j <substring>` - Skip the picker entirely. Case-insensitive substring match against both label *and* path, takes the first hit. The minimum unique prefix works — e.g. `j d` → Downloads (first match), `j prog` → ProgramData, `j local` → LocalAppData, `j main` → main repo, `j github` → GitHub root (matches the path, not the label)
- `jb` / `jf` - Browser-style back/forward through visited folders (per-session)
- Tab completion: `j <TAB>` cycles destination labels (substring match, path as tooltip); `j -Remove <TAB>` offers only your own bookmarks
- `j -Add` - Bookmark the current directory (label defaults to the folder's leaf name); `j -Add <path> -Label <name>` bookmarks a specific folder. `j -Remove <label>` drops one. Bookmarks persist to `%LOCALAPPDATA%\pwsh-toolkit\jump-bookmarks.json` and load at every shell start — the no-friction way to add favorites, no file editing. Re-adding a label repoints it; it won't shadow or remove a built-in/config destination
- Built-in destinations: Home, Downloads, OneDrive, LocalAppData, ProgramData. For favorites, prefer `j -Add`. For version-controlled literals use `config.psd1`'s `ExtraJumpFolders`; for anything needing evaluation (env vars, conditional paths) append in `Machines/<COMPUTERNAME>.ps1`: `$script:JumpFolders += [pscustomobject]@{ Label='VMs'; Path='D:\VMs' }`

**Git Projects:**
- `prj` - Scrollable picker over git repos found under your `ProjectRoots`, with the current branch shown (read straight from `.git/HEAD`, no `git` subprocess). Up/Down, PgUp/PgDn, Home/End to move, Enter to jump (via `jb`/`jf` history), Esc to cancel; each row has a single-key jump label (`1`-`9` then `a`-`z`, up to 35 items). Built on the shared `Show-Picker` (alternate screen buffer, viewport scrolling for long lists)
- `prj <name>` - Jump directly by case-insensitive name/path substring match
- `prj -Refresh` - Rescan the roots (the repo list is cached per session)
- Roots come from `config.psd1`'s `ProjectRoots` (literals only); empty falls back to `C:\GitHub` if it exists. Repos are found up to four directories deep under each root

**Archive Peek:**
- `peek <archive>` - Extract to `$env:TEMP\peek\<name>-<timestamp>` and `Set-Location` there. If the archive unpacks to a single top-level folder, jumps directly into that folder
- `peek -List <archive>` - Show contents without extracting
- `peek -Active` - List currently-extracted peeks (name, size, when, path)
- `peek -Clean` - Wipe the peek temp tree (walks you out first if you're standing inside it)
- `jb` - Jump back to where you peeked from (integrates with the folder jumper)
- Tool dispatch: `.rar` → WinRAR's `Rar.exe`/`UnRAR.exe` (RAR-only by design); everything else → 7-Zip (`7z.exe`) which handles ZIP, 7Z, TAR.GZ, ISO, CAB, WIM, etc. Falls back to built-in `Expand-Archive` for `.zip` if neither tool is present. Auto-finds both in their default install dirs (`C:\Program Files\WinRAR\`, `C:\Program Files\7-Zip\`) if not on PATH

**JSON viewer (json):**
- `json <file.json>` - Pretty-print and syntax-highlight a JSON file. Keys, string values, numbers, `true`/`false`/`null`, and punctuation each get their own color. Minified or untidy JSON is reflowed to readable indentation
- `… | json` - Pipe in JSON text (`gh api … | json`) or any object (`Get-Process | json`); a lone string is treated as JSON text, objects are serialized first with `ConvertTo-Json`
- `json <file> -Raw` - Show the text exactly as-is (no reflow), preserving original layout and JSONC `//` comments
- `-NoColor` forces plain output; output is also plain (uncolored) automatically when redirected or piped, so `json data.json > pretty.json` writes a clean reformatted file. `-Depth` (default 32) bounds object/round-trip serialization. Input that isn't valid JSON is shown as-is with a warning rather than failing

**Winget Upgrade:**
- `winup` - Interactive winget upgrade picker (Space toggles, A toggles all, Enter confirms). Upgrades only what you select
- `winup -All` - Skip the picker and upgrade everything
- `winup -Elevated` - Re-run elevated via a real `sudo` (gsudo / Windows' built-in `sudo`, else a new elevated window) so you approve one UAC prompt instead of one per package. Extra args pass through (e.g. `winup -Elevated -All`)
- Upgrading PowerShell itself can't happen in-process (Restart Manager would close the running session), so it's deferred to a detached process and the rest of the batch completes first; its result lands in a `…-deferred.log` side file
- CMTrace-XML logs land in `C:\ProgramData\WingetUpgrade\Logs\`. Implementation in `WingetUpgrade/Invoke-WingetUpgrade.ps1`

**Downloads (AI tagging, sorting + viewing):**
- `tagdl [-Limit N]` - Tag files in Downloads with FILE_ID.DIZ-style AI descriptions, stored as NTFS alternate data streams plus a CSV index. Uses the `Anthropic-API-Key` SecretStore secret (env `ANTHROPIC_API_KEY` fallback). Implementation in `DownloadsOrganizer/`
- `sortdl` - File the tagged downloads at the Downloads root into `~\Downloads\<Bucket>\` subfolders (reads `tagdl`'s CSV index; nothing ever leaves Downloads). Previews the move plan and asks before moving; `sortdl -WhatIf` previews only, `-Yes` skips the prompt, `sortdl -Undo` reverses the last sort. `Other` and untagged files stay at the root. Implementation in `DownloadsOrganizer/`
- `dird [path]` - Directory listing showing those AI descriptions, color-coded by extension and bucket (alphabetical). `dird -GroupByBucket`, `dird -Bucket Installers`
- `fr [path]` - Same as `dird`, newest-first (BBS-style "filelisting reverse")

**System Utilities:**
- `Get-PubIP` - Show public IP addresses (IPv4 & IPv6)
- `Get-Uptime` - Show system uptime
- `Get-SysInfo` - At-a-glance panel: host/user, OS (accurate Windows 11 edition + display version + build), uptime, CPU (cores/threads), memory with a colored usage bar, GPU(s), and machine model
- `Find-File <name>` - Recursive file search
- `Start-AdminTerminal` - Launch new admin terminal
- `sudo <command>` - Run a command elevated. Delegates to a real `sudo` if available (gsudo, then Windows' built-in `sudo` when enabled) so it runs in the current window; falls back to a new elevated window otherwise. No-arg opens an elevated shell; `-Verbose` shows the chosen backend
- `df` - Disk free overview with colored usage bars (green ≤70%, yellow 71-89%, red ≥90%). Fixed drives only by default; `df -All` adds removable, network, and CD-ROM. Sorted by drive letter
- `Format-ByteSize <bytes>` - Format a byte count as a human-readable size (e.g. `31.5 GB`). `-DecimalUnits` picks which units get a decimal, `-Width` right-aligns for tables. Shared by `Get-SysInfo` and `df`

**Remote Servers:**
- `rdp [name]` - Remote Desktop (mstsc). No arg opens a picker over `config.psd1`'s `RemoteServers`; `rdp <name>` fuzzy-matches label/address first, then falls back to a literal address (so `rdp 10.0.0.5` works without a bookmark)
- `rps [name]` - Same picker/matching, but PowerShell Remoting (Enter-PSSession). Pre-fills `Get-Credential` from the entry's `User`; translates WinRM failures into specific fixes (TrustedHosts, access denied, unreachable)

**Notes / Journal:**
- `note "text"` - Append a timestamped bullet to today's `YYYY-MM-DD.md` under `NotesRoot` (file created with a header on first write)
- `today` - Open today's note in your default `.md` app (alias of `note` with no args)
- `Find-Note "query"` - Grep across every daily note; returns file + line number + matching line
- `Set-NotesRoot` - Interactive picker over detected locations (Obsidian vaults, OneDrive Documents, local Documents); applies for the session and prints the `config.psd1` snippet. `NotesRoot` auto-detects via a cascade when unset

**Explain errors (wtf):**
- `wtf` - Explain the last error (`$Error[0]`) in plain English with a likely fix, via Claude Haiku (~$0.001/call). `wtf "<text>"` explains arbitrary text; `$Error[0] | wtf` and `Some-Command 2>&1 | wtf` pipe in. Uses the `Anthropic-API-Key` SecretStore secret (env `ANTHROPIC_API_KEY` fallback)

**Oh My Posh themes (when `Prompt = 'OhMyPosh'`):**
- `Update-PoshThemes` - Download the full official theme gallery (~120 themes) into a local cache at `%LOCALAPPDATA%\pwsh-toolkit\PoshThemes` (regenerable; not committed to the repo). Re-run after upgrading oh-my-posh
- `Set-PoshTheme [name]` - Picker over all themes plus a Random entry; applies the choice live and prints the `config.psd1` snippet to persist it. `Set-PoshTheme atomic` applies directly; `Set-PoshTheme Random` switches to random-each-shell
- `Get-PoshTheme` - Report the theme this shell is using (handy in Random mode — tells you what to pin)
- Set `OhMyPoshTheme = 'Random'` in `config.psd1` for a different theme each shell; the loader names the one it rolled (`prompt theme: <name>`) so you can `Set-PoshTheme <name>` to keep it

**Windows Terminal:**
- `Get-TerminalFont` - Report the font face Windows Terminal uses for the PowerShell profile (its override if set, else the default). `-Verbose` shows the breakdown
- `Set-TerminalFont '<name>'` - Change the font face in `settings.json` via a targeted, value-only edit (backs up to `settings.json.bak`, validates the result is valid JSON, and leaves the rest of the file untouched rather than reflowing it). Terminal reloads automatically; `-WhatIf` previews. Handles the common single-font case — for no font set, or multiple per-profile overrides, it tells you to use the Terminal UI / edit by hand

**Secret Management:**
- `Get-OrCreateSecret -Name "API-Key" [-AsPlainText]` - Get or create secure secret
- `Get-StoredSecrets` - List all stored secrets
- `Remove-StoredSecret -Name "API-Key"` - Remove a secret

**Command catalog (discovery):**
- `toolkit` - Print every toolkit command grouped by area, each with a one-line synopsis — the "what can I do here?" overview (alias for `Show-Toolkit`)
- `Get-ToolkitCommand` - The same data as objects (Command, Group, Synopsis, Function, Alias) for piping/filtering — the toolkit's `Get-Command -Module` equivalent, since it ships as a profile rather than a module
- Both take `-All` to include internal helper functions. Commands are discovered by AST-parsing the toolkit's own source files at runtime, so the catalog never drifts from reality

**Profile Tip:**
- A rotating two-line tip is shown at every shell startup, reminding you of one of the helpers in this profile. Catalog lives in `Common/Tips.ps1` (~35 entries covering the jumper, projects, peek, df, winup, tagdl, system utils, secrets, remote servers, notes, Oh My Posh themes, Terminal font, M365, etc.)
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
- `Connect-Tenant` - Connect to Microsoft Graph with preset scopes covering directory *and* Intune at each tier. Read-only by default (reporting plus Intune device/policy/app/script/RBAC reads); `-Access Write` adds user/group management and the day-to-day Intune writes; `-Access Full` adds directory and app-registration writes, Intune RBAC/service-config writes, and privileged device actions (wipe, passcode reset)
- `Disconnect-Tenant` - Disconnect from Microsoft Graph

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
- `ConsoleHost` - Plain pwsh — a regular console window, Windows Terminal, or a plain VS Code terminal (branch on `$env:WT_SESSION` / `$env:TERM_PROGRAM` inside `ConsoleHost.ps1`)
- `VisualStudioCodeHost` - The VS Code PowerShell extension's integrated console

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
