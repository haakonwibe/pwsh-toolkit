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
        Write-Error "SecretStore is locked and stdin is not interactive. Run 'Unlock-SecretStore' in a terminal first, or 'Set-SecretStoreConfiguration -Authentication None' once to skip the password prompt."
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
        $apiKey = Get-OrCreateSecret -Name "Weather-API-Key"

        Returns the stored secret as a SecureString. The first time, it prompts
        you to enter the value and stores it (DPAPI-encrypted) for next time.
    .EXAMPLE
        $apiKey = Get-OrCreateSecret -Name "Weather-API-Key" -AsPlainText

        Same, but returns a plain-text string — needed when passing the key to an
        API that wants a raw header value rather than a SecureString.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCmdletCorrectly', '', Justification = 'Unlock-SecretStore has no mandatory parameters; the analyzer heuristic is a false positive.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$AsPlainText
    )

    # Bootstrap check. Without the SecretManagement module, every cmdlet below
    # blows up with "term 'Get-SecretVault' is not recognized" — an opaque
    # error that hides the actual fix (install the two modules once).
    if (-not (Get-Command Get-SecretVault -ErrorAction Ignore)) {
        Write-Host "  SecretManagement modules aren't installed. Install them once:" -ForegroundColor Yellow
        Write-Host "      Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser" -ForegroundColor Cyan
        return $null
    }

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
            # -ErrorAction Stop: Register-SecretVault reports failure
            # non-terminatingly, so without it a failed registration fell
            # through to the fetch below against a vault that does not exist.
            Register-SecretVault @registerArgs -ErrorAction Stop

            # Configure passwordless mode as the default. DPAPI already binds
            # the vault file to your Windows user account, so the optional
            # vault password is largely second-factor theater for personal
            # use. Users who want the extra layer can switch via:
            #     Set-SecretStoreConfiguration -Authentication Password
            # README's Security section documents the threat model.
            #
            # Cmdlet choice — this is subtle. SecretStore 1.0.x's
            # Set-SecretStoreConfiguration cannot bootstrap a never-created
            # store into passwordless mode: it reads the not-yet-existent
            # store's configuration first (which falls back to the default —
            # Password required) and triggers the module's lazy "Creating a
            # new vault... A password is required by the current store
            # configuration. Enter password:" prompt before our requested
            # config can apply. Reset-SecretStore is the only cmdlet that
            # creates the on-disk store file with the requested auth policy
            # applied in one shot, so we use it for the fresh-install path.
            # We gate on the localstore data file's absence because Reset
            # would otherwise wipe existing secrets — and an existing
            # password-protected store is the user's choice to leave alone.
            try {
                Import-Module Microsoft.PowerShell.SecretStore -ErrorAction Stop
                $storeDataPath = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement\localstore'
                $storeIsFresh = -not (Test-Path -LiteralPath $storeDataPath) -or
                                -not (Get-ChildItem -LiteralPath $storeDataPath -File -ErrorAction Ignore)
                if ($storeIsFresh) {
                    Reset-SecretStore -Authentication None -Interaction None -Force -ErrorAction Stop
                }
                # Else: existing store — don't touch it. If it's
                # password-protected the rest of Get-OrCreateSecret will
                # unlock it interactively or surface the locked state.
            }
            catch {
                # Best-effort: vault is registered, rest of function still
                # works. Routed to the debug stream rather than swallowed so
                # `-Debug` can surface it, but silent on the happy path.
                Write-Debug "SecretStore bootstrap (non-fatal): $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-Warning "Failed to set up SecretStore vault: $($_.Exception.Message)"
        return $null
    }

    # Fetch the secret. Deliberately WITHOUT a Get-SecretInfo probe first to
    # test whether the store is unlocked: that enumerates every secret in the
    # vault to answer a yes/no question, and a locked store fails the fetch
    # below with the same password/unlock error the probe was looking for — so
    # the fetch is its own lock check. -Vault matters for the same reason: an
    # unqualified Get-Secret makes SecretManagement enumerate the registered
    # vaults to locate the name before fetching it, a second round-trip that
    # one explicit argument removes. Together those two were three vault hits
    # per call, plainly visible as repeated "successfully retrieved from vault"
    # lines under -Verbose (e.g. from wtf).
    $getArgs = @{ Name = $Name; Vault = "SecretStore"; ErrorAction = 'Stop' }
    if ($AsPlainText) { $getArgs.AsPlainText = $true }

    $secret = $null
    $fetched = $false
    foreach ($attempt in 1, 2) {
        try {
            $secret = Get-Secret @getArgs
            $fetched = $true
            break
        }
        catch {
            # Classify on the module's error identity, never on message text.
            # Measured against Microsoft.PowerShell.SecretManagement 1.1.2:
            #
            #   missing secret  GetSecretNotFound,<cmdlet>       ItemNotFoundException
            #   missing vault   GetSecretVaultNotFound,<cmdlet>  PSInvalidOperationException
            #   locked store    (no id of its own)               PasswordRequiredException
            #
            # The first two BOTH report category ObjectNotFound, and the vault
            # error reads "Vault not found in registry: SecretStore" — so a
            # "*not found*"/ObjectNotFound test cannot tell them apart. It sent
            # a broken vault down the create-and-store path below, where the
            # value the user then typed was lost on the equally broken
            # Set-Secret.
            #
            # Match the error id by PREFIX. It arrives in two shapes: the
            # compiled cmdlet emits "<id>,<command>"
            # (GetSecretNotFound,Microsoft.PowerShell.SecretManagement.GetSecretCommand)
            # while other producers — a wrapper, or the mocked command in
            # tests/Unit.Tests.ps1 — emit the bare "<id>". An -eq matches
            # neither reliably and a ",*" match drops the bare form, and a miss
            # here is silent: a missing secret would become a hard error instead
            # of the create path, this function's whole purpose. The two ids do
            # not collide, since GetSecretVaultNotFound does not start with
            # GetSecretNotFound.
            $errId = [string] $_.FullyQualifiedErrorId

            # Locked store: unlock and retry the fetch once. A lock error on the
            # retry is fatal rather than another prompt — if the store is still
            # locked after a successful-looking unlock, asking again just loops.
            # Type name compared as a string rather than -is [Type]: the type
            # literal has to resolve the SecretManagement assembly at runtime
            # and throws when it is not loaded. The message match stays as a
            # fallback for paths where an extension wraps the error in its own
            # exception type.
            $isLocked = $_.Exception.GetType().FullName -eq 'Microsoft.PowerShell.SecretManagement.PasswordRequiredException' -or
                        $_.Exception.Message -like "*password*" -or
                        $_.Exception.Message -like "*unlock*"
            if ($isLocked -and $attempt -eq 1) {
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
                continue
            }

            # Secret genuinely absent — fall through to the create path.
            if ($errId -like 'GetSecretNotFound*' -or
                $_.Exception -is [System.Management.Automation.ItemNotFoundException]) {
                break
            }

            # Everything else is fatal, including a still-locked store on the
            # retry. Prompting for a value we have no working vault to store in
            # would only lose it.
            if ($errId -like 'GetSecretVaultNotFound*') {
                Write-Error "Vault 'SecretStore' is not available ($($_.Exception.Message)). Re-register it with: Register-SecretVault -Name SecretStore -ModuleName Microsoft.PowerShell.SecretStore"
            }
            else {
                Write-Error "Error accessing secret '$Name': $_"
            }
            return $null
        }
    }

    # Gate on the fetch having SUCCEEDED, not on the value being truthy: an
    # empty string (or a stored 0 / $false) is a real secret that "if ($secret)"
    # reads as absent, which would drop through to the prompt below and
    # overwrite what is already in the vault.
    if ($fetched) {
        return $secret
    }

    # Secret doesn't exist, prompt for it. The context line below answers the
    # obvious "wait, why is my terminal asking for a sensitive key?" question
    # someone running a toolkit command for the first time will reasonably
    # ask — see README's Security section for the full threat model.
    Write-Host "🔐 Secret '$Name' not found. Please enter it to store securely." -ForegroundColor Cyan
    Write-Host "  Stored locally via DPAPI-encrypted SecretStore — scoped to your Windows account, never written in plaintext, never synced." -ForegroundColor DarkGray
    $secretValue = Read-Host -AsSecureString -Prompt "Enter secret value"

    try {
        # -Vault to match the qualified read above. Unqualified, Set-Secret
        # writes to the DEFAULT vault — which is not SecretStore when another
        # vault already held that slot (see the registration warning above) —
        # and the next run's SecretStore-scoped read would never find it,
        # re-prompting forever.
        Set-Secret -Name $Name -Secret $secretValue -Vault "SecretStore" -ErrorAction Stop
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
    .DESCRIPTION
        Shows the name, type, and vault of every secret in SecretStore — never the
        values. Handy for remembering what you've stashed and under which name.
    .EXAMPLE
        Get-StoredSecrets

        Prints a table of your stored secrets (e.g. Weather-API-Key) with their
        type and vault — the values themselves stay encrypted and unshown.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a collection; the plural name is the established public command and reads naturally.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCmdletCorrectly', '', Justification = 'Unlock-SecretStore has no mandatory parameters; the analyzer heuristic is a false positive.')]
    [CmdletBinding()]
    param()
    # No Get-SecretInfo probe before the listing: the listing is the probe. A
    # locked store fails it with the same password/unlock error the probe was
    # looking for, and the probe was a second full enumeration of the vault —
    # the same redundancy Get-OrCreateSecret had. The listing itself stays
    # unqualified on purpose: it reports VaultName per row, so a second
    # registered vault belongs in the output.
    foreach ($attempt in 1, 2) {
        # -ErrorAction SilentlyContinue with -ErrorVariable rather than -Stop:
        # this listing is unqualified on purpose (it reports VaultName per row,
        # so a second registered vault belongs in the output), and Stop let one
        # locked or broken vault abort the whole table instead of showing the
        # vaults that did answer. Collecting the errors keeps the rows AND the
        # diagnosis, and separates "nothing stored" from "nothing worked" — a
        # distinction a bare empty result cannot make.
        $listErrors = @()
        $info = Get-SecretInfo -ErrorAction SilentlyContinue -ErrorVariable listErrors

        if ($info) {
            $info | Select-Object Name, Type, VaultName | Format-Table -AutoSize
        }

        $isLocked = @($listErrors | Where-Object {
            $_.Exception.GetType().FullName -eq 'Microsoft.PowerShell.SecretManagement.PasswordRequiredException' -or
            $_.Exception.Message -like "*password*" -or
            $_.Exception.Message -like "*unlock*"
        }).Count -gt 0

        if ($isLocked -and $attempt -eq 1) {
            if (-not (Test-SecretStoreInteractive)) { return }
            Write-Host "🔐 SecretStore is locked. Please unlock it first:" -ForegroundColor Yellow
            try {
                Unlock-SecretStore
            }
            catch {
                Write-Error "Failed to unlock SecretStore: $_"
                return
            }
            continue
        }

        # Name the vaults that failed without hiding the ones that answered.
        foreach ($listError in $listErrors) {
            Write-Warning "Vault listing error: $($listError.Exception.Message)"
        }
        if (-not $info -and -not $listErrors) {
            Write-Warning "No secrets stored yet, or SecretStore is not initialized."
        }
        break
    }
}

# Helper function to remove a secret
function Remove-StoredSecret {
    <#
    .SYNOPSIS
        Removes a secret from the vault
    .PARAMETER Name
        The name of the secret to remove
    .EXAMPLE
        Remove-StoredSecret -Name "Weather-API-Key"

        Permanently deletes that secret from SecretStore — e.g. after rotating a
        key, so the next run that needs it re-prompts for the new value.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCmdletCorrectly', '', Justification = 'Unlock-SecretStore has no mandatory parameters; the analyzer heuristic is a false positive.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    # Same shape as Get-OrCreateSecret: the removal is its own lock check, so
    # no Get-SecretInfo probe first. The probe read like a safety check before
    # a destructive call, but bought nothing — the removal is one atomic call
    # that already fails cleanly on a locked store — and it checked a vault the
    # removal didn't necessarily target (see -Vault below).
    foreach ($attempt in 1, 2) {
        try {
            # -ErrorAction Stop: Remove-Secret's "secret not found" error is
            # non-terminating — without Stop the catch never fires and the
            # success message prints right after the error.
            # -Vault: MANDATORY on Remove-Secret, unlike Get-Secret and
            # Set-Secret where it is optional. Unqualified, this call did not
            # quietly delete from the default vault — it stopped on
            # PowerShell's mandatory-parameter prompt ("Supply values for the
            # following parameters: Vault:"), or threw a binding exception in a
            # non-interactive host. Naming it also keeps the delete pointed at
            # the same vault the read and the write use.
            Remove-Secret -Name $Name -Vault "SecretStore" -ErrorAction Stop
            Write-Host "✅ Secret '$Name' removed!" -ForegroundColor Green
            break
        }
        catch {
            $isLocked = $_.Exception.Message -like "*password*" -or $_.Exception.Message -like "*unlock*"
            if ($isLocked -and $attempt -eq 1) {
                if (-not (Test-SecretStoreInteractive)) { return }
                Write-Host "🔐 SecretStore is locked. Please unlock it first:" -ForegroundColor Yellow
                try {
                    Unlock-SecretStore
                }
                catch {
                    Write-Error "Failed to unlock SecretStore: $_"
                    return
                }
                continue
            }

            Write-Error "Failed to remove secret: $_"
            return
        }
    }
}
