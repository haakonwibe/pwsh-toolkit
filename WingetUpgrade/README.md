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

# Anchor a package so it's never offered again (winget pin)
.\Invoke-WingetUpgrade.ps1 -Pin Tailscale

# Gate instead of hide: keep offering fixes within a branch, never past it
.\Invoke-WingetUpgrade.ps1 -Pin 'Assessment and Deployment' -Version '10.1.26100.*'

# List / remove anchors
.\Invoke-WingetUpgrade.ps1 -Pins
.\Invoke-WingetUpgrade.ps1 -Unpin Tailscale
```

### Selector controls

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move cursor |
| `Space` | Toggle current row |
| `A` | Toggle all on/off |
| `P` | Pin (anchor) the highlighted package — drops it from the list and every future run |
| `PgUp` / `PgDn`, `Home` / `End` | Fast navigation |
| `Enter` | Confirm and proceed |
| `Esc` (or `Q`) | Cancel |

---

## 📌 Anchoring packages (pins)

Some upgrades you never want — e.g. the Windows ADK's 10.1.28000 line is arm64-focused, and taking it would break servicing x86/x64 images. Anchoring uses **winget's native pin store**, not a config file of this repo's own, so a pin also protects you when running plain `winget upgrade --all` outside the toolkit.

- `-Pin <match>` (or `P` in the picker) — plain pin: the package stops being offered. Explicit `winget upgrade <id>` can still bypass it; add `-Blocking` to refuse even that.
- `-Pin <match> -Version '10.1.26100.*'` — **gating** pin: upgrades *within* the gate keep being offered (the trailing `*` wildcards the last version part), anything outside it never is. The right tool for "stay on this branch".
- `-Unpin <match>` removes the pin; `-Pins` lists them.

One implementation detail worth knowing: current `Microsoft.WinGet.Client` builds ship no `Get-WinGetPin`, so the module listing path can't see winget's pin store. Pins created *through this script* are therefore mirrored to `%LOCALAPPDATA%\WingetUpgrade\pinned.json` and filtered from the module listing (gate-aware). Pins added with raw `winget pin add` outside the script are still honored by the text path (winget hides them natively) but may appear in the module-path picker until the module ships a pin query — pin through `winup` and everything lines up.

---

## 🚀 Running from any terminal

A wrapper alias is defined in [`Profiles/Common/Aliases.ps1`](../Profiles/Common/Aliases.ps1):

```powershell
winup            # interactive selector
winup -All       # upgrade everything
winup -IncludeUnknown
winup -Pin ADK -Version '10.1.26100.*'   # anchor: gate the ADK to its 26100 branch
winup -Pins      # list anchors
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
