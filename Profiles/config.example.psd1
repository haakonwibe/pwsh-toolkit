# ============================================================================
# pwsh-toolkit profile configuration
# ----------------------------------------------------------------------------
# Copy this file to `config.psd1` (same folder) and edit. The loader reads
# `config.psd1` if present; otherwise it falls back to these defaults.
#
# `config.psd1` is gitignored — your edits stay local.
# ============================================================================

@{
    # ─── Prompt ──────────────────────────────────────────────────────────────
    # 'OhMyPosh'  – Use Oh My Posh + the theme below. Requires oh-my-posh on
    #               PATH and a Nerd Font in your terminal.
    # 'Custom'    – Use the in-repo custom prompt (Common/Prompt.ps1).
    # 'Default'   – Leave PowerShell's default prompt alone.
    Prompt = 'Custom'

    # OhMyPosh theme. Bare filename = looked up in Profiles/OhMyPosh/.
    # Absolute path or path-containing-slash = used as-is.
    OhMyPoshTheme = 'default.omp.json'

    # ─── Toolkit location ────────────────────────────────────────────────────
    # Folder containing WingetUpgrade/, DownloadsOrganizer/, etc. Used by the
    # `winup`, `tagdl`, `dird`, `fr` wrappers to find their target scripts.
    #
    # $null  = auto-detect (parent of Profiles/) — works for the default layout
    #          where Profiles/ is a subfolder of the cloned repo.
    # string = explicit path. Use this if you've split Profiles/ off into a
    #          separate dotfiles repo and need to point at the toolkit elsewhere.
    ToolkitRoot = $null

    # ─── OneDrive ────────────────────────────────────────────────────────────
    # Organization suffix for "OneDrive - <Org>" paths used by the `docs`,
    # `desktop`, `onedrive` helpers and the default OneDrive jump entry.
    #
    # $null    = auto-detect from $env:OneDriveCommercial (set by the OneDrive
    #            client when signed into a Business account). Falls back to
    #            personal OneDrive if no Business account is signed in.
    # ''       = force personal OneDrive (no " - Org" suffix).
    # 'Name'   = explicit override.
    OneDriveOrg = $null

    # ─── Folder jumper (j) ───────────────────────────────────────────────────
    # Extra destinations appended to the built-in starter list (Home, Downloads,
    # OneDrive, LocalAppData, ProgramData).
    #
    # IMPORTANT — only literal strings here. This file is parsed by
    # Import-PowerShellDataFile in restricted-language mode, which DISALLOWS
    # variable references and expressions:
    #
    #     Path = 'C:\GitHub'        ← OK (literal string)
    #     Path = $env:TEMP          ← ERROR (variable reference)
    #     Path = "$HOME\dev"        ← ERROR (interpolation)
    #     Path = (Join-Path ...)    ← ERROR (cmdlet call)
    #
    # For anything that needs PowerShell evaluation (env vars, conditional
    # paths, Test-Path checks, etc.), put it in Machines/<COMPUTERNAME>.ps1 —
    # that file is regular PowerShell, dot-sourced after this config is
    # applied, so it can extend $script:JumpFolders with arbitrary expressions:
    #
    #     $script:JumpFolders += [pscustomobject]@{ Label = 'Temp'; Path = $env:TEMP }
    ExtraJumpFolders = @(
        # @{ Label = 'GitHub'; Path = 'C:\GitHub' }
        # @{ Label = 'VMs';    Path = 'D:\VMs' }
    )

    # ─── Remote servers (rdp, rps) ───────────────────────────────────────────
    # Destinations for the `rdp` (Remote Desktop / mstsc) and `rps` (PowerShell
    # Remoting / Enter-PSSession) helpers. Same literals-only constraint as
    # ExtraJumpFolders.
    #
    # Each entry takes:
    #   Label   — short display name shown in the picker
    #   Address — DNS name or IP that mstsc / Enter-PSSession will connect to
    #   User    — optional. rps pre-fills Get-Credential with this name; rdp
    #             ignores it (use Windows Credential Manager / cmdkey if you
    #             want RDP creds saved).
    #
    # No credential helpers in v1 — let Windows / Get-Credential prompt as
    # needed. SSH transport for PSRemoting is also out of scope; rps uses the
    # default WinRM transport.
    RemoteServers = @(
        # @{ Label = 'Lab DC';      Address = 'dc01.lab.local';   User = 'lab\admin' }
        # @{ Label = 'Build';       Address = 'build.contoso.com' }
        # @{ Label = 'Jumphost';    Address = '10.0.5.20' }
    )

    # ─── Startup tips ────────────────────────────────────────────────────────
    # The rotating tip shown at shell startup. The env var $env:PSPROFILE_NO_TIPS
    # also disables tips and overrides this setting (handy for CI / scripts).
    DisableStartupTips = $false

    # ─── Feature toggles ─────────────────────────────────────────────────────
    Features = @{
        # Skip the M365/ helpers even if Microsoft.Graph is installed.
        DisableM365 = $false
    }
}
