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
    # For complex or conditional setup, use Machines/<COMPUTERNAME>.ps1 and
    # append to $script:JumpFolders from there — that file is dot-sourced after
    # this config is applied, so it can override or extend anything here.
    ExtraJumpFolders = @(
        # @{ Label = 'GitHub'; Path = 'C:\GitHub' }
        # @{ Label = 'VMs';    Path = 'D:\VMs' }
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
