# Oh My Posh

This folder holds the [Oh My Posh](https://ohmyposh.dev/) theme used when `config.psd1` sets `Prompt = 'OhMyPosh'`. Drop more `.omp.json` files in here to switch between them — point `OhMyPoshTheme` at the file you want.

## Prerequisites

- PowerShell 7+
- Windows Terminal (recommended)
- A [Nerd Font](https://www.nerdfonts.com/) installed and selected in your terminal

## Setup

### 1. Install Oh My Posh

```powershell
winget install JanDeDobbeleer.OhMyPosh
```

### 2. Install a Nerd Font

```powershell
oh-my-posh font install Meslo
```

Then set **MesloLGM Nerd Font** as the font in Windows Terminal:
**Settings > Profiles > Defaults > Appearance > Font face > MesloLGM Nerd Font**

### 3. Install Terminal-Icons (optional)

Adds file-type icons to `Get-ChildItem` output.

```powershell
Install-Module -Name Terminal-Icons -Force
```

### 4. Enable in `config.psd1`

In `Profiles/config.psd1` (copy from `config.example.psd1` if you haven't):

```powershell
Prompt        = 'OhMyPosh'
OhMyPoshTheme = 'default.omp.json'   # bare filename = looked up in Profiles/OhMyPosh/
```

Open a new terminal tab to verify.

## Switching back to the bundled custom prompt

```powershell
Prompt = 'Custom'
```

…or `'Default'` for PowerShell's built-in prompt.

## Prompt segments (`default.omp.json`)

### Left side

| Segment | Color | Description |
|---------|-------|-------------|
| OS | Dark (`#0c1117`) | Windows or WSL icon |
| Shell | Navy (`#1e3a5f`) | Shows `pwsh` with terminal icon |
| User | Blue (`#2563eb`) | Current username |
| Admin | Red (`#dc2626`) | Only appears in elevated sessions |
| M365 | Purple (`#8b5cf6`) | Connected Graph account (auto-detected) |
| Path | Cyan (`#0891b2`) | Smart truncation with optional mapped shortcuts |
| Git | Green/Amber/Red | Branch, status, stash count, worktree count |

### Right side

| Segment | Description |
|---------|-------------|
| Node.js | Version (only in Node projects) |
| Python | Version + venv name (only in Python projects) |
| .NET | Version (only in .NET projects) |
| Command | Execution time of last command |
| Battery | Charge level with color coding (red/amber/green) |
| Time | Current time (24h format) |

### Prompt character

- `╰─❯` in cyan — turns red when last command failed
- Transient prompt collapses previous prompts to `❯`

## Mapped path shortcuts

The path segment can replace any directory prefix with a friendly icon + label. The shipped theme has an empty `mapped_locations` block — add your own entries in `default.omp.json`:

```jsonc
"mapped_locations": {
  "C:\\GitHub": " GitHub",
  "D:\\Projects": " Projects"
}
```

(The `` etc. are Nerd Font glyph codepoints — pick one from [nerdfonts.com/cheat-sheet](https://www.nerdfonts.com/cheat-sheet).)

## Git segment colors

| State | Background | Meaning |
|-------|-----------|---------|
| Green (`#16a34a`) | Clean working tree | |
| Amber (`#d97706`) | Uncommitted changes | Modified or staged files |
| Red (`#dc2626`) | Diverged | Both ahead and behind remote |

## M365 Graph indicator

The purple M365 segment automatically detects Microsoft Graph connection state:

- **Connect** with `Connect-Graph` or `Connect-MgGraph` — the segment appears on the next prompt
- **Disconnect** with `Disconnect-Graph` or `Disconnect-MgGraph` — the segment disappears
- Detection runs via a `PowerShell.OnIdle` engine event registered by the loader (only when `Prompt = 'OhMyPosh'`), so it works regardless of how you connect

## Customizing the theme

Edit `default.omp.json` directly, or copy it to a new file and point `OhMyPoshTheme` at the new name. To preview your changes:

```powershell
oh-my-posh print primary --config .\default.omp.json
```

See the [Oh My Posh documentation](https://ohmyposh.dev/docs/) for available segments and configuration options.
