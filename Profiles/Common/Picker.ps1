# Scrollable interactive list picker (shared by prj; available to others).
# ============================================================================
# The folder jumper `j` and `rdp`/`rps` each grew their own inline picker that
# redraws every item from cursor-home each frame. That's fine for a handful of
# bookmarks, but with a long list (e.g. `prj` over 40+ repos) the content is
# taller than the window, the terminal scrolls, and cursor-home no longer maps
# to the top of the list — so the display glitches and "resets" as you move.
#
# Show-Picker fixes that with a fixed viewport: it draws only the rows that fit
# in the window, scrolls a window over the list as the cursor moves, and emits
# the whole frame as ONE string (home, content, clear-to-end) so there's no
# per-line cursor juggling and nothing ever overflows the screen.

function Get-PickerScrollTop {
    <#
    .SYNOPSIS
        Pure viewport math: the scroll offset that keeps the cursor visible.
    .DESCRIPTION
        Given the cursor index, the previous scroll offset, the number of
        visible rows, and the total item count, returns the new top-of-window
        index — adjusted minimally so the cursor stays in view and the window
        never runs past the end of the list. Pulled out as a pure function so
        the scrolling logic is unit-testable without a console.
    #>
    [OutputType([int])]
    param(
        [int] $Cursor,
        [int] $ScrollTop,
        [int] $ViewRows,
        [int] $Count
    )
    if ($ViewRows -lt 1) { $ViewRows = 1 }
    if ($Cursor -lt $ScrollTop) {
        $ScrollTop = $Cursor
    } elseif ($Cursor -ge $ScrollTop + $ViewRows) {
        $ScrollTop = $Cursor - $ViewRows + 1
    }
    $maxTop = [Math]::Max(0, $Count - $ViewRows)
    if ($ScrollTop -gt $maxTop) { $ScrollTop = $maxTop }
    if ($ScrollTop -lt 0)       { $ScrollTop = 0 }
    return $ScrollTop
}

function Get-PickerHotkey {
    <#
    .SYNOPSIS
        Single-character jump key for a 0-based item index: 1-9 then a-z.
    .DESCRIPTION
        Items 0-8 map to '1'..'9'; items 9-34 map to 'a'..'z' (so the list is
        addressable by one keypress up to 35 items). Returns '' beyond that.
    #>
    [OutputType([string])]
    param([int] $Index)
    if ($Index -ge 0  -and $Index -lt 9)  { return [string]($Index + 1) }
    if ($Index -ge 9  -and $Index -lt 35) { return [string][char]([int][char]'a' + ($Index - 9)) }
    return ''
}

function Get-PickerHotkeyIndex {
    <#
    .SYNOPSIS
        Inverse of Get-PickerHotkey: a typed char -> 0-based index, or -1.
    .DESCRIPTION
        '1'..'9' -> 0..8; 'a'..'z' (case-insensitive) -> 9..34. Anything else -> -1.
    #>
    [OutputType([int])]
    param([char] $Key)
    $k = [char]::ToLower($Key)
    if ($k -ge '1' -and $k -le '9') { return ([int][string]$k - 1) }
    if ($k -ge 'a' -and $k -le 'z') { return (9 + ([int][char]$k - [int][char]'a')) }
    return -1
}

function Get-PickerPlainText {
    <#
    .SYNOPSIS
        Strip ANSI SGR color sequences from a string.
    .DESCRIPTION
        Row bodies may carry `e[..m color codes; padding, truncation, and the
        cursor-row highlight must all work on the VISIBLE text, not the raw
        string. Pulled out as a pure function so the width math is unit-testable
        without a console.
    #>
    [OutputType([string])]
    param([string] $Text)
    if (-not $Text) { return '' }
    return ($Text -replace "`e\[[0-9;]*m", '')
}

function Show-Picker {
    <#
    .SYNOPSIS
        Interactive single-select list picker with a scrolling viewport.
    .DESCRIPTION
        Renders Items on the alternate screen buffer. Up/Down move (PageUp/Down,
        Home/End jump), Enter selects, Esc cancels; each row carries a single-key
        jump label (1-9 then a-z, up to 35 items). Returns the selected item, or
        $null on cancel. RenderRow formats each row's body (after the marker + key).
    .PARAMETER Items
        The objects to choose from.
    .PARAMETER RenderRow
        Scriptblock ($item, [int]$width) -> string producing the row body.
        Use .GetNewClosure() if it references caller variables (e.g. a column width).
        The body may embed ANSI color codes (`e[..m): the picker pads and
        truncates by visible width, and strips codes on the cursor row so the
        highlight bar stays uniform.
    .PARAMETER Title
        Header line shown at the top.
    .PARAMETER Hint
        Sub-header line describing the keys.
    #>
    param(
        [Parameter(Mandatory)] [array] $Items,
        [Parameter(Mandatory)] [scriptblock] $RenderRow,
        [string] $Title = 'Select',
        [string] $Hint  = 'Up/Down + Enter  Esc cancel  |  digits 1-9 jump'
    )

    if (-not $Items -or $Items.Count -eq 0) { return $null }

    $esc       = [char]27
    $cursor    = 0
    $scrollTop = 0
    $selected  = $null

    [Console]::Write("$esc[?1049h")   # alternate screen buffer
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $winW = [Math]::Max(20, [Console]::WindowWidth - 1)
            $winH = [Math]::Max(8,  [Console]::WindowHeight)

            # Header (title, hint, blank) + footer (status) + 1 safety row.
            $viewRows = [Math]::Max(1, $winH - 3 - 1 - 1)
            $viewRows = [Math]::Min($viewRows, $Items.Count)
            $scrollTop = Get-PickerScrollTop -Cursor $cursor -ScrollTop $scrollTop -ViewRows $viewRows -Count $Items.Count

            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.Append("$esc[H")   # cursor home — frame drawn top-down from here
            [void]$sb.AppendLine(("  $Title").PadRight($winW))
            [void]$sb.AppendLine(("  $Hint").PadRight($winW))
            [void]$sb.AppendLine(''.PadRight($winW))

            for ($r = 0; $r -lt $viewRows; $r++) {
                $i        = $scrollTop + $r
                $isCursor = ($i -eq $cursor)
                $marker   = if ($isCursor) { '>' } else { ' ' }
                $numKey   = Get-PickerHotkey $i
                if (-not $numKey) { $numKey = ' ' }
                $body      = [string](& $RenderRow $Items[$i] ($winW - 7))
                $plainBody = Get-PickerPlainText $body

                if ($isCursor) {
                    # The highlight bar owns this row's colors: render the body
                    # stripped, or embedded codes would break out of the bar.
                    $line = "  {0} {1}  {2}" -f $marker, $numKey, $plainBody
                    if ($line.Length -gt $winW) { $line = $line.Substring(0, $winW) }
                    [void]$sb.AppendLine("$esc[30;46m$($line.PadRight($winW))$esc[0m")   # black on cyan
                } else {
                    # Pad by VISIBLE width (the gutter "  > k  " is 7 columns).
                    # An overflowing row falls back to stripped text — truncating
                    # mid-escape would leak a broken sequence into the frame.
                    $visible = 7 + $plainBody.Length
                    if ($visible -gt $winW) {
                        [void]$sb.AppendLine(("  {0} {1}  {2}" -f $marker, $numKey, $plainBody).Substring(0, $winW))
                    } else {
                        $prefix = "  {0} $esc[36m{1}$esc[0m  " -f $marker, $numKey   # hotkey column in cyan
                        [void]$sb.AppendLine("$prefix$body$esc[0m" + ''.PadRight($winW - $visible))
                    }
                }
            }

            $status = "  $($cursor + 1)/$($Items.Count)"
            if ($scrollTop -gt 0)                          { $status += '   ↑ more' }
            if ($scrollTop + $viewRows -lt $Items.Count)   { $status += '   ↓ more' }
            [void]$sb.Append($status.PadRight($winW))
            [void]$sb.Append("$esc[J")   # wipe anything left below the frame

            [Console]::Write($sb.ToString())

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($cursor -gt 0)                { $cursor-- } }
                'DownArrow' { if ($cursor -lt $Items.Count - 1) { $cursor++ } }
                'PageUp'    { $cursor = [Math]::Max(0, $cursor - $viewRows) }
                'PageDown'  { $cursor = [Math]::Min($Items.Count - 1, $cursor + $viewRows) }
                'Home'      { $cursor = 0 }
                'End'       { $cursor = $Items.Count - 1 }
                'Enter'     { $selected = $Items[$cursor] }
                'Escape'    { $selected = $null }
            }
            if ($key.Key -eq 'Enter' -or $key.Key -eq 'Escape') { break }

            $idx = Get-PickerHotkeyIndex $key.KeyChar
            if ($idx -ge 0 -and $idx -lt $Items.Count) { $selected = $Items[$idx]; break }
        }
    }
    finally {
        [Console]::CursorVisible = $true
        [Console]::Write("$esc[?1049l")
    }

    return $selected
}
