<#
.SYNOPSIS
    Full check suite. Runs identically locally and in CI.

.PARAMETER SkipAhk
    Skip the AutoHotkey syntax, runtime and selftest checks.

.PARAMETER SkipRuntime
    Skip starting the relay, and with it the selftest. The runtime check
    restarts the relay (the script is #SingleInstance Force); a relay that was
    already running is restarted in normal mode afterwards.

.PARAMETER SkipSelfTest
    Start the relay but do not drive it with tools/relay-selftest.ahk.

.PARAMETER SkipAnalyzer
    Skip PSScriptAnalyzer even when the module is present.

.EXAMPLE
    pwsh -File tools/ci.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipAhk,
    [switch]$SkipRuntime,
    [switch]$SkipSelfTest,
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

$generatedPaths = @(
    Get-RepoPath 'relay/bindings.generated.ahk'
    Get-RepoPath 'docs/control-panel-entry-sheet.md'
    Get-RepoPath 'config/links.local.example.json'
)

# --- 1. config parses, and local links stay local ---------------------------

Start-Section '1. Config'

$configPath = Get-RepoPath 'config/bindings.json'
$config = $null
try {
    $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
    Write-Check -Status PASS -Name 'config/bindings.json parses'
} catch {
    Add-Failure 'config/bindings.json does not parse' $_.Exception.Message
}

if ($config) {
    # generate.ps1 already throws on unknown buttons, unreachable actions,
    # chord collisions and bad URLs. What it cannot see is whether the real
    # contest URLs could reach the public repository.
    $linksRelative = [string]$config.relay.linksFile
    $null = & git -C $RepoRoot check-ignore -q -- $linksRelative 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Check -Status PASS -Name "$linksRelative is gitignored"
    } else {
        Add-Failure "$linksRelative is not gitignored" 'real contest URLs could be committed'
    }

    # Should a local overlay exist on this machine, none of its values may
    # appear in any committed, generated file.
    $overlay = $null
    try {
        $overlay = Read-LinkOverlay -Config $config
    } catch {
        Add-Failure "$linksRelative does not parse" $_.Exception.Message
    }
    if ($null -eq $overlay) {
        Write-Check -Status INFO -Name 'no local links on this machine' -Detail 'leak check has nothing to compare'
    } else {
        $placeholders = @($config.actions.PSObject.Properties | Where-Object {
            @($_.Value.PSObject.Properties.Name) -contains 'url' } | ForEach-Object { $_.Value.url })
        $leaks = 0
        foreach ($property in $overlay.PSObject.Properties) {
            $value = [string]$property.Value
            if ($property.Name.StartsWith('_') -or $value.Length -lt 8 -or $placeholders -contains $value) { continue }
            foreach ($path in $generatedPaths) {
                if ((Test-Path -LiteralPath $path) -and (Get-Content -Raw -LiteralPath $path).Contains($value)) {
                    Add-Failure "local link '$($property.Name)' leaked" $path.Substring($RepoRoot.Length + 1)
                    $leaks++
                }
            }
        }
        if ($leaks -eq 0) {
            Write-Check -Status PASS -Name 'no local link appears in a generated file'
        }
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
# in a string literal turns into mojibake and breaks parsing. Note that the
# relay falls back to 5.1 when PowerShell 7 is absent, where this once broke
# every script silently: it failed to parse, yet still exited 0.
$sourceFiles = @(Get-ChildItem -Path $RepoRoot -Include '*.ps1', '*.ahk', '*.psd1' -Recurse -File |
                 Where-Object { $_.FullName -notmatch '\\\.git\\' })
$nonAscii = 0
foreach ($file in $sourceFiles) {
    if (-not (Test-AsciiOnly (Get-Content -Raw -LiteralPath $file.FullName))) {
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

# Note that everything down to the regeneration below inspects the COMMITTED
# files. Running generate.ps1 first would rewrite them, and these checks would
# pass whatever was committed.

if (Test-BindingsInSync) {
    Write-Check -Status PASS -Name 'committed hash matches committed config'
} else {
    Add-Failure 'committed hash does not match committed config' 'run tools/generate.ps1 and commit the result'
}

# A BOM means the generator ran under Windows PowerShell 5.1, whose
# -Encoding UTF8 adds one, so output would differ by edition. Note that this is
# the only check able to see it: Get-Content -Raw drops a BOM, so the
# byte-comparison below is blind to it.
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
# clone would point at the author's home directory. Note that %VAR% paths are
# expanded at runtime and are therefore permitted.
$committedAhk = Get-Content -Raw -LiteralPath (Get-RepoPath 'relay/bindings.generated.ahk')
if ($committedAhk -match '"[A-Za-z]:\\' -or $committedAhk -match '"\\\\') {
    Add-Failure 'absolute path in generated file' 'paths must stay repo-relative or %VAR% - see ConvertTo-EmittedPath in tools/generate.ps1'
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

$relayPath    = Get-RepoPath 'relay/swiftpoint-relay.ahk'
$selftestPath = Get-RepoPath 'tools/relay-selftest.ahk'
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
        foreach ($script in @($relayPath, $selftestPath)) {
            $name = Split-Path -Leaf $script
            $output = & $ahk /ErrorStdOut /validate $script 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                Write-Check -Status PASS -Name "syntax: $name"
            } else {
                Add-Failure "syntax: $name" $output.Trim()
            }
        }
    }
}

# --- 6. relay starts and registers its chords -------------------------------
# --- 7. relay behaves: the selftest's expectations match the relay's log ----

Start-Section '6. Relay runtime'

$relayUp = $false
$wasRunning = $false
$logPath = $null

if ($SkipAhk -or $SkipRuntime -or -not $ahk -or -not $config) {
    Write-Check -Status INFO -Name 'skipped'
} else {
    $logPath       = Get-RepoPath $config.relay.logFile
    $expectedCount = @(Get-RelayActionId -Config $config).Count
    $wasRunning    = (Get-RelayProcess).Count -gt 0

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
    } elseif ($startedLine -notmatch 'test=on') {
        Add-Failure 'relay did not start in test mode' $startedLine
    } elseif ($startedLine -match 'chords=(\d+)') {
        $actual = [int]$Matches[1]
        if ($actual -eq $expectedCount) {
            Write-Check -Status PASS -Name 'relay registered its chords' -Detail "chords=$actual"
            $relayUp = $true
        } else {
            Add-Failure 'wrong chord count' "expected $expectedCount, got $actual"
        }
    } else {
        Add-Failure 'relay start line malformed' $startedLine
    }
}

Start-Section '7. Relay behaviour'

if ($SkipSelfTest) {
    Write-Check -Status INFO -Name 'skipped' -Detail '-SkipSelfTest'
} elseif (-not $relayUp) {
    Write-Check -Status INFO -Name 'skipped' -Detail 'it is required that the relay started in test mode'
} else {
    $linesBefore = @(Get-Content -LiteralPath $logPath).Count
    $output = & $ahk /ErrorStdOut $selftestPath --relay-in-test-mode 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    $expected = @($output -split "`r?`n" | Where-Object { $_ -like 'EXPECT *' } |
                  ForEach-Object { $_.Substring(7) })
    # The origin of a local link (local or placeholder) depends on this
    # machine's overlay, not on the relay, so it is not compared.
    $actual = @(Get-Content -LiteralPath $logPath | Select-Object -Skip $linesBefore |
                Where-Object { $_ -match '^\S+ \S+  TEST  ' } |
                ForEach-Object { ($_ -replace '^\S+ \S+  TEST  ', '') -replace ' \((local|placeholder)\)$', '' })

    if ($exitCode -ne 0) {
        Add-Failure "selftest exited $exitCode" $output.Trim()
    } elseif ($expected.Count -eq 0) {
        Add-Failure 'selftest expected nothing' 'no EXPECT lines on stdout'
    } else {
        $mismatch = $null
        for ($i = 0; $i -lt [Math]::Max($expected.Count, $actual.Count); $i++) {
            $e = if ($i -lt $expected.Count) { $expected[$i] } else { '(nothing)' }
            $a = if ($i -lt $actual.Count) { $actual[$i] } else { '(nothing)' }
            if ($e -ne $a) { $mismatch = "line $($i + 1): expected '$e', got '$a'"; break }
        }
        if ($mismatch) {
            Add-Failure 'relay log does not match the selftest' $mismatch
        } else {
            Write-Check -Status PASS -Name 'relay log matches the selftest' -Detail "$($expected.Count) line(s): repeats ignored, wildcard, layers latched, wheel released"
        }
    }
}

if ($logPath -and $ahk -and -not $SkipRuntime -and -not $SkipAhk) {
    # Parenthesised so the array is enumerated. Note that the bare call yields
    # Get-RelayProcess's wrapped array as one item: with no relay running, that
    # item is an empty array, and .ProcessId throws under StrictMode.
    foreach ($process in (Get-RelayProcess)) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($wasRunning) {
        Start-Process -FilePath $ahk -ArgumentList ('"{0}"' -f $relayPath) -WorkingDirectory $RepoRoot
        Write-Check -Status INFO -Name 'relay restored to normal mode'
    }
}

# --- 8. screenshot capture --------------------------------------------------

Start-Section '8. Screenshot capture'

if (-not $config) {
    Write-Check -Status INFO -Name 'skipped' -Detail 'config did not parse'
} else {
    # A temp folder and no clipboard, so a check run disturbs neither the
    # screenshots folder nor whatever the user has copied.
    $powershell  = Find-PowerShell
    $capturePath = Get-RepoPath $config.screenshot.script
    $format      = [string]$config.screenshot.format
    if (-not (Test-Path -LiteralPath $capturePath)) {
        Add-Failure 'screenshot capture script missing' $capturePath
    } else {
        $shotDir = Join-Path ([System.IO.Path]::GetTempPath()) ("swiftpoint-shot-" + [guid]::NewGuid().ToString('N'))
        try {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $capturePath -Format $format -NoClipboard -SaveDir $shotDir *> $null
            $shot = @(Get-ChildItem -Path $shotDir -Filter "*.$format" -ErrorAction SilentlyContinue)
            if ($LASTEXITCODE -eq 0 -and $shot.Count -eq 1) {
                # The extension alone proves nothing; the leading bytes do.
                $magic = @([System.IO.File]::ReadAllBytes($shot[0].FullName) | Select-Object -First 2)
                $expectedMagic = if ($format -eq 'jpg') { @(0xFF, 0xD8) } else { @(0x89, 0x50) }
                if ($magic[0] -ne $expectedMagic[0] -or $magic[1] -ne $expectedMagic[1]) {
                    Add-Failure "capture is not a $format" ('leading bytes {0:X2} {1:X2}' -f $magic[0], $magic[1])
                } else {
                    # The expected size is read in a DPI-aware child process, as
                    # the capture itself is. Note that this process may be DPI-
                    # unaware, and would then see a scaled display at its smaller
                    # logical size, so a cropped capture would match it and pass.
                    $probe = @'
Add-Type -Namespace CiDpi -Name Native -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
"@
try { $ok = [CiDpi.Native]::SetProcessDpiAwarenessContext([IntPtr]-4) } catch { $ok = $false }
if (-not $ok) { [void][CiDpi.Native]::SetProcessDPIAware() }
'{0} {1}' -f [CiDpi.Native]::GetSystemMetrics(78), [CiDpi.Native]::GetSystemMetrics(79)
'@
                    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($probe))
                    $physical = (& $powershell -NoProfile -EncodedCommand $encoded | Select-Object -Last 1) -split ' '
                    $expected = [pscustomobject]@{ Width = [int]$physical[0]; Height = [int]$physical[1] }
                    Add-Type -AssemblyName System.Drawing
                    $image = [System.Drawing.Image]::FromFile($shot[0].FullName)
                    try {
                        if ($image.Width -eq $expected.Width -and $image.Height -eq $expected.Height) {
                            Write-Check -Status PASS -Name "full-screen capture ($format)" -Detail "$($image.Width)x$($image.Height)"
                        } else {
                            Add-Failure 'capture is not the full virtual screen' "got $($image.Width)x$($image.Height), expected $($expected.Width)x$($expected.Height)"
                        }
                    } finally {
                        $image.Dispose()
                    }
                }
            } else {
                Add-Failure "screenshot capture exited $LASTEXITCODE" "produced $($shot.Count) $format file(s)"
            }
        } finally {
            Remove-Item -LiteralPath $shotDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- 9. markdown links resolve ----------------------------------------------

Start-Section '9. Markdown links'

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
