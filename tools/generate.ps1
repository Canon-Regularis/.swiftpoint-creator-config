<#
.SYNOPSIS
    Generates relay/bindings.generated.ahk, docs/control-panel-entry-sheet.md and
    config/links.local.example.json from config/bindings.json. Run it after any
    edit to that file.

.PARAMETER Quiet
    Print nothing on success.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ci.ps1 and install.ps1 run this script in their own session, so the import
# must leave theirs alone: -Scope Local keeps the commands out of the caller's
# scope, and there is no -Force, which would unload a module the caller has
# already imported.
Import-Module (Join-Path $PSScriptRoot 'SwiftpointConfig/SwiftpointConfig.psd1') -Scope Local

$model = Get-BindingModel

# Everything is rendered before anything is written, so a render error leaves
# the committed files untouched rather than half-updated.
$outputs = foreach ($file in Get-GeneratedFile) {
    [pscustomobject]@{
        File    = $file
        Content = & $file.Renderer -Model $model
    }
}
foreach ($output in $outputs) {
    Write-Utf8NoBom -Path $output.File.Path -Content $output.Content
}

if (-not $Quiet) {
    Write-Host "Generated from config/bindings.json (chord set: $($model.ActiveChordSet))" -ForegroundColor Green
    foreach ($output in $outputs) {
        Write-Host "  $($output.File.RelativePath)"
    }
    Write-Host ''
    foreach ($chord in $model.Chords) {
        Write-Host ('  {0,-26} {1,-16} {2}' -f $chord.Display, $chord.Id, $chord.Where)
    }
}
