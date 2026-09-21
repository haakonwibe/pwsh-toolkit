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

$script:ClipSnippetFile = Get-ToolkitDataPath 'clipboard-snippets.json'

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

    # The data dir is guaranteed by Get-ToolkitDataPath at path-bind time.
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

# Safe paste: `psnip`
# ============================================================================
# The one clipboard operation `cb` doesn't cover, and the risky one: getting a
# multi-line snippet from a web page or a chat into the shell. Pasting it at
# the prompt goes wrong in three ways that all arrive as the same shrug from
# Windows Terminal's "you're pasting multiple lines" warning:
#
#   - A clipboard ending in a newline submits the paste before you can read
#     it. Copying from rendered text nearly always picks that newline up.
#   - Several top-level statements run as they arrive, so a half-landed paste
#     has already executed its first half.
#   - Rendered HTML smuggles in characters that aren't what they look like:
#     curly quotes don't delimit strings, a non-breaking space doesn't separate
#     tokens, and an en dash in front of `-Force` isn't a parameter prefix.
#
# `psnip` breaks the loop - clipboard to a scratch .ps1 to your editor, where
# you read it syntax-highlighted with nothing executed, then run it once you're
# satisfied. `-Repair` additionally fixes the third case.
#
#   psnip            clipboard -> scratch .ps1 -> editor
#   psnip -Repair    the same, with smart quotes and invisible spaces fixed
#   psnip -List      the captures still on disk, newest first
#   psnip -Clean     wipe the scratch tree
#
# `-Clean` wipes rather than repairs on purpose: `peek -Clean` already means
# "wipe the temp tree", and one switch meaning two unrelated things across one
# toolkit is worse than a slightly longer name for the repair.
#
# Scratch, not state: these files go to %TEMP% rather than through
# Get-ToolkitDataPath (ARCHITECTURE #13). That convention covers what the
# toolkit *persists*; a snippet you're about to run once is the opposite, and
# %TEMP% is the one place Windows already cleans up behind us. `peek` stages
# its extractions the same way, which is why it lends its `-List`/`-Clean` pair.

# What rendered text substitutes for ASCII, and what it should have been.
#
# Written as code points rather than as the characters themselves, because a
# table of curly quotes, non-breaking spaces and zero-width characters is
# unreviewable as literals - and a file carrying the very characters it exists
# to repair is one careless save away from being the bug it fixes.
#
# A list of pairs rather than [ordered]@{}: on an OrderedDictionary an [int]
# indexer is a POSITION, not a key, so $table[0x2018] is element 8216 - $null,
# no error - while .Contains(0x2018) still answers true. That reads at a glance
# as "the character was deleted" rather than "the lookup missed". A plain @{}
# would key correctly, but a list keeps the table in reading order.
#
# Not exhaustive - the substitutions rendered text and Word documents actually
# produce, plus the bidi controls, which are the one class that changes what a
# reviewer SEES rather than what parses (a right-to-left override can make the
# editor show a line in an order the parser will never use).
$script:SnippetSubstitution = @(
    [pscustomobject]@{ From = 0x2018; To = "'" }   # left single quotation mark
    [pscustomobject]@{ From = 0x2019; To = "'" }   # right single quotation mark
    [pscustomobject]@{ From = 0x201A; To = "'" }   # single low-9 quotation mark
    [pscustomobject]@{ From = 0x201B; To = "'" }   # single high-reversed-9 quotation mark
    [pscustomobject]@{ From = 0x201C; To = '"' }   # left double quotation mark
    [pscustomobject]@{ From = 0x201D; To = '"' }   # right double quotation mark
    [pscustomobject]@{ From = 0x201E; To = '"' }   # double low-9 quotation mark
    [pscustomobject]@{ From = 0x201F; To = '"' }   # double high-reversed-9 quotation mark
    [pscustomobject]@{ From = 0x2010; To = '-' }   # hyphen
    [pscustomobject]@{ From = 0x2011; To = '-' }   # non-breaking hyphen
    [pscustomobject]@{ From = 0x2013; To = '-' }   # en dash - what turns -Force into an argument
    [pscustomobject]@{ From = 0x2014; To = '-' }   # em dash
    [pscustomobject]@{ From = 0x2212; To = '-' }   # minus sign - what a math-aware renderer makes of -Force
    [pscustomobject]@{ From = 0x00A0; To = ' ' }   # no-break space
    [pscustomobject]@{ From = 0x2000; To = ' ' }   # en quad
    [pscustomobject]@{ From = 0x2001; To = ' ' }   # em quad
    [pscustomobject]@{ From = 0x2002; To = ' ' }   # en space
    [pscustomobject]@{ From = 0x2003; To = ' ' }   # em space
    [pscustomobject]@{ From = 0x2004; To = ' ' }   # three-per-em space
    [pscustomobject]@{ From = 0x2005; To = ' ' }   # four-per-em space
    [pscustomobject]@{ From = 0x2006; To = ' ' }   # six-per-em space
    [pscustomobject]@{ From = 0x2007; To = ' ' }   # figure space
    [pscustomobject]@{ From = 0x2008; To = ' ' }   # punctuation space
    [pscustomobject]@{ From = 0x2009; To = ' ' }   # thin space
    [pscustomobject]@{ From = 0x200A; To = ' ' }   # hair space
    [pscustomobject]@{ From = 0x202F; To = ' ' }   # narrow no-break space
    [pscustomobject]@{ From = 0x3000; To = ' ' }   # ideographic space
    [pscustomobject]@{ From = 0x00AD; To = ''  }   # soft hyphen - invisible until a line wraps
    [pscustomobject]@{ From = 0x200B; To = ''  }   # zero width space
    [pscustomobject]@{ From = 0x200C; To = ''  }   # zero width non-joiner
    [pscustomobject]@{ From = 0x200D; To = ''  }   # zero width joiner
    [pscustomobject]@{ From = 0x2060; To = ''  }   # word joiner
    [pscustomobject]@{ From = 0xFEFF; To = ''  }   # zero width no-break space, or a BOM adrift
    [pscustomobject]@{ From = 0x200E; To = ''  }   # left-to-right mark        - bidi: change what
    [pscustomobject]@{ From = 0x200F; To = ''  }   # right-to-left mark        - you see, not what
    [pscustomobject]@{ From = 0x202A; To = ''  }   # left-to-right embedding   - parses
    [pscustomobject]@{ From = 0x202B; To = ''  }   # right-to-left embedding
    [pscustomobject]@{ From = 0x202C; To = ''  }   # pop directional formatting
    [pscustomobject]@{ From = 0x202D; To = ''  }   # left-to-right override
    [pscustomobject]@{ From = 0x202E; To = ''  }   # right-to-left override
    [pscustomobject]@{ From = 0x2066; To = ''  }   # left-to-right isolate
    [pscustomobject]@{ From = 0x2067; To = ''  }   # right-to-left isolate
    [pscustomobject]@{ From = 0x2068; To = ''  }   # first strong isolate
    [pscustomobject]@{ From = 0x2069; To = ''  }   # pop directional isolate
)

function Repair-SnippetText {
    # Swap the characters rendered HTML substitutes for ASCII back to the ASCII
    # the snippet meant. Each of these parses, just not as what it resembles:
    # PowerShell reads a curly quote as an ordinary character rather than a
    # string delimiter, and a non-breaking space as part of the token it sits
    # in, so `Get-Process` carrying one is a single unknown command name.
    #
    # String.Replace per entry rather than one regex per class: a snippet is a
    # few hundred characters, so the table above is the whole behaviour and no
    # pattern in this file has to contain a character you can't see.
    #
    # Opt-in (psnip -Repair), never automatic. A curly quote INSIDE a string
    # literal is content the snippet wants kept, and silently rewriting a file
    # is a worse failure than a parse error you can see and fix.
    [OutputType([string])]
    param([string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $out = $Text
    foreach ($sub in $script:SnippetSubstitution) {
        $out = $out.Replace([string][char]$sub.From, $sub.To)
    }
    return $out
}

# Where captures land. One definition, because `psnip -List` and `psnip -Clean`
# have to mean the same folder Get-SnippetScratchPath writes into - the class of
# drift ARCHITECTURE #13 keeps out of the persisted data root, applied to the
# scratch root for the same reason.
#
# $env:TEMP, not [IO.Path]::GetTempPath(): that is what `peek` uses and what
# every doc says, and GetTempPath honours TMP before TEMP, so on an image where
# the two differ the captures would land somewhere the docs don't point at.
# Expanded to its long form the way `j` does, since %TEMP% is usually set with
# an 8.3 name (C:\Users\JOHNSM~1\...) that would otherwise show up in every
# printed path and dot-source line.
$script:SnipRoot = Join-Path ([IO.DirectoryInfo]::new($env:TEMP).FullName) 'pwsh-snips'

function Get-SnippetScratchPath {
    # <TEMP>\pwsh-snips\snip-<stamp>.ps1 - its own folder so the scratch files
    # are findable and deletable as a set rather than scattered through %TEMP%.
    #
    # The stamp is formatted invariant and carries no separators of its own:
    # Get-Date -Format inserts culture-specific ones, and a path is not where
    # you want to discover that. Second resolution collides if psnip runs twice
    # inside one second, so an existing name takes a -2, -3 suffix rather than
    # overwriting the snippet just opened.
    [OutputType([string])]
    param([datetime] $Now = (Get-Date), [string] $Root)

    if (-not $Root) { $Root = $script:SnipRoot }
    # -ErrorAction Stop: a root that can't be created must surface here, inside
    # psnip's try, rather than let the write below fail non-terminatingly and
    # the command carry on to replace the clipboard.
    if (-not (Test-Path -LiteralPath $Root)) { $null = New-Item -ItemType Directory -Path $Root -Force -ErrorAction Stop }

    $base = 'snip-{0}' -f $Now.ToString('yyyyMMdd-HHmmss', [cultureinfo]::InvariantCulture)
    $path = Join-Path $Root "$base.ps1"
    $n    = 2
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $Root "$base-$n.ps1"
        $n++
    }
    return $path
}

$script:SnipEditor = $null

function Get-SnippetEditor {
    # VS Code when it can be found, Notepad otherwise. PATH first, then the two
    # standard install roots (Peek.ps1's pattern, #5) - a user-scope VS Code
    # install only puts `code` on PATH if the installer's "Add to PATH" box was
    # ticked, which is exactly the machine where the fallback matters.
    #
    # Cached after the first resolve: a Get-Command miss costs ~70 ms and psnip
    # is meant to be run repeatedly in a session. The cache is re-validated the
    # way Get-PeekRarExe's is, so a VS Code that is uninstalled - or briefly
    # absent while its updater swaps bin\code.cmd - falls back to Notepad on
    # the next call instead of failing every call until a new shell. The one
    # remaining cost is that a cached Notepad won't notice VS Code being
    # installed mid-session.
    [OutputType([string])]
    param()

    if ($script:SnipEditor -and
        ($script:SnipEditor -eq 'notepad.exe' -or (Test-Path -LiteralPath $script:SnipEditor))) {
        return $script:SnipEditor
    }

    $onPath = Get-Command 'code' -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if ($onPath) {
        $script:SnipEditor = $onPath.Source
        return $script:SnipEditor
    }
    foreach ($candidate in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
            (Join-Path $env:ProgramFiles  'Microsoft VS Code\bin\code.cmd'))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $script:SnipEditor = $candidate
            return $script:SnipEditor
        }
    }
    $script:SnipEditor = 'notepad.exe'
    return $script:SnipEditor
}

function Start-SnippetEditor {
    # Kept apart from Get-SnippetEditor so that resolving an editor and
    # launching one are separately testable, and so a broken or missing editor
    # costs a warning rather than the file you just captured - by the time this
    # runs the snippet is already safely on disk, and the path is printed next.
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Path)

    $editor = Get-SnippetEditor
    try {
        # -n forces VS Code to open its own window. Reusing the open one would
        # drop an unreviewed snippet into the window that already trusts your
        # project folder; on its own it can sit in Restricted Mode, which is the
        # right posture for code you have not read yet. There is deliberately no
        # attempt to pre-answer the trust prompt - psnip exists to make you look,
        # and VS Code asking is part of looking. Notepad takes no such flag.
        if ([IO.Path]::GetFileNameWithoutExtension($editor) -like 'code*') {
            & $editor -n $Path
        } else {
            & $editor $Path
        }
        return $true
    } catch {
        Write-Host "  Couldn't open $editor - the file is at $Path" -ForegroundColor Yellow
        return $false
    }
}

function Show-SnippetScratch {
    # The captures still on disk, newest first. Mirrors `peek -Active`: a scratch
    # tree you can't see is a scratch tree you never clean. Rows reuse this
    # file's own Format-SnippetPreview and Recent.ps1's Format-FileAge, so a
    # listing reads like `cb`'s picker.
    $files = @()
    if (Test-Path -LiteralPath $script:SnipRoot) {
        $files = @(Get-ChildItem -LiteralPath $script:SnipRoot -Filter 'snip-*.ps1' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending)
    }
    if ($files.Count -eq 0) {
        Write-Host '  No captured snippets.' -ForegroundColor DarkGray
        return
    }

    foreach ($f in $files) {
        $raw     = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        $preview = Format-SnippetPreview $raw
        $age     = '{0,5}' -f (Format-FileAge $f.LastWriteTime)
        Write-Host ("  `e[90m{0}`e[0m  {1}  `e[90m{2}`e[0m" -f $age, $f.Name, $preview)
    }
    Write-Host ''
    Write-Host "  $($files.Count) in $script:SnipRoot   (psnip -Clean wipes them)" -ForegroundColor DarkGray
}

function Clear-SnippetScratch {
    # Wipe the scratch tree, the way `peek -Clean` wipes its own.
    #
    # Deliberately without peek's "step out of the tree first" dance: peek jumps
    # you INTO what it extracted, so it has to walk you out before deleting.
    # psnip only ever hands you a path, so the working directory is somewhere
    # else unless you went there yourself - which the catch below covers.
    if (-not (Test-Path -LiteralPath $script:SnipRoot)) {
        Write-Host '  Nothing to clean.' -ForegroundColor DarkGray
        return
    }
    try {
        Remove-Item -LiteralPath $script:SnipRoot -Recurse -Force -ErrorAction Stop
        Write-Host "  Cleaned $script:SnipRoot" -ForegroundColor Green
    } catch {
        Write-Host "  Cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Step out of the folder if you are standing in it - editors do not lock these files.' -ForegroundColor DarkGray
    }
}

function psnip {
    <#
    .SYNOPSIS
        Safe paste - clipboard to a scratch .ps1, opened in your editor.
    .DESCRIPTION
        Writes whatever is on the clipboard to a timestamped .ps1 under
        %TEMP%\pwsh-snips and opens it in VS Code (Notepad if VS Code isn't
        installed), so a multi-line snippet from a web page or a chat can be
        read before any of it runs.

        Pasting that same text at the prompt is what this replaces: a clipboard
        ending in a newline submits itself before you can look at it, several
        top-level statements execute as they land, and characters that rendered
        HTML substitutes for ASCII - curly quotes, non-breaking spaces, an en
        dash in front of a parameter - parse as something other than what they
        look like.

        VS Code gets its own window (-n), so an unreviewed snippet never lands
        in the window that already trusts your project folder, and its window
        can stay in Restricted Mode. The trust prompt is left alone on purpose:
        psnip exists to make you look, and that prompt is part of looking.

        The dot-source line for the file is printed, put on the clipboard and
        added to history, so running it is Up then Enter once you've read it.
        Dot-sourced rather than called, because a snippet that defines
        functions is the common case and `& <path>` would lose them along with
        the child scope.

        Captures accumulate until %TEMP% is cleaned; `psnip -List` shows them
        and `psnip -Clean` wipes them, the same pair `peek` uses.
    .PARAMETER Repair
        Repair the characters rendered text substitutes for ASCII - curly
        quotes, non-ASCII dashes, non-breaking and zero-width spaces - on the
        way to the file. Off by default: inside a string literal those
        characters are content, and a silent rewrite is worse than a parse
        error you can see.
    .PARAMETER List
        Show the captured snippets still on disk, newest first.
    .PARAMETER Clean
        Wipe the scratch tree (%TEMP%\pwsh-snips), as `peek -Clean` does.
    .EXAMPLE
        psnip

        Writes the clipboard to %TEMP%\pwsh-snips\snip-20260920-143007.ps1 and
        opens it in a new VS Code window. Read it, then Up + Enter to
        dot-source it.
    .EXAMPLE
        psnip -Repair

        The same, for a snippet copied out of a blog post or a Word document,
        with the typographic quotes and dashes turned back into ASCII.
    .EXAMPLE
        psnip -List

        Lists the captures still on disk with their age and first line.
    .LINK
        cb
    #>
    [CmdletBinding(DefaultParameterSetName = 'Capture')]
    param(
        [Parameter(ParameterSetName = 'Capture')] [switch] $Repair,
        [Parameter(ParameterSetName = 'List')]    [switch] $List,
        [Parameter(ParameterSetName = 'Clean')]   [switch] $Clean
    )

    if ($List)  { Show-SnippetScratch;  return }
    if ($Clean) { Clear-SnippetScratch; return }

    # Get-Clipboard throws on a non-text clipboard (an image, a file drop from
    # Explorer) - the same guard cb -Add uses.
    $text = $null
    try { $text = Get-Clipboard -Raw -ErrorAction Stop }
    catch { Write-Debug "Get-Clipboard failed (non-text clipboard?): $($_.Exception.Message)" }

    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-Host '  Clipboard is empty or not text - nothing to open.' -ForegroundColor Yellow
        return
    }

    if ($Repair) {
        $repaired = Repair-SnippetText $text
        if ($repaired -cne $text) {
            Write-Host '  Repaired smart quotes / dashes / invisible spaces.' -ForegroundColor DarkGray
        }
        $text = $repaired
    }

    # Nothing past this block may run unless the write succeeded. The clipboard
    # is the only copy of the snippet and Out-HowCommand replaces it, so a write
    # that fails non-terminatingly - Set-Content's default on a full disk or a
    # folder something is blocking - would otherwise sail straight on to hand
    # back a dot-source line for a file that doesn't exist and throw away the
    # text it was meant to protect.
    try {
        $path = Get-SnippetScratchPath
        # utf8BOM, not utf8: pwsh reads a BOM-less file as UTF-8 but Windows
        # PowerShell reads it as ANSI, and a pasted snippet is as likely to be
        # meant for 5.1 as for 7. The BOM is what makes the file mean the same
        # thing in both hosts, and a scratch file has nothing to lose by carrying it.
        Set-Content -LiteralPath $path -Value $text -Encoding utf8BOM -ErrorAction Stop
    } catch {
        Write-Host "  Couldn't write the snippet: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  The clipboard is untouched.' -ForegroundColor DarkGray
        return
    }

    $null = Start-SnippetEditor -Path $path

    # Count what you'd see, not what you'd split: the trailing newline that
    # rendered text nearly always carries is the very thing this command exists
    # around, and it must not report as an extra line. The file keeps it.
    $lines = @($text.TrimEnd("`r", "`n") -split "`r?`n").Count
    $unit  = if ($lines -eq 1) { 'line' } else { 'lines' }
    Write-Host "  $lines $unit  ->  $path" -ForegroundColor DarkGray

    # Out-HowCommand lives in How.ps1, which the loader dot-sources after this
    # file - fine, because psnip only ever runs interactively, by which point
    # every Common file is in the session (the same cross-file reuse as
    # Format-FileAge above; the unit suite dot-sources How.ps1 alongside this).
    # Single-quoted, so the only character that needs escaping is the quote
    # itself - and a user named O'Neil has one in every temp path.
    Out-HowCommand -Command ". '$($path.Replace("'", "''"))'"
}
