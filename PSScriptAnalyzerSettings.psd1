@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # These scripts are console tools; their output is the interface.
        'PSAvoidUsingWriteHost'

        # New-ScaffoldTargetPath builds a string and changes nothing.
        'PSUseShouldProcessForStateChangingFunctions'

        # Files are UTF-8 without BOM, which is what PowerShell 7 defaults to.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
