@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # These scripts are console tools; their output is the interface.
        'PSAvoidUsingWriteHost'

        # New-ScaffoldTargetPath builds a string and changes nothing.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
