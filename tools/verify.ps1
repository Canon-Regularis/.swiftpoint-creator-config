<#
.SYNOPSIS
    Checks the machine and the macro set. Exits non-zero on failure.

.PARAMETER Test
    Restart the relay in test mode, drive it with tools/relay-selftest.ahk, and
    leave it in test mode for the mouse checklist: relay buttons then show a
    tooltip instead of acting.

.EXAMPLE
    pwsh -File tools/verify.ps1 -Test
#>
[CmdletBinding()]
param(
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'SwiftpointConfig/SwiftpointConfig.psd1') -Force

# --- checks -----------------------------------------------------------------

function Invoke-SetupCheck {
    param([Parameter(Mandatory)][hashtable]$Context)

    if ($Context.AutoHotkey) {
        New-CheckResult -Status PASS -Name 'AutoHotkey v2 installed' -Detail $Context.AutoHotkey
    } else {
        New-CheckResult -Status FAIL -Name 'AutoHotkey v2 installed' -Detail 'run tools/install.ps1'
    }
    if (Test-BindingsInSync) {
        New-CheckResult -Status PASS -Name 'bindings.generated.ahk in sync with config'
    } else {
        New-CheckResult -Status FAIL -Name 'bindings.generated.ahk out of sync' -Detail 'run tools/generate.ps1'
    }
}

function Invoke-LinkCheck {
    param([Parameter(Mandatory)][hashtable]$Context)

    $model = $Context.Model
    $linksFile = $model.Relay.LinksFile
    if (Test-GitTracked -Path $linksFile) {
        New-CheckResult -Status FAIL -Name "$linksFile is tracked by git" -Detail 'git rm --cached it: the repository is public'
    }

    try {
        $overlay = Read-LinkOverlay -LinksFile $linksFile
    } catch {
        New-CheckResult -Status FAIL -Name "$linksFile is not valid JSON" -Detail $_.Exception.Message
        return
    }
    if ($null -eq $overlay) {
        New-CheckResult -Status INFO -Name 'no local contest links' -Detail "contest buttons open placeholders; copy config/links.local.example.json to $linksFile"
        return
    }

    # Enumerated property by property: under StrictMode, .Name on the
    # properties of an empty object {} throws rather than yielding nothing.
    $present = @($overlay.PSObject.Properties | ForEach-Object { $_.Name })
    $localIds = $model.LocalLinkIds
    $names = @($present | Where-Object { -not $_.StartsWith('_') -and $_ -ne 'browser' })
    $missing = @($localIds | Where-Object { $names -notcontains $_ })
    $unknown = @($names | Where-Object { $localIds -notcontains $_ })
    $bad = @($names | Where-Object { -not (Test-SafeUrl -Url ([string]$overlay.$_)) })
    $stale = @($names | Where-Object { $localIds -contains $_ -and [string]$overlay.$_ -eq $model.Actions[$_].Url })

    if ($stale.Count -gt 0) {
        New-CheckResult -Status WARN -Name 'local links still hold their placeholder' -Detail ($stale -join ', ')
    }
    if ($bad.Count -gt 0) {
        New-CheckResult -Status FAIL -Name 'local links that are not http(s) URLs' -Detail ($bad -join ', ')
    }
    if ($unknown.Count -gt 0) {
        New-CheckResult -Status WARN -Name 'local links for no action' -Detail ($unknown -join ', ')
    }
    if ($missing.Count -gt 0) {
        New-CheckResult -Status WARN -Name 'local links missing, placeholders used' -Detail ($missing -join ', ')
    }
    if ($bad.Count -eq 0 -and $missing.Count -eq 0 -and $stale.Count -eq 0) {
        New-CheckResult -Status PASS -Name 'local contest links' -Detail "$($names.Count) of $($localIds.Count)"
    }

    $browser = if ($present -contains 'browser') { [string]$overlay.browser } else { '' }
    if (-not $browser) {
        New-CheckResult -Status INFO -Name 'no contest browser set' -Detail 'links open in the default browser'
        return
    }
    $expanded = [System.Environment]::ExpandEnvironmentVariables($browser)
    if (Test-Path -LiteralPath $expanded) {
        New-CheckResult -Status PASS -Name 'contest browser found' -Detail $expanded
    } else {
        New-CheckResult -Status FAIL -Name 'contest browser not found' -Detail $expanded
    }
}

function Invoke-ActionTargetCheck {
    param([Parameter(Mandatory)][hashtable]$Context)

    $model = $Context.Model
    foreach ($action in $model.Actions.Values) {
        if ($action.Kind -ne 'launch') { continue }
        $found = $null
        foreach ($target in $action.Targets) {
            $expanded = [System.Environment]::ExpandEnvironmentVariables($target)
            if ($expanded.Contains('\')) {
                if (Test-Path -LiteralPath $expanded) { $found = $expanded; break }
            } elseif (Get-Command $expanded -ErrorAction SilentlyContinue) {
                $found = $expanded
                break
            }
        }
        if ($found) {
            New-CheckResult -Status PASS -Name $action.Label -Detail $found
        } else {
            New-CheckResult -Status WARN -Name "$($action.Label): no target found" -Detail ($action.Targets -join ', ')
        }
    }

    # The capture script owns the folder rule; it reports the folder without
    # capturing anything.
    $capture = Get-RepoPath $model.Screenshot.Script
    $folder = & $capture -SaveDir $model.Screenshot.SaveDir -ResolveSaveDir
    New-CheckResult -Status INFO -Name "screenshots saved as .$($model.Screenshot.Format)" -Detail $folder
}

function Invoke-HardwareCheck {
    $swiftpoint = @(Get-SwiftpointDevice)
    if ($swiftpoint.Count -eq 0) {
        New-CheckResult -Status WARN -Name 'Swiftpoint mouse not detected' -Detail 'nothing will emit the chords until it is plugged in'
    } elseif (@($swiftpoint | Where-Object { $_.Class -eq 'Keyboard' }).Count -eq 0) {
        # Each chord is sent as a keystroke, so without this interface the
        # mouse cannot deliver it, however the Control Panel is configured.
        New-CheckResult -Status WARN -Name 'Swiftpoint connected but exposes no keyboard interface' -Detail 'the chord is sent as keystrokes and needs one'
    } else {
        New-CheckResult -Status PASS -Name 'Swiftpoint mouse connected' -Detail "$($swiftpoint.Count) interfaces, including the keyboard one that carries the chord"
    }

    $controlPanel = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'Swiftpoint' })
    if ($controlPanel.Count -gt 0) {
        New-CheckResult -Status INFO -Name 'Swiftpoint Control Panel running' -Detail 'needed to program the profiles and to switch them by app'
    } else {
        New-CheckResult -Status WARN -Name 'Swiftpoint Control Panel not running' -Detail 'the sub-profiles switch by focused app only while it runs'
    }
}

function Invoke-RelayCheck {
    $running = @(Get-RelayProcess)
    if ($running.Count -gt 0) {
        New-CheckResult -Status PASS -Name 'Relay running' -Detail "pid $($running[0].ProcessId)"
    } else {
        New-CheckResult -Status WARN -Name 'Relay not running' -Detail 'run tools/install.ps1'
    }
}

# Restarts the relay in test mode and runs the selftest, so a tooltip appears
# for every chord and layer direction. The comparison against the relay's log
# lives in tools/ci.ps1.
function Invoke-TestModeCheck {
    param([Parameter(Mandatory)][hashtable]$Context)

    if (-not $Context.AutoHotkey) {
        New-CheckResult -Status FAIL -Name 'test mode needs AutoHotkey v2'
        return
    }
    Stop-Relay
    Start-Relay -AutoHotkeyPath $Context.AutoHotkey -TestMode
    Start-Sleep -Milliseconds 1000
    if (-not (Test-RelayRunning)) {
        New-CheckResult -Status FAIL -Name 'Relay failed to start in TEST mode'
        return
    }
    New-CheckResult -Status PASS -Name 'Relay started in TEST mode'

    $selftest = Get-RepoPath 'tools/relay-selftest.ahk'
    $output = & $Context.AutoHotkey /ErrorStdOut $selftest --relay-in-test-mode 2>&1 | Out-String
    $expected = @($output -split "`r?`n" | Where-Object { $_ -like 'EXPECT *' }).Count
    if ($LASTEXITCODE -eq 0) {
        New-CheckResult -Status PASS -Name 'selftest ran' -Detail "$expected expected line(s); see logs/relay.log, or run tools/ci.ps1 for the comparison"
    } else {
        New-CheckResult -Status FAIL -Name "selftest exited $LASTEXITCODE" -Detail $output.Trim()
    }
}

function Write-MouseChecklist {
    param([Parameter(Mandatory)]$Model)

    Write-Host ''
    Write-Host 'Test mode: each relay button shows a tooltip instead of acting.' -ForegroundColor Cyan
    Write-Host 'Native buttons act as normal; the relay never sees them.'
    Write-Host ''
    foreach ($entry in $Model.Profiles) {
        if ($entry.App) {
            $focus = "focus $($entry.App)"
        } elseif ($entry.IsGlobalDefault) {
            $focus = 'focus any other app'
        } else {
            $focus = 'focus the app linked to it'
        }
        Write-Host ('  {0}  ({1})' -f $entry.Label, $focus) -ForegroundColor White

        $relayButtons = @(Get-PhysicalButton | Where-Object { $entry.Buttons[$_.Id].Relay })
        foreach ($button in $relayButtons) {
            $action = $Model.Actions[$entry.Buttons[$button.Id].Relay]
            Write-Host ("       {0,-20} -> tooltip '{1}'" -f $button.Label, $action.Label)
            if ($action.Kind -eq 'layer') {
                Write-Host '                               hold it and scroll each way: one tooltip per'
                Write-Host '                               direction; after release the wheel scrolls again'
            }
        }
        if ($relayButtons.Count -eq 0) {
            Write-Host '       every button is native: no tooltips, only the game keys'
        }
        Write-Host ''
    }
    Write-Host '  No tooltip from the mouse, though the selftest passed: the Control Panel is not emitting'
    Write-Host '  the key. Tray icon > Key history shows what arrived. If F13-F24 are not offered in its'
    Write-Host "  key list, set activeChordSet to 'ctrlAltShift', re-run tools/generate.ps1 and this"
    Write-Host '  script (the relay reads its bindings only when it starts), and reprogram.'
    Write-Host ''
    Write-Host '  Leave test mode: tray icon > Exit, then'
    Write-Host '  pwsh -File tools/install.ps1 -SkipInstall -NoStartup'
    Write-Host ''
}

# --- run --------------------------------------------------------------------

Write-Host ''
Write-Host 'Swiftpoint Creator relay - verification' -ForegroundColor Cyan
Write-Host ''

$context = @{ AutoHotkey = Find-AutoHotkeyV2; Model = $null }
try {
    $context.Model = Get-BindingModel
} catch {
    Write-Check -Status FAIL -Name 'config/bindings.json is invalid' -Detail $_.Exception.Message
    exit 1
}

$steps = @(
    @{ Check = 'Invoke-SetupCheck'; Context = $true }
    @{ Check = 'Invoke-LinkCheck'; Context = $true }
    @{ Check = 'Invoke-ActionTargetCheck'; Context = $true }
    @{ Check = 'Invoke-HardwareCheck'; Context = $false }
)
if ($Test) {
    $steps += @{ Check = 'Invoke-TestModeCheck'; Context = $true }
} else {
    $steps += @{ Check = 'Invoke-RelayCheck'; Context = $false }
}

$results = foreach ($step in $steps) {
    $command = Get-Command $step.Check
    if ($step.Context) {
        Invoke-CheckStep -Check $command -Context $context
    } else {
        Invoke-CheckStep -Check $command
    }
}

if ($Test) { Write-MouseChecklist -Model $context.Model }

$failures = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
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
