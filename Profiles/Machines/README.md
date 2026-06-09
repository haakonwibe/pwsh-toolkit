# Machine-Specific Profile Configuration

This directory contains machine-specific PowerShell profile customizations. Each file is named after the computer it applies to (`$env:COMPUTERNAME.ps1`).

## Purpose

Machine-specific configurations are useful for:
- Different OneDrive for Business organizations
- Machine-specific network drives or paths
- Performance tweaks for slower/faster machines
- Environment-specific tools or shortcuts
- Machine-specific environment variables

## Creating a Machine-Specific Configuration

**Fastest start** — copy the bundled template (`EXAMPLE-DESKTOP.ps1.example`) to your computer's name:

```powershell
Copy-Item EXAMPLE-DESKTOP.ps1.example "$env:COMPUTERNAME.ps1"
```

Then edit the new `.ps1` and reload with `. $PROFILE`. The template ships with every line commented, so it does nothing until you uncomment what you want. Or from scratch:

1. Get your computer name:
   ```powershell
   $env:COMPUTERNAME
   ```

2. Create a file named `{COMPUTERNAME}.ps1` in this directory

3. Add your customizations

## Example Configurations

### Override OneDrive Organization

```powershell
# File: WORKSTATION01.ps1

# Override the default OneDrive organization
$script:OneDriveOrg = "ClientName Inc"

# Now docs, desktop, onedrive functions will use this organization
```

### Add Machine-Specific Navigation Shortcuts

```powershell
# File: LAPTOP-GAMING.ps1

# Add gaming-specific shortcuts
function games { Set-Location "D:\Gaming" }
function steam { Set-Location "D:\Gaming\SteamLibrary" }
function epic { Set-Location "D:\Gaming\EpicGames" }
```

### Add Jump Folder Destinations

The folder jumper (`j` picker, `j name` direct jump, `jb`/`jf` history) reads
its destinations from `$script:JumpFolders`. Simple literal paths belong in
`config.psd1`'s `ExtraJumpFolders`, but anything that needs PowerShell to
evaluate — environment variables, `Test-Path` checks, conditional paths —
belongs here, because this file is dot-sourced *after* the config is applied.

```powershell
# File: LAPTOP-WORK.ps1

# Append destinations the picker can't express as plain literals.
$script:JumpFolders += [pscustomobject]@{ Label = 'Temp'; Path = $env:TEMP }
$script:JumpFolders += [pscustomobject]@{ Label = 'VMs';  Path = 'D:\VMs' }

# Only add the drive if it's actually mapped on this machine.
if (Test-Path 'Z:\') {
    $script:JumpFolders += [pscustomobject]@{ Label = 'Share'; Path = 'Z:\Projects' }
}

# Add every immediate subfolder of a repo root as its own destination.
Get-ChildItem 'C:\GitHub' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $script:JumpFolders += [pscustomobject]@{ Label = "gh:$($_.Name)"; Path = $_.FullName }
}
```

After reloading, `j` shows the new entries and `j temp` jumps straight there.
For static, literal-only paths prefer `config.psd1` instead:

```powershell
# In config.psd1 (not here) — no PowerShell evaluation needed:
ExtraJumpFolders = @(
    @{ Label = 'GitHub'; Path = 'C:\GitHub' }
    @{ Label = 'VMs';    Path = 'D:\VMs' }
)
```

### Machine-Specific Performance Tuning

```powershell
# File: SLOWPC.ps1

# Disable expensive prompt features for slower machines
function prompt {
    $location = Get-Location
    $path = $location.Path

    # Simpler prompt without expensive Get-MgContext call
    Write-Host "PS $path" -ForegroundColor Green
    return "> "
}
```

### Environment-Specific Variables

```powershell
# File: DEVMACHINE.ps1

# Development environment variables
$env:DEVELOPMENT_MODE = "true"
$env:API_ENDPOINT = "https://dev.example.com/api"

# Dev-specific shortcuts
function devlogs { Set-Location "C:\Logs\Development" }
```

### Network Drive Mappings

```powershell
# File: OFFICE-PC.ps1

# Map network drives
if (-not (Test-Path "Z:\")) {
    New-PSDrive -Name "Z" -PSProvider FileSystem -Root "\\fileserver\share" -Persist
}

# Add navigation shortcut
function shared { Set-Location "Z:\" }
```

### Client-Specific Configuration

```powershell
# File: CONSULTANT-LAPTOP.ps1

# Override for current client
$script:OneDriveOrg = "Acme Corporation"

# Client-specific paths
function client { Set-Location "$env:USERPROFILE\OneDrive - Acme Corporation\Client Work" }

# Client-specific environment
$env:CLIENT_NAME = "Acme"
$env:PROJECT_ROOT = "C:\Projects\Acme"
```

## Overriding Functions

You can completely replace any function from Common/ or M365/:

```powershell
# File: CUSTOMPC.ps1

# Override the default prompt with your own
function prompt {
    # Your custom prompt implementation
    return "CUSTOM> "
}

# Override navigation shortcuts
function projects { Set-Location "E:\MyProjects" }
```

## Testing Your Configuration

1. Save your machine-specific file
2. Reload your profile:
   ```powershell
   . $PROFILE
   ```
3. Verify your customizations loaded:
   ```powershell
   # Test overridden variable
   $script:OneDriveOrg

   # Test custom function
   Get-Command games -ErrorAction SilentlyContinue
   ```

## Debugging

Enable verbose output to see if your machine config is loading:

```powershell
$VerbosePreference = "Continue"
. $PROFILE
```

You should see:
```
Loading machine-specific configuration: {COMPUTERNAME}
```

## Best Practices

1. **Keep it minimal** - Only include machine-specific items
2. **Document your changes** - Add comments explaining why something is different
3. **Test thoroughly** - Reload your profile after changes
4. **Use script scope** - Use `$script:` for variables that override Common/ defaults
5. **Avoid secrets** - Use `Get-OrCreateSecret` instead of hardcoding credentials

## Example: Full Machine Configuration

```powershell
# File: LAPTOP-WORK.ps1
# Work laptop configuration for Contoso deployment

# === OneDrive Configuration ===
$script:OneDriveOrg = "Contoso Ltd"

# === Navigation Shortcuts ===
function contoso { Set-Location "$env:USERPROFILE\OneDrive - Contoso Ltd\Projects" }
function tickets { Set-Location "$env:USERPROFILE\OneDrive - Contoso Ltd\Support Tickets" }

# === Environment Variables ===
$env:CONTOSO_TENANT_ID = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# === Performance Tweaks ===
# Disable expensive Get-TenantOverview auto-completion on slow VPN
$PSDefaultParameterValues['Get-TenantOverview:Confirm'] = $true

# === Machine-Specific Aliases ===
Set-Alias -Name vpn -Value "C:\Program Files\Cisco\Cisco AnyConnect\vpnui.exe"

# === Custom Functions ===
function Connect-ContosoVPN {
    Start-Process "C:\Program Files\Cisco\Cisco AnyConnect\vpnui.exe"
}

Write-Host "✅ Contoso work configuration loaded" -ForegroundColor Green
```
