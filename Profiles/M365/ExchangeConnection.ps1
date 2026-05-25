# Exchange Online Connection Functions
# Provides easy connectivity to Exchange Online for mailbox administration
# Requires: ExchangeOnlineManagement PowerShell module

# Separate Exchange Online connection when needed
function Connect-Exchange {
    Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan

    try {
        Connect-ExchangeOnline
        Write-Host "✅ Exchange Online connected" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to connect to Exchange Online: $_"
    }
}

# Clean disconnect for Exchange
function Disconnect-Exchange {
    try {
        Disconnect-ExchangeOnline -Confirm:$false
        Write-Host "✅ Exchange Online disconnected" -ForegroundColor Green
    } catch {
        Write-Warning "Error disconnecting from Exchange: $_"
    }
}
