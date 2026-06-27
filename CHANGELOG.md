# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> The detailed pre-release history (0.1.0–0.1.62) was condensed into the summary
> below when the repository was squashed for its public release.

## [Unreleased]

### Added

- The M365 module gate is now discoverable: `toolkit` lists the Microsoft 365 group as "Not loaded" with the reason (Microsoft.Graph not installed, or `Features.DisableM365`) instead of omitting it, and the loader logs the reason under `-Verbose`.
- Startup tips only suggest commands that exist in the current session, so a machine without Microsoft.Graph is no longer told to try `Connect-Tenant`.
- `winup` is now hands-on about the `Microsoft.WinGet.Client` module: when it isn't installed an interactive run offers to install it (CurrentUser scope, no admin), `-InstallWinGetModule` installs it non-interactively, and `-All`/non-interactive runs print a one-line suggestion. The module is what makes upgrade listing locale-independent.
- `winup` shows which listing channel produced the upgrade list on-screen — in the picker title and the confirmation screen ("via WinGet module" / "via winget CLI"), and in the "nothing to upgrade" line — so you no longer have to open the log to tell whether the locale-proof module path or the console-parsing fallback ran.
- `winup`'s module listing path excludes winget-pinned packages when the module exposes a pin query (`Get-WinGetPin`), matching `winget upgrade`'s default of hiding pinned packages. It's a fail-safe no-op on module versions that don't expose pins, and never parses `winget pin list` console text (which would reintroduce the locale fragility the module path avoids). The "Querying winget…" step also notes it can take several seconds, since `Get-WinGetPackage` resolves every installed package against its source.

### Fixed

- `winup` no longer strands the rest of the batch when PowerShell is among the upgrades. Upgrading the running interpreter let Windows Installer's Restart Manager close the script's own `pwsh.exe` host mid-loop, so every package listed after `Microsoft.PowerShell` was silently skipped and no summary was written (the log just stopped at the "Upgrading PowerShell" line). Self-replacing packages are now run last, in a detached Windows PowerShell process after the in-process batch finishes and the summary is logged; their result lands in a `…-deferred.log` side file in CMTrace format.
- `winup` no longer reports "nothing to upgrade" on a non-English Windows. It lists available upgrades via the `Microsoft.WinGet.Client` module when that module is installed, falling back to parsing `winget upgrade` console output otherwise. The text parser locates columns by the English header words (`Name`/`Id`/`Available`), which `winget` localizes to the Windows display language — so on a localized system the header match failed and the picker silently found nothing. The module path reads structured objects from WinGet's COM API, so listing is locale-independent. (`-IncludeUnknown` still uses the text path, which maps winget's `--include-unknown` flag precisely.)
- Navigation shortcuts (`docs`/`desktop`/`downloads`/`onedrive`/`home`/`up`) now pass `-LiteralPath` to `Set-Location`, so a `[` in a resolved path is treated literally instead of as a wildcard — matching `j`/`mkcd`, which already did.
- The Custom prompt no longer mangles paths that share a prefix with the home directory. With `$HOME` = `C:\Users\Bob`, a sibling like `C:\Users\Bobby\proj` was collapsed to `~by\proj`; the home-to-`~` substitution is now prefix-only and bounded on a path separator.
- `dird -Newest` now sorts on the real `LastWriteTime` rather than the `yy-MM-dd HH:mm` display string (which only happened to sort chronologically within the same century).
- `winup`'s end-of-run summary no longer shows up red in CMTrace on a clean run. CMTrace red-highlights any line containing keywords like "failed"/"error" regardless of the entry type, so the literal "0 failed" in the summary painted a successful (Info-level) run as an error. The all-succeeded case now reads "Done. N of N succeeded." (no trigger words); runs with actual failures keep "X succeeded, Y failed" and are logged at Error level, where the red is correct.
- `winup`'s CMTrace log timestamps are now culture-invariant. The `time="HH:mm:ss.fff"` field was built with the current culture's time separator, which is `:` on most regions but `.` on some (e.g. Finnish) — there the field came out as `17.40.35.590` and CMTrace couldn't parse it. Both `Format-CMTraceLine` copies (the main one and the one baked into the deferred-upgrade child) now format the time and date with `InvariantCulture`, so the log is well-formed on any regional setting.
- `tagdl`'s "SecretStore unavailable" message no longer prints the entire multi-line exception. It used `.Split([Environment]::NewLine)[0]` to keep just the first line, but that binds to the string-separator overload and leaves a message delimited by bare LF untrimmed; it now splits on a `\r?\n` regex — the same fix applied to `winup`'s module-failure warning.

## [0.2.0] - 2026-06-11

### Changed

- **BREAKING:** `Connect-Graph`/`Disconnect-Graph` renamed to `Connect-Tenant`/`Disconnect-Tenant`. The old names were shadowed by Microsoft.Graph.Authentication's own `Connect-Graph` alias (aliases take precedence over functions), so the toolkit versions never ran once that module was loaded.
- `Connect-Tenant` now defaults to read-only scopes, which cover every toolkit M365 command. Write access is opt-in: `-Access Write` (user/group management) or `-Access Full` (directory and app-registration writes).
- The loader now wraps every dot-source (Common, M365, Machines, Hosts) in per-file error isolation. A broken file warns and is skipped instead of stopping everything that loads after it.
- Profile load no longer auto-imports Microsoft.Graph.Authentication when the Graph SDK is installed. The OMP Graph indicator only checks already-loaded modules (saves hundreds of ms per shell start) and clears a stale `POSH_GRAPH` value inherited from a parent shell.
- The VS Code host override template is now `Hosts/VisualStudioCodeHost.ps1.example`, matching the name the loader computes from `(Get-Host).Name`. Docs corrected throughout: Windows Terminal and plain VS Code terminals report `ConsoleHost`, so branch on `$env:WT_SESSION` / `$env:TERM_PROGRAM` there.

### Fixed

- `install.ps1` no longer claims ownership of a personal profile that merely dot-sources the loader. Reinstall and `-Uninstall` previously deleted such profiles without backup; ownership now requires a symlink or a pure stub.
- `install.ps1` stub generation escapes apostrophes in the repo path (e.g. `C:\Users\O'Brien`), which previously produced a profile-breaking parse error.
- `tagdl` no longer overwrites `_downloads-index.csv` with only the current run's rows. Partial (`-Limit`) runs now merge with the existing index instead of dropping previously tagged files.
- `tagdl` progress bar no longer sits at 100% for whole runs (the denominator collapsed to 1 when `-Limit` was unset).
- `winup -All` no longer blocks on the `Proceed? [Y/n]` prompt, so non-interactive and elevated unattended runs work as documented.
- `Remove-StoredSecret` no longer reports success after a failed removal (missing `-ErrorAction Stop` on `Remove-Secret`).
- `sudo`'s new-window fallback re-quotes arguments, so paths with spaces survive elevation.
- `j`, `prj`, `rdp`/`rps` fuzzy matching no longer crashes on wildcard metacharacters in the search text (e.g. an unbalanced `[`).
- `toolkit`/`Get-ToolkitCommand` no longer lists M365 commands on machines where M365/ never loaded.
- `Get-Content file.json | json` (without `-Raw`) now renders the document instead of a JSON array of its source lines.

## [0.1.63] - 2026-06-09

A modular PowerShell 7 profile + toolkit for Windows — 56 commands wired up
through one config-driven loader. Run `toolkit` to list them all.

### Profile & prompt

- One declarative `config.psd1` selects the prompt (Oh My Posh / Custom / Default), OneDrive org, jump folders, project roots, and feature toggles; everything else auto-detects.
- Oh My Posh integration: a ~120-theme gallery (`Update-PoshThemes`), `OhMyPoshTheme = 'Random'` for a fresh prompt each shell, `Set-PoshTheme` to browse/pin, and a Nerd-Font check.
- Per-machine (`Machines/<COMPUTERNAME>.ps1`) and per-host (`Hosts/<HostName>.ps1`) overrides, each with a tracked `.ps1.example` template.

### Commands

- **Navigation** — `j` folder jumper (alt-screen picker, `jb`/`jf` history), `prj` git-repo jumper, `mkcd`/`up`/`..`/`...`, and OneDrive shortcuts (`docs`/`desktop`/`downloads`/`onedrive`/`home`).
- **Files** — `peek` (extract & explore any archive), `json` (syntax-highlighting viewer/formatter), `dird`/`fr` (AI-described listings).
- **System** — `df`, `Get-SysInfo`, `Get-Uptime`, `Get-PubIP`, `Find-File`, `sudo`, `Start-AdminTerminal`.
- **AI helpers** — `ask` (ch.at), `wtf` (explain the last error), `tagdl` (AI-tag Downloads) — keys held in SecretStore.
- **Also** — `winup` (winget upgrade picker, `-Elevated`), `rdp`/`rps` (remote servers), `note`/`today`/`Find-Note` (journal), Secrets helpers, Windows Terminal font get/set, Microsoft 365 (`Connect-Graph`, `Get-TenantOverview`, …), and `toolkit`/`tip` discovery.

### Install & quality

- One-command `install.ps1` (symlink, or a dot-source stub as fallback) with a safe, restorative `-Uninstall` (removes only what it added, restores your prior profile) and `-Purge` for caches.
- Comment-based help on every command; rotating startup tips.
- Windows CI: PSScriptAnalyzer (lint clean; warnings block the build) + Pester smoke & unit suites (100+ tests).

### Docs

- README, per-folder READMEs, `docs/ARCHITECTURE.md`, and an interactive poster (`docs/poster.html`).
