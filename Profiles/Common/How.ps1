# ============================================================================
# how — ask Claude how to do something, get runnable commands back
# ============================================================================
# The forward-looking sibling to `wtf`: that one explains what just went wrong,
# this one answers "how do I do X" and hands you the command. The output is the
# point — `ask` returns prose you read, `how` returns commands you run, which
# is why this asks the API for structured JSON rather than free text and feeds
# the result to the shared picker.
#
# Two entry points, because only one of them can put text on your prompt:
#   how "question"   prints the chosen command (and copies it, and stores it in
#                    history) — works anywhere, including non-interactive hosts.
#   Alt+h            takes what you have already typed as the question and
#                    REPLACES the line with the command you pick.
# The split is not a style choice. PSReadLine's Insert()/Replace() only write to
# a live input buffer; called from a normal command — by which time the line has
# been submitted — Insert() does not throw, it writes into the already-drawn
# line and corrupts it. Inside a key handler the buffer is still live, so that
# is the only place the "lands on your prompt" behaviour can actually work.
#
# Shares Anthropic-API-Key with `wtf` and `tagdl`; no new secret is introduced.

# The model, the candidate count, and the effort — all three are settled by
# measurement rather than taste; see the evaluation notes in docs/.
#
# Sonnet 5 is the shipped default because it is the best balance of the three
# things that matter here: a measured 5.4s median against Opus 5's 8.6s, a
# quarter of the cost, and validity within about two points of it. Opus 5 is
# the better answer when correctness outranks both — it led on parameter
# validity, which is the metric that matters for code about to be run — so
# `HowModel` in config.psd1 switches the default, and -Model switches one call.
#
# Three candidates, not five: past rank two, roughly half of what comes back
# restates something already on the list (near-duplicate rates of 47% at rank
# 3, 46% at rank 4), so the extra rows cost latency and tokens to say the same
# thing again.
#
# Effort is 'medium' rather than the API default 'high' — suggesting a one-liner
# is not deep reasoning work, and latency is felt at the prompt.
$script:HowModel   = if ($script:Config.HowModel) { $script:Config.HowModel } else { 'claude-sonnet-5' }
$script:HowCount   = 3
$script:HowEffort  = 'medium'
$script:HowMaxTok  = 8000
$script:HowChord   = 'Alt+h'

# The response schema. Structured output (output_config.format) is what makes
# the picker possible: free text would need parsing back out of prose, and the
# model's formatting choices would become this command's bugs. Note the schema
# limits — no maxItems, no minLength — so the candidate count is asked for in
# the prompt instead of constrained here.
function Get-HowSchema {
    [OutputType([hashtable])]
    param()
    @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('candidates')
        properties           = @{
            candidates = @{
                type  = 'array'
                items = @{
                    type                 = 'object'
                    additionalProperties = $false
                    required             = @('command', 'explanation')
                    properties           = @{
                        command     = @{ type = 'string' }
                        explanation = @{ type = 'string' }
                    }
                }
            }
        }
    }
}

# One catalog line for the system prompt: name, real parameters, synopsis.
#
# The parameters are the point. Measured across 126 calls, the toolkit category
# had the WORST validity of any subject area — not because the models failed to
# find the right command (they picked the intended one every single time) but
# because a catalog of names and synopses tells them a command exists while
# saying nothing about its surface, so they invented plausible switches for it:
# `dird -Recurse`, `task -New`, `Connect-Tenant -Scopes`. Listing the real
# parameters is what closes that gap, and they come from the live function so
# they cannot drift from the code.
function Format-HowCatalogEntry {
    [OutputType([string])]
    param([Parameter(Mandatory)] $Entry)

    $params = ''
    $name = if ($Entry.Function) { $Entry.Function } else { $Entry.Command }
    $cmd = Get-Command -Name $name -ErrorAction Ignore | Select-Object -First 1
    if ($cmd) {
        while ($cmd.CommandType -eq 'Alias' -and $cmd.ResolvedCommand) { $cmd = $cmd.ResolvedCommand }
        try {
            $common = [System.Management.Automation.PSCmdlet]::CommonParameters +
                      [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
            $names = @($cmd.Parameters.Keys | Where-Object { $_ -notin $common })
            if ($names) { $params = ' ' + (($names | ForEach-Object { "-$_" }) -join ' ') }
        }
        catch { Write-Debug "no parameter metadata for $name" }
    }

    "  {0}{1} - {2}" -f $Entry.Command, $params, $Entry.Synopsis
}

# The system prompt, with the toolkit's own command list folded in. That list is
# what makes `how "jump to a repo"` answer `prj` instead of a generic
# Set-Location — the toolkit has more commands than anyone keeps in their head,
# and this is the command best placed to close that gap.
function Get-HowSystemPrompt {
    [OutputType([string])]
    param([int] $Count = $script:HowCount, [switch] $NoToolkit)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine(@"
You help a Windows PowerShell 7 power user get things done at the terminal.
Answer with runnable commands, not prose.

Rules:
- Give at most $Count candidates, best first. Fewer is fine when fewer are good.
- Each command must be a single line that can be pasted at a prompt and run.
- Prefer PowerShell 7 built-ins and this user's own toolkit commands over
  external tools. Never invent a command or a parameter that does not exist.
- Use real parameter names. Placeholders the user must replace go in <angle
  brackets> so they are obviously placeholders.
- The explanation is one short line: what the command does and when to pick it
  over the others. No markdown, no backticks — this prints to a raw console.
- If the request is destructive, prefer the -WhatIf form as the first candidate.
"@)

    if (-not $NoToolkit -and (Get-Command Get-ToolkitCommand -ErrorAction Ignore)) {
        # Best-effort: a catalog failure must not take the command down with it.
        try {
            $rows = @(Get-ToolkitCommand | ForEach-Object { Format-HowCatalogEntry -Entry $_ })
            if ($rows) {
                [void]$sb.AppendLine()
                [void]$sb.AppendLine("The user's own toolkit commands. Prefer these when they fit, and use")
                [void]$sb.AppendLine("ONLY the parameters listed - these commands have no others:")
                [void]$sb.AppendLine(($rows -join [Environment]::NewLine))
            }
        }
        catch { Write-Debug "toolkit catalog unavailable for the system prompt: $($_.Exception.Message)" }
    }

    $sb.ToString()
}

# The raw request. Split out from Get-HowCandidate so callers that want the
# response envelope — token usage, cache hits, stop_reason — can have it without
# a second code path drifting away from the one the command actually uses.
function Invoke-HowRequest {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Question,
        [Parameter(Mandatory)][string] $ApiKey,
        [string] $Model = $script:HowModel,
        [int]    $Count = $script:HowCount,
        [switch] $NoToolkit,
        [switch] $NoEffort
    )

    $payload = @{
        model         = $Model
        max_tokens    = $script:HowMaxTok
        system        = @(
            # A cache breakpoint on the system block: the toolkit catalog is the
            # same bytes on every call, so repeat questions only pay for the
            # question itself once the prefix is warm.
            @{
                type          = 'text'
                text          = (Get-HowSystemPrompt -Count $Count -NoToolkit:$NoToolkit)
                cache_control = @{ type = 'ephemeral' }
            }
        )
        messages      = @(@{ role = 'user'; content = $Question })
        output_config = @{
            format = @{
                type   = 'json_schema'
                schema = (Get-HowSchema)
            }
        }
    }
    # Not every model accepts output_config.effort — Haiku 4.5 rejects it with a
    # 400 outright, which made -Model on anything but the default fail. The
    # alternative to an allow-list that goes stale with every release is to ask
    # for it and stand down once when the API says that model cannot have it.
    if (-not $NoEffort) { $payload.output_config.effort = $script:HowEffort }

    $headers = @{
        'x-api-key'         = $ApiKey
        'anthropic-version' = '2023-06-01'
        'content-type'      = 'application/json'
    }

    try {
        Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' -Method Post `
            -Headers $headers -Body ($payload | ConvertTo-Json -Depth 20 -Compress) -ErrorAction Stop
    }
    catch {
        $detail = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
        if (-not $NoEffort -and $detail -match 'effort') {
            Write-Debug "$Model rejected the effort parameter; retrying without it."
            return Invoke-HowRequest -Question $Question -ApiKey $ApiKey -Model $Model `
                -Count $Count -NoToolkit:$NoToolkit -NoEffort
        }
        throw
    }
}

# The API call, kept separate from the UX so it can be tested against a mocked
# Invoke-RestMethod without a console, a key, or a network.
function Get-HowCandidate {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Question,
        [Parameter(Mandatory)][string] $ApiKey,
        [string] $Model = $script:HowModel,
        [int]    $Count = $script:HowCount,
        [switch] $NoToolkit
    )

    $resp = Invoke-HowRequest -Question $Question -ApiKey $ApiKey -Model $Model -Count $Count -NoToolkit:$NoToolkit

    # A safety decline comes back as HTTP 200 with stop_reason 'refusal', so the
    # status code alone never reveals it — check before reading the content.
    if ($resp.stop_reason -eq 'refusal') {
        throw 'Claude declined to answer that one.'
    }

    # Thinking is on by default on Opus 5, so the first content block is not
    # necessarily the answer. Take the text block, wherever it sits.
    $textBlock = @($resp.content | Where-Object { $_.type -eq 'text' })[0]
    if (-not $textBlock -or -not $textBlock.text) {
        throw 'The API returned no text content.'
    }

    $parsed = $textBlock.text | ConvertFrom-Json
    @($parsed.candidates | Where-Object { $_.command })
}

# One picker row: the command in cyan, its note dimmed behind it, so the eye
# lands on the runnable part — which is the part that gets taken.
#
# The clamp is load-bearing rather than cosmetic. Show-Picker renders any row
# whose VISIBLE width overflows the window as stripped plain text, because
# truncating mid-escape would leak a broken sequence into the frame. A single
# over-long command therefore came out white and note-less while every row
# around it stayed cyan. Keeping the body inside the width budget is what keeps
# it coloured. Display only: the item still carries the full command, and that
# is what gets taken.
function Format-HowRow {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)][int] $Width
    )
    $esc = [char]27
    $ell = [char]0x2026

    $cmd = [string]$Item.command
    if ($cmd.Length -gt $Width) {
        $cmd = $cmd.Substring(0, [Math]::Max(1, $Width - 1)) + $ell
    }

    # Two columns only when the note can say something useful; below that the
    # command gets the whole row.
    $note = [string]$Item.explanation
    $room = $Width - $cmd.Length - 3
    if ($room -gt 8 -and $note) {
        if ($note.Length -gt $room) { $note = $note.Substring(0, $room - 1) + $ell }
        "$esc[36m$cmd$esc[0m  $esc[90m$note$esc[0m"
    } else {
        "$esc[36m$cmd$esc[0m"
    }
}

# What the picker shows beneath the list for the highlighted candidate.
#
# When the row had to clip the command, the note alone is not enough: at 110
# columns two candidates can render as identical text, and the thing that
# differs -- `-WhatIf` against `-Force` -- is past the cut. Leading with the
# whole command means the choice is made on what will actually run rather than
# on its description. When the command already fits on its row, repeating it
# here would be noise, so the note stands alone.
function Format-HowDetail {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)][int] $RowWidth
    )
    $cmd  = [string]$Item.command
    $note = [string]$Item.explanation
    if ($cmd.Length -le $RowWidth) { return $note }
    if ($note) { "$cmd  $([char]0x2014)  $note" } else { $cmd }
}

# Resolve the API key the same way wtf does: SecretStore first, env var second.
# The Get-OrCreateSecret call is deliberately left unwrapped so its specific
# failure messages ("Failed to unlock SecretStore: ...") reach the user instead
# of being flattened into a generic "no key found".
function Get-HowApiKey {
    [OutputType([string])]
    param([switch] $Quiet)

    $apiKey = $null
    if (Get-Command Get-OrCreateSecret -ErrorAction Ignore) {
        $apiKey = Get-OrCreateSecret -Name 'Anthropic-API-Key' -AsPlainText
    }
    if (-not $apiKey -and $env:ANTHROPIC_API_KEY) { $apiKey = $env:ANTHROPIC_API_KEY }
    if (-not $apiKey -and -not $Quiet) {
        Write-Host '  No Anthropic API key found.' -ForegroundColor Yellow
        Write-Host "      Get-OrCreateSecret -Name 'Anthropic-API-Key' -AsPlainText" -ForegroundColor White
        Write-Host '  Or set $env:ANTHROPIC_API_KEY for the session.' -ForegroundColor DarkGray
    }
    $apiKey
}

# Question in, chosen command out (or $null if anything went wrong or the user
# cancelled). Shared by both entry points so the command form and the key
# handler can never drift in what they ask for or how they present it.
# -Quiet suppresses console writes: inside a key handler the prompt line is
# still on screen and anything written over it leaves artifacts.
function Get-HowCommand {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Question,
        [string] $Model = $script:HowModel,
        [int]    $Count = $script:HowCount,
        [switch] $NoToolkit,
        [switch] $Quiet
    )

    $apiKey = Get-HowApiKey -Quiet:$Quiet
    if (-not $apiKey) { return $null }

    try {
        if (-not $Quiet) { Write-Host '  Asking Claude...' -ForegroundColor DarkGray -NoNewline }
        $candidates = @(Get-HowCandidate -Question $Question -ApiKey $apiKey -Model $Model -Count $Count -NoToolkit:$NoToolkit)
        if (-not $Quiet) { Write-Host ("`r" + (' ' * 20) + "`r") -NoNewline }
    }
    catch {
        if (-not $Quiet) {
            Write-Host ("`r" + (' ' * 20) + "`r") -NoNewline
            Write-Host '  Could not get an answer:' -ForegroundColor Yellow
            Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray
        }
        Write-Debug "how failed: $($_.Exception.Message)"
        return $null
    }

    if (-not $candidates) {
        if (-not $Quiet) { Write-Host '  No commands came back for that. Try rephrasing.' -ForegroundColor Yellow }
        return $null
    }

    $chosen = Show-Picker -Items $candidates -Title "how: $Question" `
        -Hint 'Up/Down + Enter to take a command  Esc cancel  |  digits 1-9 jump' `
        -RenderRow { param($item, $width) Format-HowRow -Item $item -Width $width } `
        -DetailRow {
            # The row truncates its note to fit, and on a narrow terminal drops
            # it entirely - which loses the one thing that makes the candidates
            # comparable. The detail line carries the highlighted candidate
            # whole, at any width. The row budget mirrors what Show-Picker hands
            # RenderRow: the window less its gutter.
            param($item)
            Format-HowDetail -Item $item -RowWidth ([Math]::Max(20, [Console]::WindowWidth - 8))
        }

    if ($chosen) { $chosen.command } else { $null }
}

function how {
    <#
    .SYNOPSIS
        Ask Claude how to do something and get runnable commands back.
    .DESCRIPTION
        The forward-looking half of `wtf`. Describe what you want to do and get
        back a short list of runnable commands, each with a one-line note on
        when to pick it. The command you choose is printed, copied to the
        clipboard, and added to history, so Up-arrow or Ctrl+V retrieves it.

        To have the command land directly on your prompt instead, type the
        question at the prompt and press Alt+h — see about_How_Chord in the
        description below. Only a key handler can write to the input buffer,
        which is why that path is a chord rather than a switch on this command.

        The toolkit's own command list is sent along with the question, so
        answers prefer `prj`, `df` or `peek` over the generic equivalents when
        they fit. -NoToolkit asks the question without that context.

        Uses the same Anthropic-API-Key as `wtf` and `tagdl` (SecretStore, or
        $env:ANTHROPIC_API_KEY).
    .PARAMETER Question
        What you want to do. Quoting is optional: `how create a scheduled task`
        and `how "create a scheduled task"` are the same.
    .PARAMETER Model
        Model to ask. Defaults to `HowModel` in config.psd1, or Claude Sonnet 5
        when that is unset. Claude Opus 5 is the choice when correctness matters
        more than the extra three seconds and four-times cost.
    .PARAMETER Count
        Maximum number of candidates to ask for (1-9). Default 3 — past the
        second, roughly half of what comes back restates something above it.
    .PARAMETER NoToolkit
        Leave the toolkit command list out of the prompt — for plain PowerShell
        answers, or a smaller, cheaper request.
    .EXAMPLE
        how "find the 10 largest files under this folder"

        Offers a few one-liners; the one you pick is copied and printed.
    .EXAMPLE
        how create a scheduled task that runs at logon

        Unquoted questions work too.
    .EXAMPLE
        how -NoToolkit "restart a service on a remote machine"

        Skips the toolkit context for a plain PowerShell answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
        [string[]] $Question,

        [string] $Model = $script:HowModel,

        [ValidateRange(1, 9)]
        [int] $Count = $script:HowCount,

        [switch] $NoToolkit
    )

    $q = ($Question -join ' ').Trim()
    if (-not $q) { Write-Warning 'Ask something: how "how do I ..."'; return }

    $cmd = Get-HowCommand -Question $q -Model $Model -Count $Count -NoToolkit:$NoToolkit
    if ($cmd) { Out-HowCommand -Command $cmd }
}

# Hand the chosen command back from the command form. Note what is NOT here:
# PSConsoleReadLine::Insert(). From a normal command the input line has already
# been submitted, and Insert() then writes into that drawn line rather than a
# fresh one — it appends the command to the echo of what you typed and leaves
# the display mangled. History plus clipboard is the honest alternative: Up
# recalls it, Ctrl+V pastes it, and it is printed so it survives when neither
# is available. Alt+h is the path that actually reaches the prompt.
function Out-HowCommand {
    param([Parameter(Mandatory)][string] $Command)

    $psrl = 'Microsoft.PowerShell.PSConsoleReadLine' -as [type]
    if ($psrl) {
        try { $psrl::AddToHistory($Command) } catch { Write-Debug 'AddToHistory unavailable.' }
    }

    $copied = $false
    if (Get-Command Set-Clipboard -ErrorAction Ignore) {
        try { Set-Clipboard -Value $Command; $copied = $true } catch { Write-Debug 'Set-Clipboard failed.' }
    }

    Write-Host ''
    Write-Host "  $Command" -ForegroundColor Cyan
    $note = if ($copied) { 'copied - Ctrl+V to paste, or Up to recall' } else { 'Up to recall it' }
    Write-Host "  ($note)" -ForegroundColor DarkGray
    Write-Host ''
}

# The chord. Inside a key handler the input buffer is live, so the line the user
# typed can be swapped for the command they pick — the one place this works.
# Registered only for a real console host; nothing else has a buffer to edit.
if ($Host.Name -eq 'ConsoleHost' -and (Get-Command Set-PSReadLineKeyHandler -ErrorAction Ignore)) {
    Set-PSReadLineKeyHandler -Chord $script:HowChord `
        -BriefDescription 'AskHow' `
        -LongDescription 'Ask Claude how to do what is on the line, and replace it with the chosen command.' `
        -ScriptBlock {
            $line = $null
            $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref] $line, [ref] $cursor)
            $q = "$line".Trim()
            if (-not $q) { return }

            # Quiet: the prompt line is still drawn, so progress chatter would
            # land on top of it. The picker uses the alternate screen buffer and
            # restores what was there, so the prompt survives it intact.
            $cmd = Get-HowCommand -Question $q -Quiet
            if ($cmd) {
                [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $line.Length, $cmd)
            }
        }
}
