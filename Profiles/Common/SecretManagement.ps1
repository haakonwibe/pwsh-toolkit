# Secret Management Functions
# Provides secure credential storage using Microsoft.PowerShell.SecretStore
# Requires: Microsoft.PowerShell.SecretManagement and Microsoft.PowerShell.SecretStore modules

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

    # Ensure SecretStore vault exists
    try {
        $vault = Get-SecretVault -Name "SecretStore" -ErrorAction SilentlyContinue
        if (-not $vault) {
            Write-Host "Setting up SecretStore vault..." -ForegroundColor Yellow
            Register-SecretVault -Name "SecretStore" -ModuleName "Microsoft.PowerShell.SecretStore" -DefaultVault
        }
    }
    catch {
        Write-Host "Setting up SecretStore vault..." -ForegroundColor Yellow
        Register-SecretVault -Name "SecretStore" -ModuleName "Microsoft.PowerShell.SecretStore" -DefaultVault
    }

    # Check if SecretStore is unlocked, unlock if needed
    try {
        # Test access to SecretStore
        $null = Get-SecretInfo -Vault "SecretStore" -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -like "*password*" -or $_.Exception.Message -like "*unlock*") {
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

        # Return in the requested format
        if ($AsPlainText) {
            return Get-Secret -Name $Name -AsPlainText
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
