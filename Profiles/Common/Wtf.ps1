# What The...? — pipe the last $Error (or any text) to Claude Haiku for an
# instant plain-English explanation + likely fix. Reuses the same
# Anthropic-API-Key SecretStore convention as DownloadsOrganizer/tagdl, with
# $env:ANTHROPIC_API_KEY as a fallback.
#
# Usage:
#   wtf                            # explain $Error[0]
#   wtf "<pasted error>"           # explain arbitrary text
#   $Error[0] | wtf                # pipe an ErrorRecord
#   Some-Command 2>&1 | wtf        # pipe command output (errors and all)
#
# Cost: ~$0.001 per call on Haiku 4.5.

function wtf {
    <#
    .SYNOPSIS
        Ask Claude what just went wrong and how to fix it.
    .DESCRIPTION
        Sends an error (or any text) to Claude Haiku and prints a plain-English
        explanation plus likely fix. With no input, explains $Error[0]. Uses the
        Anthropic-API-Key SecretStore secret, falling back to $env:ANTHROPIC_API_KEY.
        Roughly $0.001 per call.
    .PARAMETER InputObject
        An ErrorRecord, a string, or piped command output. Defaults to $Error[0].
    .EXAMPLE
        wtf

        With no input, explains the most recent error ($Error[0]) — run it right
        after something blows up to get a plain-English diagnosis and likely fix.
    .EXAMPLE
        $Error[0] | wtf

        Pipe a specific ErrorRecord in (e.g. an older one from the session) rather
        than defaulting to the latest.
    .EXAMPLE
        Some-Command 2>&1 | wtf

        Merge a command's error stream into the pipe (2>&1) so wtf sees the actual
        failure output — useful for native tools that don't throw ErrorRecords.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)][object] $InputObject
    )

    begin {
        $accumulated = New-Object 'System.Collections.Generic.List[string]'
    }

    process {
        if ($null -ne $InputObject) {
            if ($InputObject -is [System.Management.Automation.ErrorRecord]) {
                # Out-String gives the full formatted ErrorRecord (with position,
                # target object, etc.) — much more useful than ToString() which
                # is just the message.
                $accumulated.Add(($InputObject | Out-String).Trim())
            } else {
                $accumulated.Add("$InputObject")
            }
        }
    }

    end {
        # Resolve what to send: pipeline > positional > $Error[0]
        if ($accumulated.Count -gt 0) {
            $context = ($accumulated -join "`n").Trim()
        } elseif ($Error.Count -gt 0) {
            $context = ($Error[0] | Out-String).Trim()
        } else {
            Write-Host '  Nothing to explain — $Error is empty.' -ForegroundColor Yellow
            Write-Host '  Try: wtf "<paste an error message>"  or  $Error[0] | wtf' -ForegroundColor DarkGray
            return
        }

        # Defensive truncation — anthropic accepts large inputs but we don't
        # need to send a multi-megabyte stack trace for an "explain this" call.
        if ($context.Length -gt 4000) {
            $context = $context.Substring(0, 4000) + "`n[...truncated]"
        }

        # API key resolution: SecretStore first (preferred), env var fallback.
        # No try/catch wrapper — Get-OrCreateSecret handles its own failure
        # modes via Write-Error + return $null, and we want those diagnostics
        # to reach the user. A previous version wrapped this in
        # try { ... -ErrorAction Stop } catch {} and silently swallowed the
        # specific "Failed to unlock SecretStore: <reason>" messages, leaving
        # the user with only the generic "No Anthropic API key found" below.
        $apiKey = $null
        if (Get-Command Get-OrCreateSecret -ErrorAction Ignore) {
            $apiKey = Get-OrCreateSecret -Name 'Anthropic-API-Key' -AsPlainText
        }
        if (-not $apiKey -and $env:ANTHROPIC_API_KEY) {
            $apiKey = $env:ANTHROPIC_API_KEY
        }
        if (-not $apiKey) {
            Write-Host '  No Anthropic API key found.' -ForegroundColor Yellow
            if (Get-Command Get-SecretVault -ErrorAction Ignore) {
                Write-Host '  Set up via SecretStore:' -ForegroundColor DarkGray
                Write-Host "      Get-OrCreateSecret -Name 'Anthropic-API-Key' -AsPlainText" -ForegroundColor White
            } else {
                Write-Host '  Install SecretStore modules to enable secure storage:' -ForegroundColor DarkGray
                Write-Host '      Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser' -ForegroundColor White
            }
            Write-Host '  Or set $env:ANTHROPIC_API_KEY for the session.' -ForegroundColor DarkGray
            return
        }

        $prompt = @"
You are an expert Windows + PowerShell developer helping a power user understand
and fix errors quickly. Be concise: 2-4 sentences explaining what went wrong,
then 1-3 lines of likely fixes. Don't quote the error back. Get to the point.
If the cause is clear, lead with the fix.

FORMAT — your output prints directly to a PowerShell console; markdown is NOT
rendered. Follow these rules:
- No markdown. No **bold**, no triple-backtick code fences, no # headings, no
  hyphen/asterisk bullet lists. They show as literal characters.
- Highlight commands by indenting them 4 spaces on their own line.
- Keep paragraphs short. A blank line between explanation and fixes is fine.

ERROR / TEXT TO EXPLAIN:
$context
"@

        $body = @{
            model      = 'claude-haiku-4-5-20251001'
            max_tokens = 600
            messages   = @(
                @{ role = 'user'; content = $prompt }
            )
        } | ConvertTo-Json -Depth 10 -Compress

        $headers = @{
            'x-api-key'         = $apiKey
            'anthropic-version' = '2023-06-01'
            'content-type'      = 'application/json'
        }

        try {
            Write-Host '  Asking Claude...' -ForegroundColor DarkGray -NoNewline
            $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' `
                -Method Post -Headers $headers -Body $body -ErrorAction Stop
            # Best-effort erase the "Asking Claude..." pending message
            Write-Host ("`r" + (' ' * 20) + "`r") -NoNewline

            # Defensive markdown strip — the prompt asks for plain text but
            # the model occasionally lapses. Handles the common offenders:
            # **bold**, `inline code`, ```code fences```, and # headings.
            $text = $resp.content[0].text
            $text = $text -replace '\*\*([^*]+)\*\*', '$1'         # **bold** -> bold
            $text = $text -replace '(?m)^```\w*\s*$', ''           # opening/closing fences (lang)
            $text = $text -replace '(?m)^```\s*$', ''              # plain ``` fences
            $text = $text -replace '`([^`]+)`', '$1'               # `inline` -> inline
            $text = $text -replace '(?m)^#{1,6}\s+', ''            # # heading -> heading
            $text = $text.Trim()

            # Light coloring: lines indented 4+ spaces look like commands —
            # surface them in cyan so the eye lands on the runnable bits.
            Write-Host ''
            foreach ($line in ($text -split "`r?`n")) {
                if ($line -match '^\s{4,}\S') {
                    Write-Host $line -ForegroundColor Cyan
                } else {
                    Write-Host $line -ForegroundColor White
                }
            }
            Write-Host ''
        }
        catch {
            Write-Host ("`r" + (' ' * 20) + "`r") -NoNewline
            Write-Host "  Anthropic API call failed:" -ForegroundColor Yellow
            Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
}
