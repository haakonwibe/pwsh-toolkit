# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> The detailed pre-release history (0.1.0–0.1.62) was condensed into the summary
> below when the repository was squashed for its public release.

## [Unreleased]

### Added

- `cb` — a curated clipboard snippet stash (IDEAS.md #4, reframed from "clipboard history"). The durable text you paste often — signature, address, a gnarly command — named and fuzzy-searchable, surviving reboots: the thing Win+V can't be, rather than a worse copy of it. `cb -Add -Label sig` stashes the current clipboard under a name (upsert by label; identical text de-dupes and bumps to the top); `cb` opens the shared picker and Enter copies the selection back to the clipboard (reliable auto-paste isn't possible from the alternate screen buffer, so you Ctrl+V it yourself, same as Win+V); `cb <text>` copies the first label/content match without the picker; `cb -Remove <text>` drops one by label or content, so unlabeled snippets are reachable too. Snippets persist as plaintext JSON under `%LOCALAPPDATA%\pwsh-toolkit\clipboard-snippets.json` (the `j`-bookmark pattern), capped at 100 with oldest *unlabeled* entries trimmed first — labeled favorites are never auto-dropped. Deliberately not a background clipboard watcher and not a secret store: keep passwords and tokens in SecretStore (`Set-Secret` / `Get-OrCreateSecret`). `cb <TAB>` and `cb -Remove <TAB>` complete snippet labels with the preview as the tooltip.

### Fixed

- `Connect-Tenant` no longer prints a false "✅ Microsoft Graph connected" banner over an empty session when the sign-in fails. `Connect-MgGraph` surfaces authentication failures (a cancelled browser prompt, a Conditional Access block, a port-binding failure) as *non-terminating* errors, so the wrapper's `try/catch` never fired and execution fell through to the success message with a blank `Tenant:`/`Account:`. It now passes `-ErrorAction Stop` so a failed connection is caught and reported with the real reason, plus a guard that treats a missing context/account as a failure.

## [0.5.0] - 2026-07-09

### Added

- The shared picker (`j`, `prj`, `recent`, `task`, `rdp`/`rps`, `Set-PoshTheme`) got color. The picker itself now understands ANSI-colored row bodies — padding and truncation work on visible width, the cursor row is stripped so the highlight bar stays uniform, and the 1-9/a-z hotkey column renders cyan everywhere. On top of that, each list got a restrained palette: `j` shows your own bookmarks in green with paths in dark gray; `prj` puts the git branch in yellow; `recent` color-codes age by freshness (green under an hour, yellow today, dark gray for dated); `task` states read at a glance (Running cyan, Ready green, Disabled dark gray); `rdp`/`rps` fade the address and highlight a non-default user; and `Set-PoshTheme`'s Random entry reads as an action, not a theme. Labels — the thing you're scanning for — stay default-bright throughout.
- `Get-IntuneOverview` — the payoff for `Connect-Tenant`'s Intune tiers: one read-only snapshot of the device estate. Devices by compliance state (non-compliant ones named), by OS, sync health with stale devices (30+ days) called out individually, configuration surface (classic profiles, compliance policies, and Settings Catalog policies — the latter via the `/beta` endpoint, best-effort), and managed-app count. Built on `Invoke-MgGraphRequest` with a shared paging helper, so no Graph submodule beyond the authentication one every connected session already has. Everything is covered by the default ReadOnly tier.
- `j` now tab-completes its destinations: `j <TAB>` cycles the labels (built-ins, config, machine entries, and your `j -Add` bookmarks) with the target path shown as the tooltip, and `j -Remove <TAB>` offers only your own bookmarks — the only entries it can drop. Matching is substring, mirroring `j <text>`'s own lookup, and labels with spaces complete quoted.
- `recent` — the "where did that file just go" view (IDEAS.md #2, now shipped). Shows the newest N files (default 30, `recent 50` for more) across Downloads and Desktop — plus any folders a machine file appends to `$script:RecentFolders` — in the shared picker: compact age (5m / 3h / 12d), name, source folder, and the `tagdl` `:description` ADS when one exists, so AI-tagged downloads keep their descriptions here too. Enter opens the file with its default app, except archives (`.zip`/`.rar`/`.7z`), which are handed to `peek` — extract to temp and jump there beats whatever the shell association would do. Top-level files only, by design: `sortdl`'s bucket subfolders are the archive, not the recent pile.

## [0.4.0] - 2026-07-06

### Added

- `winup` can now anchor packages you never want offered: `winup -Pin <name>` (or the new `P` key on the highlighted row in the picker) pins a package, `-Unpin <name>` releases it, `-Pins` lists them. Anchors are winget's own pin store — not a toolkit config file — so a plain `winget upgrade --all` outside the toolkit honors them too. `-Pin <name> -Version '10.1.26100.*'` makes it a gating pin: upgrades within the branch keep being offered, anything past it never is (the fix for "the next ADK line is arm64-only and would break x86/x64 image servicing"); `-Blocking` refuses even explicit upgrades. Because current `Microsoft.WinGet.Client` builds ship no pin query, pins created through `winup` are also mirrored to `%LOCALAPPDATA%\WingetUpgrade\pinned.json` so the module listing path filters them (gate-aware) — closing the previously documented gap where a pinned package could still appear in the module-path picker.

- `Connect-Tenant` tiers now cover Intune — same single knob, each tier is everything at that level. ReadOnly gains the device-management reads (devices, configuration/compliance policies, apps, scripts, RBAC), `-Access Write` gains the matching day-to-day writes, and `-Access Full` gains service-config and RBAC writes plus the privileged remote actions (wipe, passcode reset) that Graph deliberately keeps out of the ReadWrite scopes. Scripts get their own `DeviceManagementScripts.*` scope because Graph split the script endpoints off `DeviceManagementConfiguration.*` in July 2025. All Intune scopes are admin-consent, so the first connection per tier after upgrading re-prompts once; and since Intune's Graph surface is largely `/beta`, the same session works for `Invoke-MgGraphRequest` against beta endpoints — no Microsoft.Graph.Beta install needed.
- `j -Add` / `j -Remove` — bookmark folders for the jumper without hand-editing config. `j -Add` bookmarks the current directory (label defaults to the folder's leaf name); `j -Add <path> -Label <name>` bookmarks a specific folder under a chosen name; `j -Remove <label>` drops one. Bookmarks are stored as JSON under `%LOCALAPPDATA%\pwsh-toolkit\jump-bookmarks.json` — never in the repo, safe to rewrite from code — and are loaded into the jump list at every shell start, so they persist across restarts. They take effect immediately (no reload). The list is tagged so `-Remove` only touches your own bookmarks: it won't shadow or delete a built-in/config/machine destination, and re-adding a label repoints it (upsert). This is the low-friction path for simple favorites; `config.psd1`'s `ExtraJumpFolders` and `Machines/<COMPUTERNAME>.ps1` remain for literal and evaluated entries respectively.
- `sortdl` — file tagged downloads into per-bucket subfolders, the hands to `tagdl`'s brain. It reads `_downloads-index.csv` and moves each file at the Downloads root into `~\Downloads\<Bucket>\`; everything stays inside Downloads, so a sort is contained and reversible. Files tagged `Other` and untagged files are left at the root by design (a visible pile beats a junk drawer). Because it's the only toolkit command that moves your files, it leads with safety: a real run prints the move plan grouped by bucket and asks before moving (the prompt defaults to No), `-WhatIf` previews without touching disk, `-Yes` skips the prompt for scheduled/`task` use, it never overwrites (a same-named file in the destination is reported as a collision and left in place), and every run is recorded to `%LOCALAPPDATA%\DownloadsOrganizer\last-sort.json` so `sortdl -Undo` can move everything back and delete the bucket folders it emptied. Descriptions written by `tagdl` live in each file's ADS and travel with the move, so `dird <bucket>` still shows them afterwards.
- `task` — run or manage a Windows scheduled task. With no argument it opens a picker over your tasks (everything outside `\Microsoft\*`; `-All` includes Windows' own), then a detail screen showing the task's state and decoded last-run result with single-key run / stop / toggle-enabled actions. `task <name>` fuzzy-matches a task and runs it directly (falling back to an exact task name across all paths), and `-Stop` / `-Enable` / `-Disable` / `-Info` act without running. Built on the in-box ScheduledTasks module and the shared `Show-Picker`; tasks registered under a protected principal that need elevation get an actionable `sudo …-ScheduledTask` hint.

### Fixed

- `tagdl` no longer aborts the final index write with `Argument types do not match` after every file was already tagged. The merge step wrapped its results in an array subexpression (`$rows = @($results)`); on PowerShell 7.6.x the `@()` operator over a generic `List[object]` intermittently throws that .NET `ArgumentException` — a JIT-tiering engine flake where a cold call throws and a warm one succeeds — which skipped `_downloads-index.csv` and the run summary even though the cache had been written. It now copies the list with its native `.ToArray()`, which doesn't route through the `@()` path.
- `winup` no longer reports a false "nothing to upgrade — you are up to date" on a Windows whose display language winget actually localizes (de/es/fr/it/ja/ko/pt-BR/ru/zh). winget translates its `upgrade` table header into those languages, and the console-text fallback parser — used when the `Microsoft.WinGet.Client` module isn't installed — can only read winget's English header, so it found nothing and the empty result was reported as success. winup now distinguishes a parse failure from a genuinely empty list: on a winget-localized display language it warns that it couldn't read the upgrade list, points at `winup -InstallWinGetModule`, and exits non-zero, instead of claiming you're up to date. Languages winget doesn't translate (e.g. Norwegian, Danish, Dutch) get English winget output, so the text path stays reliable there and the message is unchanged.

## [0.3.0] - 2026-06-28

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
