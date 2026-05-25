# pwsh-toolkit

<p align="center">
  <a href="https://haakonwibe.github.io/pwsh-toolkit/poster.html"><strong>📊 View the project poster →</strong></a>
</p>

A modular PowerShell profile system + toolkit for Windows. Folder jumper, archive previewer, disk-free overview, interactive winget upgrade picker, AI-tagged Downloads viewer, and a rotating tip system — all wired up through one config-driven loader.

This is a **personal-but-public** setup. It's what I actually run on my own machines; the install script is for anyone who finds something here useful. Not a generic framework, not aiming to be Oh My Posh-scale.

**Windows-only**, **PowerShell 7+**. macOS / Linux is a future stretch goal, not a present commitment.

---

## Quickstart

```powershell
git clone https://github.com/haakonwibe/pwsh-toolkit.git C:\Tools\pwsh-toolkit
cd C:\Tools\pwsh-toolkit
.\install.ps1
```

That's it. The installer will ask whether you also want to set up Oh My Posh (installs `oh-my-posh`, the Meslo Nerd Font, and the `Terminal-Icons` module, and flips your config to use OMP). Answer yes for the polished prompt; no to keep the dependency-free custom prompt. Open a new PowerShell tab to see the result.

Under the hood, the installer creates a symbolic link from your `$PROFILE` to `Profiles/pwsh-toolkit-profile.ps1` if it can (admin or Windows Developer Mode), and falls back to a dot-source stub otherwise. Either way, edits inside the repo are picked up by every new shell — no re-install needed.

```powershell
# Common installer variants
.\install.ps1 -InstallOhMyPosh   # one-shot polished install (skip the interactive prompt, just do it)
.\install.ps1 -SkipOhMyPosh      # skip the OMP prompt non-interactively (keeps Prompt = 'Custom')
.\install.ps1 -AllHosts          # load in pwsh, VS Code, ISE, ... from one install
.\install.ps1 -Stub              # force the no-admin dot-source stub even if symlinks would work
.\install.ps1 -WhatIf            # dry-run — show what would change without doing it
.\install.ps1 -Uninstall         # remove the $PROFILE entry (repo + config.psd1 untouched)
```

After an OMP install, set your terminal font to a Meslo Nerd Font variant — **MesloLGMDZ Nerd Font Mono** is the recommended pick (Windows Terminal: Settings → Profiles → Defaults → Appearance → Font face).

---

## What you get

| Helper | What it does |
|---|---|
| **`j`** | Interactive folder jumper — picker with digit shortcuts (1-9 instant), arrow keys + Enter, Esc cancel. Renders on the terminal's alternate screen buffer so scrollback is preserved. `j <name>` skips the picker for a direct fuzzy jump against your configured bookmarks; if no bookmark matches, falls through to treating the argument as a literal directory path, so `j C:\Some\Path` works too. |
| **`jb` / `jf`** | Browser-style back/forward through visited folders, per session. |
| **`peek <archive>`** | Extracts an archive to `$env:TEMP\peek\<name>-<timestamp>` and jumps you there. Dispatches to WinRAR for `.rar`, 7-Zip for everything else, `Expand-Archive` for `.zip` if neither is installed. `peek -List`, `peek -Active`, `peek -Clean` for the obvious variants. |
| **`df`** | Disk-free overview with colored usage bars (green ≤70%, yellow 71-89%, red ≥90%). Fixed drives by default; `df -All` includes removable, network, and CD-ROM. |
| **`winup`** | Interactive winget upgrade picker. Space to toggle, A toggles all, Enter to confirm. `winup -All` skips the picker. Logs to `C:\ProgramData\WingetUpgrade\Logs\` in CMTrace XML format. |
| **`tagdl`** | Scans `~\Downloads`, calls Claude Haiku with a structured-output schema, writes a description to each file's NTFS Alternate Data Stream `:description` + a portable `_downloads-index.csv`. Costs ~$0.001 per file. Caches results. |
| **`dird` / `fr`** | Directory listings with the AI descriptions from `tagdl`, color-coded by extension and bucket. `dird` is alphabetical; `fr` is newest-first ("filelisting reverse" — BBS-style paging). |
| **`Get-PubIP`** | Public IPv4 and IPv6 with multiple service fallbacks. |
| **`Get-Uptime` / `Get-SysInfo`** | How long since last boot; OS + memory + CPU + version. |
| **`Find-File <name>`** | Recursive filename search from the current directory. |
| **`Start-AdminTerminal`** | Launch a new elevated Windows Terminal. |
| **`Get-OrCreateSecret`** | Retrieve a SecretStore secret or prompt to create it. Companion: `Get-StoredSecrets`, `Remove-StoredSecret`. |
| **`rdp` / `rps`** | Remote-server shortcuts driven by `config.psd1`'s `RemoteServers` list. `rdp` launches `mstsc`, `rps` launches `Enter-PSSession`. No arg → picker (digit shortcuts, arrow keys, Esc). `rdp <name-or-address>` → fuzzy match against the configured list first, falling back to treating the argument as a literal address (so `rps 10.0.0.2` and `rdp myhost.lab` work without adding bookmarks first). |
| **`ask <question>`** | Quick reference via the ch.at API. `ask -Brief "..."` for one-line answers. |
| **`wtf`** | Ask Claude Haiku what went wrong with the last error. No-arg explains `$Error[0]`; `wtf "<pasted error>"` works on arbitrary text; `$Error[0] \| wtf` and `Some-Command 2>&1 \| wtf` pipe in. Reuses the `Anthropic-API-Key` SecretStore convention. ~$0.001 per call. |
| **`docs` / `desktop` / `downloads` / `onedrive` / `home`** | Named navigation shortcuts. OneDrive paths auto-detect your Business org from `$env:OneDriveCommercial`. |
| **`tip`** | Re-roll the rotating profile tip. Set `$env:PSPROFILE_NO_TIPS=1` to silence at startup. |
| **`ll` / `la` / `touch` / `which`** | The shell-script staples. |

**M365 helpers** (loaded only if `Microsoft.Graph` is installed): `Connect-Graph`, `Connect-Exchange`, `Get-TenantOverview`, `Disconnect-Graph`, `Disconnect-Exchange`.

---

## Screenshots

Captured against a clean Windows Terminal with **MesloLGMDZ Nerd Font Mono** and `Prompt = 'OhMyPosh'` — i.e. exactly what `install.ps1 -InstallOhMyPosh` gives you. See [`docs/screenshots/CAPTURE-GUIDE.md`](docs/screenshots/CAPTURE-GUIDE.md) if you want to retake or extend.

### The shell at rest

![pwsh-toolkit prompt with a startup tip](docs/screenshots/prompt-hero.png)

A fresh tab: rotating profile tip on top, the polished Oh My Posh prompt with `pwsh` + user + battery + clock segments below.

### Folder jumper (`j`)

![j picker showing bookmark destinations](docs/screenshots/j-picker.png)

Press `1`-`9` for an instant jump, or arrow + Enter. Renders on the terminal's alternate screen buffer so your scrollback stays intact when the picker exits. `j <text>` (or any literal path) skips the picker entirely.

### Disk-free overview (`df`)

![df with colored usage bars](docs/screenshots/df.png)

Fixed drives by default with colored usage bars (green ≤70%, yellow 71-89%, red ≥90%). `df -All` adds removable, network, and CD-ROM drives.

### Archive peek (`peek`)

![peek -List output listing an archive](docs/screenshots/peek-list.png)

Dispatches to WinRAR for `.rar`, 7-Zip for everything else, and falls back to `Expand-Archive` for plain `.zip` if neither is installed. `peek <archive>` extracts to `$env:TEMP\peek\…` and jumps you in.

### Interactive winget upgrade (`winup`)

![winup picker with toggled selections](docs/screenshots/winup.png)

Space to toggle, A toggles all, Enter to confirm. CMTrace-XML logs land in `C:\ProgramData\WingetUpgrade\Logs\`. `winup -All` skips the picker.


---

## Configuration

The installer seeds `Profiles/config.psd1` from `Profiles/config.example.psd1`. Edit it to customize:

```powershell
@{
    Prompt        = 'Custom'              # 'OhMyPosh' | 'Custom' | 'Default'
    OhMyPoshTheme = 'default.omp.json'    # used only when Prompt = 'OhMyPosh'
    ToolkitRoot   = $null                 # $null = auto-detect (parent of Profiles/)
    OneDriveOrg   = $null                 # $null = auto-detect from $env:OneDriveCommercial,
                                          # ''   = personal OneDrive, 'Name' = explicit

    ExtraJumpFolders = @(
        # @{ Label = 'GitHub'; Path = 'C:\GitHub' }
        # @{ Label = 'VMs';    Path = 'D:\VMs'   }
    )

    DisableStartupTips = $false
    Features = @{ DisableM365 = $false }
}
```

For more complex per-machine logic (registering network drives, machine-specific functions, conditional setup), drop a `Profiles/Machines/<COMPUTERNAME>.ps1` — it's dot-sourced after the Common helpers load. Same pattern for `Profiles/Hosts/<HostName>.ps1` for per-host (VS Code, Windows Terminal, ISE) tweaks. See the READMEs in those folders for examples.

`config.psd1` is gitignored — your edits stay local.

---

## Requirements

- **Windows 10/11**
- **PowerShell 7+** (`winget install Microsoft.PowerShell`)
- An **execution policy** that allows local scripts: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

The installer checks PowerShell version and stops with a clear message if you're on 5.1.

## Optional dependencies

The profile loads fine without any of these — the relevant feature just stays dark until you add it.

| Want | Install |
|---|---|
| `Prompt = 'OhMyPosh'` (the polished prompt) | `.\install.ps1 -InstallOhMyPosh` does the whole setup. (Manual: `winget install JanDeDobbeleer.OhMyPosh` + `oh-my-posh font install Meslo --user` + `Install-Module Terminal-Icons`.) |
| `tagdl` (AI Downloads tagger) | `Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore`, then store an `Anthropic-API-Key` secret with `Get-OrCreateSecret -Name 'Anthropic-API-Key'` |
| `peek` for `.rar` / `.7z` / `.tar.gz` / ISO / etc. (not just `.zip`) | `winget install 7zip.7zip` (and/or WinRAR for `.rar`) |
| M365 helpers (`Connect-Graph`, `Get-TenantOverview`) | `Install-Module Microsoft.Graph, ExchangeOnlineManagement` |

---

## Security

Secrets used by helpers like `tagdl` are stored via [Microsoft.PowerShell.SecretStore](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.secretstore), which encrypts at rest using Windows DPAPI. The encryption keys are tied to your Windows user account.

**What this protects against:** accidental commits of API keys (secrets live in `%LOCALAPPDATA%`, never in the repo), env-var leaks via process listings (`Get-Process` won't show them), and access by other Windows users on the same machine.

**What it does NOT protect against:** compromise of your Windows user account (DPAPI keys derive from it), process memory inspection by code running as you, or `SecureString` analysis — Microsoft has [formally deprecated `SecureString` as a security boundary in .NET 6+](https://learn.microsoft.com/en-us/dotnet/api/system.security.securestring). Treat it as an obfuscated string, not a vault.

For higher-assurance storage (separate vault password, keys not derived from your Windows account), use a tool like [1Password CLI](https://developer.1password.com/docs/cli/) or [Bitwarden CLI](https://bitwarden.com/help/cli/) and pipe the secret to the wrapper at runtime instead of via `Get-OrCreateSecret`.

**Passwordless by default.** When `Get-OrCreateSecret` first sets up the vault for a new user, it configures `Authentication = None` — DPAPI is the only security boundary, which is honest about what's actually protecting the secrets. No per-session password prompts.

If you want the extra layer (vault password on top of DPAPI), run once after setup:

```powershell
Initialize-SecretStore -Authentication Password
```

Existing vaults aren't touched — the default only applies on first-time vault creation. To change an already-configured vault, use the command above (with the current password if there is one).

## Connecting to remote hosts

`rdp` and `rps` are thin wrappers — the targets still need the right server-side bits enabled. Quick reference:

### RDP target setup

Run elevated on the **target** machine:

```powershell
# Enable RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
# Open the firewall
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
# Optionally let non-admins connect
# Add-LocalGroupMember -Group 'Remote Desktop Users' -Member 'lab\someuser'
```

Windows **Home** SKUs don't include the RDP server; Pro / Enterprise / Server do. Azure VMs typically come with this already enabled.

### PSRemoting target setup

Run elevated on the **target** machine:

```powershell
Enable-PSRemoting -Force
```

That's it for domain-joined targets — Kerberos handles auth automatically when you connect as a domain account. Windows **Server** SKUs have WinRM enabled by default since 2012 R2; Windows 10/11 client SKUs do not, so this one-liner is still needed there.

### Cross-domain / workgroup (TrustedHosts)

When the target isn't in your AD domain (workgroup machine, lab VM, IP-only target), one more step on **this client**:

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'targethost' -Concatenate -Force
```

If you hit this in the wild, `rps` will detect the error message and print this exact remediation command with the target address pre-filled — you can usually just copy/paste from the failure output.

### Sanity checks

```powershell
Test-NetConnection target -Port 3389       # RDP reachable?
Test-NetConnection target -Port 5985       # WinRM HTTP reachable?
Test-WSMan target                          # WinRM actually responding?
```

## Documentation

- **[`Profiles/README.md`](Profiles/README.md)** — module structure, helper reference, installation alternatives
- **[`Profiles/LOADING.md`](Profiles/LOADING.md)** — loader internals, load order, cross-file dependencies. Read this before touching `pwsh-toolkit-profile.ps1`.
- **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** — design decisions and load-bearing conventions. Read this before contributing.
- **[`Profiles/OhMyPosh/README.md`](Profiles/OhMyPosh/README.md)** — OMP prompt segments, theme customization
- **[`Profiles/Machines/README.md`](Profiles/Machines/README.md)** — per-machine configuration examples
- **[`Profiles/Hosts/README.md`](Profiles/Hosts/README.md)** — per-host configuration examples
- **[`CHANGELOG.md`](CHANGELOG.md)** — release history
- **[`IDEAS.md`](IDEAS.md)** — candidate future helpers (`prj`, `recent`, `gcm`, `cb`)

## Future direction

The eventual v2 plan is to split this into a module on PSGallery (`pwsh-toolkit`) + a dotfiles repo importing it (`pwsh-profile`). For day one it's one repo — simpler to fork, simpler to understand, no PSGallery publish gate. v2 is a thought, not a commitment.

## License

MIT. See [LICENSE](LICENSE).
