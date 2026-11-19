@{
    RootModule           = 'SwiftpointConfig.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '6e56986e-9482-4b39-940a-36ea6b3a3f40'
    Author               = 'Matthew MIEZANIEC'
    Copyright            = '(c) 2026 Matthew MIEZANIEC. MIT License.'
    Description          = 'Loads and validates the Swiftpoint Creator bindings, renders the generated files, and holds the helpers shared by the scripts in tools/.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport    = @(
        # Repository
        'Get-RepoRoot'
        'Get-RepoPath'
        'Get-RepoRelativePath'
        'Get-RepoFile'
        'Test-GitCheckout'
        'Test-GitIgnored'
        'Test-GitTracked'

        # Environment
        'Find-AutoHotkeyV2'
        'Find-PowerShell'
        'Get-SwiftpointDevice'

        # Relay
        'Get-RelayProcess'
        'Test-RelayRunning'
        'Start-Relay'
        'Stop-Relay'

        # Bindings
        'Read-BindingConfig'
        'Get-ConfigHash'
        'Get-PhysicalButton'
        'Get-RelayActionId'
        'Get-BindingModel'
        'Test-BindingsInSync'
        'Get-GeneratedFile'

        # Rendering
        'ConvertTo-RelayInclude'
        'ConvertTo-EntrySheet'
        'ConvertTo-LinksExample'

        # Links
        'Read-LinkOverlay'
        'Test-SafeUrl'

        # Text
        'Test-AsciiOnly'
        'Test-ContentEqual'
        'Test-Utf8Bom'
        'Write-Utf8NoBom'

        # Reporting
        'Write-Section'
        'Write-Check'
        'New-CheckResult'
        'Invoke-CheckStep'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            ProjectUri = 'https://github.com/Canon-Regularis/.swiftpoint-creator-config'
            LicenseUri = 'https://github.com/Canon-Regularis/.swiftpoint-creator-config/blob/main/LICENSE'
        }
    }
}
