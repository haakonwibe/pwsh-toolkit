# Profile tips: rotating reminder of helpers in this profile, shown once at
# shell startup. Set `$env:PSPROFILE_NO_TIPS = '1'` to silence; re-roll
# anytime with the `tip` alias.

$script:ProfileTips = @(
    [pscustomobject]@{ H = 'j (no args)  —  interactive folder picker (digits 1-9 instant, Up/Down + Enter)';            E = 'Try: j   (also: j prog, j down, j main — substring match jumps directly)' }
    [pscustomobject]@{ H = 'jb / jf  —  browser-style back/forward through visited folders';                            E = 'Try: jb   (works after any cd or j to retrace your steps)' }
    [pscustomobject]@{ H = 'prj  —  jump to a git repo (picker, or prj <name>); scans your ProjectRoots';             E = 'Try: prj   (also: prj toolkit, prj -Refresh after cloning)' }
    [pscustomobject]@{ H = 'peek <archive>  —  extract any archive to a temp folder and jump there';                    E = 'Try: peek installer.zip   (also: peek -List, peek -Active, peek -Clean)' }
    [pscustomobject]@{ H = 'df  —  disk free overview with colored usage bars (green / yellow / red)';                  E = 'Try: df   (also: df -All for removable, network, and CD-ROM drives)' }
    [pscustomobject]@{ H = 'winup  —  interactive winget upgrade picker with CMTrace-friendly logging';                 E = 'Try: winup   (also: winup -All to skip the picker)' }
    [pscustomobject]@{ H = 'winup -Elevated  —  upgrade with a single UAC prompt up front, not one per package';        E = 'Try: winup -Elevated   (runs via Windows sudo / gsudo when enabled; new window otherwise)' }
    [pscustomobject]@{ H = 'tagdl  —  AI-tagged Downloads with BBS-style file descriptions';                            E = 'Try: tagdl -Limit 5   (then browse with dird or fr)' }
    [pscustomobject]@{ H = 'dird / fr  —  directory listing with AI descriptions and color coding';                     E = 'Try: fr ~\Downloads   (also: dird -GroupByBucket, dird -Bucket Installers)' }
    [pscustomobject]@{ H = 'json  —  pretty-print and syntax-highlight JSON (a file, a pipe, or an object)';            E = 'Try: json package.json   (also: gh api ... | json, Get-Process | json, json file -Raw)' }
    [pscustomobject]@{ H = 'Get-PubIP  —  public IPv4 and IPv6 with multiple fallback services';                        E = 'Try: Get-PubIP' }
    [pscustomobject]@{ H = 'Get-Uptime  —  how long since last boot';                                                   E = 'Try: Get-Uptime' }
    [pscustomobject]@{ H = 'Get-SysInfo  —  OS, memory, processor, and version at a glance';                            E = 'Try: Get-SysInfo' }
    [pscustomobject]@{ H = 'Find-File <name>  —  recursive filename search from the current directory';                 E = 'Try: Find-File config.json' }
    [pscustomobject]@{ H = 'Start-AdminTerminal  —  launch a new elevated Windows Terminal';                            E = 'Try: Start-AdminTerminal   (useful before winup on a non-elevated shell)' }
    [pscustomobject]@{ H = 'wtf  —  ask Claude what went wrong with the last error (or any piped text)';               E = 'Try: wtf   (or: $Error[0] | wtf, or: wtf "<pasted error>")' }
    [pscustomobject]@{ H = 'note "thing"  —  timestamped append to today''s markdown journal (Obsidian-friendly)';      E = 'Try: note Met with Karen re: policy rollout   (today opens the file)' }
    [pscustomobject]@{ H = 'Find-Note <query>  —  grep across every daily note';                                        E = 'Try: Find-Note "registry policy"' }
    [pscustomobject]@{ H = 'Set-NotesRoot  —  interactive picker over Obsidian vaults + OneDrive paths for NotesRoot';  E = 'Try: Set-NotesRoot   (default auto-detects, picker is for overriding)' }
    [pscustomobject]@{ H = 'Get-OrCreateSecret  —  retrieve a SecretStore secret or prompt to create it';               E = 'Try: Get-OrCreateSecret -Name "Weather-API-Key" -AsPlainText' }
    [pscustomobject]@{ H = 'Get-StoredSecrets  —  list every secret you have stashed in SecretStore';                   E = 'Try: Get-StoredSecrets' }
    [pscustomobject]@{ H = 'rdp  —  Remote Desktop picker driven by config.psd1''s RemoteServers list';                 E = 'Try: rdp   (also: rdp dc, rdp build — fuzzy match)' }
    [pscustomobject]@{ H = 'rps  —  PowerShell Remoting picker (Enter-PSSession) — same data as rdp';                   E = 'Try: rps   (User on the server entry pre-fills Get-Credential)' }
    [pscustomobject]@{ H = 'Connect-Tenant  —  Microsoft Graph login, read-only scopes preset';                          E = 'Try: Connect-Tenant   (then: Get-TenantOverview; -Access Write to modify)' }
    [pscustomobject]@{ H = 'Connect-Exchange  —  Exchange Online login';                                                E = 'Try: Connect-Exchange' }
    [pscustomobject]@{ H = 'Get-TenantOverview  —  comprehensive tenant statistics in one shot';                        E = 'Try: Get-TenantOverview   (after Connect-Tenant)' }
    [pscustomobject]@{ H = 'ask <question>  —  quick reference via the ch.at API';                                      E = 'Try: ask "regex to match an IPv4 address"' }
    [pscustomobject]@{ H = 'docs / desktop / downloads / onedrive / home  —  named navigation shortcuts';              E = 'Try: downloads   (or use j for an interactive picker)' }
    [pscustomobject]@{ H = 'mkcd / up / .. / ...  —  make-and-enter a dir; go up N levels';                            E = 'Try: mkcd src\new-feature   (also: up 2, .., ...)' }
    [pscustomobject]@{ H = 'sudo <command>  —  run one command elevated (delegates to gsudo / Windows sudo if enabled)'; E = 'Try: sudo winget upgrade --all   (runs in this window with native sudo; new window if none)' }
    [pscustomobject]@{ H = 'll / la / lh  —  list files: normal / all (incl. hidden) / only hidden+system';            E = 'Try: ll   (la adds hidden, lh shows ONLY hidden+system; dird for descriptions)' }
    [pscustomobject]@{ H = 'touch <file>  —  create a file, or bump its timestamp if it already exists (never truncates)'; E = 'Try: touch notes.md   (accepts paths and multiple files: touch a.txt src\b.txt)' }
    [pscustomobject]@{ H = 'which <command>  —  find which file backs a command';                                       E = 'Try: which pwsh' }
    [pscustomobject]@{ H = 'Set-PoshTheme  —  browse/switch Oh My Posh themes (Update-PoshThemes gets ~120 first)';      E = 'Try: Set-PoshTheme   (or OhMyPoshTheme = ''Random'' for a new one each shell; Get-PoshTheme shows it)' }
    [pscustomobject]@{ H = 'Get-TerminalFont / Set-TerminalFont  —  read or change the Windows Terminal font face';     E = 'Try: Get-TerminalFont   (then: Set-TerminalFont ''MesloLGM Nerd Font'' — backs up settings.json)' }
    [pscustomobject]@{ H = 'toolkit  —  list every toolkit command grouped by area (the what-can-I-do view)';            E = 'Try: toolkit   (or Get-ToolkitCommand | Where Group -eq ''Secrets'' to filter)' }
    [pscustomobject]@{ H = 'tip  —  show another profile tip (re-roll)';                                                E = 'Try: tip   (or set $env:PSPROFILE_NO_TIPS=1 to silence at startup)' }
)

function Show-ProfileTip {
    <#
    .SYNOPSIS
        Show a random profile tip (alias: tip).
    #>
    [CmdletBinding()]
    param()

    if (-not $script:ProfileTips -or $script:ProfileTips.Count -eq 0) { return }

    $stateDir  = Join-Path $env:LOCALAPPDATA 'PSProfile'
    $stateFile = Join-Path $stateDir 'last-tip.txt'
    $lastIdx   = -1
    if (Test-Path -LiteralPath $stateFile) {
        $raw = Get-Content -LiteralPath $stateFile -ErrorAction SilentlyContinue | Select-Object -First 1
        [int]::TryParse($raw, [ref] $lastIdx) | Out-Null
    }

    # Pick a fresh tip — avoids repeating the same one when you spawn multiple shells in a row.
    $count = $script:ProfileTips.Count
    do { $idx = Get-Random -Minimum 0 -Maximum $count } while ($count -gt 1 -and $idx -eq $lastIdx)

    try {
        if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        Set-Content -LiteralPath $stateFile -Value $idx -Encoding utf8
    }
    catch {
        # Tip rotation is best-effort, not load-bearing — don't fail the
        # shell over it. Routed to the debug stream rather than swallowed.
        Write-Debug "Tip-state write failed (non-fatal): $($_.Exception.Message)"
    }

    $tip = $script:ProfileTips[$idx]
    Write-Host ('💡 ' + $tip.H) -ForegroundColor Cyan
    Write-Host ('   ' + $tip.E) -ForegroundColor DarkGray
}

Set-Alias tip Show-ProfileTip
