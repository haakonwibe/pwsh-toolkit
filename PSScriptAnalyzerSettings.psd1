@{
    # Surface everything in CI logs (so reviewers can see Warnings/Information),
    # but the workflow only FAILS on Severity = 'Error'.
    Severity = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # Write-Host with colors is the intentional UX layer for a profile +
        # toolkit (the picker, df bars, install.ps1 status, tips). The analyzer
        # would otherwise flag every line of colored output.
        'PSAvoidUsingWriteHost',

        # ShouldProcess on every state-changing function would add ceremony to
        # personal CLI helpers like `jb`/`peek`/`tagdl`. install.ps1 already
        # implements it for the genuinely destructive operations.
        'PSUseShouldProcessForStateChangingFunctions',

        # The only ConvertTo-SecureString -AsPlainText -Force in this codebase
        # is in DownloadsOrganizer/Invoke-DownloadsTag.ps1 wrapping an API key
        # pulled from SecretStore for the API call's SecureString header
        # parameter. The plaintext source is itself secure storage and is
        # nulled immediately after. The rule can't distinguish that case from
        # a hardcoded password.
        'PSAvoidUsingConvertToSecureStringWithPlainText',

        # BOM-on-UTF-8 is a dated style preference from the Windows-1252 era.
        # Modern PowerShell handles BOM-less UTF-8 fine; most editors don't
        # write BOMs anymore. Enforcing this would touch every file in the
        # repo with no real-world payoff.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
