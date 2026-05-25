# ============================================================================
# Default Parameter Values
# ============================================================================
# Sets default parameter values for common cmdlets using $PSDefaultParameterValues

# Install and update modules to AllUsers scope by default (requires elevation)
$PSDefaultParameterValues['Install-Module:Scope'] = 'AllUsers'
$PSDefaultParameterValues['Update-Module:Scope'] = 'AllUsers'

# Suppress the Microsoft Graph welcome banner
$PSDefaultParameterValues['Connect-MgGraph:NoWelcome'] = $true
