# Screenshot capture guide

This document describes how to take the canonical screenshots referenced from the top-level README. Drop the PNGs in this folder under the names listed below and the README will pick them up automatically.

All seven shots are captured. If you retake one, keep the existing filename so the README keeps resolving it.

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

## The shots

### 1. `prompt-hero.png` — Prompt at rest with a tip

Open a fresh terminal tab. You'll see the rotating tip (💡) followed by the prompt. Capture everything from the PowerShell version line down to and including the prompt arrow.

If the tip that appears is one of the less interesting ones, run `tip` a few times to re-roll until you get a good one — `j`, `peek`, `winup`, or `tagdl` make the best hero tips because they hint at the toolkit's TUI personality.

Don't include the post-prompt cursor blinking; capture before typing anything.

### 2. `j-picker.png` — Folder jumper

The built-in destinations (Home, Downloads, OneDrive, Program Files, Temp, Windows, …) fill most of the list on their own. Add a couple of your own with `j -Add` so the green bookmark rows show too — GitHub, Projects, whatever's not too personal. Then run:

```
j
```

Press `↓` once or twice so a non-first row is highlighted (proves it's interactive, not just a list). Capture the whole alt-screen-buffer view including the title bar (`Jump`) and the help line (`Up/Down + Enter  PgUp/PgDn  Esc cancel  |  j <text> jumps directly`).

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

### 6. `cb.png` — Clipboard snippet stash

Seed six or seven snippets that between them exercise every row style: labeled entries (green label + dim preview), at least one unlabeled (renders by first line), and a multi-line one in each category so the `(N lines)` marker shows up both ways.

Don't stash them with `cb -Add` for this. It only reads the live clipboard and always stamps `Added` as now, so every row renders the same age and the freshness column looks broken. Write the store directly instead — `%LOCALAPPDATA%\pwsh-toolkit\clipboard-snippets.json`, a plain JSON array of `Label` / `Text` / `Added` — with `Added` backdated across minutes-to-weeks so the age column has a real spread. Timestamps must be invariant ISO-8601 round-trip (`.ToString('o', [cultureinfo]::InvariantCulture)`); a locale-formatted date parses back as `DateTime.MinValue` and the snippet sorts to the bottom.

Back up your real store first and restore it afterwards — the demo set replaces it wholesale.

Everything in the file is visible in the capture, so treat it as published text: no real signature, no real email (the repo's commits use a GitHub noreply address on purpose), no tenant ID, no internal hostnames. Generic placeholders and `example.com` throughout.

Capture at ~140 columns if the set includes long Graph URLs, or accept one truncated row.

Then run `cb`, arrow down one row so a non-first row is highlighted, and capture. Press `Esc` to dismiss without copying.

### 7. `uninst.png` — Uninstall picker

Run `uninst` with no argument and capture the picker. The two markers are the point of the shot: `*` for silent-capable entries and `!` for ones that force their own UI, so frame a region of the list where both appear (`apps -SilentOnly` beforehand tells you which of your installed apps carry `*`).

**Press `Esc`, not Enter.** Enter starts a real uninstall of the highlighted app.

### 8. `cockpit.png` — Intune dashboard

Not a terminal shot, and not taken against a real tenant — a live one leaks the signed-in username in the `file://` path, the tenant domain in the header, and every device name in the callout lists. `ConvertTo-IntuneDashboardHtml` is pure (data + template → string), so build a synthetic `Get-IntuneOverviewData`-shaped object instead and render through the exact same code path the real command uses. Give it enough shape to be worth showing: several platforms, all four compliance buckets, and a stale tail spanning the 30d/60d cutoffs plus one device that never checked in. Two details are worth setting deliberately, because they only appear when the data earns them: a `ComplianceReasons` map (device id -> failing policy names) is what makes the non-compliant rows say something other than "noncompliant", and one device that is *both* stale and non-compliant is what shows the cross-referencing and the tile's overlap caption. Pin `Generated` to a fixed timestamp too — the stale day counts are derived from it, so an unpinned capture renumbers them every time. Keep each attention list to four entries or fewer, or it hits the `.att-list` 280px scroll cap and the capture shows a half-row.

Render it headlessly, the same way `poster.png` is made — for the poster itself
that means `--window-size=1013,715` at the same 2x scale, which lands exactly on
its committed 2026x1430 with no cropping (the hero region, cut mid-panel by the
viewport edge). `docs/poster.html` pulls Tailwind and Google Fonts from the
network, so its render needs internet, and re-rendering shifts roughly 12% of
its pixels by one or two levels — gradient dithering Chrome doesn't reproduce
byte-for-byte between runs. Compare a re-render by difference *magnitude*, not
by pixel count, or you'll chase noise. The cockpit's own numbers:

```
chrome --headless=new --hide-scrollbars --user-data-dir=<temp> \
       --window-size=1320,1400 --force-device-scale-factor=2 \
       --force-prefers-reduced-motion --virtual-time-budget=15000 \
       --screenshot=out.png file:///…/cockpit.html
```

`--force-prefers-reduced-motion` is the load-bearing flag: the platform bars grow via a CSS animation, and without it the screenshot lands mid-animation with the bars part-drawn. The template's own `prefers-reduced-motion` block turns the animation off, so the final width paints immediately. Then crop to the last content row.

### 9. `how.png` — the command-suggestion picker

The one shot that does NOT follow the ~1107px house width, and deliberately.

The picker has two columns — the command and a one-line note — and the note is
what makes it more than a list. Fit both or the shot is worthless: at 110
columns the notes fall off the right edge entirely and the candidates then look
identical to each other, because the part that differs (`-WhatIf` vs `-Force`)
is beyond the cut. There are only two ways out, and only one of them keeps a
question worth showing:

- **Capture wide.** `how "delete log files older than 90 days"` needs roughly
  1900px. That is the reference shot: three candidates that form a progression —
  preview, then commit, then confirm each — which is the clearest argument for
  offering candidates at all. Crop to the content and it lands about 1918x136,
  a wide strip that reads fine in the README.
- **Or ask something with short answers**, e.g. `how "look inside a zip without
  extracting it"`, which fits at house width and shows answers reaching for the
  toolkit's own commands (`peek -List`).

The first is the better advert; the second is the tidier file. The repo ships
the first — `cockpit.png` is already 2640px wide, so a wide asset is no novelty.

Two things to know. The answer is generated fresh each call, so it will not be
byte-identical to a previous capture — re-run until you get a set worth showing
rather than trying to reproduce one. And the picker draws on the alternate
screen buffer, so the shot contains only the picker: the header line, the key
hint, the candidates, and the `1/3` counter. There is no prompt to include, which
is why these shots are shorter than the terminal ones above.

`how-run.png` is the companion shot, and it carries what the picker cannot: the
payoff. Ask, take a candidate, press Up to recall it, run it — then crop to just
those lines. A destructive question earns its place here because the answer
arrives with `-WhatIf` already on it. Crop tight: the `What if:` output repeats
one sentence per file, and two lines make the point that twenty do not.

Keep the window narrow enough that the longest candidate still fits on its line.
An overflowing row is rendered without colour by design (truncating mid-escape
would leak a broken sequence), so a too-wide command shows up grey among cyan
ones — visually wrong, and not what the command normally looks like.

## Optional: the OMP prompt segments

If you want a sixth shot purely for the poster's hero block, capture just a single prompt line with all the trimmings showing — admin icon, M365 icon (after `Connect-Tenant`), folder name, git status. Save as `prompt-segments.png`. This one's purely decorative; the README doesn't depend on it.

## After capture

1. Drop the PNGs in this folder using the exact filenames above.
2. The README's `## Screenshots` section already has the layout — once the files exist, they render.
3. Commit + push. The poster (`docs/poster.html`) can also be updated to reference one of these (probably `prompt-hero.png`) for its own hero block at any time.
