# Winget Upgrade Helper

📦 Interactive `winget upgrade` selector with logging.

Lists every package with an available upgrade, lets you pick which ones to install via an arrow-key driven checkbox UI, then upgrades only what you selected. Built for daily use — no extra modules required.

---

## 📜 Scripts Overview

| Script | Description |
|--------|-------------|
| `Invoke-WingetUpgrade.ps1` | Interactive upgrade picker. Parses `winget upgrade`, shows a console selector, upgrades chosen packages, logs to `C:\ProgramData\WingetUpgrade\Logs\`. |

---

## ⚙️ Usage

```powershell
# Interactive selector
.\Invoke-WingetUpgrade.ps1

# Upgrade everything non-interactively
.\Invoke-WingetUpgrade.ps1 -All

# Include packages with unknown installed versions
.\Invoke-WingetUpgrade.ps1 -IncludeUnknown

# Override log directory
.\Invoke-WingetUpgrade.ps1 -LogDirectory 'D:\Logs\WingetUpgrade'
```

### Selector controls

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move cursor |
| `Space` | Toggle current row |
| `A` | Toggle all on/off |
| `PgUp` / `PgDn`, `Home` / `End` | Fast navigation |
| `Enter` | Confirm and proceed |
| `Esc` (or `Q`) | Cancel |

---

## 🚀 Running from any terminal

A wrapper alias is defined in [`Profiles/Common/Aliases.ps1`](../Profiles/Common/Aliases.ps1):

```powershell
winup            # interactive selector
winup -All       # upgrade everything
winup -IncludeUnknown
```

Reload the profile (`. $PROFILE`) or open a new terminal after pulling.

---

## 🔁 Upgrading PowerShell itself

Upgrading the PowerShell that's *running the script* would have Windows Installer's Restart Manager close this session's own `pwsh.exe` mid-batch — taking the loop down with it, so anything queued after `Microsoft.PowerShell` never ran and no summary was written.

To avoid that, any package in `$selfReplacingIds` (currently `Microsoft.PowerShell` / `…PowerShell.Preview`) is held back, run *after* the in-process batch, and handed to a **detached Windows PowerShell process** — never the pwsh being replaced — which waits for this session to exit and then performs the upgrade. Its result is written to a separate `…-deferred.log` (same CMTrace format). Transient CLIs the prompt merely shells out to (oh-my-posh, node, git) are *not* self-replacing — a clash there is just a normal retryable failure — so they stay in the main batch. To treat another package this way, add its winget `Id` to `$selfReplacingIds`.

> Note: any *other* `pwsh` windows you have open are still fair game for Restart Manager to close — that's inherent to upgrading PowerShell while it's in use.

## 📝 Logging

- Path: `C:\ProgramData\WingetUpgrade\Logs\winget-upgrade-YYYYMMDD-HHmmss.log` (plus `…-deferred.log` when a self-replacing package is upgraded — see above).
- Captures: winget version, the list parsed from `winget upgrade`, every upgrade attempt with `Id`, version `X -> Y`, exit code, and a final summary table.
- Winget itself writes a detailed install trace under `%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbcc\LocalState\DiagOutputDir\` — handy when a single upgrade fails.

---

## 🔧 Requirements

- PowerShell 7+
- `winget` (App Installer from the Microsoft Store)
- Some packages require an elevated session — run from an Administrator PowerShell to be safe.

---

## 📄 License

MIT — Free to use, modify, and share.
