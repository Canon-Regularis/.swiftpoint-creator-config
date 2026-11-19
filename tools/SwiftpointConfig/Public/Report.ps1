function Write-Section {
    <#
    .SYNOPSIS
        Prints a section heading in the console report.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
}

function Write-Check {
    <#
    .SYNOPSIS
        Prints one check line: [STATUS] name  - detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Status,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Detail = ''
    )
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ('  [{0}] ' -f $Status) -ForegroundColor $color -NoNewline
    Write-Host $Name -NoNewline
    if ($Detail) { Write-Host "  - $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
}

function New-CheckResult {
    <#
    .SYNOPSIS
        One check outcome, emitted by a check step and printed by
        Invoke-CheckStep.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an object in memory; changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Status,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Detail = ''
    )
    return [pscustomobject]@{
        PSTypeName = 'SwiftpointConfig.CheckResult'
        Status     = $Status
        Name       = $Name
        Detail     = $Detail
    }
}

function Invoke-CheckStep {
    <#
    .SYNOPSIS
        Runs one check step, printing each result as it arrives and passing it
        on.
    .DESCRIPTION
        The step must emit only New-CheckResult objects. An exception inside it
        becomes a FAIL result instead of ending the whole run.
    .PARAMETER Title
        A section heading to print first, if any.
    .PARAMETER Check
        The step: a script block, or a command from Get-Command. A script's own
        functions are not visible inside this module, so pass the command, not
        its name.
    .PARAMETER Context
        Passed to the step as -Context, when given.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Title,
        [Parameter(Mandatory)]$Check,
        [hashtable]$Context
    )

    if ($Title) { Write-Section -Title $Title }
    $arguments = @{}
    if ($PSBoundParameters.ContainsKey('Context')) { $arguments['Context'] = $Context }
    try {
        & $Check @arguments | ForEach-Object {
            if (@($_.PSObject.TypeNames) -notcontains 'SwiftpointConfig.CheckResult') {
                throw "a check step emitted something other than a check result: $_"
            }
            Write-Check -Status $_.Status -Name $_.Name -Detail $_.Detail
            $_
        }
    } catch {
        $name = if ($Title) { "${Title}: stopped unexpectedly" } else { 'check stopped unexpectedly' }
        $result = New-CheckResult -Status FAIL -Name $name -Detail $_.Exception.Message
        Write-Check -Status $result.Status -Name $result.Name -Detail $result.Detail
        $result
    }
}
