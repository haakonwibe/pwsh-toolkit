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

## 📝 Logging

- Path: `C:\ProgramData\WingetUpgrade\Logs\winget-upgrade-YYYYMMDD-HHmmss.log`
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
