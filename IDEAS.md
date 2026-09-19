# Future Enhancements

Captured candidate features that fit this repo's pattern of small,
interactive, picker-driven, daily-driver tools. Each is roughly the same
scope as the folder jumper (`Profiles/Common/Navigation.ps1`) or archive
peek (`Profiles/Common/Peek.ps1`).

When picking one up, decide the open questions first, then build.

---

## 1. Git project picker (`prj`) — ✅ Shipped in 0.1.30

Built in `Profiles/Common/Projects.ps1`. Resolved the open questions as: configurable
`ProjectRoots` (defaults to `C:\GitHub`); cached per session with `prj -Refresh` to
rescan; branch shown (read cheaply from `.git/HEAD`, no `git` subprocess) but no dirty
status; single-select (no batch ops). Kept below for the design record.

**What:** Scans `C:\GitHub` (and any configured roots) for `.git` directories,
shows them in an interactive picker with current branch + dirty/clean status,
Enter to `cd` into the selected repo.

**Why it fits:** Closest cousin to the folder jumper — same alt-screen-buffer
+ digit-key UX, same integration with `jb`/`jf` history. Daily payoff: you
already work across many repos under `C:\GitHub`.

**Scope:** ~1-2 hours. Mostly UI reuse from the jumper's `Show-InteractiveSelector`
pattern.

**Open questions:**
- Single scan root (`C:\GitHub`) or configurable list (`$script:PrjRoots`)?
- Cache the repo list (fast) vs re-scan every call (always fresh)? Probably cache
  with a `prj -Refresh` switch.
- Show branch + dirty status in the picker (requires running `git` per repo —
  slow on large lists) or just paths? Probably lazy: paths instantly, status on
  demand via `-Status`.
- Multi-select for batch operations like `git fetch` across selected repos?

---

## 2. Recent-files browser (`recent` / `fresh`) — ✅ Shipped 2026-07-06

Built in `Profiles/Common/Recent.ps1`. Resolved the open questions as: default 30
files, `-Limit`/positional to change; newest N regardless of age (no time-window
filter); sources are hardcoded defaults (Downloads + both Desktop variants) with
machine additions via `$script:RecentFolders +=`, the `$script:JumpFolders`
pattern as planned; Enter opens with the default app, and archives auto-`peek` —
no extra picker key needed. ADS descriptions from `tagdl` show in the listing.
Kept below for the design record.

**What:** Cross-folder version of `fr`. Scans Downloads + Desktop + a configurable
watchlist, shows the newest N files in a picker with the same BBS/4DOS coloring
as `dird`. Enter opens in default app, or auto-`peek` if it's an archive.

**Why it fits:** Bridges the BBS aesthetic with the reality that "recent stuff"
lands in 3-4 different folders. Plays nicely with both `DownloadsOrganizer`
(showing AI descriptions if present) and `peek` (auto-extracting archives on
selection).

**Scope:** ~2 hours. The ADS-reading logic from `Get-DirDescriptions.ps1` is
reusable; main new work is the multi-folder scan + sort + picker.

**Open questions:**
- How many files in the default view? Probably 30, configurable with `-Limit`.
- Time window: "last 7 days" filter, or just "newest N regardless of age"?
- Watchlist sources: hardcoded defaults in `Common/` + machine-specific additions
  via `Machines/{COMPUTERNAME}.ps1`, same pattern as `$script:JumpFolders`.
- Should it auto-`peek` archives on Enter, or just `cd` to their location? Maybe
  Enter = open, `p` key in picker = peek.

---

## 3. AI commit message (`gcm` / `git ai-commit`) — ❌ Shelved 2026-06-30

Shelved after reconsidering the value. `gcm` only ever sees `git diff --staged`
— the *what* — but a good commit message is mostly the *why*, which isn't in the
diff, so the tool is structurally stuck paraphrasing the change back to you (the
"bland" risk already noted below). And commits made through an AI agent like Claude
Code already get a message written with full session context — what the change was
*for* — which is strictly more than a diff-only helper can know. The niche it was
meant to fill is mostly already filled, and filled better. Kept below for the
design record.

**What:** Pipes `git diff --staged` to Claude Haiku, drops you into the standard
`git commit` editor with the generated message pre-filled. Reuses the existing
`Anthropic-API-Key` SecretStore convention.

**Why it fits:** Same Anthropic API + SecretStore pattern as `DownloadsOrganizer`.
Cost is trivial (~$0.001/commit on Haiku 4.5). Fills a real gap on tired-eyes
commits where you'd otherwise skip writing a good message.

**Scope:** ~2-3 hours. Most of the work is prompt engineering — instructing
Claude to follow this repo's commit style (look at `git log --oneline -20` for
examples), keep titles under 70 chars, write "why" not "what".

**Open questions:**
- Pre-fill the editor (interactive review/edit before commit) vs commit
  directly with `-m` (faster but no review)? Strongly prefer pre-fill.
- Include recent commit messages in the prompt as style examples? Yes —
  cheap and dramatically improves style adherence.
- Handle empty staged diff with a friendly "stage something first" message.
- Risk: AI commit messages tend toward bland. Mitigation: prompt should explicitly
  ask for the *why* (which the human still has to verify by reading), not a
  paraphrase of the diff.
- Should it offer to `git add -A` first, or strictly require staged-only? Strictly
  staged. Adding-all is too easy to get wrong (secrets, junk files).

---

## 4. Clipboard snippet stash (`cb`) — ✅ Shipped 2026-07-19

Built in `Profiles/Common/Clipboard.ps1`. Reframed from "clipboard history" to a
**curated snippet stash** — the sharper tool, and the one Win+V can't be. A pure
manual stash of raw clipboard entries has a hole: to catch something you'd have
to run `cb` right after copying and before the next copy, which is exactly the
moment history is meant to save you from. Win+V already covers chronological
recent-copy recovery; the gap it *can't* fill is durable, named,
fuzzy-searchable snippets that survive reboots. So `cb` is "`j` bookmarks, but
for text." Resolved open questions:

- **Capture model → manual add, option (a).** Rejected the background watcher
  (b): the "spy on my clipboard" discomfort is real and a poller captures every
  password a manager copies straight to plaintext on disk. Win+V covers (c)'s
  "recover my last few copies" already.
- **Storage → plaintext JSON**, `%LOCALAPPDATA%\pwsh-toolkit\clipboard-snippets.json`
  — the `jump-bookmarks.json` pattern (Get/Save helpers, tolerant read,
  -ThrowOnError before a rewrite). No DPAPI in v1: curating what goes in already
  removes the accidental-password risk a watcher would have; the docs point
  passwords/tokens at SecretStore instead. A `-Secret` DPAPI mode is a clean
  later addition if wanted.
- **Naming → optional labels.** `cb -Add -Label sig` names a snippet (upsert by
  label, like `j -Add`); unlabeled entries show by their first line. `cb <text>`
  and `cb -Remove <text>` match label OR content substring, so unlabeled
  snippets are still reachable and removable without a picker delete key.
- **Trim → cap 100, drop oldest UNLABELED first**; labeled favorites are never
  auto-dropped. Identical text upserts (bumps to top) instead of duplicating.
- **Picker → `Show-Picker` unchanged.** Rows show age + label/preview + an
  `(N lines)` marker for multi-line blobs. No side preview pane — that would
  require modifying `Show-Picker`, breaking the "every consumer uses the picker
  untouched" property `prj`/`recent`/`rdp` all keep. Enter copies to the
  clipboard (reliable auto-paste isn't possible from the alt-screen buffer).

Kept below for the design record.

**What:** A small picker over recent clipboard entries. Win+V exists but can't
fuzzy-search, and clears between reboots.

**Why it fits:** Same picker UX, useful daily. Reuses the alt-screen-buffer
trick so the picker doesn't pollute scrollback.

**Scope:** ~3-4 hours, *or* much simpler if you accept the "manual stash" model.

**Open questions — pick one approach:**
- **(a) Manual stash:** A hotkey or `cb stash` command snapshots the current
  clipboard into a history file. `cb` opens a picker over the file. Simple, no
  daemon, fully under your control. Loses anything you didn't explicitly stash.
- **(b) Background watcher:** A scheduled task or PowerShell job polls the
  clipboard every N seconds and dedupes into the history. Captures everything.
  Adds a background process and "spy on my clipboard" feels uncomfortable.
- **(c) Just learn Win+V better:** Native Windows clipboard history (Win+V) is
  already 80% of this. Maybe the gap doesn't justify the work.

Recommend (a). If after a week you wish it caught everything, then consider (b).

**Other questions:**
- Storage: plaintext file in `%LOCALAPPDATA%\ClipboardHistory\history.jsonl`?
  Risk if you stash secrets — needs a `.gitignore`-style exclude filter or an
  `Encrypted` mode using DPAPI.
- History size: trim to last 100 entries? Last 7 days?
- Picker should show first line of each entry + a preview pane (Right arrow to
  expand multi-line entries).

---

## Notes on picking one

- **Most fun:** `gcm` — gets to flex the AI tooling pattern again, useful from
  day one.
- **Highest variance:** `cb` — could be daily-driver gold or a maintenance burden
  depending on storage/secrets handling.
- **Best for cross-folder organization:** `recent` — also unblocks "I downloaded
  something an hour ago, where did it go" cases.

---

# Bigger bets — beyond the CLI

A different class from the helpers above: these change the *medium* or *mode*
of the toolkit rather than adding another picker-driven verb. The insight is
that the toolkit already computes genuinely valuable state (`Get-TenantOverview`,
`Get-IntuneOverview`, `Get-AzureResourceCosts`) and then throws it at a terminal
where it scrolls away. These bets reuse that data differently.

## 5. Cockpit — a visual dashboard from data the toolkit already gathers — ✅ Shipped 2026-07-21 (static snapshot; live/hosted still open)

**What:** Render the overview commands' output as a single at-a-glance visual
dashboard instead of scrolling green text — compliance donut, stale devices
called out, device-by-OS bars, a cost trend. Same data, different leverage.

**Why it fits the arc:** Plays to an existing Blazor skill and a real Azure
Static Web Apps hosting path. Prototype first as a self-contained HTML artifact
(mock-but-realistic Intune numbers) to react to the actual thing; then decide
whether to wire it to live `Get-IntuneOverview` output and, later, host it.

**Open questions:** static snapshot (PowerShell writes an HTML file you open)
vs a live hosted SWA reading Graph; how much to lean on the existing `/beta`
Settings Catalog reads; whether cost data (Azure) and tenant data (Graph) share
one board or split.

## 6. Proactive tenant briefing — from "I invoke it" to "it watches"

**What:** A scheduled agent that each morning diffs the tenant against yesterday
and surfaces only what *changed* — new non-compliant devices, ones gone stale,
a cost spike, secrets/certs nearing expiry. Push exceptions, don't pull status.

**Why it fits the arc:** Turns the reactive overview commands into a proactive
assistant. Builds on the existing `task`/scheduled-task surface (or a cloud
routine). Needs a stored "yesterday" snapshot to diff against.

## 7. Intune Win32 content-info module — package the research — 🌱 Seeded in-toolkit 2026-08-15

> Status note: three commands now live in `Profiles/M365/IntuneWin32Apps.ps1` as
> ordinary toolkit cmdlets — `Get-IntuneWin32App` (inventory),
> `Get-IntuneWin32AppDetail` (install mechanics, MSI internals, applicability
> gates, detection/requirement rules, outcome counts, dependency and
> supersedence edges, assignments with group names resolved), and
> `Get-IntuneWin32AppContentInfo` (committed content versions, real vs.
> encrypted file sizes, stale uploads). The standalone-module framing below
> stays open for the deeper probe research, if/when it's worth publishing
> separately.

**What:** A focused module exposing Intune Win32 app content/delivery info that
the portal doesn't surface (the `SideCar` / `CompanyPortalCatalog` /
`Iw32LiveContentInfo` probing already done in practice). Community value; a
sharper, publishable artifact than a personal convenience.

**Why it fits the arc:** This is knowledge most admins never dig out. Separable
from pwsh-toolkit — likely its own repo/module rather than a `Common/` helper.

## 8. Conversational admin layer — natural language → Graph (wildcard) — 🌱 First step shipped 2026-08-23

> Status note: `how` (`Profiles/Common/How.ps1`) is the read-only, general-purpose
> half of this — natural language in, runnable commands out, with the guardrail
> this section asks for: the chosen command lands on the prompt *unexecuted*, so
> nothing runs until you press Enter. It answers Graph questions like any other,
> but it does not execute them, and it holds no tenant context between calls.
> What is still open below is the *doing* part: running the generated query and
> shaping the result. `docs/how-eval.md` has the measured behaviour to build on.


**What:** `ask -Do "devices not checked in for 30 days"` → generate the Graph
query, run it, show the result. Natural language to Intune/Graph, in the shell.

**Why it fits the arc:** Extends the existing Claude integration (`wtf`, `ask`,
`tagdl`) from explanation into action. Highest variance — needs guardrails so a
generated query is shown/confirmed before anything runs, and read-only by default.

---

# Captured 2026-08-25

Three candidates noted as they came up; none of them is started. Where an entry
rests on a measurement, the measurement is deliberately not recorded here —
re-run it when picking the entry up. A number from one machine on one day ages
badly, and in two of the three cases producing that number is the feature.

## 9. `peek` for `.intunewin` — read the package, not just the portal

> Status note (2026-09-19): likely absorbed by #12. The companion module
> already handles the format, so `peek` would hand `.intunewin` files to it
> rather than carry its own decoder.

**Evidence:** `AppData\Local\IntuneWinAppUtil\IntuneWinAppUtil.exe` and
`Downloads\Installers\IntuneWinAppUtilDecoder.exe` are both on this machine.
The second is the tell: inspecting a Win32 package today means leaving the
toolkit for a third-party decoder in a Downloads folder.

**What:** `peek app.intunewin` reports what's inside a package without
hand-unzipping it — setup file, package name, unencrypted payload size, and for
MSI packages the product/upgrade codes, execution context and per-machine flag.
`-Extract` decrypts the payload and jumps you into it, exactly as `peek` does
for a `.rar` today.

**Why it fits:** `peek` already dispatches by extension, so this is one more
branch on an existing table — no new verb, no new UX. And it closes a real
asymmetry: the M365 half of the toolkit reads Win32 apps *from Graph*
(inventory, detection rules, assignments, content versions) and has never
touched the local artifact those apps are built from. The fields it would
surface are the same ones `Get-IntuneWin32AppDetail` reports from the cloud
side — readable *before* the upload rather than after.

**Feasibility:** self-contained and offline. A `.intunewin` is a zip holding
`Metadata\Detection.xml` plus an AES-encrypted `Contents\IntunePackage.intunewin`,
and the key lives in that XML — so decryption needs no tenant, no network, and
no secret. Test fixtures can be generated locally with the `IntuneWinAppUtil.exe`
already installed. This is the half that doesn't need luck.

**The stretch:** `Get-IntuneWin32App … | peek` — inspect what is actually
deployed to the fleet rather than what happens to be on this disk.
`Get-IntuneWin32AppContentInfo` already walks the committed content versions.
Whether it can be finished depends on the file encryption info being reachable
on a *read* from Graph, which is unverified — check that before promising it,
and don't let it hold up the local half.

**Open questions:**
- Does `peek` own this, or does it want its own verb? `peek` keeps the muscle
  memory; a separate verb keeps `peek -List` / `-Active` / `-Clean` coherent,
  since a decrypted package isn't quite a temp extraction like the others.
- Decrypt in-process with .NET AES, or shell out to the decoder that's already
  there? In-process removes the dependency and is testable; shelling out is an
  afternoon. Prefer in-process — the key handling is ~20 lines and the whole
  point is retiring the downloaded exe.
- Prior art check before building: MSEndpointMgr's `IntuneWin32App` module
  covers packaging/upload/download. Worth reading for format details, and worth
  being honest in the README about what's novel here versus what's convenience.

## 10. The shell history is a data set nobody reads

**What:** Muscle memory favours the generic command over the toolkit one — `cd`
over `j`, a bare listing over `ll`, `winget` over `winup` — and the toolkit has
no way to notice, so the gap persists indefinitely. Two possible shapes, and
they are separable.

(a) A report — `Get-ToolkitUsage`: which commands actually get used, which have
never once been run, and which keep getting typed the long way. The raw material
is PSReadLine's history file, already on disk.

(b) A just-in-time nudge through PSReadLine's `AddToHistoryHandler`: after a `cd`
into a directory `prj` would have jumped to, one dim line naming the shorter
form. Contextual, at the moment of the miss, derived from real input rather than
from a guess about what the user doesn't know.

**Why it fits:** `toolkit`, `tip` and `how` all attack the discovery problem —
the toolkit has more commands than anyone holds in their head — and all three
guess at what the user doesn't know. This is the version that reads what the
user actually does. The buffer/handler mechanics are already understood from
`how` (ARCHITECTURE.md #15).

**Constraint, known up front:** the PSReadLine history file carries **no
timestamps**. All-time counts are the only window it can produce; anything
trend-shaped ("this week", "since 0.7.0") needs its own log written going
forward. That argues for (b) writing a small timestamped usage log as a side
effect, with (a) reading it — history for the cold start, the log for trends.

**Open questions:**
- Nudge budget: once per pattern per N days? Only above a confidence bar?
  Without a budget this is Clippy, and the off switch has to be a config slot,
  not folklore.
- Where does the nudge render? The handler runs *before* execution, so writing
  from it puts the hint above the command's own output. Surfacing it on the
  next prompt is correct, but the prompt is owned by Oh My Posh in the common
  case — `OnIdle` may be the seam. Verify against both prompt modes.
- Privacy is the whole ballgame here, and it constrains the feature rather than
  just the docs. A shell history is one of the likelier places to find a secret
  typed on a command line. Count toolkit command *names* and nothing else: never
  store or render raw history lines, arguments or paths; keep the store local
  (`Get-ToolkitDataPath`, ARCHITECTURE.md #13); and make "would I paste this
  straight into an issue?" the bar any report output has to clear.

## 11. Profile startup budget — measure it, then spend the findings

**What:** `Measure-ProfileLoad` — the profile instruments its own load and
prints where the time went, per phase and per file — plus a budget assertion in
the smoke suite, so a future file cannot quietly add a third of a second. The
fixes then follow from the numbers rather than from taste.

**Shape of a first pass** (the figures are deliberately not written down — take
fresh ones): the cost is not evenly spread, and dot-sourcing `Common/` is not
the problem it looks like. The largest single line item was an optional module
import — `Terminal-Icons`, which is lazy-loadable and currently loads in every
shell whether or not a listing is ever run. One Common file came out several
times heavier than the next one down, which wants an explanation before it wants
an optimization. The two `Get-Module -ListAvailable` probes and the prompt
initialisation each cost more than their job suggests.

**Why it fits:** the same instinct as `docs/how-eval.md` — measure the thing
instead of having opinions about it — turned on the toolkit itself. It also fits
the two-layer test split (ARCHITECTURE.md #14): a budget is a load-state
assertion, so it belongs in `Smoke.Tests.ps1`.

**Open questions:**
- A budget in CI is a flaky-test risk, since CI hardware is not the dev machine.
  Assert a *relative* shape (no single file over N% of the total) or pin an
  absolute ceiling loose enough to catch only real regressions?
- Lazy-loading the heavy optional import means the first listing pays for it
  instead of every shell. Better, but it moves a cost into an interactive
  moment — confirm it doesn't just relocate the annoyance.
- Cold and warm load differ by far more than the tuning stands to gain, and the
  cold case is the one actually felt (the first shell after a boot). Measure
  cold as well, or the work optimizes the case that was never the problem.
- Does `Measure-ProfileLoad` ship as a public command or stay a dev tool? Public
  makes the toolkit's own cost self-evident to anyone forking it; a dev tool
  keeps the command surface smaller.

---

# Captured 2026-09-19

## 12. Companion modules — front a separately built module without absorbing it

**What:** Give the toolkit a way to front a module developed in its own repo.
The first candidate is a device-side Intune Win32 backup module: save the
`.intunewin` content of any Win32 app this device is already entitled to,
device- or user-targeted, and read the device's own app state. The toolkit side
stays thin:
- a short alias;
- a place in `toolkit` / `tip`;
- `peek` handing `.intunewin` files to the module, which absorbs #9.

**Why it fits:** The M365 half already reads Win32 apps from Graph (#7). This is
the device-side counterpart: what this machine actually received. It is also
the natural home for #9's package inspection, since the module already handles
the format.

**Shape (leaning):**
- **Don't vendor the source.** The module keeps its own repo, tests and release.
  It has a build step (a compiled helper), needs elevation for most commands,
  and keeps its own provenance record. None of that belongs in a profile
  toolkit's install path.
- **Install it to the all-users module path** (`C:\Program Files\PowerShell\Modules`),
  which `pwshup` keeps stable across PowerShell updates.
- **Add nothing to startup.** No import and no `Get-Module -ListAvailable` probe
  at load (see #11). The wrappers resolve the command on first use through
  module autoloading, and print an install hint when it's missing.
- **Elevation.** Either tell the user to run elevated, or relaunch elevated like
  `winup -Elevated`. Objects don't cross the elevation boundary, so a relaunch
  only suits the save path.

**Open questions:**
- Public or private? The toolkit is public and the module isn't yet. A wrapper
  for a module nobody else can install is noise, so until the module is
  published the integration can live in a gitignored `Machines/<COMPUTERNAME>.ps1`
  instead.
- Which codebase to target: the rewrite, once its download path lands. Keep the
  command names stable (`Save-…`, `Get-…DeviceAppState`) so the wrapper doesn't
  care which version is installed.
- Is this a general "companion module" slot (a config list of optional modules,
  each with its aliases) or a one-off? One module doesn't justify a mechanism;
  a second would.
- Alias names.
