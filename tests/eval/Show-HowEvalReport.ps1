#Requires -Version 7.0
<#
.SYNOPSIS
    Score and report a `how` evaluation run.
#>
[CmdletBinding()]
param([string] $InFile = (Join-Path $PSScriptRoot 'how-eval.jsonl'))

$ErrorActionPreference = 'Stop'
# The profile so toolkit commands resolve — a suggestion of `prj` must score as
# a real command, not a hallucination.
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Profiles/pwsh-toolkit-profile.ps1') *> $null
. (Join-Path $PSScriptRoot 'HowEvalScoring.ps1')

$rows = @(Get-Content -LiteralPath $InFile | ForEach-Object { $_ | ConvertFrom-Json })
"rows: {0}   models: {1}" -f $rows.Count, (($rows.model | Sort-Object -Unique) -join ', ')

function Get-Pct { param([double[]] $V, [double] $P)
    if (-not $V) { return 0 }
    $s = @($V | Sort-Object)
    $s[[Math]::Min($s.Count - 1, [int][Math]::Floor($P * $s.Count))]
}

# ---------------------------------------------------------------- per model --
$summary = foreach ($g in ($rows | Group-Object model)) {
    $ok = @($g.Group | Where-Object { -not $_.error })
    $lat = @($ok.latencyMs | ForEach-Object { [double]$_ })
    $price = $script:HowEvalPrices[$g.Name]

    $cands = @(); $scores = @()
    foreach ($r in $ok) {
        foreach ($c in @($r.candidates)) {
            $cands += $c
            $scores += (Get-CandidateScore -Command ([string]$c.command))
        }
    }

    $inTok  = ($ok.inTokens  | Measure-Object -Sum).Sum
    $outTok = ($ok.outTokens | Measure-Object -Sum).Sum
    $cw     = ($ok.cacheWrite | Measure-Object -Sum).Sum
    $cr     = ($ok.cacheRead  | Measure-Object -Sum).Sum
    $cost   = ($inTok / 1e6 * $price.in) + ($outTok / 1e6 * $price.out)

    [pscustomobject]@{
        model        = $g.Name
        calls        = $ok.Count
        errors       = @($g.Group | Where-Object { $_.error }).Count
        p50ms        = [int](Get-Pct $lat 0.5)
        p90ms        = [int](Get-Pct $lat 0.9)
        candPerCall  = [math]::Round($cands.Count / [Math]::Max(1, $ok.Count), 2)
        parsePct     = [math]::Round(100 * (@($scores | Where-Object parses).Count / [Math]::Max(1, $scores.Count)), 1)
        resolvePct   = [math]::Round(100 * (@($scores | Where-Object { $_.parses -and -not $_.unresolved }).Count / [Math]::Max(1, $scores.Count)), 1)
        paramPct     = [math]::Round(100 * (@($scores | Where-Object { $_.parses -and -not $_.badParams }).Count / [Math]::Max(1, $scores.Count)), 1)
        multiline    = @($scores | Where-Object multiline).Count
        markdown     = @($scores | Where-Object markdown).Count
        cacheReadTok = $cr
        cacheWriteTok = $cw
        costUSD      = [math]::Round($cost, 3)
        centsPerCall = [math]::Round(100 * $cost / [Math]::Max(1, $ok.Count), 2)
    }
}

''
'=== per model ===='
$summary | Format-Table -AutoSize model, calls, errors, p50ms, p90ms, candPerCall, parsePct, resolvePct, paramPct, multiline, markdown, centsPerCall, costUSD

''
'=== cache (is the catalog prefix actually caching?) ===='
$summary | Format-Table -AutoSize model, cacheReadTok, cacheWriteTok

# ------------------------------------------------------------- hallucinated --
''
'=== INVENTED PowerShell commands (Verb-Noun that does not exist) ===='
$halluc = @{}
foreach ($r in ($rows | Where-Object { -not $_.error })) {
    foreach ($c in @($r.candidates)) {
        $s = Get-CandidateScore -Command ([string]$c.command)
        foreach ($u in $s.unresolved) {
            $k = "$($r.model)|$u"
            if (-not $halluc.ContainsKey($k)) { $halluc[$k] = 0 }
            $halluc[$k]++
        }
    }
}
if ($halluc.Count) {
    $halluc.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 |
        ForEach-Object { "  {0,-40} x{1}" -f $_.Key, $_.Value }
} else { '  none' }

# ------------------------------------------------------------ what failed --
''
'=== candidates that failed a check ===='
$failed = 0
foreach ($r in ($rows | Where-Object { -not $_.error })) {
    foreach ($c in @($r.candidates)) {
        $cmd = [string]$c.command
        $s2 = Get-CandidateScore -Command $cmd
        $why = @()
        if (-not $s2.parses)   { $why += 'no-parse' }
        if ($s2.unresolved)    { $why += "unknown: $($s2.unresolved -join ',')" }
        if ($s2.badParams)     { $why += "bad param: $($s2.badParams -join ',')" }
        if ($s2.multiline)     { $why += 'multiline' }
        if ($s2.markdown)      { $why += 'markdown' }
        if (-not $why) { continue }
        $failed++
        $short = if ($cmd.Length -gt 110) { $cmd.Substring(0, 110) + [char]0x2026 } else { $cmd }
        "  [{0}] {1}/{2}: {3}" -f $r.model, $r.id, ($why -join '; '), $short
    }
}
if (-not $failed) { '  none' }

# --------------------------------------------------------------- by category --
''
'=== validity by category (all models) ===='
foreach ($g in ($rows | Where-Object { -not $_.error } | Group-Object cat)) {
    $sc = @()
    foreach ($r in $g.Group) { foreach ($c in @($r.candidates)) { $sc += (Get-CandidateScore -Command ([string]$c.command)) } }
    if (-not $sc) { continue }
    "  {0,-12} parse {1,5:N1}%  resolve {2,5:N1}%  params {3,5:N1}%   (n={4})" -f $g.Name,
        (100 * @($sc | Where-Object parses).Count / $sc.Count),
        (100 * @($sc | Where-Object { $_.parses -and -not $_.unresolved }).Count / $sc.Count),
        (100 * @($sc | Where-Object { $_.parses -and -not $_.badParams }).Count / $sc.Count),
        $sc.Count
}

# ------------------------------------------------------------------- gold ----
''
'=== toolkit awareness (gold command present?) ===='
foreach ($g in ($rows | Where-Object { $_.gold -and -not $_.error } | Group-Object model)) {
    $hit = 0; $top = 0; $n = 0
    foreach ($r in $g.Group) {
        $n++
        $cmds = @($r.candidates | ForEach-Object { [string]$_.command })
        $gold = @($r.gold)
        if ($cmds | Where-Object { $c = $_; $gold | Where-Object { $c -match "(^|\s|\|)$([regex]::Escape($_))(\s|$)" } }) { $hit++ }
        if ($cmds.Count -and ($gold | Where-Object { $cmds[0] -match "(^|\s|\|)$([regex]::Escape($_))(\s|$)" })) { $top++ }
    }
    "  {0,-18} anywhere {1}/{2}   as first candidate {3}/{2}" -f $g.Name, $hit, $n, $top
}

# ---------------------------------------------------------------- destructive -
''
'=== destructive questions: is -WhatIf the first candidate? ===='
foreach ($g in ($rows | Where-Object { $_.wantWhatIf -and -not $_.error } | Group-Object model)) {
    $first = @($g.Group | Where-Object { @($_.candidates).Count -and [string]$_.candidates[0].command -match '(?i)-WhatIf' }).Count
    $any = @($g.Group | Where-Object { @($_.candidates | Where-Object { [string]$_.command -match '(?i)-WhatIf' }).Count }).Count
    "  {0,-18} first {1}/{2}   anywhere {3}/{2}" -f $g.Name, $first, $g.Group.Count, $any
}

# ---------------------------------------------------------------- redundancy -
''
'=== redundancy by rank (max similarity to any earlier candidate) ===='
'    higher = this rank is mostly repeating something above it'
$byRank = @{}
foreach ($r in ($rows | Where-Object { -not $_.error })) {
    $cmds = @($r.candidates | ForEach-Object { [string]$_.command })
    for ($i = 1; $i -lt $cmds.Count; $i++) {
        $best = 0.0
        for ($j = 0; $j -lt $i; $j++) {
            $s = Get-Jaccard $cmds[$i] $cmds[$j]
            if ($s -gt $best) { $best = $s }
        }
        $rank = $i + 1
        if (-not $byRank.ContainsKey($rank)) { $byRank[$rank] = @() }
        $byRank[$rank] += $best
    }
}
foreach ($k in ($byRank.Keys | Sort-Object)) {
    $v = $byRank[$k]
    "  rank {0}: mean {1:N2}   >=0.6 (near-duplicate) {2}/{3}" -f $k,
        (($v | Measure-Object -Average).Average), @($v | Where-Object { $_ -ge 0.6 }).Count, $v.Count
}

''
'=== candidates returned per call ===='
$rows | Where-Object { -not $_.error } | Group-Object model | ForEach-Object {
    $counts = @($_.Group | ForEach-Object { @($_.candidates).Count })
    "  {0,-18} {1}" -f $_.Name, (($counts | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join '  ')
}
