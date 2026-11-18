@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # These scripts are console tools; their output is the interface.
        'PSAvoidUsingWriteHost'

        # Start-Section in tools/ci.ps1 prints a heading and changes nothing.
        # Note that the rule judges by verb alone, so it cannot see this.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
