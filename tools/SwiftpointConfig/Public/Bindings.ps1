function Read-BindingConfig {
    <#
    .SYNOPSIS
        config/bindings.json as parsed JSON, unvalidated.
    .DESCRIPTION
        Read as UTF-8 explicitly: Windows PowerShell 5.1 would otherwise decode
        a BOM-less file as ANSI.
    #>
    [CmdletBinding()]
    param([string]$Path = (Get-RepoPath 'config/bindings.json'))
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config not found: $Path"
    }
    return (Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json)
}

function Get-ConfigHash {
    <#
    .SYNOPSIS
        SHA-256 of the config's text with line endings normalised.
    .DESCRIPTION
        Not Get-FileHash: core.autocrlf decides whether a checkout has LF or
        CRLF, so raw bytes would hash differently on different machines and the
        sync check would fail for no real reason. The explicit UTF-8 keeps any
        non-ASCII text hashing the same on both PowerShell editions.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $normalized = (Get-Content -Raw -Encoding UTF8 -LiteralPath $Path) -replace "`r`n", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Get-PhysicalButton {
    <#
    .SYNOPSIS
        The fifteen physical buttons of the Creator, in table order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    return $script:PhysicalButtons
}

function Get-RelayActionId {
    <#
    .SYNOPSIS
        Every action bound to a button with "relay", in profile order then
        button order, each once.
    .DESCRIPTION
        It is guaranteed that this is the set of chords the relay registers;
        tools/ci.ps1 compares the relay's start line against its count.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Config)

    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Config.profiles) {
        $buttons = Resolve-BindingProfile -Config $Config -Id $entry.id
        foreach ($button in $script:PhysicalButtons) {
            if (-not $buttons.Contains($button.Id)) { continue }
            $relay = Get-OptionalProperty -InputObject $buttons[$button.Id] -Name 'relay'
            if ($null -ne $relay -and -not $ids.Contains([string]$relay)) { $ids.Add([string]$relay) }
        }
    }
    return $ids.ToArray()
}

function Get-BindingModel {
    <#
    .SYNOPSIS
        Loads and validates config/bindings.json into the model every generated
        file is rendered from.
    .DESCRIPTION
        Throws on the first problem found. The stages always run in the same
        order, so a broken config always reports the same error first.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path = (Get-RepoPath 'config/bindings.json'))

    $config = Read-BindingConfig -Path $Path
    $sourceHash = Get-ConfigHash -Path $Path
    Assert-BindingHeader -Config $config
    $actions = ConvertTo-ActionModel -Config $config
    $profiles = ConvertTo-ProfileModel -Config $config -Actions $actions
    $relayIds = @(Get-RelayActionId -Config $config)
    Assert-ActionReachable -Actions $actions -RelayActionId $relayIds
    Assert-ChordSet -Config $config -RelayActionId $relayIds
    $settings = ConvertTo-SettingModel -Config $config
    $chords = ConvertTo-ChordModel -Config $config -Actions $actions -Profiles $profiles -RelayActionId $relayIds

    $chordsById = @{}
    foreach ($chord in $chords) { $chordsById[$chord.Id] = $chord }

    return [pscustomobject]@{
        PSTypeName     = 'SwiftpointConfig.BindingModel'
        SourceHash     = $sourceHash
        ActiveChordSet = [string]$config.activeChordSet
        Timing         = $settings.Timing
        Relay          = $settings.Relay
        Screenshot     = $settings.Screenshot
        Turn           = $settings.Turn
        Actions        = $actions
        Profiles       = $profiles
        GlobalDefault  = @($profiles | Where-Object { $_.IsGlobalDefault })[0]
        Chords         = $chords
        ChordsById     = $chordsById
        LocalLinkIds   = [string[]]@($actions.Values | Where-Object { $_.Kind -eq 'openUrl' -and $_.Local } | ForEach-Object { $_.Id })
    }
}

function Test-BindingsInSync {
    <#
    .SYNOPSIS
        True when relay/bindings.generated.ahk was generated from the current
        config/bindings.json.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $configPath = Get-RepoPath 'config/bindings.json'
    $generatedPath = Get-RepoPath 'relay/bindings.generated.ahk'
    if (-not (Test-Path -LiteralPath $generatedPath)) { return $false }
    if (-not (Test-Path -LiteralPath $configPath)) { return $false }

    $generated = Get-Content -Raw -LiteralPath $generatedPath
    if ($generated -match 'BINDINGS_SOURCE_HASH\s*:=\s*"([0-9A-Fa-f]+)"') {
        return ($Matches[1] -eq (Get-ConfigHash -Path $configPath))
    }
    return $false
}

function Get-GeneratedFile {
    <#
    .SYNOPSIS
        The files generated from config/bindings.json, with the renderer that
        produces each.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $files = @(
        @{ RelativePath = 'relay/bindings.generated.ahk'; Renderer = 'ConvertTo-RelayInclude' }
        @{ RelativePath = 'docs/control-panel-entry-sheet.md'; Renderer = 'ConvertTo-EntrySheet' }
        @{ RelativePath = 'config/links.local.example.json'; Renderer = 'ConvertTo-LinksExample' }
    )
    foreach ($file in $files) {
        [pscustomobject]@{
            RelativePath = $file.RelativePath
            Path         = Get-RepoPath $file.RelativePath
            Renderer     = $file.Renderer
        }
    }
}
