<#
.SYNOPSIS
    Installs AutoHotkey v2, generates bindings, registers the relay at login, starts it.

.PARAMETER SkipInstall
    Skip winget. Use when AutoHotkey v2 is already installed.

.PARAMETER NoStartup
    Skip the login shortcut.

.PARAMETER NoStart
    Do not launch the relay.

.EXAMPLE
    pwsh -File tools/install.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipInstall,
    [switch]$NoStartup,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'SwiftpointConfig/SwiftpointConfig.psd1') -Force

$ShortcutName = 'Swiftpoint Creator Relay.lnk'

Write-Host ''
Write-Host 'Swiftpoint Creator relay - setup' -ForegroundColor Cyan
Write-Host ''

# --- AutoHotkey v2 ----------------------------------------------------------

$ahk = Find-AutoHotkeyV2

if (-not $ahk -and -not $SkipInstall) {
    Write-Host 'Installing AutoHotkey v2 via winget...' -ForegroundColor Yellow
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget unavailable. Install AutoHotkey v2 from https://www.autohotkey.com/ and re-run with -SkipInstall.'
    }
    & winget install -e --id AutoHotkey.AutoHotkey --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget exited $LASTEXITCODE. Install AutoHotkey v2 manually and re-run with -SkipInstall."
    }
    $ahk = Find-AutoHotkeyV2
}

if (-not $ahk) {
    throw 'AutoHotkey v2 not found after install. Install from https://www.autohotkey.com/ and re-run.'
}
Write-Check -Status PASS -Name 'AutoHotkey v2' -Detail $ahk

# --- derived files ----------------------------------------------------------

& (Get-RepoPath 'tools/generate.ps1') -Quiet
Write-Check -Status PASS -Name 'Generated bindings' -Detail ((Get-GeneratedFile).RelativePath -join ', ')

# --- start at login ---------------------------------------------------------

if (-not $NoStartup) {
    $shortcutPath = Join-Path ([System.Environment]::GetFolderPath('Startup')) $ShortcutName

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $ahk
    $shortcut.Arguments = '"{0}"' -f (Get-RepoPath 'relay/swiftpoint-relay.ahk')
    $shortcut.WorkingDirectory = Get-RepoRoot
    $shortcut.Description = 'Swiftpoint Creator macro relay'
    $shortcut.Save()

    Write-Check -Status PASS -Name 'Starts at login' -Detail $shortcutPath
} else {
    Write-Check -Status INFO -Name 'Startup shortcut skipped' -Detail '-NoStartup'
}

# --- launch -----------------------------------------------------------------

if (-not $NoStart) {
    Stop-Relay
    Start-Relay -AutoHotkeyPath $ahk
    Start-Sleep -Milliseconds 700

    if (Test-RelayRunning) {
        Write-Check -Status PASS -Name 'Relay running' -Detail 'tray icon: Swiftpoint Creator Relay'
    } else {
        Write-Check -Status WARN -Name 'Relay did not stay running' -Detail 'run tools/verify.ps1 -Test'
    }
}

Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host '  1. Program the four profiles - docs/control-panel-entry-sheet.md'
Write-Host '  2. Optionally, the real contest URLs: copy config/links.local.example.json'
Write-Host '     to config/links.local.json (gitignored) and fill it in'
Write-Host '  3. pwsh -File tools/verify.ps1 -Test'
Write-Host ''
