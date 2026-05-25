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
        $apiKey = $null
        if (Get-Command Get-OrCreateSecret -ErrorAction Ignore) {
            try {
                $apiKey = Get-OrCreateSecret -Name 'Anthropic-API-Key' -AsPlainText -ErrorAction Stop
            } catch {
                # SecretStore unavailable / vault locked / etc. — fall through.
            }
        }
        if (-not $apiKey -and $env:ANTHROPIC_API_KEY) {
            $apiKey = $env:ANTHROPIC_API_KEY
        }
        if (-not $apiKey) {
            Write-Host '  No Anthropic API key found.' -ForegroundColor Yellow
            Write-Host '  Set up via SecretStore:' -ForegroundColor DarkGray
            Write-Host "      Get-OrCreateSecret -Name 'Anthropic-API-Key' -AsPlainText" -ForegroundColor White
            Write-Host '  Or set $env:ANTHROPIC_API_KEY for the session.' -ForegroundColor DarkGray
            return
        }

        $prompt = @"
You are an expert Windows + PowerShell developer helping a power user understand
and fix errors quickly. Be concise: 2-4 sentences explaining what went wrong,
then 1-3 lines of likely fixes. Don't quote the error back. Get to the point.
If the cause is clear, lead with the fix.

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
            $text = $resp.content[0].text
            Write-Host ''
            Write-Host $text -ForegroundColor White
            Write-Host ''
        }
        catch {
            Write-Host ("`r" + (' ' * 20) + "`r") -NoNewline
            Write-Host "  Anthropic API call failed:" -ForegroundColor Yellow
            Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
}
