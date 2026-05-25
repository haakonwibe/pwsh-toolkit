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
git clone https://github.com/<your-fork>/pwsh-toolkit.git C:\Tools\pwsh-toolkit
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
| **`j`** | Interactive folder jumper — picker with digit shortcuts (1-9 instant), arrow keys + Enter, Esc cancel. Renders on the terminal's alternate screen buffer so scrollback is preserved. `j <substring>` skips the picker for a direct fuzzy jump. |
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
| **`ask <question>`** | Quick reference via the ch.at API. `ask -Brief "..."` for one-line answers. |
| **`docs` / `desktop` / `downloads` / `onedrive` / `home`** | Named navigation shortcuts. OneDrive paths auto-detect your Business org from `$env:OneDriveCommercial`. |
| **`tip`** | Re-roll the rotating profile tip. Set `$env:PSPROFILE_NO_TIPS=1` to silence at startup. |
| **`ll` / `la` / `touch` / `which`** | The shell-script staples. |

**M365 helpers** (loaded only if `Microsoft.Graph` is installed): `Connect-Graph`, `Connect-Exchange`, `Get-TenantOverview`, `Disconnect-Graph`, `Disconnect-Exchange`.

---

## Screenshots

*(Coming soon — `j`, `peek`, `df`, `winup`, and the OMP prompt are the obvious candidates. Drop PNGs in `docs/screenshots/` and reference them here.)*

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
