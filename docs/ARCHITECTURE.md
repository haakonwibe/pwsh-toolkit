# Architecture & Conventions

This document captures the design decisions and load-bearing conventions of pwsh-toolkit. Read this if you're forking, contributing, or refactoring — it explains the WHY behind choices that aren't obvious from the code.

For "how do I use this?", see the top-level [README.md](../README.md). For loader internals (path resolution, load order, cross-file dependencies), see [`Profiles/LOADING.md`](../Profiles/LOADING.md).

---

## Audience and scope

This is a **personal-but-public** setup: "here's what I actually use; fork what's useful." Not a generic framework, not aiming to be Oh My Posh-scale. Polished enough to read.

Day one is **Windows-only** and **PowerShell 7+**. Many helpers are Windows-specific (`Win32_LogicalDisk`, `winget`, `WinRAR`). macOS / Linux is a future stretch goal, not a present commitment.

The eventual **v2 plan** is to split this into a module on PSGallery (`pwsh-toolkit`) + a dotfiles repo importing it (`pwsh-profile`). For now it's one repo: simpler to fork, simpler to understand, no PSGallery publish gate.

---

## Design decisions

| Decision | Choice |
|---|---|
| Repo structure | One repo for day one. Module + dotfiles split is a v2 idea. |
| Publish to PSGallery? | No, not yet. v2 decision. |
| Cross-platform? | Windows-only for now. Stretch goal, not a precondition. |
| `$PROFILE` install pattern | Symlink if possible (admin or Developer Mode), dot-source stub otherwise. `install.ps1` auto-detects. |
| Startup tips | On by default. `$env:PSPROFILE_NO_TIPS=1` opts out; `config.psd1`'s `DisableStartupTips = $true` opts out persistently. |
| Prompt options | `config.psd1`'s `Prompt = 'OhMyPosh' / 'Custom' / 'Default'`. |
| Wrapper-path source | `$Config.ToolkitRoot` (auto-detected as parent of `Profiles/`) — parameterized so users don't edit profile code. |
| OneDrive org source | `$Config.OneDriveOrg` (auto-detected from `$env:OneDriveCommercial`). |

---

## Load-bearing conventions

These exist for non-obvious reasons. Don't "clean them up" without understanding why — most cost real debugging time to discover.

### 1. Wrapper functions splat `@args`, not `@PassthruArgs`

Profile alias wrappers like `winup`, `tagdl` use `function Foo { & script.ps1 @args }`. **Do not** convert to `param([Parameter(ValueFromRemainingArguments)] $PassthruArgs)` followed by `@PassthruArgs` — that splats positionally and breaks `-Name value` parameter pairs. The automatic `$args` array is what's needed.

### 2. Wrapper script paths resolve from `$Config.ToolkitRoot` at profile-load time

```powershell
$script:WingetUpgradeScript = Join-Path $script:Config.ToolkitRoot 'WingetUpgrade\Invoke-WingetUpgrade.ps1'
function Invoke-WingetUpgradeMenu { & $script:WingetUpgradeScript @args }
```

The path is captured into a script-scoped variable **at load time**, not re-evaluated in the function body. `$PSScriptRoot` is empty when a function body is evaluated interactively, so it cannot be used here. See `Profiles/Common/Aliases.ps1` for the pattern.

### 3. `Anthropic-API-Key` is the SecretStore secret name

`DownloadsOrganizer/Invoke-DownloadsTag.ps1` pulls the API key via `Get-OrCreateSecret -Name 'Anthropic-API-Key' -AsPlainText` and falls back to `$env:ANTHROPIC_API_KEY`. Keep this convention — it's the documented name in the README's optional-dependencies table.

**But don't use it as a throwaway example.** In *illustrative* docs — the rotating tips and the comment-based help for the generic secret helpers (`Get-OrCreateSecret`, `Get-StoredSecrets`, `Remove-StoredSecret`) — use a low-privilege placeholder like `Weather-API-Key`. Examples get copy-pasted and skimmed, and parading a real high-privilege key name around normalizes handling it casually. The functional references above, and any *setup* instructions that must name the real secret to work (e.g. wtf's "store your key like this" hint, the README optional-deps table), stay as the real name.

### 4. Persistent log files use CMTrace XML format

Any tool that writes a long-lived `.log` file (WingetUpgrade is the existing case) formats file output as CMTrace XML envelopes:

```
<![LOG[message]LOG]!><time="HH:mm:ss.fff±offset" date="MM-dd-yyyy" component="ComponentName" context="" type="1|2|3" thread="PID" file="">
```

Severity mapping: INFO/OK → `type=1`, WARN → `type=2`, ERROR → `type=3` (CMTrace has no "success" color — both INFO and OK use type=1). Console output stays human-readable; only file output is XML-formatted. See `Invoke-WingetUpgrade.ps1`'s `Format-CMTraceLine` for the reference implementation (~10 lines).

**Why:** CMTrace is a real log-viewing tool people use. Without the XML format it falls back to keyword-matching plain text, which causes false reds on lines like "0 failed" (matches "failed" as substring).

### 5. Tool detection uses standard install dirs + PATH, with `$script:` caching

`Peek.ps1` looks for `Rar.exe`/`UnRAR.exe` and `7z.exe` first on PATH, then in `C:\Program Files\WinRAR\` and `C:\Program Files\7-Zip\` (and the `(x86)` variants). The resolved path is cached in `$script:PeekRarExe` / `$script:Peek7zExe`. Preserve this pattern for any future tool detection — it works for users who haven't put things on PATH (the common case).

### 6. Interactive single-select pickers go through `Show-Picker`

`j`, `rdp`/`rps`, and `prj` all render their menu through one shared picker — `Show-Picker` in `Common/Picker.ps1`. A caller passes its items, a `Title`/`Hint`, and a `RenderRow` scriptblock (use `.GetNewClosure()` if the row formatter references a caller variable like a column width); the picker owns the rest: alternate screen buffer, a scrolling viewport, the `1-9`/`a-z` jump keys, and key handling. It returns the selected item or `$null`.

Two load-bearing details:
- **Alternate screen buffer**: `ESC[?1049h` on entry, `ESC[?1049l` on exit (what `less`/`vim`/`fzf` do) so scrollback survives. Don't swap in `Clear-Host` — that wipes scrollback.
- **Fixed viewport, one-string frames**: each frame is built as a single string (`ESC[H` home → exactly the rows that fit → `ESC[J` clear-to-end) and written once. Never `SetCursorPosition` + redraw-all-items — with a list taller than the window that scrolls the terminal and the display garbles (the 0.1.31 `prj` bug). The viewport math is the pure, unit-tested `Get-PickerScrollTop`.

Add a new picker by calling `Show-Picker`, not by hand-rolling another menu loop.

### 7. `$script:` variables defined in Common/*.ps1 work correctly

`$script:JumpFolders`, `$script:ProfileTips`, `$script:Config`, etc. work fine when defined at the top of a Common file (or the loader) and read from functions in the same file. PowerShell handles the dot-source-through-ForEach-Object scoping correctly. Don't preemptively "fix" this with `$global:`.

### 8. Optional cmdlets must be guarded with `Get-Command`, and use `-ErrorAction Ignore` (not `SilentlyContinue`) on the probe

Two distinct traps, same root cause: PowerShell's "silent" error actions still record errors in `$Error`.

**Trap 1 — `-ErrorAction SilentlyContinue` does not suppress "command not found":** that's a `CommandNotFoundException` thrown before any parameter binding happens, so `-ErrorAction` never gets read. If a function calls `Get-MgContext -ErrorAction SilentlyContinue` and Microsoft.Graph isn't installed, the function throws. For `prompt`, this means PowerShell silently falls back to the default `PS>` and you'll spend an hour figuring out why.

**Trap 2 — `-ErrorAction SilentlyContinue` ≠ `-ErrorAction Ignore`:** `SilentlyContinue` doesn't display the error or stop execution, **but still adds it to `$Error`**. `Ignore` is the only action that's truly silent. For pre-flight "is this thing available?" probes (Get-Command, Test-Path, Remove-Item on optional things), use `Ignore` so `$Error` stays clean. Tests that assert "load with zero errors" will catch this; humans typically won't until they `$Error[-5..-1]` and wonder where the noise came from.

Combined pattern:

```powershell
if (Get-Command Get-MgContext -ErrorAction Ignore) {
    $ctx = Get-MgContext -ErrorAction SilentlyContinue   # inside guard — real errors here ARE diagnostic-worthy
    # ... use $ctx
}
Remove-Item Env:\POSH_GRAPH -ErrorAction Ignore   # might not exist — no need to log it
```

### 9. Skip interactive-only setup when stdout is redirected

`Common/PSReadLine.ps1` guards its `Set-PSReadLineOption -PredictionSource History` calls with `if ([Console]::IsOutputRedirected) { return }`. Without the guard, PSReadLine emits "The handle is invalid" into `$Error` on every CI run, `pwsh -Command` invocation, or piped-output scenario. Apply the same pattern to any future host-feature setup that requires a real TTY.

### 10. Name-lookup helpers are bookmarks, not whitelists

Any helper that takes a `<name>` argument and looks it up against a configured list — `j <name>`, `rdp <name>`, `rps <name>` — must:

1. Try the configured list first (fuzzy match against label / path / address).
2. Fall through to treating the argument as a literal value if nothing matches.

`j C:\Some\Path` and `rps 10.0.0.2` should "just work" without requiring the user to add an entry first. The configured list is a shortcut layer, not a gating whitelist. Empty-config friendly messages (the "no jump destinations configured" / "no remote servers configured" guards) apply ONLY to the no-arg picker path, never to explicit-argument calls.

See `j` in `Profiles/Common/Navigation.ps1` and `Resolve-RemoteServer` in `Profiles/Common/RemoteServers.ps1` for the reference implementation. Three tagged releases (v0.1.5 → v0.1.6 → v0.1.7) were spent iterating to this shape; any future "lookup by name" helper should ship with the pattern in place.

### 11. AI helpers must instruct plain-text output and strip markdown defensively

LLM responses default to markdown formatting — `**bold**`, triple-backtick code fences, `#` headings, `-` bullets. The PowerShell console does NOT render any of that, so it comes through as literal characters and makes output worse than just plain text would have been.

Any helper that calls an LLM and prints the response to the terminal must:

1. **Tell the model explicitly that its output goes to a console**, with concrete examples of what to avoid. Generic "be concise" instructions aren't enough — the model still reaches for markdown by default.
2. **Strip the common offenders post-receipt as defense in depth.** Five regex lines catch ~95% of lapses: `**bold**`, `` `inline` ``, `` ``` `` fences (with or without language), `#`-prefix headings.
3. **Use ANSI color via `Write-Host -ForegroundColor`** to highlight structured bits (e.g., indented commands in cyan), so the eye lands on the runnable parts without the model needing to "format" them with markdown.

See `wtf` in `Profiles/Common/Wtf.ps1` for the reference pattern — both the prompt's FORMAT block and the post-process strip. Any future AI helper (`gcm`, etc.) should follow the same shape from day one instead of shipping with raw markdown leakage like v0.1.12-14 of `wtf` did.

### 12. Config slots are literal strings; env-var resolution lives in the loader

`Profiles/config.psd1` is parsed by `Import-PowerShellDataFile`, which runs in restricted-language mode — no `$variable` references, no string interpolation, no cmdlet calls. The first time someone tries `Path = $env:TEMP` in `ExtraJumpFolders`, they get a confusing parse-time error.

All path-like config slots accept either:

- A **literal string** path (`'C:\Users\johnsmith\Obsidian Vault\Daily'`), or
- **`$null`** for "use the default / auto-detect"

When the value is `$null`, the resolution happens in PowerShell code after the data file is imported — usually in the loader (`pwsh-toolkit-profile.ps1`), but a Common file can own its own resolution when the cascade is more involved than a one-liner:

```powershell
# Simple case — fine to keep in the loader's "hard fallback defaults" block.
if (-not $script:Config.ToolkitRoot) {
    $script:Config.ToolkitRoot = Split-Path -Parent $script:ProfileRoot
}

# Complex case — Common/Notes.ps1 owns its own cascade because the resolution
# reads %APPDATA%\obsidian\obsidian.json and walks a 6-way preference list
# (Obsidian vault inside OneDrive > any open vault > OneDrive Documents > ...).
# The loader leaves NotesRoot as $null; Notes.ps1 fills it at the end of its
# own load via Resolve-NotesRoot.
```

Currently applied across `ToolkitRoot`, `OneDriveOrg`, `OhMyPoshTheme` (loader-owned) and `NotesRoot` (Notes.ps1-owned). Any new path-like slot follows the same shape: literal-or-`$null` in `config.example.psd1` (with the constraint documented inline near the slot), plus a resolver in either the loader or the relevant Common file depending on how involved the cascade is.

For complex per-machine logic that needs PowerShell expressions (network drive mappings, conditional paths, Test-Path checks), the answer is **`Machines/<COMPUTERNAME>.ps1`** — that file is regular PowerShell, dot-sourced after the config is applied, so it can extend any `$script:` variable with arbitrary expressions. The config.psd1 restriction is acceptable precisely because this escape hatch exists.

### 13. Two test layers: smoke tests for load-state, unit tests for behavior

`tests/` has two complementary suites, and a new test belongs in exactly one of them depending on what it proves:

- **`Smoke.Tests.ps1`** answers *"does the profile assemble correctly?"* — it spawns `pwsh -NoProfile` children, loads the profile in known config states (Custom prompt, OhMyPosh), and asserts on a JSON state dump: zero load errors, every expected command defined, the prompt renders, empty-state UX produces no `$Error` entries. Child processes are deliberate here — they isolate load-time side effects and stdout-encoding pitfalls from the runner.

- **`Unit.Tests.ps1`** answers *"does this function do the right thing?"* — it dot-sources individual `Common/*.ps1` files **in-process** with a minimal mocked `$script:Config` (ToolkitRoot pointing nowhere real so optional dot-sources are skipped; NotesRoot preset so Notes.ps1 skips its cascade) and asserts on return values and filesystem effects.

The split exists because the two failure modes are disjoint. Every behavioral bug fixed in 0.1.25/0.1.26 (`touch` truncating files, `la` showing nothing, `which` returning blank / hanging on circular aliases / erroring on bad wildcards) **loaded cleanly and the command existed** — the smoke suite was structurally blind to all of them. Pure-logic functions (`touch`, `which`, `Get-PeekTool`'s dispatch, `Format-RemoteServerDisplay`, name-match helpers) get a unit test; anything that depends on a fully-assembled profile or a real prompt stays a smoke test. When you fix a behavioral bug, add the regression guard to `Unit.Tests.ps1` and confirm it actually *fails* against the old code before trusting it. CI discovers both files automatically via `Run.Path = './tests'`.

---

## What NOT to do

- **Don't auto-publish to PSGallery.** Module split + publishing is v2.
- **Don't refactor the helpers themselves** unless there's a clear bug. The implementations of `j`, `peek`, `df`, `winup`, etc. have been ironed out over many iterations — preserve their behavior. Focus refactor energy on the loader/config layer.
- **Don't add cross-platform support unprompted.** Many helpers are Windows-specific. Documenting "Windows-only for now" is fine.
- **Don't add a config knob without updating `config.example.psd1` and the loader's hard-fallback defaults.** Keys missing from both files entirely hit the loader's `if (-not $script:Config.ContainsKey(...)) { ... }` block; only add to that block if the key is critical for the loader itself to function.
- **Don't bypass the symlink-aware `$PSCommandPath` resolution** in `pwsh-toolkit-profile.ps1`. Specifically, don't rewrite `(Get-Item $PSCommandPath).Target ?? $PSCommandPath` as plain `$PSCommandPath` — it breaks the symlink case while looking like a simplification.
- **Don't deep-merge user config over example defaults.** The loader does a shallow merge — keys the user defines fully replace those in the example, including nested hashtables like `Features`. Keep example sub-blocks complete enough that a replace doesn't lose anything important.
