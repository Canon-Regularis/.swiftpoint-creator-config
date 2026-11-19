# Access to parsed JSON under StrictMode, where reading a missing property is a
# terminating error.

function Get-OptionalProperty {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($null -ne $InputObject -and @($InputObject.PSObject.Properties.Name) -contains $Name) {
        return $InputObject.$Name
    }
    return $Default
}

# The property names of a JSON object in file order, without the '_' comments.
function Get-PropertyName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$InputObject)
    return [string[]]@($InputObject.PSObject.Properties.Name | Where-Object { -not $_.StartsWith('_') })
}
