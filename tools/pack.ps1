<#
.SYNOPSIS
    Builds a release bundle: dist/swiftpoint-creator-config-<version>.zip

.DESCRIPTION
    The bundle is everything needed to install on a fresh machine. It excludes
    workflow files, runtime output, any exported .spcf (personal device config)
    and config/links.local.json (the real contest URLs).

.PARAMETER Version
    Version string for the filename. A leading "v" is kept as given.

.PARAMETER OutDir
    Output directory. Defaults to dist/ in the repo root.

.EXAMPLE
    pwsh -File tools/pack.ps1 -Version v1.0.0
#>
[CmdletBinding()]
param(
    [string]$Version = 'dev',
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/_common.ps1"

$RepoRoot = Get-RepoRoot
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'dist' }

$include = @(
    'config'
    'relay'
    'capture'
    'tools'
    'docs'
    'README.md'
    'LICENSE'
    'PSScriptAnalyzerSettings.psd1'
)

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("swiftpoint-pack-" + [guid]::NewGuid().ToString('N'))
$bundleRoot = Join-Path $staging 'swiftpoint-creator-config'
New-Item -ItemType Directory -Force -Path $bundleRoot | Out-Null

try {
    foreach ($item in $include) {
        $source = Join-Path $RepoRoot $item
        if (-not (Test-Path -LiteralPath $source)) {
            Write-Check -Status WARN -Name "missing, skipped" -Detail $item
            continue
        }
        Copy-Item -LiteralPath $source -Destination $bundleRoot -Recurse -Force
    }

    # config/ is copied whole, so the gitignored overlay of real contest URLs
    # comes with it whenever one exists on this machine. It is removed here,
    # and it is required that no copy of it survives anywhere in the bundle.
    Remove-Item -LiteralPath (Join-Path $bundleRoot 'config/links.local.json') -Force -ErrorAction SilentlyContinue
    $leaked = @(Get-ChildItem -Path $bundleRoot -Filter 'links.local.json' -Recurse -File)
    if ($leaked.Count -gt 0) {
        throw "links.local.json is still in the bundle: $($leaked[0].FullName)"
    }

    # The generated include must be in the bundle, or the relay will not start.
    $generated = Join-Path $bundleRoot 'relay/bindings.generated.ahk'
    if (-not (Test-Path -LiteralPath $generated)) {
        throw "relay/bindings.generated.ahk missing. Run tools/generate.ps1 first."
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $zipPath = Join-Path $OutDir "swiftpoint-creator-config-$Version.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath
    $size = (Get-Item -LiteralPath $zipPath).Length

    Write-Check -Status PASS -Name 'bundle built' -Detail ("{0} ({1:N0} bytes)" -f $zipPath, $size)
    Write-Output $zipPath
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
