<#
.SYNOPSIS
    Checks the macro set. Exits non-zero on failure.

.PARAMETER Test
    Restart the relay in test mode: gestures show a tooltip instead of acting.

.EXAMPLE
    pwsh -File tools/verify.ps1 -Test
#>
[CmdletBinding()]
param(
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/_common.ps1"

$RepoRoot  = Get-RepoRoot
$RelayPath = Get-RepoPath 'relay/swiftpoint-relay.ahk'
$failures  = 0
$warnings  = 0

Write-Host ''
Write-Host 'Swiftpoint Creator relay - verification' -ForegroundColor Cyan
Write-Host ''

$ahk = Find-AutoHotkeyV2
if ($ahk) {
    Write-Check -Status PASS -Name 'AutoHotkey v2 installed' -Detail $ahk
} else {
    Write-Check -Status FAIL -Name 'AutoHotkey v2 installed' -Detail 'run tools/install.ps1'
    $failures++
}

if (Test-BindingsInSync) {
    Write-Check -Status PASS -Name 'bindings.generated.ahk in sync with config'
} else {
    Write-Check -Status FAIL -Name 'bindings.generated.ahk out of sync' -Detail 'run tools/generate.ps1'
    $failures++
}

$config = Get-Content -Raw -LiteralPath (Get-RepoPath 'config/bindings.json') | ConvertFrom-Json
foreach ($slotName in $config.slots.PSObject.Properties.Name) {
    $scriptPath = Get-RepoPath $config.slots.$slotName.script
    if (Test-Path -LiteralPath $scriptPath) {
        Write-Check -Status PASS -Name "slot '$slotName'" -Detail $config.slots.$slotName.description
    } else {
        Write-Check -Status FAIL -Name "slot '$slotName' script missing" -Detail $scriptPath
        $failures++
    }
}

$build = [System.Environment]::OSVersion.Version.Build
if ($build -ge 22621) {
    Write-Check -Status PASS -Name 'Windows build supports Win+Shift+R' -Detail "build $build (needs 22621+)"
} else {
    Write-Check -Status WARN -Name 'Win+Shift+R may be unsupported' -Detail "build $build, needs 22621+"
    $warnings++
}

$snip = Get-AppxPackage -Name 'Microsoft.ScreenSketch' -ErrorAction SilentlyContinue
if ($snip) {
    Write-Check -Status PASS -Name 'Snipping Tool present' -Detail "v$($snip.Version)"
} else {
    Write-Check -Status WARN -Name 'Snipping Tool not detected' -Detail 'Win+Shift+R recording may not work'
    $warnings++
}

if (-not $Test) {
    $running = Get-RelayProcess
    if ($running.Count -gt 0) {
        Write-Check -Status PASS -Name 'Relay running' -Detail "pid $($running[0].ProcessId)"
    } else {
        Write-Check -Status WARN -Name 'Relay not running' -Detail 'run tools/install.ps1'
        $warnings++
    }
}

# --- test mode --------------------------------------------------------------

if ($Test) {
    if (-not $ahk) { throw 'Cannot start test mode without AutoHotkey v2.' }

    foreach ($process in Get-RelayProcess) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Process -FilePath $ahk -ArgumentList @(('"{0}"' -f $RelayPath), '--test') -WorkingDirectory $RepoRoot
    Start-Sleep -Milliseconds 700

    if ((Get-RelayProcess).Count -gt 0) {
        Write-Check -Status PASS -Name 'Relay started in TEST mode'
    } else {
        Write-Check -Status FAIL -Name 'Relay failed to start in TEST mode'
        $failures++
    }

    $activeSet = $config.activeChordSet
    Write-Host ''
    Write-Host 'Test mode: each gesture shows a tooltip instead of acting.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1. Keyboard only - isolates the relay from the mouse config:' -ForegroundColor White
    foreach ($button in $config.buttons) {
        $chord   = $config.chordSets.$activeSet.$($button.chord)
        $display = (@($chord.mods) + @($chord.key)) -join '+'
        Write-Host ("       {0,-22} -> tooltip naming '{1}'" -f $display, $button.label)
    }
    Write-Host ''
    Write-Host '  2. From the mouse - same tooltips.' -ForegroundColor White
    Write-Host '     Keyboard works but mouse does not: the Control Panel is not emitting the chord.'
    Write-Host "     Set activeChordSet to 'f9' in config/bindings.json, re-run tools/generate.ps1,"
    Write-Host '     and reprogram.'
    Write-Host ''
    Write-Host '  3. Gestures - tap and double-tap must name different slots, one tooltip each.' -ForegroundColor White
    Write-Host '     Two tooltips from one gesture: raise timing.doubleTapMs.'
    Write-Host ''
    Write-Host '  Leave test mode: tray icon > Exit, then'
    Write-Host '  pwsh -File tools/install.ps1 -SkipInstall -NoStartup'
    Write-Host ''
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures failed, $warnings warning(s)." -ForegroundColor Red
    exit 1
} elseif ($warnings -gt 0) {
    Write-Host "Passed with $warnings warning(s)." -ForegroundColor Yellow
} else {
    Write-Host 'All checks passed.' -ForegroundColor Green
}
Write-Host ''
