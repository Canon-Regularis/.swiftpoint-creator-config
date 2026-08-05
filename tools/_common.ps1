# Shared helpers for tools/. Dot-source: . "$PSScriptRoot/_common.ps1"

$ToolsRepoRoot = Split-Path -Parent $PSScriptRoot

function Get-RepoRoot {
    return $ToolsRepoRoot
}

function Get-RepoPath {
    param([Parameter(Mandatory)][string]$Relative)
    return (Join-Path $ToolsRepoRoot $Relative)
}

# Returns the AutoHotkey v2 interpreter path, or $null.
# v1 is not accepted: the relay is v2-only syntax and v1 fails with confusing
# parse errors rather than a clear version complaint.
function Find-AutoHotkeyV2 {
    $candidates = @(
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe"
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey32.exe"
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe"
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey32.exe"
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe"
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey32.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    # Registry, not a recursive glob: walking Program Files costs minutes on a
    # cold cache.
    foreach ($key in @('HKLM:\SOFTWARE\AutoHotkey', 'HKCU:\SOFTWARE\AutoHotkey')) {
        $entry = Get-ItemProperty -Path $key -Name 'InstallDir' -ErrorAction SilentlyContinue
        # StrictMode makes a missing key or value a terminating error on plain
        # property access, so check before reaching for it.
        if (-not $entry -or -not $entry.PSObject.Properties.Name.Contains('InstallDir')) { continue }
        $installDir = $entry.InstallDir
        if (-not $installDir) { continue }
        foreach ($exe in @('v2\AutoHotkey64.exe', 'v2\AutoHotkey32.exe')) {
            $path = Join-Path $installDir $exe
            if (Test-Path -LiteralPath $path) { return $path }
        }
    }

    $onPath = Get-Command 'AutoHotkey64.exe', 'AutoHotkey.exe' -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    return $null
}

function Get-RelayProcess {
    $scriptPath = Get-RepoPath 'relay/swiftpoint-relay.ahk'
    $leaf = Split-Path -Leaf $scriptPath
    $found = @(
        Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$leaf*" }
    )
    # Leading comma stops PowerShell unwrapping an empty array to $null, which
    # would make .Count throw at every call site under StrictMode.
    return ,$found
}

# Hash of the config's content with line endings normalised.
#
# Not Get-FileHash: git checkout style (core.autocrlf) decides whether the
# working copy has LF or CRLF, so raw bytes hash differently on different
# machines and the sync check fails for no real reason.
function Get-ConfigHash {
    param([Parameter(Mandatory)][string]$Path)

    $normalized = (Get-Content -Raw -LiteralPath $Path) -replace "`r`n", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

# Content equality ignoring line-ending style, for the same reason.
function Test-ContentEqual {
    param([string]$Left, [string]$Right)
    return (($Left -replace "`r`n", "`n") -eq ($Right -replace "`r`n", "`n"))
}

# True when bindings.generated.ahk was generated from the current bindings.json.
function Test-BindingsInSync {
    $configPath    = Get-RepoPath 'config/bindings.json'
    $generatedPath = Get-RepoPath 'relay/bindings.generated.ahk'

    if (-not (Test-Path -LiteralPath $generatedPath)) { return $false }
    if (-not (Test-Path -LiteralPath $configPath))    { return $false }

    $currentHash = Get-ConfigHash -Path $configPath
    $generated   = Get-Content -Raw -LiteralPath $generatedPath

    if ($generated -match 'BINDINGS_SOURCE_HASH\s*:=\s*"([0-9A-Fa-f]+)"') {
        return ($Matches[1] -eq $currentHash)
    }
    return $false
}

function Write-Check {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Status,
        [Parameter(Mandatory)][string]$Name,
        [string]$Detail = ''
    )
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ('  [{0}] ' -f $Status) -ForegroundColor $color -NoNewline
    Write-Host $Name -NoNewline
    if ($Detail) { Write-Host "  — $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
}
