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

### 1. Wrapper functions splat `@args` — or declare parameters and splat `@PSBoundParameters`

Profile alias wrappers come in two shapes, and the choice is about tab completion.

`function Foo { & script.ps1 @args }` is the default (`winup`). **Do not** convert it to `param([Parameter(ValueFromRemainingArguments)] $PassthruArgs)` followed by `@PassthruArgs` — an array splatted with `@` binds *positionally*, which breaks `-Name value` pairs. The automatic `$args` array is what's needed.

The cost of `@args` is that it is opaque to the completion engine: `tagdl -<Tab>` offered nothing, because the function declares no parameters. Where that matters, declare the parameters and splat **`$PSBoundParameters`** — a hashtable, so it splats by *name*, not position, and only the arguments the caller actually bound are forwarded:

```powershell
function Invoke-DownloadsTagger {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Path, [int] $Limit, [switch] $Force, ...)
    & $script:DownloadsTagScript @PSBoundParameters
}
```

Two rules make this safe. Declare **no default values** in the wrapper — the script stays the single source of truth for both defaults and behaviour, and an unbound parameter simply is not forwarded. And keep declaration order identical to the script's, so positional binding matches. The pair drifts silently otherwise, so `tests/Unit.Tests.ps1` asserts the wrapper's parameter list equals the script's; see `Describe 'DownloadsOrganizer wrappers'`.

`SupportsShouldProcess` on such a wrapper needs a justified `SuppressMessageAttribute` — the forwarded script owns the `ShouldProcess` call, but the attribute is what lets `-WhatIf` bind on the wrapper at all.

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

**At profile load, guard a *function* with `Test-Path Function:\Name` instead.** When the name isn't defined, `Get-Command` searches every module on `PSModulePath` before giving up: about 70 ms per miss, in every shell. That's how `Get-Command Enable-PoshTransientPrompt` came to cost every start once Oh My Posh 31 dropped the function. `Get-Command` stays right for cmdlets and executables, and for anything that runs on demand rather than at load (see #17).

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

**When the response is data rather than prose, constrain it instead of cleaning it up.** `how` asks for `output_config.format` with a JSON schema, so the model's formatting choices never reach the console at all — the failure mode is removed rather than mitigated, and the result arrives addressable enough to hand to `Show-Picker`. Two response details bite anyone porting `wtf`'s call: thinking is on by default on current models, so the answer is **not** `content[0]` — find the block whose `type` is `text` — and a safety decline arrives as HTTP 200 with `stop_reason: refusal`, so the status code never reveals it.

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

### 13. Toolkit state lives under `Get-ToolkitDataPath`, and `AppData.ps1`'s filename is load-bearing

Everything the toolkit persists per-machine (jump bookmarks, clip snippets, the posh-themes cache, the Intune cockpit HTML) lives under `%LOCALAPPDATA%\pwsh-toolkit`, resolved through `Get-ToolkitDataPath` in `Common/AppData.ps1` — never a hand-rolled `Join-Path $env:LOCALAPPDATA 'pwsh-toolkit'` literal, so a typo can't silently fork the data root. The helper ensures the root directory exists, which is why callers can bind file paths at load and write without ceremony.

Two constraints keep this working:

- The loader dot-sources `Common/*.ps1` **alphabetically**, and several files call the helper at load time to bind their `$script:` store paths — so `AppData.ps1` is *named* to sort before them. Renaming it (or adding a load-time caller that sorts earlier) breaks profile load.
- Two places legitimately keep the literal because they run before Common/ exists: `install.ps1` (PS 5.1, standalone) and the loader's OhMyPosh branch. Both carry keep-in-sync comments.

### 14. Two test layers: smoke tests for load-state, unit tests for behavior

`tests/` has two complementary suites, and a new test belongs in exactly one of them depending on what it proves:

- **`Smoke.Tests.ps1`** answers *"does the profile assemble correctly?"* — it spawns `pwsh -NoProfile` children, loads the profile in known config states (Custom prompt, OhMyPosh), and asserts on a JSON state dump: zero load errors, every expected command defined, the prompt renders, empty-state UX produces no `$Error` entries. Child processes are deliberate here — they isolate load-time side effects and stdout-encoding pitfalls from the runner.

- **`Unit.Tests.ps1`** answers *"does this function do the right thing?"* — it dot-sources individual `Common/*.ps1` files **in-process** with a minimal mocked `$script:Config` (ToolkitRoot pointing nowhere real so optional dot-sources are skipped; NotesRoot preset so Notes.ps1 skips its cascade) and asserts on return values and filesystem effects.

The split exists because the two failure modes are disjoint. Every behavioral bug fixed in 0.1.25/0.1.26 (`touch` truncating files, `la` showing nothing, `which` returning blank / hanging on circular aliases / erroring on bad wildcards) **loaded cleanly and the command existed** — the smoke suite was structurally blind to all of them. Pure-logic functions (`touch`, `which`, `Get-PeekTool`'s dispatch, `Format-RemoteServerDisplay`, name-match helpers) get a unit test; anything that depends on a fully-assembled profile or a real prompt stays a smoke test. When you fix a behavioral bug, add the regression guard to `Unit.Tests.ps1` and confirm it actually *fails* against the old code before trusting it. CI discovers both files automatically via `Run.Path = './tests'`.

---

### 15. The input buffer can only be edited from inside a PSReadLine key handler

`[Microsoft.PowerShell.PSConsoleReadLine]::Insert()` / `::Replace()` write to the *live* input buffer. Called from an ordinary command they do not fail loudly: by then the line has been submitted, so the text is written into the already-drawn line and the display is left mangled — the command appears appended to the echo of what the user typed. A headless probe is no help either; outside a console the same call throws, which suggests a guard is enough. It is not.

Inside a key handler registered with `Set-PSReadLineKeyHandler`, the buffer is still live, and this is the only place the "put a command on the user's prompt" behaviour can work. `how` is the reference: `Alt+h` reads the typed line with `GetBufferState`, and swaps it for the chosen command with `Replace(0, $line.Length, $cmd)`. The command form of `how` never touches the buffer — it uses history plus clipboard, which works in every host.

Tests pin the rule in both directions: no `::Insert(`/`::Replace(` anywhere in the command path, and `::Replace(` present in the handler.

Handlers must also stay quiet. The prompt line is still on screen while one runs, so anything written over it leaves artifacts — `Get-HowCommand -Quiet` exists for exactly this.

---

### 16. `PwshUpdate/` is the one SYSTEM-context component, and it plays by different rules

`PwshUpdate/Invoke-PwshUpdate.ps1` keeps a systemwide PowerShell 7 current from the ZIP packages, driven by `pwshup` in `Common/PwshUpdate.ps1`. It is the only code in the repo that runs as SYSTEM, and the only standalone script besides `install.ps1` that must run under Windows PowerShell 5.1. The five rules below follow from that:

- **5.1, ASCII-only.** It must never depend on the pwsh it replaces, and it must be able to repair a broken install. Tests parse it under `powershell.exe`, run its harness under both hosts, and fail on any byte over 127.
- **The SYSTEM task runs the installed copy only** (`C:\Program Files\PowerShell\pwshup\updater\`, writable by admins only), never the repo. The script refuses to run as SYSTEM from anywhere else, and a test pins the task's `-File` to the installed copy. `pwshup -Update`/`-Rollback` also run the installed copy, so what runs elevated is what the task runs.
- **Link-safe removal only.** 5.1's `Remove-Item -Recurse` follows junctions, so deleting through `7`, or a planted link, could take out `C:\Program Files\PowerShell\Modules`. All removal goes through `Remove-PwshLink`/`Remove-PwshTree`, which never enter a reparse point. A test forbids `Remove-Item -Recurse` on the file system, and the harness plants such a link to prove it.
- **Switch the junction only while nothing runs from it.** pwsh doesn't resolve the junction: `$PSHOME` and every assembly path stay `...\7\...` (measured). A session left open across a switch would load its remaining assemblies from the new version. Updates stage fully and verify first; the switch itself is deferred until no pwsh runs from `7`, unless `-Force` is given.
- **All mutable state lives under the admin-only install root:** staging, logs, the state file and the lock. `C:\ProgramData` and `%TEMP%` let ordinary users create folders first, and a folder a user created first is a way to redirect SYSTEM's writes.

---

### 17. Profile load time is budgeted: measure with `Measure-ProfileLoad`, keep probes off the load path

Every shell pays for everything at the top level of the loader and every `Common/`/`M365/` file. A few calls cost far more than they look:

| Call | Cost | What to do instead |
|---|---|---|
| `Get-Module -ListAvailable` | ~70 ms | Check for the module folder on `PSModulePath` |
| The session's first `ConvertFrom-Json` | ~55 ms | `System.Text.Json`, or parse on first use |
| An eager `Import-Module` | often 0.5 s | Defer it |
| `Get-Command` on an undefined name | ~70 ms | `Test-Path Function:\Name` (#8) |

Three measures keep them out:

- **Instrumentation.** With `PWSH_TOOLKIT_TIMING` set, the loader records each phase and file into `$script:ProfileLoadTimings`. `Measure-ProfileLoad` loads the profile in fresh processes that way and reports medians per step beside a bare `pwsh` start. Measure before optimizing: the first measurement found about 70% of the load in two optional modules (Oh My Posh init and Terminal-Icons), not in the toolkit's own files.
- **Deferral.** Terminal-Icons imports on the first `PowerShell.OnIdle` after the prompt appears (one-shot, `-Global`, since an event action has its own scope). `ll`/`la`/`lh` import it themselves if they run first. The notes folder cascade resolves on the first notes command (`Get-NotesRoot`). Oh My Posh init stays synchronous by choice: deferring it would show a plain prompt first.
- **Tests.**
  - A unit test forbids `Get-Module -ListAvailable`, `ConvertFrom-Json` and `Import-Module` at the top level of any loaded file, and non-`oh-my-posh` `Get-Command` in the loader. Inside a function or scriptblock is fine; those run on demand.
  - The smoke suite checks the load's *shape*: every Common file is timed, and no single one takes over 40% of `Common/`. It deliberately doesn't use a tight absolute number, because CI hardware isn't a dev laptop.

## What NOT to do

- **Don't auto-publish to PSGallery.** Module split + publishing is v2.
- **Don't refactor the helpers themselves** unless there's a clear bug. The implementations of `j`, `peek`, `df`, `winup`, etc. have been ironed out over many iterations — preserve their behavior. Focus refactor energy on the loader/config layer.
- **Don't commit a screenshot taken as yourself.** The repo is public and a PNG publishes whatever was on screen — username, paths, drive labels, installed software, real device names — in a form no `.gitignore` catches later. Capture from a throwaway account with invented data; see [`docs/screenshots/CAPTURE-GUIDE.md`](screenshots/CAPTURE-GUIDE.md).
- **Don't point the PwshUpdate task at the repo, or "simplify" its deletes to `Remove-Item -Recurse`.** Both are privilege or data-loss bugs that look like cleanups — see #16.
- **Don't add cross-platform support unprompted.** Many helpers are Windows-specific. Documenting "Windows-only for now" is fine.
- **Don't add a config knob without updating `config.example.psd1` and the loader's hard-fallback defaults.** Keys missing from both files entirely hit the loader's `if (-not $script:Config.ContainsKey(...)) { ... }` block; only add to that block if the key is critical for the loader itself to function.
- **Don't bypass the symlink-aware `$PSCommandPath` resolution** in `pwsh-toolkit-profile.ps1`. Specifically, don't rewrite `(Get-Item $PSCommandPath).Target ?? $PSCommandPath` as plain `$PSCommandPath` — it breaks the symlink case while looking like a simplification.
- **Don't fold `winup`'s deferred self-upgrade back into the main loop.** `Invoke-WingetUpgrade.ps1` partitions `$selfReplacingIds` (PowerShell) out and runs them in a *detached* Windows PowerShell process after the in-process batch. This looks like needless indirection, but upgrading the interpreter in-process lets Windows Installer's Restart Manager close the script's own host mid-loop — stranding every remaining package and truncating the log. The detached child is deliberately `powershell.exe` (5.1), never the `pwsh` being replaced; keep that body 5.1-compatible.
- **Don't deep-merge user config over example defaults.** The loader does a shallow merge — keys the user defines fully replace those in the example, including nested hashtables like `Features`. Keep example sub-blocks complete enough that a replace doesn't lose anything important.
