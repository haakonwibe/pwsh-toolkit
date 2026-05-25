# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-25

Initial public release. Extracted and reorganized from a larger private repository, with personal identifiers stripped and a single config-driven loader replacing the previous two duplicate variants.

### Added

- **Profile loader** (`Profiles/pwsh-toolkit-profile.ps1`) with config-driven prompt selection — `Prompt = 'OhMyPosh' | 'Custom' | 'Default'` in `config.psd1`.
- **Config system**: `config.example.psd1` provides committed defaults; `config.psd1` (gitignored) holds user overrides via shallow merge; `ToolkitRoot` and `OneDriveOrg` auto-detect from environment when left at `$null`.
- **Installer** (`install.ps1`) — probes symlink capability and creates a symbolic link when admin or Developer Mode is available, otherwise falls back to a dot-source stub. Supports `-AllHosts`, `-Stub`, `-Force`, `-Uninstall`, `-WhatIf`. Backs up any existing non-pwsh-toolkit `$PROFILE` before replacing.
- **Optional Oh My Posh setup** in the installer — interactive prompt at install time, or `-InstallOhMyPosh` for one-shot polished setup (installs `oh-my-posh` via winget, Meslo Nerd Font, Terminal-Icons module, and flips `Prompt = 'OhMyPosh'` in `config.psd1`). `-SkipOhMyPosh` opts out non-interactively. Each step is idempotent.
- **Common helpers**: `j`/`jb`/`jf` folder jumper with alternate-screen-buffer picker, `peek` archive previewer (RAR/7-Zip/zip dispatch), `df` disk-free with colored usage bars, `winup` interactive winget upgrade picker with CMTrace logging, `tagdl` AI-tagged Downloads describer, `dird`/`fr` description-aware directory listings, `Get-PubIP`, `Get-Uptime`, `Get-SysInfo`, `Find-File`, `Start-AdminTerminal`, `ask` (ch.at quick reference), and ergonomic shortcuts (`ll`, `la`, `touch`, `which`, `home`, `docs`, `desktop`, `downloads`, `onedrive`).
- **Rotating tip system**: 23-entry catalog shown once at shell startup, state cached in `%LOCALAPPDATA%\PSProfile\last-tip.txt` to avoid back-to-back repeats. `tip` re-rolls; `$env:PSPROFILE_NO_TIPS=1` or `DisableStartupTips = $true` silences.
- **M365 helpers** (`M365/*.ps1`) — loaded only when `Microsoft.Graph` is installed and `Features.DisableM365` is false. Includes `Connect-Graph`, `Connect-Exchange`, `Get-TenantOverview`, `Disconnect-Graph`, `Disconnect-Exchange`.
- **SecretStore helpers** — `Get-OrCreateSecret`, `Get-StoredSecrets`, `Remove-StoredSecret`.
- **Per-machine and per-host overrides** via `Profiles/Machines/<COMPUTERNAME>.ps1` and `Profiles/Hosts/<HostName>.ps1`, dot-sourced after Common helpers load.
- **Oh My Posh theme** (`Profiles/OhMyPosh/default.omp.json`) with OS/Shell/User/Admin/M365/Path/Git segments on the left and Node/Python/.NET/Command/Battery/Time on the right. Graph connectivity indicator synced via `PowerShell.OnIdle`.
- **Documentation**: top-level [README.md](README.md), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (design decisions + load-bearing conventions), [`Profiles/LOADING.md`](Profiles/LOADING.md) (loader internals), per-folder READMEs for OhMyPosh/Machines/Hosts.
- **Continuous integration**: PSScriptAnalyzer lint + Pester smoke tests on `windows-latest` via GitHub Actions.

[Unreleased]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/haakonwibe/pwsh-toolkit/releases/tag/v0.1.0
