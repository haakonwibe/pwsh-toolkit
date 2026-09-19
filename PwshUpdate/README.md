# PwshUpdate

A systemwide PowerShell 7 that keeps itself current: the official ZIP package, and an updater that runs as SYSTEM every night.

## Why this exists

There are three ways Microsoft ships PowerShell 7 for Windows. From 7.7 on, only two are left, and neither is both systemwide and self-updating:

| Package | Systemwide | Gets 7.7 and later | Updates itself |
|---|---|---|---|
| MSI | Yes | **No.** 7.6 is the last MSI; Microsoft Update only patches within 7.6 | Within 7.6, via Microsoft Update |
| Store / MSIX (what `winget install Microsoft.PowerShell` now installs) | **No.** Per-user; no inbound remoting, no `Set-ExecutionPolicy -Scope LocalMachine`, no all-users profiles | Yes | Yes |
| ZIP | Yes | Yes | **No** |

This folder supplies the missing column for the ZIP.

## Quick start

From the toolkit (the profile's `pwshup` command elevates for you):

```powershell
pwshup -Install          # one UAC prompt; then open a new terminal
pwshup                   # status any time
```

No PowerShell 7 on the machine yet? The script runs under Windows PowerShell 5.1, so it can bootstrap from nothing. In an **elevated Windows PowerShell**:

```powershell
powershell -ExecutionPolicy Bypass -File .\PwshUpdate\Invoke-PwshUpdate.ps1 -Install
```

## What it sets up

```
C:\Program Files\PowerShell\
  7\                       junction -> pwshup\versions\<current>
  pwshup\versions\7.6.6\   one unpacked release per folder (current + previous)
  pwshup\updater\          the copy of this script the task runs
  pwshup\state\ logs\      state.json, the CMTrace log (PwshUpdate.log)
  Modules\  Scripts\       the all-users module scope - never touched
```

- `C:\Program Files\PowerShell\7\pwsh.exe` is the one path everything uses: the machine PATH, an `App Paths` entry (Win+R `pwsh`), a Start Menu shortcut, Windows Terminal's auto-detected profile, and your scheduled tasks. It's the path the MSI used, so tasks written for the MSI work unchanged.
- A scheduled task, `\pwsh-toolkit\PwshUpdate`, runs as SYSTEM daily at 03:00 (plus up to an hour's random delay) and 3 minutes after startup.

## How an update happens

1. **Pick the version.** Read `StableReleaseTag` from the PowerShell repo's `tools/metadata.json`. That's the latest Stable release, not the newest by date: LTS patches for older lines ship afterwards (7.4.20 was published after 7.6.6).
   - It never downgrades on its own.
   - A new **major** version is held back until you opt in with `pwshup -Update -AllowMajor`, since every task pointing at `7` would silently change major.
2. **Stage it** in `pwshup\versions\<v>`:
   1. Download the ZIP and the release's `hashes.sha256`, and check the SHA-256.
   2. Check Authenticode on every exe and dll: all must be Valid, and `pwsh.exe`, `pwsh.dll` and `System.Management.Automation.dll` must be signed by Microsoft Corporation. The hash file comes from the same release as the ZIP, so it only proves the download is intact; the signatures are what prove it's genuine.
   3. Run the new `pwsh.exe` and check it reports the right version.
3. **Switch `7`** to the new folder, but only while **no pwsh is running from it**.
   - pwsh keeps the path it was started from: `$PSHOME` is `...\7`, not the version folder. So a shell left open across a switch would load the rest of its assemblies from the new version. The nightly run leaves the update staged instead, and the startup run applies it.
   - `pwshup -Update -Force` switches right away; restart your shells afterwards.
4. **Carry settings over.** Some settings live inside `$PSHOME`, which is the version folder, so they're carried from the old folder to the new one. The switch aborts rather than dropping them.
   - `powershell.config.json` is merged. A setting moves over only if you changed it from what the old release shipped, so the new release's own defaults still apply.
   - The all-users profiles (`profile.ps1`, `Microsoft.PowerShell_profile.ps1`) are copied.
5. **Run the smoke test again through `7`.** If it fails, `7` goes back to the old version, and the new one is marked bad and never retried automatically.
6. **Keep current + previous.** Older versions are removed. A version still in use is skipped and retried next run.

## Commands

| | |
|---|---|
| `pwshup` | Status: active version, latest Stable, staged or bad versions, the task's last run, tasks still using the Store build, the last log lines. `-Offline` skips the web lookup. From a non-elevated shell the task itself is invisible, as SYSTEM tasks registered by an admin are; the "Last good check" row, stamped by every run, is the health signal there. |
| `pwshup -Install` | One-time setup, described above. First it moves an **empty** leftover `7` folder (debris from a removed MSI) aside to `7.debris-<date>`; one that holds files stops the install. Re-running it refreshes the installed updater copy. `-HealthcheckUrl <url>` makes the nightly run ping a Healthchecks-style URL (`<url>/fail` on failure). |
| `pwshup -Update` | Check and apply now. `-Version 7.6.5` installs an exact version (may downgrade); `-AllowMajor` accepts 8.x; `-Force` switches with pwsh windows open. |
| `pwshup -Rollback` | Back to the previous version; the one you left is marked bad. `pwshup -Update -Version <it>` brings it back deliberately. |
| `pwshup -Uninstall` | Removes the task, PATH entry, App Paths key, shortcut, the `7` junction and `pwshup\`. `Modules\` and `Scripts\` stay. |

The profile prints one line at startup if no check has succeeded for 7 days, or an update has waited 7 days for pwsh windows to close. The job runs at 03:00, so a failure would otherwise go unnoticed.

## Moving over from the Store build

`pwshup -Install` lists the scheduled tasks that still run the Store build's `...\WindowsApps\pwsh.exe`. It doesn't rewrite them: they belong to whatever registered them. Order matters:

1. `pwshup -Install`, then open a **new** terminal.
2. Re-point those tasks at `C:\Program Files\PowerShell\7\pwsh.exe`.
3. From the new pwsh (not a Store one): `Get-AppxPackage Microsoft.PowerShell | Remove-AppxPackage`.
4. If Windows Terminal's default profile was the Store PowerShell, pick the new one.

## Safety notes (for anyone changing the script)

- **It runs as SYSTEM, so the task only ever runs the copy in `pwshup\updater\`**, which only admins can write. The script refuses to run as SYSTEM from anywhere else. A SYSTEM task pointed at a user-writable file, such as this repo, would hand SYSTEM rights to anything that can edit it.
- **Never use `Remove-Item -Recurse` on these folders.** In Windows PowerShell 5.1 it follows junctions, so it could delete through `7` or a planted link into `Modules\`. Removal goes through `Remove-PwshLink` / `Remove-PwshTree`, which never step inside a reparse point. A test guards this.
- **Keep it ASCII-only and 5.1-compatible.** 5.1 reads a BOM-less file as ANSI, and the task must not depend on the pwsh it replaces. Tests check both.
- **Write the machine PATH as `REG_EXPAND_SZ`, read unexpanded.** `[Environment]::SetEnvironmentVariable` would flatten every `%SystemRoot%` reference into a plain path.
- **A PowerShell 7 MSI would install through the junction** into a version folder, and uninstalling it would delete files from under us. The updater stops if one is registered.

`tests/PwshUpdate.Tests.ps1` runs `tests/assets/pwshupdate-harness.ps1` under both Windows PowerShell 5.1 and PowerShell 7. The harness drives the real junction switching, staging, merging, pruning, repair, install and uninstall against temporary folders, with the network and the machine-wide calls stubbed out.
