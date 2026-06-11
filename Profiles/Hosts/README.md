# Host-Specific Profile Configuration

This directory contains PowerShell host-specific customizations. Each file is named after the PowerShell host it applies to.

## Purpose

Host-specific configurations are useful for:
- Different PSReadLine settings per terminal
- Host-specific key bindings
- Different prompt styles for different terminals
- Terminal-specific color schemes
- Editor integration settings

## What is a PowerShell Host?

A PowerShell "host" is the application running PowerShell. Different hosts may have different capabilities and display characteristics.

Common hosts:
- **ConsoleHost** - What plain pwsh reports — in a traditional console window, in Windows Terminal, *and* in a plain VS Code integrated terminal. Use `$env:WT_SESSION` / `$env:TERM_PROGRAM -eq 'vscode'` inside `ConsoleHost.ps1` to tell them apart (see [Detecting Multiple Hosts](#detecting-multiple-hosts)).
- **Visual Studio Code Host** - The VS Code *PowerShell extension's* integrated console (file: `VisualStudioCodeHost.ps1`)
- **Windows PowerShell ISE Host** - PowerShell ISE (legacy; file: `WindowsPowerShellISEHost.ps1`)

> Windows Terminal is not its own host — it reports `ConsoleHost` like any other terminal running pwsh.

## Getting Your Host Name

```powershell
(Get-Host).Name
# Example output: "ConsoleHost" or "Visual Studio Code Host"
```

## Creating a Host-Specific Configuration

**Fastest start** — copy the bundled template (`ExampleHost.ps1.example`) to your host's name:

```powershell
Copy-Item ExampleHost.ps1.example "$((Get-Host).Name -replace ' ', '').ps1"
```

Then edit the new `.ps1` and reopen the host (or `. $PROFILE`). The template ships with every line commented, so it does nothing until you uncomment what you want. Or from scratch:

1. Get your host name (spaces will be removed):
   ```powershell
   $hostName = (Get-Host).Name -replace " ", ""
   # "Visual Studio Code Host" becomes "VisualStudioCodeHost"
   ```

2. Create a file named `{HostName}.ps1` in this directory

3. Add your customizations

## Example Configurations

### VS Code Specific Settings

> **Want Oh My Posh off in VS Code (but kept everywhere else)?** Set `$script:Config.Prompt = 'Custom'` here and dot-source the Custom prompt — that one flip also makes the loader's Oh My Posh tail (transient prompt + Graph hook) skip itself, so nothing is left half-initialized. A ready-to-copy `VisualStudioCodeHost.ps1.example` ships in this folder:
>
> ```powershell
> $script:Config.Prompt = 'Custom'
> . (Join-Path $script:ProfileRoot 'Common\Prompt.ps1')
> ```

This file fires for the PowerShell *extension's* integrated console (host name "Visual Studio Code Host"). A plain VS Code terminal without the extension reports `ConsoleHost` — branch on `$env:TERM_PROGRAM -eq 'vscode'` in `ConsoleHost.ps1` for that case.

```powershell
# File: VisualStudioCodeHost.ps1

# VS Code-specific PSReadLine settings
Set-PSReadLineOption -PredictionViewStyle InlineView  # Better for narrow terminal

# VS Code already has excellent command history
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

# Simpler prompt for VS Code (save space)
function prompt {
    $location = Split-Path -Leaf (Get-Location)
    Write-Host "PS $location" -NoNewline -ForegroundColor Cyan
    return "> "
}

Write-Verbose "VS Code host configuration loaded"
```

### Windows Terminal Settings

Windows Terminal reports the host name `ConsoleHost`, so these settings go in `ConsoleHost.ps1` gated on `$env:WT_SESSION`:

```powershell
# File: ConsoleHost.ps1 (Windows Terminal branch)
if (-not $env:WT_SESSION) { return }

# Windows Terminal has better Unicode support
$OutputEncoding = [System.Text.Encoding]::UTF8

# Fancy prompt with more emoji (Terminal handles it well)
function prompt {
    $isAdmin = ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        Write-Host "⚡ ADMIN ⚡" -NoNewline -ForegroundColor Red
    }

    $location = Get-Location
    Write-Host " 📂 $location" -NoNewline -ForegroundColor Cyan
    return "`n🚀 "
}

# Terminal-specific key bindings
Set-PSReadLineKeyHandler -Key Ctrl+Shift+C -Function Copy
Set-PSReadLineKeyHandler -Key Ctrl+Shift+V -Function Paste
```

### Console Host Settings

```powershell
# File: ConsoleHost.ps1

# Conservative settings for traditional console
Set-PSReadLineOption -BellStyle None
Set-PSReadLineOption -EditMode Windows

# Simple prompt (no fancy Unicode that might not render)
function prompt {
    $location = Get-Location
    $isAdmin = ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        Write-Host "[ADMIN] " -NoNewline -ForegroundColor Red
    }

    Write-Host "PS $location" -NoNewline -ForegroundColor Green
    return "> "
}

# Console-specific utilities
function open($path) {
    explorer.exe $path
}
```

### PowerShell ISE Settings (Legacy)

```powershell
# File: WindowsPowerShellISEHost.ps1

# ISE doesn't support PSReadLine
# Skip PSReadLine configuration

# ISE-specific functions
function Run-Selection {
    $selectedText = $psISE.CurrentFile.Editor.SelectedText
    if ($selectedText) {
        Invoke-Expression $selectedText
    }
}

Write-Host "ISE host configuration loaded" -ForegroundColor Yellow
```

## PSReadLine Configurations

### Inline vs ListView Prediction

```powershell
# Inline view - subtle, appears as you type
Set-PSReadLineOption -PredictionViewStyle InlineView

# List view - shows dropdown list of predictions
Set-PSReadLineOption -PredictionViewStyle ListView
```

### Edit Modes

```powershell
# Windows mode (default) - familiar Windows key bindings
Set-PSReadLineOption -EditMode Windows

# Emacs mode - Unix-like key bindings
Set-PSReadLineOption -EditMode Emacs

# Vi mode - Vim-like key bindings
Set-PSReadLineOption -EditMode Vi
```

### Custom Key Bindings

```powershell
# Ctrl+D to exit (like bash)
Set-PSReadLineKeyHandler -Key Ctrl+d -Function DeleteCharOrExit

# Ctrl+W to delete word
Set-PSReadLineKeyHandler -Key Ctrl+w -Function BackwardKillWord

# F1 to show command help
Set-PSReadLineKeyHandler -Key F1 -Function ShowCommandHelp

# Ctrl+Shift+C/V for copy/paste
Set-PSReadLineKeyHandler -Key Ctrl+Shift+C -Function Copy
Set-PSReadLineKeyHandler -Key Ctrl+Shift+V -Function Paste
```

## Testing Your Configuration

1. Save your host-specific file
2. Close and reopen your PowerShell host (or reload profile)
3. Verify with verbose output:
   ```powershell
   $VerbosePreference = "Continue"
   . $PROFILE
   ```

You should see:
```
Loading host-specific configuration: {HostName}
```

## Detecting Multiple Hosts

You can create conditional logic within a single host file:

```powershell
# File: ConsoleHost.ps1

# Check if running in Windows Terminal
if ($env:WT_SESSION) {
    # Running in Windows Terminal
    Set-PSReadLineOption -PredictionViewStyle ListView
} else {
    # Running in traditional console
    Set-PSReadLineOption -PredictionViewStyle InlineView
}
```

## Common Use Cases

### Different Prompts per Host

**VS Code** - Compact prompt for narrow terminal:
```powershell
function prompt { return "PS> " }
```

**Windows Terminal** - Fancy prompt with emoji:
```powershell
function prompt {
    return "🚀 $(Get-Location) > "
}
```

**Console** - Clear, readable prompt:
```powershell
function prompt {
    return "PowerShell [$env:USERNAME] $(Get-Location)> "
}
```

### Terminal-Specific Colors

```powershell
# File: ConsoleHost.ps1 (Windows Terminal reports ConsoleHost — gate on $env:WT_SESSION)

# Windows Terminal supports more colors
$PSStyle.FileInfo.Directory = "`e[34;1m"  # Bright blue for directories
$PSStyle.FileInfo.Executable = "`e[32;1m"  # Bright green for executables

# Enhance error colors
$PSStyle.Formatting.Error = "`e[91m"  # Bright red
```

## Best Practices

1. **Keep it host-specific** - Only include settings that vary by host
2. **Test across hosts** - Verify your profile works in all your common hosts
3. **Fallback gracefully** - Handle missing features (e.g., ISE doesn't support PSReadLine)
4. **Document why** - Explain why certain hosts need different settings
5. **Check capabilities** - Test for features before using them

## Example: Full Host Configuration

```powershell
# File: VisualStudioCodeHost.ps1
# VS Code PowerShell extension terminal optimizations

# === PSReadLine Configuration ===
# Inline view works better in VS Code's narrower terminal
Set-PSReadLineOption -PredictionViewStyle InlineView
Set-PSReadLineOption -HistorySearchCursorMovesToEnd

# === Key Bindings ===
# VS Code already uses Ctrl+K for its own commands
# Use Alt+K for kill line instead
Set-PSReadLineKeyHandler -Key Alt+k -Function KillLine

# === Prompt Configuration ===
# Compact prompt to save vertical space in split terminals
function prompt {
    $location = Split-Path -Leaf (Get-Location)
    $isAdmin = ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $graphConnected = Get-MgContext -ErrorAction SilentlyContinue

    $segments = @()
    if ($isAdmin) { $segments += "⚡" }
    if ($graphConnected) { $segments += "☁️" }
    $segments += $location

    Write-Host ($segments -join " ") -NoNewline -ForegroundColor Cyan
    return "> "
}

# === VS Code Specific Functions ===
function Open-VSCode {
    param([string]$Path = ".")
    code $Path
}
Set-Alias -Name edit -Value Open-VSCode

Write-Verbose "✅ VS Code host configuration loaded"
```
