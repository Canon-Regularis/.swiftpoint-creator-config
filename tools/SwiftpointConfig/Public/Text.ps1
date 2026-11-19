function Test-AsciiOnly {
    <#
    .SYNOPSIS
        True when the string holds only 7-bit ASCII.
    .DESCRIPTION
        Windows PowerShell 5.1 reads a BOM-less file as ANSI, so one non-ASCII
        character in a script breaks its parsing there.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$Value)
    return -not ($Value -match '[^\x00-\x7F]')
}

function Test-ContentEqual {
    <#
    .SYNOPSIS
        Text equality that ignores line-ending style.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    return (($Left -replace "`r`n", "`n") -eq ($Right -replace "`r`n", "`n"))
}

function Test-Utf8Bom {
    <#
    .SYNOPSIS
        True when the file starts with a UTF-8 byte order mark.
    .DESCRIPTION
        Get-Content -Raw drops a BOM, so a text comparison cannot see one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $head = @([System.IO.File]::ReadAllBytes($Path) | Select-Object -First 3)
    return $head.Count -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF
}

function Write-Utf8NoBom {
    <#
    .SYNOPSIS
        Writes UTF-8 without a BOM, identically on every PowerShell edition,
        creating the parent folder if needed.
    .DESCRIPTION
        Not Set-Content -Encoding UTF8: that means "with BOM" on Windows
        PowerShell 5.1 and "without BOM" on PowerShell 7, so generated files
        would differ by edition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Force -Path $directory
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
