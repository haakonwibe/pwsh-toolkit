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

## 7. Intune Win32 content-info module — package the research

**What:** A focused module exposing Intune Win32 app content/delivery info that
the portal doesn't surface (the `SideCar` / `CompanyPortalCatalog` /
`Iw32LiveContentInfo` probing already done in practice). Community value; a
sharper, publishable artifact than a personal convenience.

**Why it fits the arc:** This is knowledge most admins never dig out. Separable
from pwsh-toolkit — likely its own repo/module rather than a `Common/` helper.

## 8. Conversational admin layer — natural language → Graph (wildcard)

**What:** `ask -Do "devices not checked in for 30 days"` → generate the Graph
query, run it, show the result. Natural language to Intune/Graph, in the shell.

**Why it fits the arc:** Extends the existing Claude integration (`wtf`, `ask`,
`tagdl`) from explanation into action. Highest variance — needs guardrails so a
generated query is shown/confirmed before anything runs, and read-only by default.
