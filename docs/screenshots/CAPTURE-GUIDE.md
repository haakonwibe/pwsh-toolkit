# Screenshot capture guide

This document describes how to take the five canonical screenshots referenced from the top-level README. Drop the PNGs in this folder under the names listed below and the README will pick them up automatically.

## Terminal setup (do this once)

- **Terminal:** Windows Terminal (the screenshots should match what a new user sees after running `install.ps1 -InstallOhMyPosh`)
- **Font:** `MesloLGMDZ Nerd Font Mono` at 12pt or larger (the icons must render)
- **Background:** solid, no transparency. Default dark theme is fine
- **Window width:** at least 120 columns so output doesn't wrap
- **Window height:** at least 30 rows so pickers fit without clipping
- **Color scheme:** stock Windows Terminal dark looks clean enough; avoid anything high-contrast or themed
- **Profile:** `Prompt = 'OhMyPosh'` in `config.psd1` so all shots show the polished prompt

## Capture tools

- **Win+Shift+S** — Snipping Tool's rectangular capture. Free, built-in. Save as PNG.
- **ShareX** / **Greenshot** — if you want padding, drop shadows, or auto-save with a naming pattern.

Crop tight to the terminal content. Leave a small margin of background so the rounded window corners are visible, but don't include the rest of the desktop.

## The five shots

### 1. `prompt-hero.png` — Prompt at rest with a tip

Open a fresh terminal tab. You'll see the rotating tip (💡) followed by the prompt. Capture everything from the PowerShell version line down to and including the prompt arrow.

If the tip that appears is one of the less interesting ones, run `tip` a few times to re-roll until you get a good one — `j`, `peek`, `winup`, or `tagdl` make the best hero tips because they hint at the toolkit's TUI personality.

Don't include the post-prompt cursor blinking; capture before typing anything.

### 2. `j-picker.png` — Folder jumper

Make sure your `config.psd1`'s `ExtraJumpFolders` has at least 3-5 sensible entries (Home, Downloads, OneDrive, plus a couple of yours — GitHub, Projects, whatever's not too personal). Then run:

```
j
```

Press `↓` once or twice so a non-first row is highlighted (proves it's interactive, not just a list). Capture the whole alt-screen-buffer view including the title bar (`Jump`) and the help line (`Digits 1-9 jump  Up/Down + Enter  Esc cancel  | Tip: j <text> jumps directly`).

Press `Esc` to dismiss without jumping when done.

### 3. `df.png` — Disk-free bars

Just run:

```
df
```

The shot should show: the header (Drive / Label / Used / Free / Total / Use% / Usage), at least one drive at each color tier if possible (green ≤70%, yellow 71-89%, red ≥90%). If all your drives are green, the screenshot is still fine — the bars themselves are the visual.

### 4. `peek-list.png` — Archive listing

Pick a small `.zip` you have lying around (or download a small one — even a release zip from any GitHub repo works). Run:

```
peek -List <path-to-zip>
```

Capture the header line + a half-dozen rows of the listing. If the archive's huge, that's fine — readers don't need to see the whole thing.

If you want a more impressive shot, use a `.rar` or `.7z` so the dispatch to WinRAR / 7-Zip is exercised (the tool name appears in the verbose output). `.zip` works too.

### 5. `winup.png` — Winget upgrade picker

Run:

```
winup
```

If your system has no upgrades available, `winup` will tell you and exit — try the screenshot just after installing or skipping an update so something is pending. If you really have nothing pending, install a small package (`winget install jqlang.jq`) and then immediately uninstall it; check whether anything else shows up. Failing that, skip this shot — it's the lowest-priority of the five.

When the picker is open, toggle 1-2 items with **Space** so the checkboxes are visible (`[x]`). Don't press Enter — escape with Ctrl+C or Esc after capturing.

## Optional: the OMP prompt segments

If you want a sixth shot purely for the poster's hero block, capture just a single prompt line with all the trimmings showing — admin icon, M365 icon (after `Connect-Tenant`), folder name, git status. Save as `prompt-segments.png`. This one's purely decorative; the README doesn't depend on it.

## After capture

1. Drop the PNGs in this folder using the exact filenames above.
2. The README's `## Screenshots` section already has the layout — once the files exist, they render.
3. Commit + push. The poster (`docs/poster.html`) can also be updated to reference one of these (probably `prompt-hero.png`) for its own hero block at any time.
