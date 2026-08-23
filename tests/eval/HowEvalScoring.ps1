# Scoring for the `how` evaluation. Dot-sourced by both the runner and the
# report so the two can never disagree about what a "valid" candidate is.

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
        unresolved   = @()     # PowerShell-shaped names that do not exist: real inventions
        external     = @()     # bare tool names absent from THIS machine: docker, jq, ...
        badParams    = @()
    }
    if (-not $result.parses) { return [pscustomobject]$result }

    $cmdAsts = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    $names = New-Object System.Collections.Generic.List[string]
    $unres = New-Object System.Collections.Generic.List[string]
    $ext = New-Object System.Collections.Generic.List[string]
    $bad = New-Object System.Collections.Generic.List[string]

    # A candidate may define a function and then call it in the same one-liner
    # (the JSON-flattening answers do exactly this). Those are self-contained,
    # not inventions, so collect them before resolving anything.
    $selfDefined = @($ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | ForEach-Object { $_.Name })

    foreach ($c in $cmdAsts) {
        $name = $c.GetCommandName()
        if (-not $name -or $name -match '^\$') { continue }
        $names.Add($name)

        if ($selfDefined -contains $name) { continue }

        $resolved = Get-Command -Name $name -ErrorAction Ignore | Select-Object -First 1
        if (-not $resolved) {
            # Distinguish "invented a cmdlet" from "names a real external tool
            # this machine happens not to have". A Verb-Noun shape is a
            # PowerShell command and its absence is a genuine hallucination; a
            # bare lowercase word is a CLI (docker, jq, kubectl) and says
            # nothing about the model.
            if ($name -match '^[A-Za-z]+-[A-Za-z]') { $unres.Add($name) } else { $ext.Add($name) }
            continue
        }
        while ($resolved.CommandType -eq 'Alias' -and $resolved.ResolvedCommand) { $resolved = $resolved.ResolvedCommand }
        # Native executables and scripts have no discoverable parameter metadata.
        if ($resolved.CommandType -in 'Application', 'ExternalScript') { continue }
        # `sudo Register-ScheduledTask -TaskName ...` parses with sudo as the
        # command, so every parameter of the wrapped command looks like sudo's.
        if ($name -in 'sudo', 'pwsh', 'powershell') { continue }

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
    $result.external   = @($ext)
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

# Anthropic list prices, $ per million tokens. Cache-token pricing is
# deliberately NOT modelled — cache reads and writes are reported as raw token
# counts instead, so nothing here depends on a multiplier that could be wrong.
$script:HowEvalPrices = @{
    'claude-opus-5'    = @{ in = 5.0; out = 25.0 }
    'claude-sonnet-5'  = @{ in = 2.0; out = 10.0 }   # intro pricing, to 2026-08-31
    'claude-haiku-4-5' = @{ in = 1.0; out = 5.0 }
}
