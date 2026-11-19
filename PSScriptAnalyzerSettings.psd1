@{
    Severity     = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # These scripts are console tools; their output is the interface.
        'PSAvoidUsingWriteHost'
    )

    # PSUseCorrectCasing is left off: in PSScriptAnalyzer 1.25 it resolves every
    # command it sees, which takes minutes on a cold run, and it intermittently
    # fails the whole analysis with "Object reference not set to an instance of
    # an object".

    Rules        = @{
        # One true brace style; one-line blocks such as { return $x } allowed.
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        # Aligned hashtable values are allowed; aligned statements are not.
        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
        # The relay may run scripts under Windows PowerShell 5.1.
        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
