# JSON viewer: `json` (Show-Json)
# ============================================================================
# Pretty-print and syntax-highlight JSON in the terminal — from a .json file, a
# piped JSON string, or any piped object (which gets serialized first). Keys,
# strings, numbers, literals (true/false/null) and punctuation each get their
# own color via ANSI escapes, mirroring the toolkit's palette (cyan keys, green
# strings, gray punctuation).
#
# Minified JSON is reflowed to readable indentation; already-formatted or JSONC
# (comment-bearing) files can be shown verbatim with -Raw, and anything that
# isn't strict JSON falls back to as-is highlighting rather than erroring out.
# When the output is redirected (`json data.json > pretty.json`) or the host
# can't render virtual-terminal sequences, it emits clean, uncolored JSON so
# the captured text is usable.

# ANSI SGR color codes per token kind. Keep in step with the poster's highlight
# classes (cyan keys, green strings, purple keywords, gray punctuation).
$script:JsonColors = @{
    Key     = 96   # bright cyan
    String  = 92   # bright green
    Number  = 93   # bright yellow
    Literal = 95   # bright magenta (true / false / null)
    Punct   = 90   # dark gray  ( {} [] , : )
    Comment = 90   # dark gray  (JSONC // and /* */, when present)
}

# Token grammar. Order matters within the alternation:
#   - a key is a string that's immediately followed by a colon, so it has to be
#     tried before the plain-string rule;
#   - strings come before comments so a `//` inside a quoted value (e.g. a URL)
#     is swallowed by the string rule and never seen as a comment.
$script:JsonTokenRegex = [regex]::new(
    '(?<key>"(?:\\.|[^"\\])*"(?=\s*:))' +
    '|(?<str>"(?:\\.|[^"\\])*")' +
    '|(?<comment>//[^\n]*|/\*[\s\S]*?\*/)' +
    '|(?<lit>\b(?:true|false|null)\b)' +
    '|(?<num>-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)' +
    '|(?<punct>[{}\[\],:])'
)

function script:Format-JsonColor {
    param([string] $Json)

    $esc  = [char]27
    $eval = {
        param([System.Text.RegularExpressions.Match] $m)
        $code =
            if     ($m.Groups['key'].Success)     { $script:JsonColors.Key }
            elseif ($m.Groups['str'].Success)     { $script:JsonColors.String }
            elseif ($m.Groups['comment'].Success) { $script:JsonColors.Comment }
            elseif ($m.Groups['lit'].Success)     { $script:JsonColors.Literal }
            elseif ($m.Groups['num'].Success)     { $script:JsonColors.Number }
            elseif ($m.Groups['punct'].Success)   { $script:JsonColors.Punct }
            else                                  { $null }
        if ($code) { "$esc[${code}m$($m.Value)$esc[0m" } else { $m.Value }
    }
    $script:JsonTokenRegex.Replace($Json, [System.Text.RegularExpressions.MatchEvaluator]$eval)
}

function Show-Json {
    <#
    .SYNOPSIS
        View JSON with syntax highlighting — from a file, a pipe, or an object.
    .DESCRIPTION
        Reads JSON from a file path, a piped JSON string, or any piped object
        (serialized with ConvertTo-Json), then prints it with each token kind
        colored — keys, string values, numbers, true/false/null, and the
        structural punctuation.

        Minified or untidy JSON is reparsed and reflowed to readable
        indentation. Use -Raw to show the text exactly as-is instead —
        preserving the original formatting and any // comments, which the
        default reflow drops. Input that doesn't parse as JSON at all is shown
        verbatim with a warning rather than failing.

        Color is used only on an interactive terminal that supports it; when the
        output is redirected or piped, or with -NoColor, plain uncolored JSON is
        written to the output stream so `json data.json > pretty.json` produces
        a clean file.
    .PARAMETER Path
        Path to a .json file to view.
    .PARAMETER InputObject
        JSON text, or an object, received from the pipeline. A single piped
        string is treated as JSON text; objects are serialized first.
    .PARAMETER Depth
        Serialization depth for object input and for the reflow round-trip
        (ConvertTo-Json). Raise it for very deeply nested data. Default 32.
    .PARAMETER Raw
        Show the text exactly as-is — skip the parse-and-reflow step. Preserves
        original formatting and JSONC comments.
    .PARAMETER NoColor
        Emit plain, uncolored JSON even on an interactive terminal.
    .EXAMPLE
        json package.json

        Pretty-prints package.json with syntax highlighting. A minified file is
        reflowed to indented, readable JSON first.
    .EXAMPLE
        gh api repos/owner/name | json

        Pipes another command's JSON output through the highlighter — the piped
        string is parsed, reflowed, and colored.
    .EXAMPLE
        Get-Process pwsh | Select-Object Name, Id, WS | json

        Serializes objects to JSON and highlights them — a quick way to eyeball
        structured data.
    .EXAMPLE
        json .vscode\settings.json -Raw

        Shows a JSONC file verbatim — highlighted but not reformatted — so its
        // comments and existing layout are preserved instead of stripped.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([string])]
    param(
        [Parameter(ParameterSetName = 'Path', Position = 0)]
        [string] $Path,

        [Parameter(ParameterSetName = 'Input', ValueFromPipeline = $true)]
        [object] $InputObject,

        [int] $Depth = 32,
        [switch] $Raw,
        [switch] $NoColor
    )

    begin { $items = [System.Collections.Generic.List[object]]::new() }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Input') { $items.Add($InputObject) }
    }

    end {
        # --- 1. Resolve the JSON text, and whether we may reflow it -----------
        $text = $null
        $canReformat = -not $Raw

        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            if ([string]::IsNullOrWhiteSpace($Path)) {
                Write-Host '  Usage: json <file.json>   |   <command that emits JSON> | json' -ForegroundColor Yellow
                return
            }
            $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
            if (-not $resolved) { Write-Error "File not found: $Path"; return }
            if (Test-Path -LiteralPath $resolved -PathType Container) {
                Write-Error "Path is a directory, not a JSON file: $($resolved.Path)"; return
            }
            $text = Get-Content -Raw -LiteralPath $resolved -ErrorAction Stop
        }
        else {
            if ($items.Count -eq 0) {
                Write-Host '  Nothing to show — pipe JSON or pass a file: json <file.json>' -ForegroundColor Yellow
                return
            }
            # A lone piped string is JSON text; anything else (an object, a
            # number, several objects) is serialized — already pretty, so the
            # reflow round-trip is skipped.
            if ($items.Count -eq 1 -and $items[0] -is [string]) {
                $text = [string]$items[0]
            }
            elseif (-not ($items | Where-Object { $_ -isnot [string] })) {
                # Several piped strings are usually the LINES of one document
                # (Get-Content without -Raw). If the joined text parses as JSON,
                # show that document; otherwise serialize the strings as a JSON
                # array like any other object input.
                $joined = $items -join "`n"
                try {
                    $null = ConvertFrom-Json -InputObject $joined -ErrorAction Stop
                    $text = $joined
                } catch {
                    $text = ConvertTo-Json -InputObject $items.ToArray() -Depth $Depth
                    $canReformat = $false
                }
            }
            else {
                $obj = if ($items.Count -eq 1) { $items[0] } else { $items.ToArray() }
                $text = ConvertTo-Json -InputObject $obj -Depth $Depth
                $canReformat = $false
            }
        }

        if ([string]::IsNullOrWhiteSpace($text)) {
            Write-Host '  (empty)' -ForegroundColor DarkGray
            return
        }

        # --- 2. Reflow text input to tidy indentation (unless -Raw) -----------
        if ($canReformat) {
            try {
                $parsed = $text | ConvertFrom-Json -ErrorAction Stop
                $text   = ConvertTo-Json -InputObject $parsed -Depth $Depth
            }
            catch {
                # Not strict JSON (comments? trailing commas? truncated?). Show
                # it as-is rather than failing — still useful, still colored.
                Write-Warning "Couldn't parse as JSON ($($_.Exception.Message.Trim())); showing as-is. Use -Raw to skip this notice."
            }
        }

        # --- 3. Color for an interactive TTY, else emit plain JSON ------------
        $useColor = -not $NoColor -and
                    -not [Console]::IsOutputRedirected -and
                    ($Host.UI.SupportsVirtualTerminal -or
                     ($null -ne $PSStyle -and $PSStyle.OutputRendering -ne 'PlainText'))

        if ($useColor) { Write-Host (script:Format-JsonColor $text) }
        else           { $text }
    }
}
Set-Alias json Show-Json
