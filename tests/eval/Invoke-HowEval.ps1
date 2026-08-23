#Requires -Version 7.0
<#
.SYNOPSIS
    Evaluation harness for `how` — model comparison on speed, cost and quality.

.DESCRIPTION
    Runs a fixed question set through the REAL system prompt and schema that
    `how` uses (imported from How.ps1, not reimplemented), across several
    models and repeats, and scores the answers automatically.

    "Quality" here is deliberately mechanical, because the failure that matters
    is a plausible-but-wrong command:
      parse   - does the candidate parse as PowerShell at all
      resolve - does every command it invokes actually exist on this machine
      params  - does every named parameter exist on the command it is passed to
    Plus prompt-rule compliance (single line, no markdown), toolkit-awareness
    against gold answers, and inter-candidate redundancy by rank.

    Results stream to a JSONL file as they arrive, so a crash or a rate limit
    costs only the remaining rows.
#>
[CmdletBinding()]
param(
    [string[]] $Model = @('claude-opus-5', 'claude-sonnet-5', 'claude-haiku-4-5'),
    [int]      $Runs = 2,
    [int]      $Count = 5,
    [string[]] $Only,
    [string]   $OutFile,
    [switch]   $ScoreOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'how-eval.jsonl' }

# The profile, so the toolkit's own commands resolve during scoring (a
# suggestion of `prj` must not be scored as a hallucination) and so the system
# prompt carries the same catalog a real call would.
. (Join-Path $repoRoot 'Profiles/pwsh-toolkit-profile.ps1') *> $null

# ---------------------------------------------------------------- questions --
# Gold: a toolkit command that ought to appear. WhatIf: destructive, so the
# prompt's "-WhatIf first" rule should show up in the top candidate.
$Questions = @(
    @{ id = 'core-1'; cat = 'core';       q = 'find the 10 largest files under this folder' }
    @{ id = 'core-2'; cat = 'core';       q = 'show which process is listening on port 8080' }
    @{ id = 'core-3'; cat = 'core';       q = 'count lines of code in all ps1 files recursively' }

    @{ id = 'mod-1';  cat = 'modules';    q = 'find and install a module from the gallery' }
    @{ id = 'mod-2';  cat = 'modules';    q = 'list which of my installed modules have updates available' }
    @{ id = 'mod-3';  cat = 'modules';    q = 'see every version of a module I have installed and remove the old ones' }

    @{ id = 'graph-1'; cat = 'graph';     q = 'list intune devices that have not checked in for 30 days' }
    @{ id = 'graph-2'; cat = 'graph';     q = 'show which entra users have no mfa methods registered' }
    @{ id = 'graph-3'; cat = 'graph';     q = 'export all conditional access policies to json' }

    @{ id = 'tk-1';   cat = 'toolkit';    q = 'jump to one of my git repositories';        gold = @('prj') }
    @{ id = 'tk-2';   cat = 'toolkit';    q = 'how much free space is on my disks';        gold = @('df') }
    @{ id = 'tk-3';   cat = 'toolkit';    q = 'look inside a zip without extracting it';   gold = @('peek') }
    @{ id = 'tk-4';   cat = 'toolkit';    q = 'what did I download recently';              gold = @('recent', 'fr', 'dird') }

    @{ id = 'sys-1';  cat = 'sysadmin';   q = 'create a scheduled task that runs a script at logon' }
    @{ id = 'sys-2';  cat = 'sysadmin';   q = 'show installed windows updates from the last month' }
    @{ id = 'sys-3';  cat = 'sysadmin';   q = 'find which service is set to auto start but is stopped' }

    @{ id = 'data-1'; cat = 'data';       q = 'flatten a nested json file into a csv' }
    @{ id = 'data-2'; cat = 'data';       q = 'extract all email addresses from a log file' }
    @{ id = 'data-3'; cat = 'data';       q = 'group a csv by a column and sum another column' }

    @{ id = 'del-1';  cat = 'destructive'; q = 'delete all files older than 90 days in a folder'; whatif = $true }
    @{ id = 'del-2';  cat = 'destructive'; q = 'remove every stopped docker container';           whatif = $true }
)

if ($Only) { $Questions = @($Questions | Where-Object { $Only -contains $_.id }) }

# ------------------------------------------------------------------ scoring --
$script:PlaceholderPattern = '<[^>\r\n]{1,60}>'

function Get-NormalizedCommand {
    # <angle bracket> placeholders are what the prompt asks for, and they are
    # not valid PowerShell — substitute before parsing or every templated
    # answer scores as a syntax error.
    param([string] $Command)
    $Command -replace $script:PlaceholderPattern, "'PLACEHOLDER'"
}

function Get-CandidateScore {
    param([string] $Command)

    $norm = Get-NormalizedCommand $Command
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($norm, [ref] $null, [ref] $errs)

    $result = [ordered]@{
        parses       = (@($errs).Count -eq 0)
        multiline    = ($Command -match "`r|`n")
        markdown     = ($Command -match '```|\*\*')
        placeholders = ([regex]::Matches($Command, $script:PlaceholderPattern)).Count
        commands     = @()
        unresolved   = @()
        badParams    = @()
    }
    if (-not $result.parses) { return [pscustomobject]$result }

    $cmdAsts = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    $names = New-Object System.Collections.Generic.List[string]
    $unres = New-Object System.Collections.Generic.List[string]
    $bad = New-Object System.Collections.Generic.List[string]

    foreach ($c in $cmdAsts) {
        $name = $c.GetCommandName()
        if (-not $name -or $name -match '^\$') { continue }
        $names.Add($name)

        $resolved = Get-Command -Name $name -ErrorAction Ignore | Select-Object -First 1
        if (-not $resolved) { $unres.Add($name); continue }
        while ($resolved.CommandType -eq 'Alias' -and $resolved.ResolvedCommand) { $resolved = $resolved.ResolvedCommand }
        # Native executables and scripts have no discoverable parameter metadata.
        if ($resolved.CommandType -in 'Application', 'ExternalScript') { continue }

        $valid = @()
        try {
            foreach ($p in $resolved.Parameters.GetEnumerator()) {
                $valid += $p.Key
                if ($p.Value.Aliases) { $valid += $p.Value.Aliases }
            }
        }
        catch { continue }
        if (-not $valid) { continue }

        foreach ($el in $c.CommandElements) {
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $pn = $el.ParameterName
            # PowerShell accepts unambiguous prefixes, so a prefix match counts.
            $hit = @($valid | Where-Object { $_ -eq $pn -or $_ -like "$pn*" })
            if (-not $hit) { $bad.Add("$name -$pn") }
        }
    }

    $result.commands   = @($names)
    $result.unresolved = @($unres)
    $result.badParams  = @($bad)
    [pscustomobject]$result
}

function Get-Jaccard {
    param([string] $A, [string] $B)
    $ta = [System.Collections.Generic.HashSet[string]]::new([string[]]@($A.ToLower() -split '\W+' | Where-Object { $_ }))
    $tb = [System.Collections.Generic.HashSet[string]]::new([string[]]@($B.ToLower() -split '\W+' | Where-Object { $_ }))
    if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return 0.0 }
    $inter = [System.Collections.Generic.HashSet[string]]::new($ta)
    $inter.IntersectWith($tb)
    $union = [System.Collections.Generic.HashSet[string]]::new($ta)
    $union.UnionWith($tb)
    [double]$inter.Count / $union.Count
}

# ------------------------------------------------------------------- runner --
function Invoke-EvalCall {
    # Goes through the toolkit's own Invoke-HowRequest, so the eval measures the
    # request the command actually sends — including the effort stand-down for
    # models that reject it — rather than a lookalike that can drift.
    param([string] $Question, [string] $Model, [int] $Count, [string] $ApiKey)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-HowRequest -Question $Question -ApiKey $ApiKey -Model $Model -Count $Count
    $sw.Stop()

    $text = @($resp.content | Where-Object { $_.type -eq 'text' })[0].text
    $cands = if ($text) { @(($text | ConvertFrom-Json).candidates) } else { @() }

    [pscustomobject]@{
        latencyMs  = [int]$sw.Elapsed.TotalMilliseconds
        stopReason = $resp.stop_reason
        usage      = $resp.usage
        candidates = $cands
    }
}

if (-not $ScoreOnly) {
    $apiKey = Get-HowApiKey -Quiet
    if (-not $apiKey) { throw 'No API key.' }

    $total = $Model.Count * $Runs * $Questions.Count
    $n = 0
    if (Test-Path $OutFile) { Remove-Item $OutFile }

    foreach ($m in $Model) {
        for ($run = 1; $run -le $Runs; $run++) {
            foreach ($qq in $Questions) {
                $n++
                $row = [ordered]@{
                    model = $m; run = $run; id = $qq.id; cat = $qq.cat; question = $qq.q
                    gold = @($qq.gold); wantWhatIf = [bool]$qq.whatif
                }
                try {
                    $r = Invoke-EvalCall -Question $qq.q -Model $m -Count $Count -ApiKey $apiKey
                    $row.latencyMs   = $r.latencyMs
                    $row.stopReason  = $r.stopReason
                    $row.inTokens    = $r.usage.input_tokens
                    $row.outTokens   = $r.usage.output_tokens
                    $row.cacheWrite  = $r.usage.cache_creation_input_tokens
                    $row.cacheRead   = $r.usage.cache_read_input_tokens
                    $row.candidates  = @($r.candidates | ForEach-Object {
                        @{ command = $_.command; explanation = $_.explanation }
                    })
                    $row.error = $null
                }
                catch {
                    $row.error = $_.Exception.Message
                    $row.candidates = @()
                }
                ($row | ConvertTo-Json -Depth 10 -Compress) | Add-Content -LiteralPath $OutFile
                Write-Host ("[{0,3}/{1}] {2,-20} {3,-8} run{4}  {5,6}ms  {6} cand" -f `
                    $n, $total, $m, $qq.id, $run, $row.latencyMs, @($row.candidates).Count)
            }
        }
    }
}

Write-Host ''
Write-Host '=== results ===' -ForegroundColor Cyan
$rows = Get-Content -LiteralPath $OutFile | ForEach-Object { $_ | ConvertFrom-Json }
$rows | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath ($OutFile -replace '\.jsonl$', '.json')
"rows: {0}" -f @($rows).Count
