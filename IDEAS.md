# Future Enhancements

Captured candidate features that fit this repo's pattern of small,
interactive, picker-driven, daily-driver tools. Each is roughly the same
scope as the folder jumper (`Profiles/Common/Navigation.ps1`) or archive
peek (`Profiles/Common/Peek.ps1`).

When picking one up, decide the open questions first, then build.

---

## 1. Git project picker (`prj`)

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

## 2. Recent-files browser (`recent` / `fresh`)

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

## 3. AI commit message (`gcm` / `git ai-commit`)

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

## 4. Clipboard history picker (`cb`)

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

- **Most momentum:** `prj` — closest cousin to existing tools, smallest behavior
  risk, immediate daily payoff.
- **Most fun:** `gcm` — gets to flex the AI tooling pattern again, useful from
  day one.
- **Highest variance:** `cb` — could be daily-driver gold or a maintenance burden
  depending on storage/secrets handling.
- **Best for cross-folder organization:** `recent` — also unblocks "I downloaded
  something an hour ago, where did it go" cases.
