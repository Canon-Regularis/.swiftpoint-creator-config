<#
.SYNOPSIS
    Checks the macro set. Exits non-zero on failure.

.PARAMETER Test
    Restart the relay in test mode, drive it with tools/relay-selftest.ahk, and
    leave it in test mode for the mouse checklist: gestures then show a tooltip
    instead of acting.

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

$config = Get-Content -Raw -Encoding UTF8 -LiteralPath (Get-RepoPath 'config/bindings.json') | ConvertFrom-Json

# --- local links ------------------------------------------------------------

$linksRelative = [string]$config.relay.linksFile
$localIds = @($config.actions.PSObject.Properties | Where-Object {
    $_.Value.kind -eq 'openUrl' -and @($_.Value.PSObject.Properties.Name) -contains 'local' -and $_.Value.local
} | ForEach-Object { $_.Name })

# Only a git checkout can track the file; a release bundle has no .git, and git
# itself may be absent. Note that under Windows PowerShell 5.1 a native
# command's redirected stderr is raised as an error, so 'Stop' is lifted here.
if ((Test-Path -LiteralPath (Join-Path $RepoRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $ErrorActionPreference = 'Continue'
    $null = & git -C $RepoRoot ls-files --error-unmatch -- $linksRelative 2>&1
    $tracked = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    if ($tracked) {
        Write-Check -Status FAIL -Name "$linksRelative is tracked by git" -Detail 'git rm --cached it: the repository is public'
        $failures++
    }
}

$overlay = $null
$overlayValid = $true
try {
    $overlay = Read-LinkOverlay -Config $config
} catch {
    Write-Check -Status FAIL -Name "$linksRelative is not valid JSON" -Detail $_.Exception.Message
    $failures++
    $overlayValid = $false
}

if ($overlayValid -and $null -eq $overlay) {
    Write-Check -Status INFO -Name 'no local contest links' -Detail "contest buttons open placeholders; copy config/links.local.example.json to $linksRelative"
} elseif ($overlayValid) {
    # Enumerated property by property: under StrictMode, .Name on the
    # properties of an empty object {} throws rather than yielding nothing.
    $present = @($overlay.PSObject.Properties | ForEach-Object { $_.Name })
    $names   = @($present | Where-Object { -not $_.StartsWith('_') -and $_ -ne 'browser' })
    $missing = @($localIds | Where-Object { $names -notcontains $_ })
    $unknown = @($names | Where-Object { $localIds -notcontains $_ })
    $bad     = @($names | Where-Object { [string]$overlay.$_ -notmatch '^https?://[^\s"]+\z' })
    $stale   = @($names | Where-Object { $localIds -contains $_ -and [string]$overlay.$_ -eq [string]$config.actions.$_.url })

    if ($stale.Count -gt 0) {
        Write-Check -Status WARN -Name 'local links still hold their placeholder' -Detail ($stale -join ', ')
        $warnings++
    }

    if ($bad.Count -gt 0) {
        Write-Check -Status FAIL -Name 'local links that are not http(s) URLs' -Detail ($bad -join ', ')
        $failures++
    }
    if ($unknown.Count -gt 0) {
        Write-Check -Status WARN -Name 'local links for no action' -Detail ($unknown -join ', ')
        $warnings++
    }
    if ($missing.Count -gt 0) {
        Write-Check -Status WARN -Name 'local links missing, placeholders used' -Detail ($missing -join ', ')
        $warnings++
    }
    if ($bad.Count -eq 0 -and $missing.Count -eq 0 -and $stale.Count -eq 0) {
        Write-Check -Status PASS -Name 'local contest links' -Detail "$($names.Count) of $($localIds.Count)"
    }

    $browser = if ($present -contains 'browser') { [string]$overlay.browser } else { '' }
    if ($browser) {
        $expanded = [System.Environment]::ExpandEnvironmentVariables($browser)
        if (Test-Path -LiteralPath $expanded) {
            Write-Check -Status PASS -Name 'contest browser found' -Detail $expanded
        } else {
            Write-Check -Status FAIL -Name 'contest browser not found' -Detail $expanded
            $failures++
        }
    } else {
        Write-Check -Status INFO -Name 'no contest browser set' -Detail 'links open in the default browser'
    }
}

# --- launch targets and screenshot folder -----------------------------------

foreach ($property in $config.actions.PSObject.Properties) {
    if ($property.Value.kind -ne 'launch') { continue }
    $found = $null
    foreach ($target in @($property.Value.targets)) {
        $expanded = [System.Environment]::ExpandEnvironmentVariables([string]$target)
        if ($expanded.Contains('\')) {
            if (Test-Path -LiteralPath $expanded) { $found = $expanded; break }
        } elseif (Get-Command $expanded -ErrorAction SilentlyContinue) {
            $found = $expanded
            break
        }
    }
    if ($found) {
        Write-Check -Status PASS -Name $property.Value.label -Detail $found
    } else {
        Write-Check -Status WARN -Name "$($property.Value.label): no target found" -Detail (@($property.Value.targets) -join ', ')
        $warnings++
    }
}

# Mirrors Resolve-SaveDirectory in the capture script.
$saveDir = [string]$config.screenshot.saveDir
$shotDir = if (-not $saveDir) {
    Join-Path ([System.Environment]::GetFolderPath('MyPictures')) 'Screenshots'
} else {
    $expanded = [System.Environment]::ExpandEnvironmentVariables($saveDir)
    if ([System.IO.Path]::IsPathRooted($expanded)) { $expanded } else { Join-Path $RepoRoot $expanded }
}
Write-Check -Status INFO -Name "screenshots saved as .$($config.screenshot.format)" -Detail $shotDir

# --- hardware ---------------------------------------------------------------

$swiftpoint = Get-SwiftpointDevice
if ($swiftpoint.Count -eq 0) {
    Write-Check -Status WARN -Name 'Swiftpoint mouse not detected' -Detail 'nothing will emit the chords until it is plugged in'
    $warnings++
} elseif (@($swiftpoint | Where-Object { $_.Class -eq 'Keyboard' }).Count -eq 0) {
    # Each chord is sent as a keystroke, so without this interface the mouse
    # cannot deliver it, however the Control Panel is configured.
    Write-Check -Status WARN -Name 'Swiftpoint connected but exposes no keyboard interface' -Detail 'the chord is sent as keystrokes and needs one'
    $warnings++
} else {
    Write-Check -Status PASS -Name 'Swiftpoint mouse connected' -Detail "$($swiftpoint.Count) interfaces, including the keyboard one that carries the chord"
}

$controlPanel = @(Get-Process -ErrorAction SilentlyContinue |
                  Where-Object { $_.ProcessName -match 'Swiftpoint' })
if ($controlPanel.Count -gt 0) {
    Write-Check -Status INFO -Name 'Swiftpoint Control Panel running' -Detail 'needed to program the profiles and to switch them by app'
} else {
    Write-Check -Status WARN -Name 'Swiftpoint Control Panel not running' -Detail 'the sub-profiles switch by focused app only while it runs'
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

    # Parenthesised so the array is enumerated. Note that the bare call yields
    # Get-RelayProcess's wrapped array as one item: with no relay running, that
    # item is an empty array, and .ProcessId throws under StrictMode.
    foreach ($process in (Get-RelayProcess)) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Process -FilePath $ahk -ArgumentList @(('"{0}"' -f $RelayPath), '--test') -WorkingDirectory $RepoRoot
    Start-Sleep -Milliseconds 1000

    if ((Get-RelayProcess).Count -gt 0) {
        Write-Check -Status PASS -Name 'Relay started in TEST mode'

        # The full comparison against the relay's log lives in tools/ci.ps1;
        # here it is only required that the selftest ran, and the tooltips
        # appear on screen as it does.
        Write-Host ''
        Write-Host 'Running the selftest: tooltips appear for every chord and layer direction.' -ForegroundColor Cyan
        $selftest = Get-RepoPath 'tools/relay-selftest.ahk'
        $output = & $ahk /ErrorStdOut $selftest --relay-in-test-mode 2>&1 | Out-String
        $expected = @($output -split "`r?`n" | Where-Object { $_ -like 'EXPECT *' }).Count
        if ($LASTEXITCODE -eq 0) {
            Write-Check -Status PASS -Name 'selftest ran' -Detail "$expected expected line(s); see logs/relay.log, or run tools/ci.ps1 for the comparison"
        } else {
            Write-Check -Status FAIL -Name "selftest exited $LASTEXITCODE" -Detail $output.Trim()
            $failures++
        }
    } else {
        Write-Check -Status FAIL -Name 'Relay failed to start in TEST mode'
        $failures++
    }

    Write-Host ''
    Write-Host 'Test mode: each relay button shows a tooltip instead of acting.' -ForegroundColor Cyan
    Write-Host 'Native buttons act as normal; the relay never sees them.'
    Write-Host ''
    foreach ($entry in $config.profiles) {
        $buttons = Resolve-BindingProfile -Config $config -Id $entry.id
        $app = if (@($entry.PSObject.Properties.Name) -contains 'app' -and $entry.app) { "focus $($entry.app)" }
               elseif ($entry.controlPanel -eq 'Global Default') { 'focus any other app' }
               else { 'focus the app linked to it' }
        Write-Host ("  {0}  ({1})" -f $entry.label, $app) -ForegroundColor White
        $relayCount = 0
        foreach ($button in Get-PhysicalButton) {
            $spec = $buttons[$button.Id]
            if (@($spec.PSObject.Properties.Name) -notcontains 'relay') { continue }
            $relayCount++
            $action = $config.actions.$($spec.relay)
            Write-Host ("       {0,-20} -> tooltip '{1}'" -f $button.Label, $action.label)
            if ($action.kind -eq 'layer') {
                Write-Host '                               hold it and scroll each way: one tooltip per'
                Write-Host '                               direction; after release the wheel scrolls again'
            }
        }
        if ($relayCount -eq 0) {
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
