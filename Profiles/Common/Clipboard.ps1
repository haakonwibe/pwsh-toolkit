# Clipboard snippet stash: `cb`
# ============================================================================
# A curated, searchable stash of text you paste often — signature, address, a
# gnarly command, an account number. `cb` is deliberately NOT a background
# clipboard spy: Windows' own Win+V already does chronological recent-copy
# recovery. `cb` does the thing Win+V can't — durable, optionally-named,
# fuzzy-searchable snippets that survive reboots. Think `j` bookmarks, but for
# text.
#
#   cb                      picker over saved snippets; Enter copies to clipboard
#   cb <text>               copy the first snippet matching label/content
#   cb -Add [-Label <name>] save the current clipboard (upsert by label)
#   cb -Remove <text>       drop the first snippet matching label/content
#
# Enter COPIES (not auto-pastes): reliable paste-into-the-focused-window isn't
# possible from a picker on the alternate screen buffer, so you get the snippet
# on the clipboard and Ctrl+V it where you want — same as Win+V effectively does.
#
# NOT a secret store: entries live as plaintext JSON under %LOCALAPPDATA% (the
# jump-bookmarks.json pattern). Keep passwords/tokens in SecretStore instead —
# Set-Secret / Get-OrCreateSecret (see SecretManagement.ps1).
#
# Age rendering reuses Format-FileAge from Recent.ps1; both are Common/*.ps1
# dot-sourced into the same session, so it's defined by the time `cb` runs
# interactively (and the unit suite dot-sources Recent.ps1 alongside this file).

$script:ClipSnippetFile = Join-Path $env:LOCALAPPDATA 'pwsh-toolkit\clipboard-snippets.json'

function ConvertTo-SnippetStamp {
    # Normalize an Added value to an invariant ISO-8601 round-trip ('o') string.
    # Critical for locale-safety: ConvertFrom-Json auto-converts our stored ISO
    # strings back to [datetime] on read, and a plain [string] cast would then
    # re-serialize them in the CURRENT culture (e.g. "19.07.2026" on nb-NO) — a
    # format Convert-SnippetDate's invariant parse can't read, so every snippet
    # would sort as MinValue. Forcing 'o' on the way through keeps the store
    # culture-independent no matter where it's written.
    [OutputType([string])]
    param($Value)
    if ($Value -is [datetime]) { return ([datetime]$Value).ToString('o', [cultureinfo]::InvariantCulture) }
    return [string]$Value
}

function Convert-SnippetDate {
    # Parse a stored ISO-8601 (round-trip 'o') timestamp back to [datetime].
    # A missing or unparseable value sorts oldest rather than throwing.
    [OutputType([datetime])]
    param([string] $Value)
    [datetime] $dt = [datetime]::MinValue
    if ([datetime]::TryParse($Value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $dt)) {
        return $dt
    }
    return [datetime]::MinValue
}

function Format-SnippetPreview {
    # One-line preview of a (possibly multi-line) snippet for the picker/messages:
    # first non-blank line, inner whitespace runs collapsed to a single space,
    # trimmed. Pure, so the formatting is unit-testable without a console.
    [OutputType([string])]
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $line = ($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    return ($line -replace '\s+', ' ').Trim()
}

function Get-ClipSnippet {
    # Read the saved snippets. A missing, empty, or corrupt file yields an empty
    # list and never throws — a bad file must not break profile load or `cb`.
    # Exception: -ThrowOnError, for callers about to REWRITE the store (cb -Add).
    # There a failed read must abort instead of masquerading as an empty list, or
    # the save would clobber every snippet the file still holds. (Same contract
    # as Get-JumpBookmark in Navigation.ps1.)
    param([switch] $ThrowOnError)
    if (-not (Test-Path -LiteralPath $script:ClipSnippetFile)) { return @() }
    try {
        $raw = Get-Content -Raw -LiteralPath $script:ClipSnippetFile -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        if ($ThrowOnError) { throw }
        Write-Warning "pwsh-toolkit: couldn't read clipboard snippets ($script:ClipSnippetFile): $($_.Exception.Message)"
        return @()
    }
    @($data) |
        Where-Object { $_ -and -not [string]::IsNullOrEmpty([string]$_.Text) } |
        ForEach-Object {
            [pscustomobject]@{
                Label = [string]$_.Label
                Text  = [string]$_.Text
                # ConvertFrom-Json may have handed back a [datetime] — pin it to
                # invariant ISO so the in-memory value is culture-independent too.
                Added = ConvertTo-SnippetStamp $_.Added
            }
        }
}

function Save-ClipSnippet {
    # Serialize the snippet list to JSON. Pure write — trimming/upsert happen in
    # the callers; this just normalizes and persists.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Snippet)

    $dir = Split-Path -Parent $script:ClipSnippetFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # -AsArray (piped, so it enumerates) keeps a single snippet as a one-element
    # JSON array; a bare object would make Get-ClipSnippet's @() wrap it wrong on
    # the next read. An empty list must serialize as '[]', not '' — an empty
    # ConvertTo-Json would leave the old file untouched and silently resurrect a
    # snippet you just removed.
    $clean = @($Snippet | ForEach-Object {
        [pscustomobject]@{ Label = [string]$_.Label; Text = [string]$_.Text; Added = ConvertTo-SnippetStamp $_.Added }
    })
    $json = if ($clean.Count -eq 0) { '[]' } else { $clean | ConvertTo-Json -Depth 3 -AsArray }
    Set-Content -LiteralPath $script:ClipSnippetFile -Value $json -Encoding utf8
}

function Limit-ClipSnippet {
    # Cap the store at $Max entries, dropping the OLDEST UNLABELED snippets first.
    # Labeled snippets are curated favorites — never auto-dropped, even past the
    # cap. Returns the kept snippets, newest first. Pure, so the policy is
    # unit-testable.
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Snippet,
        [int] $Max = 100
    )
    $all = @($Snippet)
    if ($all.Count -le $Max) {
        return @($all | Sort-Object { Convert-SnippetDate $_.Added } -Descending)
    }
    $labeled   = @($all | Where-Object { $_.Label })
    $unlabeled = @($all | Where-Object { -not $_.Label } |
                    Sort-Object { Convert-SnippetDate $_.Added } -Descending)
    $keepUnlabeled = [Math]::Max(0, $Max - $labeled.Count)
    $unlabeled = @($unlabeled | Select-Object -First $keepUnlabeled)
    @($labeled + $unlabeled) | Sort-Object { Convert-SnippetDate $_.Added } -Descending
}

function Add-ClipSnippet {
    # Save one snippet: upsert by label (re-using a label repoints it) and dedupe
    # identical text (bumps it to the top instead of duplicating). Aborts on an
    # unreadable store rather than overwriting it — same guard as Add-JumpBookmark.
    param([Parameter(Mandatory)][string] $Text, [string] $Label)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        Write-Host '  Clipboard is empty or not text — nothing to stash.' -ForegroundColor Yellow
        return
    }

    try {
        $store = @(Get-ClipSnippet -ThrowOnError)
    } catch {
        Write-Host "  Couldn't read the snippet store, so not overwriting it: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Fix or delete $script:ClipSnippetFile and retry." -ForegroundColor Yellow
        return
    }

    # Drop any entry sharing this label (case-insensitive upsert) or holding this
    # exact text (dedupe), then put the fresh entry on top.
    $store = @($store | Where-Object {
        -not ($Label -and $_.Label -ieq $Label) -and ($_.Text -cne $Text)
    })
    $entry = [pscustomobject]@{ Label = $Label; Text = $Text; Added = (Get-Date).ToString('o') }
    $store = @(Limit-ClipSnippet -Snippet (@($entry) + $store))

    Save-ClipSnippet -Snippet $store
    if ($Label) {
        Write-Host "  Saved snippet '$Label'" -ForegroundColor Green
    } else {
        Write-Host "  Saved snippet: $(Format-SnippetPreview $Text)" -ForegroundColor Green
    }
}

function Remove-ClipSnippet {
    # Drop the first snippet matching $Name — by exact label, or substring in the
    # label or the text (newest first). Matching content too means unlabeled
    # snippets are removable, which a label-only match couldn't reach.
    param([string] $Name)

    if (-not $Name) {
        Write-Host '  Which snippet? Usage: cb -Remove <label-or-text>   (list them with: cb)' -ForegroundColor Yellow
        return
    }

    $store = @(Get-ClipSnippet | Sort-Object { Convert-SnippetDate $_.Added } -Descending)
    $safe  = [WildcardPattern]::Escape($Name)
    $hit   = $store | Where-Object {
        $_.Label -ieq $Name -or $_.Label -like "*$safe*" -or $_.Text -like "*$safe*"
    } | Select-Object -First 1
    if (-not $hit) {
        Write-Host "  No snippet matching '$Name'. (Run cb to see them.)" -ForegroundColor Yellow
        return
    }

    # Remove that one object by identity, keeping every other snippet.
    $keep = @($store | Where-Object { -not [object]::ReferenceEquals($_, $hit) })
    Save-ClipSnippet -Snippet $keep
    $what = if ($hit.Label) { "'$($hit.Label)'" } else { Format-SnippetPreview $hit.Text }
    Write-Host "  Removed snippet $what" -ForegroundColor Green
}

function cb {
    <#
    .SYNOPSIS
        Clipboard snippet stash — picker, direct copy by name, or manage snippets.
    .DESCRIPTION
        A curated stash of text you paste often. With no argument, opens an
        interactive picker over your saved snippets; Enter copies the selection
        to the clipboard (then Ctrl+V it wherever you want), Esc cancels.

        With an argument, copies directly: the first snippet whose label or
        content matches (case-insensitive substring) goes to the clipboard
        without opening the picker.

        Use -Add to stash the current clipboard (optionally named with -Label,
        which also lets `cb <label>` find it and `cb -Remove <label>` drop it),
        and -Remove to drop a snippet by label or content. Snippets persist to a
        JSON file under %LOCALAPPDATA%\pwsh-toolkit and survive restarts.

        Not a secret store: snippets are plaintext on disk. Keep passwords and
        tokens in SecretStore (Set-Secret / Get-OrCreateSecret) instead.
    .PARAMETER Match
        Substring (label or content) of the snippet to copy to the clipboard.
    .PARAMETER Add
        Save the current clipboard as a snippet.
    .PARAMETER Label
        With -Add, the name shown in the picker and matched by `cb <label>`.
        Omit for an unnamed snippet shown by its first line.
    .PARAMETER Remove
        Remove a saved snippet, identified by label or content.
    .PARAMETER Name
        With -Remove, the label or content substring of the snippet to drop.
    .EXAMPLE
        cb

        Opens the picker over your saved snippets — Enter copies the selection
        to the clipboard.
    .EXAMPLE
        cb -Add -Label sig

        Stashes whatever's on the clipboard as "sig". Later: cb sig  (copies it
        back, ready to paste).
    .EXAMPLE
        cb addr

        Copies the first snippet matching "addr" straight to the clipboard, no
        picker.
    .EXAMPLE
        cb -Remove sig

        Drops the "sig" snippet.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Jump')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Jump')]
        [string] $Match,

        [Parameter(ParameterSetName = 'Add')]
        [switch] $Add,

        [Parameter(ParameterSetName = 'Add')]
        [string] $Label,

        [Parameter(ParameterSetName = 'Remove')]
        [switch] $Remove,

        [Parameter(Position = 0, ParameterSetName = 'Remove')]
        [string] $Name
    )

    # Dispatch on the bound parameter set, not the switches alone: `cb -Label x`
    # selects the Add set without -Add, `cb -Name x` the Remove set without
    # -Remove. The switches aren't Mandatory (that would stall a typo on a
    # mandatory-parameter prompt) but they still gate the write, so a typo gets
    # usage help, never a save. Mirrors `j`.
    if ($PSCmdlet.ParameterSetName -eq 'Add') {
        if (-not $Add) {
            Write-Host '  -Label goes with -Add. Usage: cb -Add [-Label <name>]' -ForegroundColor Yellow
            return
        }
        # Get-Clipboard throws on a non-text clipboard (an image/file drop); treat
        # that as "nothing to stash", which Add-ClipSnippet reports on empty text.
        $clip = $null
        try { $clip = Get-Clipboard -Raw -ErrorAction Stop }
        catch { Write-Debug "Get-Clipboard failed (non-text clipboard?): $($_.Exception.Message)" }
        Add-ClipSnippet -Text $clip -Label $Label
        return
    }
    if ($PSCmdlet.ParameterSetName -eq 'Remove') {
        if (-not $Remove) {
            Write-Host '  -Name goes with -Remove. Usage: cb -Remove <label-or-text>' -ForegroundColor Yellow
            return
        }
        Remove-ClipSnippet -Name $Name
        return
    }

    $snippets = @(Get-ClipSnippet | Sort-Object { Convert-SnippetDate $_.Added } -Descending)

    if ($Match) {
        # Copy the first label/content match straight to the clipboard, no picker.
        # Escape the input so a stray '[' is matched literally instead of throwing.
        $safe = [WildcardPattern]::Escape($Match)
        $hit  = $snippets | Where-Object { $_.Label -like "*$safe*" -or $_.Text -like "*$safe*" } | Select-Object -First 1
        if ($hit) {
            Set-Clipboard -Value $hit.Text
            $what = if ($hit.Label) { "'$($hit.Label)'" } else { Format-SnippetPreview $hit.Text }
            Write-Host "  Copied snippet $what to the clipboard." -ForegroundColor Green
            return
        }
        Write-Host "  No snippet matching '$Match'. (Run cb to see them.)" -ForegroundColor Yellow
        return
    }

    if ($snippets.Count -eq 0) {
        Write-Host '  No saved snippets yet. Copy something, then: cb -Add [-Label <name>]' -ForegroundColor Yellow
        return
    }

    # Precompute the row fields once; the render scriptblock only formats.
    $items = foreach ($s in $snippets) {
        [pscustomobject]@{
            Label   = $s.Label
            Text    = $s.Text
            When    = Convert-SnippetDate $s.Added
            Preview = Format-SnippetPreview $s.Text
            Lines   = @($s.Text -split "`r?`n").Count
        }
    }

    $labeled    = @($items | Where-Object Label)
    $labelWidth = if ($labeled) { [Math]::Min(20, ($labeled | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum) } else { 0 }

    $render = {
        param($i)
        # Age in dark gray (freshness matters less than for files, but it orders
        # the list); labeled snippets show the name in green with the preview as
        # a dim tail — mirrors `recent`'s "name  ·  desc". Unlabeled rows lead
        # with the preview. A multi-line marker disambiguates blob snippets.
        $age  = '{0,5}' -f (Format-FileAge $i.When)
        $tag  = if ($i.Lines -gt 1) { "  `e[90m($($i.Lines) lines)`e[0m" } else { '' }
        if ($i.Label) {
            $label = "`e[32m$($i.Label.PadRight($labelWidth))`e[0m"
            "`e[90m{0}`e[0m  {1}  `e[90m{2}`e[0m{3}" -f $age, $label, $i.Preview, $tag
        } else {
            "`e[90m{0}`e[0m  {1}{2}" -f $age, $i.Preview, $tag
        }
    }.GetNewClosure()

    $selected = Show-Picker -Items $items -RenderRow $render `
        -Title 'Clipboard snippets' -Hint 'Up/Down + Enter copy  PgUp/PgDn  Esc cancel  |  cb <text> copies directly'
    if (-not $selected) { return }

    Set-Clipboard -Value $selected.Text
    $what = if ($selected.Label) { "'$($selected.Label)'" } else { Format-SnippetPreview $selected.Text }
    Write-Host "  Copied snippet $what to the clipboard." -ForegroundColor Green
}

# Tab completion for `cb`: complete the labels of saved snippets. `cb <TAB>`
# (Match) and `cb -Remove <TAB>` (Name) both offer labels — only labeled
# snippets are addressable by a completed word; unlabeled ones are still
# reachable by typing a content substring. The preview shows as the tooltip.
# Kept in a $script: variable so the unit tests can invoke the completer
# directly. Mirrors Navigation.ps1's JumpLabelCompleter.
$script:ClipLabelCompleter = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters   # signature fixed by Register-ArgumentCompleter
    $word = $wordToComplete.Trim("'`"")
    $safe = [WildcardPattern]::Escape($word)
    foreach ($s in @(Get-ClipSnippet | Where-Object Label)) {
        if (-not $word -or $s.Label -like "*$safe*") {
            $text = if ($s.Label -match '\s') { "'$($s.Label)'" } else { $s.Label }
            [System.Management.Automation.CompletionResult]::new($text, $s.Label, 'ParameterValue', (Format-SnippetPreview $s.Text))
        }
    }
}
Register-ArgumentCompleter -CommandName cb -ParameterName Match -ScriptBlock $script:ClipLabelCompleter
Register-ArgumentCompleter -CommandName cb -ParameterName Name  -ScriptBlock $script:ClipLabelCompleter
