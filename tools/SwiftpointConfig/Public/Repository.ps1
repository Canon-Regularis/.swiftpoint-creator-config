function Get-RepoRoot {
    <#
    .SYNOPSIS
        The repository root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:RepoRoot
}

function Get-RepoPath {
    <#
    .SYNOPSIS
        An absolute path for a path relative to the repository root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Relative)
    return (Join-Path $script:RepoRoot $Relative)
}

function Get-RepoRelativePath {
    <#
    .SYNOPSIS
        The path of a file inside the repository, relative to its root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    return $Path.Substring($script:RepoRoot.Length + 1)
}

function Get-RepoFile {
    <#
    .SYNOPSIS
        Files in the repository matching the given patterns, outside .git.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param([Parameter(Mandatory)][string[]]$Include)
    Get-ChildItem -Path $script:RepoRoot -Include $Include -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '\\\.git\\' }
}

function Test-GitCheckout {
    <#
    .SYNOPSIS
        True when the repository is a git checkout and git is installed. A
        release bundle has no .git.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $hasGitFolder = Test-Path -LiteralPath (Join-Path $script:RepoRoot '.git')
    return $hasGitFolder -and [bool](Get-Command git -ErrorAction SilentlyContinue)
}

function Test-GitIgnored {
    <#
    .SYNOPSIS
        True when git ignores the given repo-relative path.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    return (Invoke-GitQuiet -ArgumentList @('check-ignore', '-q', '--', $Path)) -eq 0
}

function Test-GitTracked {
    <#
    .SYNOPSIS
        True when git tracks the given repo-relative path.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    return (Invoke-GitQuiet -ArgumentList @('ls-files', '--error-unmatch', '--', $Path)) -eq 0
}
