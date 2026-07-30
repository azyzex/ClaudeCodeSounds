# PSScriptAnalyzer configuration for CI.
#
# Rules are excluded only where the rule's assumption does not hold for this
# project, with the reason recorded. Everything else runs at Error and Warning.
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # These are interactive installers whose entire job is to print progress
        # to a human at a console. Write-Output would send the banner down the
        # pipeline instead of to the screen, which is not what is wanted.
        'PSAvoidUsingWriteHost',

        # Applies to functions named with a state-changing verb. New-HookGroup
        # and Save-Json are private helpers inside a script, not exported
        # cmdlets, so -WhatIf/-Confirm plumbing would be noise.
        'PSUseShouldProcessForStateChangingFunctions',

        # The installer is distributed as a single standalone .ps1 that people
        # pipe straight from a URL. Splitting it into a module to satisfy this
        # rule would defeat the point.
        'PSUseSingularNouns',

        # The notifier swallows errors on purpose. It runs on every turn of every
        # Claude Code session, and a notification that cannot play a sound must
        # never surface an error into the user's terminal or fail the hook. The
        # empty catch blocks are the design, not an oversight.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
