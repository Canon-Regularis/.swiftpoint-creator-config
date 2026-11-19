function Test-SafeUrl {
    <#
    .SYNOPSIS
        True for a plain http(s) URL with no whitespace or quotes: the only
        links the relay will open.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$Url)
    return $Url -match $script:SafeUrlPattern
}

function Read-LinkOverlay {
    <#
    .SYNOPSIS
        The parsed gitignored overlay of real contest URLs, or $null when it
        does not exist.
    .DESCRIPTION
        Invalid JSON throws; the caller decides whether that is a failure.
    .PARAMETER LinksFile
        The overlay's path relative to the repository root, as in relay.linksFile.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LinksFile)
    $path = Get-RepoPath $LinksFile
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json)
}
