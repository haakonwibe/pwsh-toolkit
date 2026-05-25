# PSReadLine Configuration
# Enhanced PowerShell command-line experience with history-based predictions.
#
# Skipped when stdout is redirected (CI, `pwsh -Command` with output capture,
# Pester runs). PSReadLine's predictive suggestion features require a real
# console — without one, Set-PSReadLineOption emits "The handle is invalid"
# into $Error on every load. Guard makes the profile clean under automation.
if ([Console]::IsOutputRedirected) { return }

Set-PSReadLineOption -PredictionSource History
Set-PSReadLineOption -PredictionViewStyle ListView
# EditMode Windows is optional - it's actually the default on Windows
# Set-PSReadLineOption -EditMode Windows
