# Evaluating `how`

`how` asks a model for commands you are about to run, so "it feels good" is not
a standard worth shipping against. This is how its model, candidate count and
prompt were chosen, and what the numbers actually were.

The harness is in [`tests/eval/`](../tests/eval/). It is not part of the Pester
suite — it costs money and needs a network — so it is run by hand:

```powershell
tests/eval/Invoke-HowEval.ps1                 # all three models, two runs (~$1)
tests/eval/Show-HowEvalReport.ps1             # score and report an existing run
tests/eval/Invoke-HowEval.ps1 -Only core-1    # one question, for smoke-testing
```

## Making "quality" mechanical

The failure that matters is a plausible-but-wrong command, so the scoring is
deliberately mechanical rather than a judgement call:

| check | what it catches |
|---|---|
| **parse** | the candidate is run through `[Parser]::ParseInput()`. Anything that doesn't parse is broken, full stop. |
| **resolve** | every command name in the AST is checked with `Get-Command`. This catches invented cmdlets directly. |
| **params** | every named parameter is checked against the command it is passed to. This catches the invented-`-Switch`, which is the sneakier failure. |

Plus prompt-rule compliance (single line, no markdown), toolkit-awareness
against gold answers, latency, and real cost from `usage`.

Three things had to be handled or the scores lie:

- **Placeholders.** The prompt asks for `<angle brackets>`, which are not valid
  PowerShell. They are substituted before parsing, or every templated answer
  scores as a syntax error.
- **Self-defined functions.** A candidate may define a function and call it in
  the same one-liner. Those are collected from the AST first, or they look like
  hallucinations.
- **External tools.** `docker` and `jq` are real commands this machine does not
  have. A Verb-Noun name that doesn't resolve is an invention; a bare lowercase
  word is a CLI, and its absence says nothing about the model.

Before those corrections the first pass reported a 54% resolve rate on one
category and a list of "hallucinated" commands. All of it was scorer artifact.

## Results

126 calls — 3 models x 21 questions x 2 runs, 2026-08-22.

| model | p50 | p90 | cand/call | parse | resolve | params | ¢/call |
|---|---|---|---|---|---|---|---|
| `claude-haiku-4-5` | **3.6s** | 4.5s | 2.67 | 96.4% | 96.4% | 93.8% | **0.30** |
| `claude-sonnet-5` | 5.4s | 7.3s | 3.93 | 97.6% | 97.6% | 95.2% | 0.40 |
| `claude-opus-5` | 8.6s | 11.3s | 4.74 | **98.0%** | **98.0%** | **97.5%** | 1.64 |

**Zero invented PowerShell commands across roughly 500 candidates.** Hallucinated
cmdlets are simply not the failure mode here; the prompt's "never invent a
command" rule holds on every model tested.

### The catalog helped discovery and hurt correctness

Every model found the intended toolkit command in **8/8** gold questions. Yet
`toolkit` was the *worst* category at 89.9% on all three checks. The failures
were invented parameters on toolkit commands — `dird -Recurse`, `task -New`,
`Connect-Tenant -Scopes` — because a catalog of names and synopses tells a model
that a command exists while saying nothing about its surface.

The catalog now lists each command's real parameters, read from the live
function so they cannot drift from the code. Re-asking the two questions that
produced those failures now yields `dird -NoColor` and `Format-ByteSize -Bytes`:
real parameters, on the same commands.

### Ranks past two mostly repeat

Share of candidates that are near-duplicates (token similarity >= 0.6) of
something already above them:

| rank | 2 | 3 | 4 | 5 |
|---|---|---|---|---|
| near-duplicate | 29% | **47%** | **46%** | 38% |

Hence three candidates, not five: the extra rows cost latency and tokens to
restate the list.

### Other findings

- **Caching works, except on Haiku.** Opus and Sonnet each read ~115K cached
  tokens over the run; Haiku read and wrote **zero**. The system prompt is
  ~1,900 tokens, which appears to sit under Haiku's minimum cacheable prefix —
  inferred from the data, not verified against documentation, but the zero is
  unambiguous. It erodes Haiku's cost advantage on repeated use.
- **`-WhatIf` compliance is total.** The raw score of 2/4 was the question set's
  fault: the file-deletion question leads with `-WhatIf` in 6/6 runs across all
  models, and the other destructive question is about `docker`, where `-WhatIf`
  does not exist.
- **A shipped bug, found before the first result.** The very first eval call
  returned `400 This model does not support the effort parameter`. `how` sent
  `output_config.effort` unconditionally, so `-Model claude-haiku-4-5` had never
  worked. Rather than maintain an allow-list that goes stale each release, the
  request now asks for `effort` and stands down once if the API says that model
  cannot have it.

## Why Sonnet ships and Opus is a one-liner away

Sonnet 5 is the balance point: 3 seconds faster than Opus, a quarter of the
cost, validity within about two points, and it put the gold toolkit command in
*first* place more often (8/8 against Opus's 6/8). Opus 5 leads on parameter
validity, which is the metric that matters most for code about to be run.

That is a genuine trade rather than a winner, so it is configuration:

```powershell
# Profiles/config.psd1
HowModel = 'claude-opus-5'
```

and `-Model` overrides a single call.

## What this does not measure

Which candidate a human would actually pick. Rank-1 accuracy is the number that
would most improve this evaluation, and it needs someone choosing.
