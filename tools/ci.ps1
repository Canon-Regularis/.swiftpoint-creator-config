<#
.SYNOPSIS
    Full check suite. Runs identically locally and in CI.

.PARAMETER SkipAhk
    Skip the AutoHotkey syntax and runtime checks.

.PARAMETER SkipRuntime
    Skip starting the relay. The runtime check restarts the relay (the script is
    #SingleInstance Force); a relay that was already running is restarted in
    normal mode afterwards.

.PARAMETER SkipAnalyzer
    Skip PSScriptAnalyzer even when the module is present.

.EXAMPLE
    pwsh -File tools/ci.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipAhk,
    [switch]$SkipRuntime,
    [switch]$SkipAnalyzer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/_common.ps1"

$RepoRoot = Get-RepoRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory)][string]$Name, [string]$Detail = '')
    Write-Check -Status FAIL -Name $Name -Detail $Detail
    $failures.Add($Name)
}

function Start-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
}

Write-Host ''
Write-Host 'Swiftpoint Creator config - CI' -ForegroundColor Cyan
Write-Host "repo: $RepoRoot"

# --- 1. config parses -------------------------------------------------------

Start-Section '1. Config'

$configPath = Get-RepoPath 'config/bindings.json'
$config = $null
try {
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    Write-Check -Status PASS -Name 'config/bindings.json parses'
} catch {
    Add-Failure 'config/bindings.json does not parse' $_.Exception.Message
}

if ($config) {
    # generate.ps1 already throws on unknown slots, chord collisions and bad
    # modes. Orphans are the gap it cannot see.
    $referenced = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($button in $config.buttons) {
        foreach ($side in @($button.primary, $button.secondary)) {
            if (@($side.PSObject.Properties.Name) -contains 'slot') {
                [void]$referenced.Add([string]$side.slot)
            }
        }
    }
    $orphans = @($config.slots.PSObject.Properties.Name | Where-Object { -not $referenced.Contains($_) })
    if ($orphans.Count -eq 0) {
        Write-Check -Status PASS -Name 'no orphan slots'
    } else {
        Add-Failure 'orphan slots defined but unreferenced' ($orphans -join ', ')
    }
}

# --- 2. PowerShell parses ---------------------------------------------------

Start-Section '2. PowerShell'

$psFiles = @(Get-ChildItem -Path $RepoRoot -Filter '*.ps1' -Recurse -File |
             Where-Object { $_.FullName -notmatch '\\\.git\\' })

foreach ($file in $psFiles) {
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
    $relative = $file.FullName.Substring($RepoRoot.Length + 1)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        Add-Failure "parse: $relative" $parseErrors[0].Message
    } else {
        Write-Check -Status PASS -Name "parse: $relative"
    }
}

# Windows PowerShell 5.1 reads BOM-less files as ANSI, so a non-ASCII character
# in a string literal turns into mojibake and breaks parsing. The relay falls
# back to 5.1 when PowerShell 7 is absent, where this silently broke every
# scaffold: the script failed to parse yet still exited 0.
$sourceFiles = @(Get-ChildItem -Path $RepoRoot -Include '*.ps1', '*.ahk', '*.psd1' -Recurse -File |
                 Where-Object { $_.FullName -notmatch '\\\.git\\' })
$nonAscii = 0
foreach ($file in $sourceFiles) {
    if ((Get-Content -Raw -LiteralPath $file.FullName) -match '[^\x00-\x7F]') {
        Add-Failure "non-ASCII in $($file.FullName.Substring($RepoRoot.Length + 1))" 'breaks Windows PowerShell 5.1 parsing'
        $nonAscii++
    }
}
if ($nonAscii -eq 0) {
    Write-Check -Status PASS -Name 'sources are ASCII-only' -Detail "$($sourceFiles.Count) file(s)"
}

# --- 3. PSScriptAnalyzer ----------------------------------------------------

Start-Section '3. PSScriptAnalyzer'

if ($SkipAnalyzer) {
    Write-Check -Status INFO -Name 'skipped' -Detail '-SkipAnalyzer'
} elseif (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Check -Status WARN -Name 'PSScriptAnalyzer not installed' -Detail 'Install-Module PSScriptAnalyzer -Scope CurrentUser'
} else {
    Import-Module PSScriptAnalyzer
    $settings = Get-RepoPath 'PSScriptAnalyzerSettings.psd1'
    $results = @(Invoke-ScriptAnalyzer -Path $RepoRoot -Recurse -Settings $settings)

    if ($results.Count -eq 0) {
        Write-Check -Status PASS -Name 'no findings'
    } else {
        foreach ($result in $results) {
            $where = '{0}:{1}' -f (Split-Path -Leaf $result.ScriptPath), $result.Line
            Add-Failure "$($result.RuleName) ($where)" $result.Message
        }
    }
}

# --- 4. generated files current ---------------------------------------------

Start-Section '4. Generated files'

$generatedPaths = @(
    Get-RepoPath 'relay/bindings.generated.ahk'
    Get-RepoPath 'docs/control-panel-entry-sheet.md'
)

# Everything down to the regeneration below inspects the COMMITTED files.
# Running generate.ps1 first would rewrite them and make these pass no matter
# what was committed.

if (Test-BindingsInSync) {
    Write-Check -Status PASS -Name 'committed hash matches committed config'
} else {
    Add-Failure 'committed hash does not match committed config' 'run tools/generate.ps1 and commit the result'
}

# A BOM means the generator ran under Windows PowerShell 5.1, whose
# -Encoding UTF8 adds one, so output would differ by edition. This is the only
# check that can see it: Get-Content -Raw drops a BOM, so the byte-comparison
# below is blind to it.
$bomCount = 0
foreach ($path in $generatedPaths) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $head = @([System.IO.File]::ReadAllBytes($path) | Select-Object -First 3)
    if ($head.Count -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
        Add-Failure "BOM in $($path.Substring($RepoRoot.Length + 1))" 'regenerate with tools/generate.ps1'
        $bomCount++
    }
}
if ($bomCount -eq 0) {
    Write-Check -Status PASS -Name 'generated files have no BOM'
}

# An absolute path means the committed file carries one machine's layout, so a
# clone would point at the author's home directory.
$committedAhk = Get-Content -Raw -LiteralPath (Get-RepoPath 'relay/bindings.generated.ahk')
if ($committedAhk -match '"[A-Za-z]:\\' -or $committedAhk -match '"\\\\') {
    Add-Failure 'absolute path in generated file' 'paths must stay repo-relative - see ConvertTo-EmittedPath in tools/generate.ps1'
} else {
    Write-Check -Status PASS -Name 'generated paths are repo-relative'
}

$before = @{}
foreach ($path in $generatedPaths) {
    $before[$path] = if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path } else { $null }
}

try {
    & (Get-RepoPath 'tools/generate.ps1') -Quiet
    Write-Check -Status PASS -Name 'generate.ps1 runs clean'

    foreach ($path in $generatedPaths) {
        $relative = $path.Substring($RepoRoot.Length + 1)
        $after = Get-Content -Raw -LiteralPath $path
        if (Test-ContentEqual -Left $before[$path] -Right $after) {
            Write-Check -Status PASS -Name "current: $relative"
        } else {
            Add-Failure "stale: $relative" 'run tools/generate.ps1 and commit the result'
        }
    }
} catch {
    Add-Failure 'generate.ps1 failed' $_.Exception.Message
}

# --- 5. AutoHotkey ----------------------------------------------------------

Start-Section '5. AutoHotkey'

$relayPath = Get-RepoPath 'relay/swiftpoint-relay.ahk'
$ahk = $null

if ($SkipAhk) {
    Write-Check -Status INFO -Name 'skipped' -Detail '-SkipAhk'
} else {
    $ahk = Find-AutoHotkeyV2
    if (-not $ahk) {
        Add-Failure 'AutoHotkey v2 not found' 'install it, or pass -SkipAhk'
    } else {
        Write-Check -Status PASS -Name 'AutoHotkey v2' -Detail $ahk

        # /validate loads the script, and the generated include with it, then
        # exits without running.
        $output = & $ahk /ErrorStdOut /validate $relayPath 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Check -Status PASS -Name 'relay syntax'
        } else {
            Add-Failure 'relay syntax' $output.Trim()
        }
    }
}

# --- 6. relay starts and registers its chords -------------------------------

Start-Section '6. Relay runtime'

if ($SkipAhk -or $SkipRuntime -or -not $ahk -or -not $config) {
    Write-Check -Status INFO -Name 'skipped'
} else {
    $logPath      = Get-RepoPath $config.relay.logFile
    $expectedCount = @($config.buttons).Count
    $wasRunning   = (Get-RelayProcess).Count -gt 0

    $linesBefore = 0
    if (Test-Path -LiteralPath $logPath) {
        $linesBefore = @(Get-Content -LiteralPath $logPath).Count
    }

    # #SingleInstance Force means this replaces any running relay.
    Start-Process -FilePath $ahk -ArgumentList @(('"{0}"' -f $relayPath), '--test') -WorkingDirectory $RepoRoot

    $startedLine = $null
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if (-not (Test-Path -LiteralPath $logPath)) { continue }
        $new = @(Get-Content -LiteralPath $logPath | Select-Object -Skip $linesBefore)
        $startedLine = $new | Where-Object { $_ -match 'relay started' } | Select-Object -Last 1
        if ($startedLine) { break }
    }

    if (-not $startedLine) {
        Add-Failure 'relay did not start' "no 'relay started' line in $logPath within 15s"
    } elseif ($startedLine -match 'chords=(\d+)') {
        $actual = [int]$Matches[1]
        if ($actual -eq $expectedCount) {
            Write-Check -Status PASS -Name 'relay registered its chords' -Detail "chords=$actual"
        } else {
            Add-Failure 'wrong chord count' "expected $expectedCount, got $actual"
        }
    } else {
        Add-Failure 'relay start line malformed' $startedLine
    }

    foreach ($process in Get-RelayProcess) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($wasRunning) {
        Start-Process -FilePath $ahk -ArgumentList ('"{0}"' -f $relayPath) -WorkingDirectory $RepoRoot
        Write-Check -Status INFO -Name 'relay restored to normal mode'
    }
}

# --- 7. scaffold stubs run --------------------------------------------------

Start-Section '7. Scaffold slots'

if (-not $config) {
    Write-Check -Status INFO -Name 'skipped' -Detail 'config did not parse'
} else {
    $powershell = Find-PowerShell
    foreach ($slotName in $config.slots.PSObject.Properties.Name) {
        $scriptPath = Get-RepoPath $config.slots.$slotName.script
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            Add-Failure "slot '$slotName' script missing" $scriptPath
            continue
        }
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Check -Status PASS -Name "runs: $slotName"
        } else {
            Add-Failure "slot '$slotName' exited $LASTEXITCODE" $scriptPath
        }
    }

    # Capture to a temp file rather than the clipboard, so a check run does not
    # clobber whatever the user has copied.
    $capturePath = Get-RepoPath $config.screenshot.script
    if (-not (Test-Path -LiteralPath $capturePath)) {
        Add-Failure 'screenshot capture script missing' $capturePath
    } else {
        $shotDir = Join-Path ([System.IO.Path]::GetTempPath()) ("swiftpoint-shot-" + [guid]::NewGuid().ToString('N'))
        try {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $capturePath -NoClipboard -SaveDir $shotDir *> $null
            $shot = @(Get-ChildItem -Path $shotDir -Filter '*.png' -ErrorAction SilentlyContinue)
            if ($LASTEXITCODE -eq 0 -and $shot.Count -eq 1) {
                Add-Type -AssemblyName System.Windows.Forms
                $expected = [System.Windows.Forms.SystemInformation]::VirtualScreen
                Add-Type -AssemblyName System.Drawing
                $image = [System.Drawing.Image]::FromFile($shot[0].FullName)
                try {
                    if ($image.Width -eq $expected.Width -and $image.Height -eq $expected.Height) {
                        Write-Check -Status PASS -Name 'full-screen capture' -Detail "$($image.Width)x$($image.Height)"
                    } else {
                        Add-Failure 'capture is not the full virtual screen' "got $($image.Width)x$($image.Height), expected $($expected.Width)x$($expected.Height)"
                    }
                } finally {
                    $image.Dispose()
                }
            } else {
                Add-Failure "screenshot capture exited $LASTEXITCODE" "produced $($shot.Count) png(s)"
            }
        } finally {
            Remove-Item -LiteralPath $shotDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- 8. markdown links resolve ----------------------------------------------

Start-Section '8. Markdown links'

$mdFiles = @(Get-ChildItem -Path $RepoRoot -Filter '*.md' -Recurse -File |
             Where-Object { $_.FullName -notmatch '\\\.git\\' })

$brokenLinks = 0
foreach ($file in $mdFiles) {
    $content = Get-Content -Raw -LiteralPath $file.FullName
    foreach ($match in [regex]::Matches($content, '\[[^\]]*\]\(([^)]+)\)')) {
        $target = $match.Groups[1].Value.Trim()
        if ($target -match '^(https?:|mailto:|#)') { continue }
        $target = ($target -split '#')[0]
        if (-not $target) { continue }
        $resolved = Join-Path (Split-Path -Parent $file.FullName) $target
        if (-not (Test-Path -LiteralPath $resolved)) {
            $relative = $file.FullName.Substring($RepoRoot.Length + 1)
            Add-Failure "broken link in $relative" $target
            $brokenLinks++
        }
    }
}
if ($brokenLinks -eq 0) {
    Write-Check -Status PASS -Name "all relative links resolve" -Detail "$($mdFiles.Count) file(s)"
}

# --- summary ----------------------------------------------------------------

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "FAILED - $($failures.Count) check(s):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
    Write-Host ''
    exit 1
}

Write-Host 'All checks passed.' -ForegroundColor Green
Write-Host ''
