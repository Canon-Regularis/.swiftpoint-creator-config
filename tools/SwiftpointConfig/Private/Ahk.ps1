# Conversions for values written into relay/bindings.generated.ahk.

# AHK v2 escapes with a backtick and doubles quotes inside strings. Backslashes
# are literal, so Windows paths need no handling. The relay may be run by
# Windows PowerShell 5.1, so everything emitted must be ASCII; see the encoding
# note in tools/ci.ps1.
function ConvertTo-AhkString {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if (-not (Test-AsciiOnly -Value $Value)) {
        throw "Non-ASCII text cannot be emitted into the relay: '$Value'. Spell it in ASCII (e.g. '180 degree', not the degree sign)."
    }
    # A raw line break would end the string literal and break the include.
    if ($Value -match '[\x00-\x1F\x7F]') {
        throw "Control characters cannot be emitted into the relay: '$($Value.Trim())'."
    }
    return $Value.Replace('`', '``').Replace('"', '""')
}

function ConvertTo-AhkBool {
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    if ($Value) { return 'true' } else { return 'false' }
}

# Emitted paths stay repo-relative and the relay resolves them against its own
# location. An absolute path would bake one machine's layout into a committed
# file, and a clone would point at the author's home directory.
function ConvertTo-EmittedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Relative)
    return $Relative -replace '/', '\'
}
