# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.22] - 2026-05-25

### Reverted

- **Rolled back v0.1.19, v0.1.20, and v0.1.21's escalating workarounds for the Electron-stderr "leak" in `today` / `note` (no-args).** The original `Invoke-Item -LiteralPath $notePath` is back. The Chromium `jump_list.cc` warnings from some Electron handlers (Typora was the reported case) are:
  - Harmless — the note still opens, the editor works fine
  - Out of our control once the handler app calls `AttachConsole(ATTACH_PARENT_PROCESS)` at runtime
  - Fixable on the user side by either (a) using a different `.md` handler that doesn't emit them (Obsidian, VS Code, Notepad) or (b) enabling "Show recently opened items in Jump Lists" in Settings → Personalization → Start
- Three releases of `Start-Process` → `ProcessStartInfo+UseShellExecute` → `cmd /c start` were premature optimization for cosmetic noise. The simpler `Invoke-Item` is idiomatic PowerShell for "open this file with the default app," and that's what's back.

### Lesson noted

Polish is good; chasing cosmetic noise from third-party apps' Chromium internals across multiple releases is over-fitting. If a future helper opens an external app, default to `Invoke-Item` — only escalate when there's an actual behavior bug (file doesn't open, app crashes, etc.), not just verbose-but-harmless stderr.

## [0.1.21] - 2026-05-25

### Fixed

- **`today` / `note` (no-args) third time's the charm — Electron stderr is genuinely contained now.** v0.1.19's `Start-Process` and v0.1.20's `ProcessStartInfo+UseShellExecute` both relied on "don't pass console handles to the spawned process," which sounds sufficient but isn't: Electron apps call `AttachConsole(ATTACH_PARENT_PROCESS)` at runtime, grabbing whatever console exists in the parent chain regardless of what was inherited at launch time. The fix is to ensure no parent console exists when that API call fires. Switched to launching through `cmd /c start "" "<file>"` with `-WindowStyle Hidden` — cmd dispatches the `start` command and exits immediately, so by the time Typora/Obsidian/VS Code's `AttachConsole` call runs, its parent (cmd) is gone and there's no console to attach to. Classic Windows fire-and-forget idiom; same shell association lookup as before.

## [0.1.20] - 2026-05-25

### Fixed

- **`today` / `note` (no-args) now really doesn't leak Electron warnings.** v0.1.19 switched from `Invoke-Item` to `Start-Process` on the theory that Start-Process gives the spawned app its own output handles — turned out not enough. PowerShell's `Start-Process` for documents still inherits parent console handles in some configurations, so Chromium's `jump_list.cc` errors kept spilling into the shell at random intervals (both before AND after the prompt returned). Switched to the explicit Win32 ShellExecuteEx path via `[System.Diagnostics.ProcessStartInfo]` with `UseShellExecute = $true` — the same code path File Explorer uses on double-click. ShellExecute provably does NOT pass console handles to the spawned process, so Chromium's stderr writes go to NUL and the shell stays clean. The associated app (Typora, Obsidian, VS Code, whatever) opens identically.

## [0.1.19] - 2026-05-25

### Fixed

- **`today` / `note` (no-args) no longer leaks Electron warnings into the shell.** Was using `Invoke-Item`, which spawns the associated app (Obsidian, VS Code, etc.) but leaves its stderr attached to the parent terminal. Electron-based editors emit Chromium-style log messages on launch (`Failed to append custom category 'Recent Locations' to Jump List due to system privacy settings`, GPU cache warnings, etc.) that are harmless but visually noisy. Switched to `Start-Process -FilePath`, which spawns the app with its own output handles — those internal warnings stay in the launched process and the parent shell stays clean.

## [0.1.18] - 2026-05-25

### Changed

- **`Resolve-NotesRoot` cascade simplified from 6 steps to 4** — the previous v0.1.17 logic preferred OneDrive-located Obsidian vaults over the user's actually-open vault, which violates Obsidian's local-first ethos. Many Obsidian users deliberately keep vaults local; quietly steering their notes into OneDrive would be exactly the wrong default for that audience. New cascade respects Obsidian-as-source-of-truth:
  1. Obsidian vault flagged `"open": true` in `obsidian.json` → `<vault>\Daily`
  2. Most-recently-touched Obsidian vault → `<vault>\Daily`
  3. OneDrive (Commercial preferred, then Consumer) → `Documents\Notes`
  4. Local `<$env:USERPROFILE>\Documents\Notes` (fallback)
- The principle: if you have Obsidian configured with a vault open, that's where you're working — whether that vault is local or in OneDrive is YOUR choice in Obsidian, not something the cascade should second-guess. Sync via OneDrive is the fallback for users who don't have Obsidian configured at all.
- `config.example.psd1` comment block updated with the new cascade + philosophy paragraph.
- Get-ObsidianVault still filters by `Test-Path -LiteralPath`, so a stale "open" entry pointing at a missing path falls through to step 2 naturally.

## [0.1.17] - 2026-05-25

### Changed

- **`NotesRoot` now auto-detects via a cascade instead of defaulting to `~\Documents\Notes`** — the previous default was hard to find in Explorer and missed the OneDrive sync story most users actually want. New cascade (in `Resolve-NotesRoot`, called at `Notes.ps1` load time):
  1. Obsidian vault registered inside `$env:OneDriveCommercial` → `<vault>\Daily` (best sync + Obsidian indexing)
  2. Any Obsidian vault flagged `open: true` in `%APPDATA%\obsidian\obsidian.json` → `<vault>\Daily`
  3. `<$env:OneDriveCommercial>\Documents\Notes`
  4. Most-recently-touched Obsidian vault → `<vault>\Daily`
  5. `<$env:OneDriveConsumer>\Documents\Notes` (personal OneDrive)
  6. `<$env:USERPROFILE>\Documents\Notes` (local-only fallback)
- Reads `%APPDATA%\obsidian\obsidian.json` if present (via new `Get-ObsidianVault` helper that filters out vaults whose paths no longer exist).
- The 'Daily' subfolder mirrors Obsidian's daily-notes plugin convention so notes land inside the vault without cluttering its root.

### Added

- **`Set-NotesRoot`** — interactive picker over the auto-detected candidates (Obsidian vaults flagged with `open` / `OneDrive` tags + OneDrive Documents paths + local fallback). User picks; the function updates `$script:Config.NotesRoot` for the current session and prints the snippet to paste into `config.psd1` for persistence (no silent data-file roundtrip).
- **`Get-ObsidianVault`** — reads `obsidian.json`, returns existing vaults with `Path` / `IsOpen` / `Ts` fields. Reusable for any future Obsidian integration.

### Updated

- `config.example.psd1` `NotesRoot` comment block now documents the cascade.
- README helper table mentions `Set-NotesRoot`.
- Tips, Smoke.Tests expected-commands list, ARCHITECTURE convention #12.

ARCHITECTURE convention #12 amended: env-var resolution can live in either the loader (simple cases like `ToolkitRoot`) or the relevant Common file (complex cases like `NotesRoot`, which reads obsidian.json and walks a 6-way cascade). The principle stays the same — `config.psd1` is literal-or-`$null`, PowerShell code resolves the rest.

## [0.1.16] - 2026-05-25

### Added

- **ARCHITECTURE convention #11** — AI helpers must instruct plain-text output (LLM responses default to markdown which the console doesn't render) and strip markdown defensively post-receipt. Codifies what we learned writing `wtf` so the next AI helper (`gcm`, etc.) ships with the pattern from day one.
- **ARCHITECTURE convention #12** — `config.psd1` slots are literal strings or `$null`; env-var resolution lives in the loader. Captures the pattern now applied across `ToolkitRoot`, `OneDriveOrg`, `NotesRoot`, and `OhMyPoshTheme`. Also documents the `Machines/<COMPUTERNAME>.ps1` escape hatch for complex per-machine logic.

### Changed

- **Poster daily-driver tile grid** bumped from `lg:grid-cols-7` to `md:grid-cols-5` (dropping the breakpoint so medium and large render the same). Cleaner 5×2 layout for the current 10 tiles vs the previous awkward 7+3.

## [0.1.15] - 2026-05-25

### Changed

- **`wtf` output is now console-formatted, not markdown.** The previous prompt didn't say anything about output format, so Claude defaulted to markdown — `**bold**` headings and triple-backtick code fences came through as literal characters in the PowerShell console. Three improvements:
  - Prompt now explicitly tells Claude "your output prints directly to a PowerShell console; markdown is NOT rendered" with rules against `**`, code fences, `#` headings, and hyphen/asterisk bullet lists. Asks for 4-space indentation on commands instead.
  - Defensive post-process strips common markdown artifacts (`**bold**`, `` `inline` ``, `` ``` `` fences, `#` headings) in case the model lapses anyway.
  - Lines indented 4+ spaces (i.e. command examples) render in cyan, so the eye lands on the runnable bits.

## [0.1.14] - 2026-05-25

### Fixed

- **`Get-OrCreateSecret` no longer fails on first-time vault registration in a fresh shell** — the v0.1.10 passwordless-by-default change called `Initialize-SecretStore` right after `Register-SecretVault`, but `Register-SecretVault` only records the module as a vault provider without importing its cmdlets, so `Initialize-SecretStore` could throw "term not recognized" on the very call meant to configure the freshly-registered vault. The outer catch then bailed out with `return $null`, even though the vault WAS successfully registered and the secrets were retrievable.

  Fix: explicit `Import-Module Microsoft.PowerShell.SecretStore` before the `Initialize-SecretStore` call, plus an inner try/catch so that any remaining auto-config failure (e.g. pre-existing password-protected store from before v0.1.10) is swallowed silently — the vault is still registered and the rest of the function proceeds. Users with existing setups are unaffected; users on fresh machines no longer hit a confusing "Failed to set up SecretStore vault" warning followed by a "No Anthropic API key found" message when the key was right there.

## [0.1.13] - 2026-05-25

### Added

- **`note` / `today` / `Find-Note`** — lightweight markdown journal. `note "thing"` appends a timestamped bullet to `<NotesRoot>/YYYY-MM-DD.md` (file is auto-created with a daily header on first touch). `today` is an alias for `note`; calling `today` with no args opens the file via `Invoke-Item` which lets your default `.md` handler take over — Obsidian, VS Code, Notepad, whatever's configured. Point `NotesRoot` at an Obsidian vault subfolder to write directly into it; Obsidian picks the file up as soon as it appears. `Find-Note "query"` greps across every note with `Select-String`, returning filename + line number + matched line. New file: `Profiles/Common/Notes.ps1`.
- **`NotesRoot` slot in `config.example.psd1`** (literal-path only, like every other config field) plus hard-fallback default in the loader → `~\Documents\Notes` auto-created on first `note` call.

## [0.1.12] - 2026-05-25

### Added

- **`wtf`** — pipe the last `$Error` (or any text) to Claude Haiku and get back a plain-English explanation + likely fix. Three invocation modes: `wtf` with no args explains `$Error[0]`; `wtf "<pasted error>"` explains arbitrary text; `$Error[0] | wtf` and `Some-Command 2>&1 | wtf` accept pipeline input (ErrorRecord or anything else). Reuses the `Anthropic-API-Key` SecretStore convention with `$env:ANTHROPIC_API_KEY` fallback. Costs ~$0.001 per call on Haiku 4.5. New file: `Profiles/Common/Wtf.ps1`.

## [0.1.11] - 2026-05-25

### Fixed

- **`df` Label column width is now dynamic** — sized to the longest label in the current result set, bounded by the `'Label'` header length (5) on the low end and 30 on the high end. The previous hardcoded width of 12 truncated any label longer than 11 characters (e.g. `🗄️ DeepStorage` → `🗄️ DeepStora…`). Format strings updated to interpolate the computed width.

### Known limitation

- Emoji-prefixed labels still nudge alignment slightly because emoji count as 1-2 `.Length` characters in PowerShell but render as 2 terminal cells. Fully wcwidth-aware padding is a separate rabbit hole, deliberately left unfixed; the widened column makes the issue cosmetic rather than functional.

## [0.1.10] - 2026-05-25

### Changed

- **`Get-OrCreateSecret` now configures SecretStore in passwordless mode (`Authentication None`) on first-time vault setup.** DPAPI already binds the vault file to the Windows user account; the optional vault password was second-factor theater that added friction (per-session prompt) without meaningfully changing the threat model on a personal machine. Users wanting the extra layer can switch with `Initialize-SecretStore -Authentication Password` after setup. Existing vaults are untouched — the new default only applies to fresh installs that haven't registered the vault yet.
- **README Security section updated** to reflect the new default. The previous "low-friction setup" paragraph (manual `Initialize-SecretStore -Authentication None`) is now redundant; replaced with an "if you want the extra layer" hint pointing at the Password mode.

## [0.1.9] - 2026-05-25

### Added

- **Screenshots in the README.** Five shots captured against a clean Windows Terminal + MesloLGMDZ Nerd Font Mono + `Prompt = 'OhMyPosh'` (the post-`install.ps1 -InstallOhMyPosh` baseline): prompt-with-tip hero, `j` picker mid-selection, `df` with colored usage bars, `peek -List` output, and `winup` picker with toggled selections. README's `## Screenshots` section now renders inline image blocks with short captions for each.
- **`docs/screenshots/CAPTURE-GUIDE.md`** — terminal-setup spec, capture-tool recommendations, and per-shot instructions. Persistent in the repo so future contributors can retake or extend the set against the same baseline.

## [0.1.8] - 2026-05-25

### Added

- **`## Connecting to remote hosts` section in README** — target-side setup commands for RDP (`Set-ItemProperty fDenyTSConnections` + `Enable-NetFirewallRule`) and PSRemoting (`Enable-PSRemoting`), the cross-domain `Set-Item WSMan:\localhost\Client\TrustedHosts` step for non-domain targets, and sanity-check one-liners (`Test-NetConnection`, `Test-WSMan`). Closes the "what do I run on the target?" gap left by v0.1.4.
- **`Format-PsRemotingError`** in `Profiles/Common/RemoteServers.ps1`. `rps` now catches `Enter-PSSession` failures and renders a short remediation for the three common first-time-setup errors: TrustedHosts (prints the exact `Set-Item WSMan:\…` command with the address pre-filled), Access Denied (creds / group membership hint), and unreachable / WinRM-not-running (`Test-NetConnection` + `Enable-PSRemoting` hints). Unknown errors fall through to the original message so nothing is hidden.
- **`ARCHITECTURE.md` convention #10** — "Name-lookup helpers are bookmarks, not whitelists." Captures the bookmark-vs-fallthrough pattern from `j`/`rdp`/`rps` so any future "lookup by name" helper ships with it from day one instead of taking three releases to converge.

### Changed

- `rps` adds `-ErrorAction Stop` to its splatted `Enter-PSSession` call so WinRM non-terminating errors get promoted into the new catch handler.

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

[Unreleased]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.22...HEAD
[0.1.22]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.21...v0.1.22
[0.1.21]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.20...v0.1.21
[0.1.20]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.19...v0.1.20
[0.1.19]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.18...v0.1.19
[0.1.18]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.17...v0.1.18
[0.1.17]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.16...v0.1.17
[0.1.16]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.15...v0.1.16
[0.1.15]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.14...v0.1.15
[0.1.14]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.13...v0.1.14
[0.1.13]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.12...v0.1.13
[0.1.12]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.11...v0.1.12
[0.1.11]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.10...v0.1.11
[0.1.10]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/haakonwibe/pwsh-toolkit/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/haakonwibe/pwsh-toolkit/releases/tag/v0.1.0
