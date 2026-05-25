# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.7] - 2026-05-25

### Changed

- **`j` (folder jumper) now accepts literal directory paths** when the argument doesn't match a configured bookmark. `j C:\Windows`, `j ~\Documents\Projects\thing`, `j .\subdir` all work — same bookmark-vs-fallthrough pattern just applied to `rdp`/`rps`. `Test-Path -PathType Container` is used so files don't sneak through and trip `Set-Location`. The "no match" error message updated to "no jump destination matching X and no such directory exists" to reflect both lookup paths.

### Added

- Three new Pester smoke tests for the `j` literal-path fallthrough: real directory → jumps there with zero errors; non-matching name with no real directory → friendly message, zero `$Error` entries. `Push-Location`/`Pop-Location` wrap the probe calls so the test runner's working directory isn't disturbed.

## [0.1.6] - 2026-05-25

### Changed

- **`rdp` and `rps` now accept ad-hoc addresses.** When the argument doesn't match a configured `RemoteServers` entry, it's used as a literal address. `rps 10.0.0.2`, `rdp myhost.lab`, `rps build-server` all work without needing to add a bookmark first — the config list is now treated as bookmarks, not a whitelist.
- The empty-config friendly message (from v0.1.5) is now only shown on the no-arg picker path. With an explicit address, `rdp`/`rps` skip the config check entirely and connect directly.
- Display format adapts: configured entries show `Label (Address)`; ad-hoc addresses show just the address.

### Added

- Internal `Resolve-RemoteServer` helper that owns the match-or-fallthrough logic, replacing duplicated code in `rdp` and `rps`.
- Two new Pester smoke tests asserting the ad-hoc fallthrough resolves correctly and produces no errors.

## [0.1.5] - 2026-05-25

### Fixed

- `rdp` and `rps` with no `RemoteServers` configured no longer crash with a confusing parameter-binding error (`Cannot bind argument to parameter 'Servers' because it is an empty collection`). They now print a friendly multi-line "no servers configured" message with a copy-pasteable config example. Affects users who haven't yet edited `config.psd1` after installing — the most common first-run state.

### Added

- New `Test-RemoteServersConfigured` helper in `Profiles/Common/RemoteServers.ps1`. Called at the top of `rdp` and `rps` so empty-config users get the helpful guidance instead of an arg-binding failure. Picker's `$Servers` parameter is no longer `Mandatory`, eliminating the original error path entirely.
- Two new Pester smoke tests asserting `rdp` and `rps` produce zero `$Error` entries when called with an empty `RemoteServers` list — regression-tests the friendly empty-state UX.

## [0.1.4] - 2026-05-25

### Added

- **`rdp` and `rps`** — remote-server shortcuts driven by a new `RemoteServers` list in `config.psd1`. No-arg invocation opens the same alt-screen-buffer picker as `j` (digit shortcuts 1-9, arrow nav, Esc cancel). `rdp <name>` and `rps <name>` do fuzzy matching against label or address.
  - `rdp` launches `mstsc /v:<address>` (Windows handles the credential prompt; use Credential Manager / `cmdkey` to persist).
  - `rps` launches `Enter-PSSession -ComputerName <address>`. When an entry has a `User` field, `rps` pre-fills `Get-Credential` with that username.
  - No credential helpers in v1 — let Windows / `Get-Credential` prompt as needed.
- `RemoteServers = @()` slot in `config.example.psd1` with commented example entries, plus a hard-fallback default in the loader so `$Config.RemoteServers` is always at least an empty array.

## [0.1.3] - 2026-05-25

### Added

- `.gitignore` now excludes `Profiles/Machines/*.ps1` and `Profiles/Hosts/*.ps1`. These are personal per-machine / per-host customization scripts (real paths, network drive mappings, company OneDrive orgs) and shouldn't ride along to a public repo. The `README.md` files in those folders stay tracked as documentation.

### Changed

- `Profiles/config.example.psd1`: expanded the `ExtraJumpFolders` comment to call out that `Import-PowerShellDataFile` runs in restricted-language mode — only literal strings work. `$env:TEMP`, `"$HOME\dev"`, and cmdlet calls all raise a parse-time error. Dynamic paths belong in `Machines/<COMPUTERNAME>.ps1` (regular PowerShell, dot-sourced after the config).

## [0.1.2] - 2026-05-25

### Added

- **Security section in README** documenting the SecretStore threat model — what DPAPI-backed storage protects against (accidental commits, process-listing leaks, cross-user access), what it doesn't (Windows-account compromise, process memory inspection, `SecureString` analysis after .NET 6's deprecation), and how to opt into low-friction setup via `Initialize-SecretStore -Authentication None`.

### Changed

- `Profiles/Common/SecretManagement.ps1`:
  - **No longer silently steals the `-DefaultVault` slot.** If another vault is already default (enterprise KeyVault integration, 1Password CLI, etc.), `SecretStore` is registered without `-DefaultVault` and a warning is emitted.
  - **Better error reporting** when vault registration fails — surfaces the actual error message instead of blindly retrying.
  - **Non-interactive guard on `Unlock-SecretStore`** — when stdin is redirected (CI, piped input), fails fast with a clear remediation message instead of hanging on the password prompt. Applied to `Get-OrCreateSecret`, `Get-StoredSecrets`, and `Remove-StoredSecret` via a new private helper.
  - **Skips the re-fetch round-trip** in `Get-OrCreateSecret`'s creation path. Converts the in-hand `SecureString` to plaintext in-process instead of round-tripping back through the vault.
- `README.md` quickstart: replaced the `<your-fork>` placeholder in the clone URL with the canonical `haakonwibe/pwsh-toolkit`.

## [0.1.1] - 2026-05-25

### Added

- `docs/poster.html` — landing-page poster (Tailwind, glassmorphism, animated gradient bg) matching the style of [registry-configuration-engine-v1](https://haakonwibe.github.io/registry-configuration-engine-v1/poster.html). Linked from the top of the README. Render via GitHub Pages from the `main` branch's `docs/` folder.

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

[Unreleased]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/haakonwibe/pwsh-toolkit/releases/tag/v0.1.0
