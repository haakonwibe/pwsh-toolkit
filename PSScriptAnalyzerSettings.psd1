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
        'PSUseBOMForUnicodeEncodedFile',

        # `Join-Path $a $b`, `Get-Slice $x 1 2`, etc. are idiomatic positional
        # calls everyone reads at a glance. This rule (Information severity)
        # would flag every one with no real-world payoff.
        'PSAvoidUsingPositionalParameters',

        # The only Invoke-Expression in the repo is the canonical
        # `oh-my-posh init pwsh --config ... | Invoke-Expression` in the loader
        # — the vendor-documented way to install the prompt. It runs trusted,
        # locally-generated output. Suppressing inline isn't possible (script
        # scope, not a function), so it's excluded here with that single
        # reviewed call understood.
        'PSAvoidUsingInvokeExpression'
    )
}

# Per-occurrence suppressions for the rules NOT excluded above (so they stay
# active to catch new violations) live as [Diagnostics.CodeAnalysis.
# SuppressMessageAttribute(...)] decorations in the source, each with a
# Justification: PSUseApprovedVerbs (Ask-ChAt/Cls-Fancy + internal render
# helpers), PSUseSingularNouns (collection-returning commands), PSUseCmdletCorrectly
# (Unlock-SecretStore false positives), PSAvoidOverwritingBuiltInCmdlets
# (intentional Get-Uptime / script-local Write-Log), and PSReviewUnusedParameter
# (params read cross-scope the analyzer can't trace).
