# Secret Management Functions
# Provides secure credential storage using Microsoft.PowerShell.SecretStore
# Requires: Microsoft.PowerShell.SecretManagement and Microsoft.PowerShell.SecretStore modules
#
# Threat model and tradeoffs are documented in the top-level README's
# "Security" section — read that before relying on these helpers for anything
# above casual API-key storage.

# Private helper: returns $false (and emits an error) when the host can't run
# an interactive password prompt for Unlock-SecretStore. Used by every public
# function below to fail fast instead of hanging in CI / piped-input contexts.
function Test-SecretStoreInteractive {
    if ([Console]::IsInputRedirected) {
        Write-Error "SecretStore is locked and stdin is not interactive. Run 'Unlock-SecretStore' in a terminal first, or 'Initialize-SecretStore -Authentication None' once to skip the password prompt."
        return $false
    }
    return $true
}

function Get-OrCreateSecret {
    <#
    .SYNOPSIS
        Gets a secret from the vault or prompts to create it if it doesn't exist
    .DESCRIPTION
        Retrieves a secret from the SecretStore vault. If the secret doesn't exist,
        prompts the user to enter it and stores it securely for future use.
    .PARAMETER Name
        The name of the secret to retrieve or create
    .PARAMETER AsPlainText
        Return the secret as plain text instead of SecureString
    .EXAMPLE
        $apiKey = Get-OrCreateSecret -Name "OpenAI-API-Key"
    .EXAMPLE
        $apiKey = Get-OrCreateSecret -Name "OpenAI-API-Key" -AsPlainText
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$AsPlainText
    )

    # Ensure SecretStore vault exists. Don't silently steal the -DefaultVault
    # slot if another vault is already default — that would override any
    # enterprise / 1Password integration without notice.
    try {
        $vault = Get-SecretVault -Name "SecretStore" -ErrorAction Ignore
        if (-not $vault) {
            $existingDefault = Get-SecretVault -ErrorAction Ignore | Where-Object IsDefault
            $registerArgs = @{ Name = "SecretStore"; ModuleName = "Microsoft.PowerShell.SecretStore" }
            if (-not $existingDefault) {
                $registerArgs.DefaultVault = $true
            } else {
                Write-Warning "Another vault is already default ('$($existingDefault.Name)'). Registering SecretStore without -DefaultVault."
            }
            Write-Host "Setting up SecretStore vault..." -ForegroundColor Yellow
            Register-SecretVault @registerArgs
        }
    }
    catch {
        Write-Warning "Failed to set up SecretStore vault: $($_.Exception.Message)"
        return $null
    }

    # Check if SecretStore is unlocked, unlock if needed
    try {
        # Test access to SecretStore
        $null = Get-SecretInfo -Vault "SecretStore" -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -like "*password*" -or $_.Exception.Message -like "*unlock*") {
            if (-not (Test-SecretStoreInteractive)) { return $null }
            Write-Host "🔐 SecretStore is locked. Please unlock it first:" -ForegroundColor Yellow
            try {
                Unlock-SecretStore
                Write-Host "✅ SecretStore unlocked!" -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to unlock SecretStore: $_"
                return $null
            }
        }
        else {
            Write-Warning "SecretStore access issue: $_"
        }
    }

    # Try to get the secret
    try {
        if ($AsPlainText) {
            $secret = Get-Secret -Name $Name -AsPlainText -ErrorAction Stop
        } else {
            $secret = Get-Secret -Name $Name -ErrorAction Stop
        }

        if ($secret) {
            Write-Host "✅ Retrieved secret: $Name" -ForegroundColor Green
            return $secret
        }
    }
    catch {
        # Check if it's a "secret not found" error vs other errors
        if ($_.Exception.Message -like "*not found*" -or $_.CategoryInfo.Category -eq "ObjectNotFound") {
            # Secret genuinely doesn't exist, continue to creation
        }
        else {
            # Some other error (authentication, vault issues, etc.)
            Write-Error "Error accessing secret '$Name': $_"
            return $null
        }
    }

    # Secret doesn't exist, prompt for it
    Write-Host "🔐 Secret '$Name' not found. Please enter it to store securely:" -ForegroundColor Cyan
    $secretValue = Read-Host -AsSecureString -Prompt "Enter secret value"

    try {
        Set-Secret -Name $Name -Secret $secretValue -ErrorAction Stop
        Write-Host "✅ Secret '$Name' stored securely!" -ForegroundColor Green

        # Return in the requested format. Convert in-process for the plaintext
        # case instead of round-tripping back through the vault — same
        # conversion Invoke-DownloadsTag.ps1 already uses on its own results.
        if ($AsPlainText) {
            return [System.Net.NetworkCredential]::new('', $secretValue).Password
        } else {
            return $secretValue
        }
    }
    catch {
        Write-Error "Failed to store secret: $_"
        return $null
    }
}

# Helper function to list stored secrets
function Get-StoredSecrets {
    <#
    .SYNOPSIS
        Lists all stored secrets (names only, not values)
    #>
    try {
        # Ensure SecretStore is unlocked
        $null = Get-SecretInfo -Vault "SecretStore" -ErrorAction Stop
        Get-SecretInfo | Select-Object Name, Type, VaultName | Format-Table -AutoSize
    }
    catch {
        if ($_.Exception.Message -like "*password*" -or $_.Exception.Message -like "*unlock*") {
            if (-not (Test-SecretStoreInteractive)) { return }
            Write-Host "🔐 SecretStore is locked. Please unlock it first:" -ForegroundColor Yellow
            try {
                Unlock-SecretStore
                Get-SecretInfo | Select-Object Name, Type, VaultName | Format-Table -AutoSize
            }
            catch {
                Write-Warning "Failed to unlock SecretStore or no secrets found"
            }
        }
        else {
            Write-Warning "No secrets found or SecretStore not initialized"
        }
    }
}

# Helper function to remove a secret
function Remove-StoredSecret {
    <#
    .SYNOPSIS
        Removes a secret from the vault
    .PARAMETER Name
        The name of the secret to remove
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        # Ensure SecretStore is unlocked
        $null = Get-SecretInfo -Vault "SecretStore" -ErrorAction Stop
        Remove-Secret -Name $Name
        Write-Host "✅ Secret '$Name' removed!" -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -like "*password*" -or $_.Exception.Message -like "*unlock*") {
            if (-not (Test-SecretStoreInteractive)) { return }
            Write-Host "🔐 SecretStore is locked. Please unlock it first:" -ForegroundColor Yellow
            try {
                Unlock-SecretStore
                Remove-Secret -Name $Name
                Write-Host "✅ Secret '$Name' removed!" -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to remove secret: $_"
            }
        }
        else {
            Write-Error "Failed to remove secret: $_"
        }
    }
}
