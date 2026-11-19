# Runs git against the repository and returns its exit code, or -1 when this is
# not a git checkout or git is not installed. Output is discarded.
#
# ErrorActionPreference is lowered for the call: Windows PowerShell 5.1 raises a
# native command's redirected stderr as an error, which 'Stop' would make fatal.
function Invoke-GitQuiet {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    if (-not (Test-GitCheckout)) { return -1 }
    $ErrorActionPreference = 'Continue'
    $null = & git -C $script:RepoRoot @ArgumentList 2>&1
    return $LASTEXITCODE
}
