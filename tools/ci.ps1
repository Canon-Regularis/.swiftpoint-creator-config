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

$ModuleManifest = Join-Path $PSScriptRoot 'SwiftpointConfig/SwiftpointConfig.psd1'
Import-Module $ModuleManifest -Force

# --- 1. config parses, and local links stay local ---------------------------

function Invoke-ConfigCheck {
    param([Parameter(Mandatory)][hashtable]$Context)

    try {
        $Context.Config = Read-BindingConfig
        New-CheckResult -Status PASS -Name 'config/bindings.json parses'
    } catch {
        New-CheckResult -Status FAIL -Name 'config/bindings.json does not parse' -Detail $_.Exception.Message
        return
    }

    # The generator already rejects unknown buttons, unreachable actions, chord
    # collisions and bad URLs. What it cannot see is whether the real contest
    # URLs could reach the public repository.
    $linksFile = [string]$Context.Config.relay.linksFile
    if (-not (Test-GitCheckout)) {
        New-CheckResult -Status INFO -Name 'not a git checkout' -Detail "cannot check that $linksFile is ignored"
    } elseif (Test-GitIgnored -Path $linksFile) {
        New-CheckResult -Status PASS -Name "$linksFile is gitignored"
    } else {
        New-CheckResult -Status FAIL -Name "$linksFile is not gitignored" -Detail 'real contest URLs could be committed'
    }

    # If a local overlay exists on this machine, none of its values may appear
    # in a committed, generated file.
    try {
        $overlay = Read-LinkOverlay -LinksFile $linksFile
    } catch {
        New-CheckResult -Status FAIL -Name "$linksFile does not parse" -Detail $_.Exception.Message
        return
    }
    if ($null -eq $overlay) {
        New-CheckResult -Status INFO -Name 'no local links on this machine' -Detail 'leak check has nothing to compare'
        return
    }

    $placeholders = @($Context.Config.actions.PSObject.Properties |
            Where-Object { @($_.Value.PSObject.Properties.Name) -contains 'url' } |
            ForEach-Object { $_.Value.url })
    $leaks = 0
    foreach ($property in $overlay.PSObject.Properties) {
        $value = [string]$property.Value
        if ($property.Name.StartsWith('_') -or $value.Length -lt 8 -or $placeholders -contains $value) { continue }
        foreach ($file in Get-GeneratedFile) {
            if ((Test-Path -LiteralPath $file.Path) -and (Get-Content -Raw -LiteralPath $file.Path).Contains($value)) {
                New-CheckResult -Status FAIL -Name "local link '$($property.Name)' leaked" -Detail $file.RelativePath
                $leaks++
            }
        }
    }
    if ($leaks -eq 0) {
        New-CheckResult -Status PASS -Name 'no local link appears in a generated file'
    }
}

# --- 2. PowerShell parses, sources are ASCII, the module manifest is right ---

function Invoke-PowerShellCheck {
    foreach ($file in Get-RepoFile -Include '*.ps1', '*.psm1', '*.psd1') {
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
        $relative = Get-RepoRelativePath -Path $file.FullName
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            New-CheckResult -Status FAIL -Name "parse: $relative" -Detail $parseErrors[0].Message
        } else {
            New-CheckResult -Status PASS -Name "parse: $relative"
        }
    }

    # Windows PowerShell 5.1 reads BOM-less files as ANSI, so a non-ASCII
    # character in a string literal turns into mojibake and breaks parsing. The
    # relay falls back to 5.1 when PowerShell 7 is absent, where this once
    # broke every script silently: each failed to parse, yet still exited 0.
    $sources = @(Get-RepoFile -Include '*.ps1', '*.psm1', '*.psd1', '*.ahk', '.editorconfig', '.gitattributes')
    $nonAscii = @($sources | Where-Object { -not (Test-AsciiOnly -Value (Get-Content -Raw -LiteralPath $_.FullName)) })
    foreach ($file in $nonAscii) {
        New-CheckResult -Status FAIL -Name "non-ASCII in $(Get-RepoRelativePath -Path $file.FullName)" -Detail 'breaks Windows PowerShell 5.1 parsing'
    }
    if ($nonAscii.Count -eq 0) {
        New-CheckResult -Status PASS -Name 'sources are ASCII-only' -Detail "$($sources.Count) file(s)"
    }

    # The manifest is the only export list, so a public function missing from
    # it is silently private, and a listed one that does not exist breaks the
    # import.
    $manifest = Test-ModuleManifest -Path $ModuleManifest
    $publicDir = Join-Path (Split-Path -Parent $ModuleManifest) 'Public'
    $defined = foreach ($file in Get-ChildItem -Path $publicDir -Filter '*.ps1') {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false).Name
    }
    $exported = @($manifest.ExportedFunctions.Keys)
    $unlisted = @($defined | Where-Object { $exported -notcontains $_ })
    $phantom = @($exported | Where-Object { $defined -notcontains $_ })
    if ($unlisted.Count -gt 0) {
        New-CheckResult -Status FAIL -Name 'public functions missing from the manifest' -Detail ($unlisted -join ', ')
    }
    if ($phantom.Count -gt 0) {
        New-CheckResult -Status FAIL -Name 'manifest exports undefined functions' -Detail ($phantom -join ', ')
    }
    if ($unlisted.Count -eq 0 -and $phantom.Count -eq 0) {
        New-CheckResult -Status PASS -Name 'module manifest exports every public function' -Detail "$($exported.Count) function(s), v$($manifest.Version)"
    }
}

# --- 3. PSScriptAnalyzer ----------------------------------------------------

function Invoke-AnalyzerCheck {
    param([Parameter(Mandatory)][hashtable]$Context)

    if ($Context.SkipAnalyzer) {
        New-CheckResult -Status INFO -Name 'skipped' -Detail '-SkipAnalyzer'
        return
    }
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        New-CheckResult -Status WARN -Name 'PSScriptAnalyzer not installed' -Detail 'Install-Module PSScriptAnalyzer -Scope CurrentUser'
        return
    }
    Import-Module PSScriptAnalyzer
    $settings = Get-RepoPath 'PSScriptAnalyzerSettings.psd1'
    $findings = @(Invoke-ScriptAnalyzer -Path (Get-RepoRoot) -Recurse -Settings $settings)
    foreach ($finding in $findings) {
        $where = '{0}:{1}' -f (Split-Path -Leaf $finding.ScriptPath), $finding.Line
        New-CheckResult -Status FAIL -Name "$($finding.RuleName) ($where)" -Detail $finding.Message
    }
    if ($findings.Count -eq 0) {
        New-CheckResult -Status PASS -Name 'no findings'
    }
}

# --- 4. generated files current ---------------------------------------------

function Invoke-GeneratedFileCheck {
    # Everything down to the regeneration inspects the COMMITTED files. Running
    # generate.ps1 first would rewrite them, and these checks would pass
    # whatever was committed.
    if (Test-BindingsInSync) {
        New-CheckResult -Status PASS -Name 'committed hash matches committed config'
    } else {
        New-CheckResult -Status FAIL -Name 'committed hash does not match committed config' -Detail 'run tools/generate.ps1 and commit the result'
    }

    # A BOM means the generator ran under Windows PowerShell 5.1, whose
    # -Encoding UTF8 adds one, so output would differ by edition. This is the
    # only check able to see it: Get-Content -Raw drops a BOM, so the
    # comparison below is blind to it.
    $files = @(Get-GeneratedFile)
    $withBom = @($files | Where-Object { (Test-Path -LiteralPath $_.Path) -and (Test-Utf8Bom -Path $_.Path) })
    foreach ($file in $withBom) {
        New-CheckResult -Status FAIL -Name "BOM in $($file.RelativePath)" -Detail 'regenerate with tools/generate.ps1'
    }
    if ($withBom.Count -eq 0) {
        New-CheckResult -Status PASS -Name 'generated files have no BOM'
    }

    # An absolute path would carry one machine's layout, so a clone would point
    # at the author's home directory. %VAR% paths are expanded at runtime and
    # are allowed.
    $include = Get-Content -Raw -LiteralPath (Get-RepoPath 'relay/bindings.generated.ahk')
    if ($include -match '"[A-Za-z]:\\' -or $include -match '"\\\\') {
        New-CheckResult -Status FAIL -Name 'absolute path in generated file' -Detail 'paths must stay repo-relative or %VAR%; see ConvertTo-EmittedPath in tools/SwiftpointConfig'
    } else {
        New-CheckResult -Status PASS -Name 'generated paths are repo-relative'
    }

    $before = @{}
    foreach ($file in $files) {
        $before[$file.Path] = if (Test-Path -LiteralPath $file.Path) { Get-Content -Raw -LiteralPath $file.Path } else { $null }
    }
    try {
        & (Get-RepoPath 'tools/generate.ps1') -Quiet
    } catch {
        New-CheckResult -Status FAIL -Name 'generate.ps1 failed' -Detail $_.Exception.Message
        return
    }
    New-CheckResult -Status PASS -Name 'generate.ps1 runs clean'
    foreach ($file in $files) {
        if (Test-ContentEqual -Left $before[$file.Path] -Right (Get-Content -Raw -LiteralPath $file.Path)) {
            New-CheckResult -Status PASS -Name "current: $($file.RelativePath)"
        } else {
            New-CheckResult -Status FAIL -Name "stale: $($file.RelativePath)" -Detail 'run tools/generate.ps1 and commit the result'
        }
    }
}

# --- 5. AutoHotkey ----------------------------------------------------------

function Invoke-AutoHotkeyCheck {
    param([Parameter(Mandatory)][hashtable]$Context)

    # The relay cannot share the module's URL rule, so the two copies are
    # compared instead. This needs no AutoHotkey.
    $links = Get-Content -Raw -LiteralPath (Get-RepoPath 'relay/lib/links.ahk')
    $modulePattern = & (Get-Module SwiftpointConfig) { $script:SafeUrlPattern }
    if ($links -match "IsSafeUrl\(url\)\s*\{[^}]*RegExMatch\(url, '([^']+)'\)") {
        if ($Matches[1] -eq $modulePattern) {
            New-CheckResult -Status PASS -Name 'relay and module share one URL rule' -Detail $modulePattern
        } else {
            New-CheckResult -Status FAIL -Name 'relay and module URL rules differ' -Detail "relay '$($Matches[1])', module '$modulePattern'"
        }
    } else {
        New-CheckResult -Status FAIL -Name 'IsSafeUrl pattern not found' -Detail 'relay/lib/links.ahk'
    }

    if ($Context.SkipAhk) {
        New-CheckResult -Status INFO -Name 'skipped' -Detail '-SkipAhk'
        return
    }
    $Context.AutoHotkey = Find-AutoHotkeyV2
    if (-not $Context.AutoHotkey) {
        New-CheckResult -Status FAIL -Name 'AutoHotkey v2 not found' -Detail 'install it, or pass -SkipAhk'
        return
    }
    New-CheckResult -Status PASS -Name 'AutoHotkey v2' -Detail $Context.AutoHotkey

    # /validate loads the script and every include, then exits without running.
    foreach ($script in @('relay/swiftpoint-relay.ahk', 'tools/relay-selftest.ahk')) {
        $name = Split-Path -Leaf $script
        $output = & $Context.AutoHotkey /ErrorStdOut /validate (Get-RepoPath $script) 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            New-CheckResult -Status PASS -Name "syntax: $name"
        } else {
            New-CheckResult -Status FAIL -Name "syntax: $name" -Detail $output.Trim()
        }
    }
}

# --- 6. relay starts and registers its chords -------------------------------

function Get-LogLineCount {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-Content -LiteralPath $Path).Count
}

function Invoke-RelayRuntimeCheck {
    param([Parameter(Mandatory)][hashtable]$Context)

    if ($Context.SkipAhk -or $Context.SkipRuntime -or -not $Context.AutoHotkey -or -not $Context.Config) {
        New-CheckResult -Status INFO -Name 'skipped'
        return
    }
    $Context.LogPath = Get-RepoPath $Context.Config.relay.logFile
    $expectedCount = @(Get-RelayActionId -Config $Context.Config).Count
    $Context.WasRunning = Test-RelayRunning
    $linesBefore = Get-LogLineCount -Path $Context.LogPath

    Start-Relay -AutoHotkeyPath $Context.AutoHotkey -TestMode
    $Context.RelayStarted = $true

    $startedLine = $null
    $deadline = (Get-Date).AddSeconds(15)
    while (-not $startedLine -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if (-not (Test-Path -LiteralPath $Context.LogPath)) { continue }
        $startedLine = Get-Content -LiteralPath $Context.LogPath |
            Select-Object -Skip $linesBefore |
            Where-Object { $_ -match 'relay started' } |
            Select-Object -Last 1
    }

    if (-not $startedLine) {
        New-CheckResult -Status FAIL -Name 'relay did not start' -Detail "no 'relay started' line in $($Context.LogPath) within 15s"
    } elseif ($startedLine -notmatch 'test=on') {
        New-CheckResult -Status FAIL -Name 'relay did not start in test mode' -Detail $startedLine
    } elseif ($startedLine -notmatch 'chords=(\d+)') {
        New-CheckResult -Status FAIL -Name 'relay start line malformed' -Detail $startedLine
    } elseif ([int]$Matches[1] -ne $expectedCount) {
        New-CheckResult -Status FAIL -Name 'wrong chord count' -Detail "expected $expectedCount, got $($Matches[1])"
    } else {
        New-CheckResult -Status PASS -Name 'relay registered its chords' -Detail "chords=$expectedCount"
        $Context.RelayUp = $true
    }
}

# --- 7. relay behaves: the selftest's expectations match the relay's log ----

# The first difference between two line lists, or $null when they are equal.
function Compare-LineSequence {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Actual
    )
    for ($i = 0; $i -lt [Math]::Max($Expected.Count, $Actual.Count); $i++) {
        $want = if ($i -lt $Expected.Count) { $Expected[$i] } else { '(nothing)' }
        $got = if ($i -lt $Actual.Count) { $Actual[$i] } else { '(nothing)' }
        if ($want -ne $got) { return "line $($i + 1): expected '$want', got '$got'" }
    }
    return $null
}

function Invoke-RelayBehaviourCheck {
    param([Parameter(Mandatory)][hashtable]$Context)

    if ($Context.SkipSelfTest) {
        New-CheckResult -Status INFO -Name 'skipped' -Detail '-SkipSelfTest'
    } elseif (-not $Context.RelayUp) {
        New-CheckResult -Status INFO -Name 'skipped' -Detail 'needs the relay running in test mode'
    } else {
        $linesBefore = Get-LogLineCount -Path $Context.LogPath
        $output = & $Context.AutoHotkey /ErrorStdOut (Get-RepoPath 'tools/relay-selftest.ahk') --relay-in-test-mode 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $expected = @($output -split "`r?`n" |
                Where-Object { $_ -like 'EXPECT *' } |
                ForEach-Object { $_.Substring(7) })
        # Whether a local link resolved to local or placeholder depends on this
        # machine's overlay, not on the relay, so it is not compared.
        $actual = @(Get-Content -LiteralPath $Context.LogPath |
                Select-Object -Skip $linesBefore |
                Where-Object { $_ -match '^\S+ \S+  TEST  ' } |
                ForEach-Object { ($_ -replace '^\S+ \S+  TEST  ', '') -replace ' \((local|placeholder)\)$', '' })

        if ($exitCode -ne 0) {
            New-CheckResult -Status FAIL -Name "selftest exited $exitCode" -Detail $output.Trim()
        } elseif ($expected.Count -eq 0) {
            New-CheckResult -Status FAIL -Name 'selftest expected nothing' -Detail 'no EXPECT lines on stdout'
        } else {
            $mismatch = Compare-LineSequence -Expected $expected -Actual $actual
            if ($mismatch) {
                New-CheckResult -Status FAIL -Name 'relay log does not match the selftest' -Detail $mismatch
            } else {
                New-CheckResult -Status PASS -Name 'relay log matches the selftest' -Detail "$($expected.Count) line(s): repeats ignored, wildcard, layers latched, wheel released"
            }
        }
    }
    Restore-RelayState -Context $Context
}

# Stops the test-mode relay, and restarts it normally if one was running before.
function Restore-RelayState {
    param([Parameter(Mandatory)][hashtable]$Context)

    if (-not $Context.RelayStarted -or $Context.RelayRestored) { return }
    $Context.RelayRestored = $true
    Stop-Relay
    if ($Context.WasRunning) {
        Start-Relay -AutoHotkeyPath $Context.AutoHotkey
        New-CheckResult -Status INFO -Name 'relay restored to normal mode'
    }
}

# --- 8. screenshot capture --------------------------------------------------

# The virtual screen's physical size, read in a DPI-aware child process as the
# capture itself is. This process may be DPI-unaware, and would then see a
# scaled display at its smaller logical size, so a cropped capture would match
# it and pass.
function Get-PhysicalScreenSize {
    param([Parameter(Mandatory)][string]$PowerShellPath)

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
    $size = (& $PowerShellPath -NoProfile -EncodedCommand $encoded | Select-Object -Last 1) -split ' '
    return [pscustomobject]@{ Width = [int]$size[0]; Height = [int]$size[1] }
}

function Invoke-ScreenshotCheck {
    param([Parameter(Mandatory)][hashtable]$Context)

    if (-not $Context.Config) {
        New-CheckResult -Status INFO -Name 'skipped' -Detail 'config did not parse'
        return
    }
    $powershell = Find-PowerShell
    $capture = Get-RepoPath $Context.Config.screenshot.script
    $format = [string]$Context.Config.screenshot.format
    if (-not (Test-Path -LiteralPath $capture)) {
        New-CheckResult -Status FAIL -Name 'screenshot capture script missing' -Detail $capture
        return
    }

    # A temp folder and no clipboard, so a check run disturbs neither the
    # screenshots folder nor whatever the user has copied.
    $shotDir = Join-Path ([System.IO.Path]::GetTempPath()) ('swiftpoint-shot-' + [guid]::NewGuid().ToString('N'))
    try {
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $capture -Format $format -NoClipboard -SaveDir $shotDir *> $null
        $exitCode = $LASTEXITCODE
        $shot = @(Get-ChildItem -Path $shotDir -Filter "*.$format" -ErrorAction SilentlyContinue)
        if ($exitCode -ne 0 -or $shot.Count -ne 1) {
            New-CheckResult -Status FAIL -Name "screenshot capture exited $exitCode" -Detail "produced $($shot.Count) $format file(s)"
            return
        }

        # The extension alone proves nothing; the leading bytes do.
        $magic = @([System.IO.File]::ReadAllBytes($shot[0].FullName) | Select-Object -First 2)
        $expectedMagic = if ($format -eq 'jpg') { @(0xFF, 0xD8) } else { @(0x89, 0x50) }
        if ($magic[0] -ne $expectedMagic[0] -or $magic[1] -ne $expectedMagic[1]) {
            New-CheckResult -Status FAIL -Name "capture is not a $format" -Detail ('leading bytes {0:X2} {1:X2}' -f $magic[0], $magic[1])
            return
        }

        $expected = Get-PhysicalScreenSize -PowerShellPath $powershell
        Add-Type -AssemblyName System.Drawing
        $image = [System.Drawing.Image]::FromFile($shot[0].FullName)
        try {
            if ($image.Width -eq $expected.Width -and $image.Height -eq $expected.Height) {
                New-CheckResult -Status PASS -Name "full-screen capture ($format)" -Detail "$($image.Width)x$($image.Height)"
            } else {
                New-CheckResult -Status FAIL -Name 'capture is not the full virtual screen' -Detail "got $($image.Width)x$($image.Height), expected $($expected.Width)x$($expected.Height)"
            }
        } finally {
            $image.Dispose()
        }
    } finally {
        Remove-Item -LiteralPath $shotDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- 9. markdown links resolve ----------------------------------------------

function Invoke-MarkdownLinkCheck {
    $files = @(Get-RepoFile -Include '*.md')
    $broken = 0
    foreach ($file in $files) {
        $content = Get-Content -Raw -LiteralPath $file.FullName
        foreach ($match in [regex]::Matches($content, '\[[^\]]*\]\(([^)]+)\)')) {
            $target = $match.Groups[1].Value.Trim()
            if ($target -match '^(https?:|mailto:|#)') { continue }
            $target = ($target -split '#')[0]
            if (-not $target) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $file.FullName) $target))) {
                New-CheckResult -Status FAIL -Name "broken link in $(Get-RepoRelativePath -Path $file.FullName)" -Detail $target
                $broken++
            }
        }
    }
    if ($broken -eq 0) {
        New-CheckResult -Status PASS -Name 'all relative links resolve' -Detail "$($files.Count) file(s)"
    }
}

# --- run --------------------------------------------------------------------

Write-Host ''
Write-Host 'Swiftpoint Creator config - CI' -ForegroundColor Cyan
Write-Host "repo: $(Get-RepoRoot)"

$context = @{
    SkipAhk       = [bool]$SkipAhk
    SkipRuntime   = [bool]$SkipRuntime
    SkipSelfTest  = [bool]$SkipSelfTest
    SkipAnalyzer  = [bool]$SkipAnalyzer
    Config        = $null
    AutoHotkey    = $null
    LogPath       = $null
    WasRunning    = $false
    RelayStarted  = $false
    RelayUp       = $false
    RelayRestored = $false
}

$steps = [ordered]@{
    '1. Config'             = 'Invoke-ConfigCheck'
    '2. PowerShell'         = 'Invoke-PowerShellCheck'
    '3. PSScriptAnalyzer'   = 'Invoke-AnalyzerCheck'
    '4. Generated files'    = 'Invoke-GeneratedFileCheck'
    '5. AutoHotkey'         = 'Invoke-AutoHotkeyCheck'
    '6. Relay runtime'      = 'Invoke-RelayRuntimeCheck'
    '7. Relay behaviour'    = 'Invoke-RelayBehaviourCheck'
    '8. Screenshot capture' = 'Invoke-ScreenshotCheck'
    '9. Markdown links'     = 'Invoke-MarkdownLinkCheck'
}

# The relay is put back even if a step throws or the run is interrupted, so it
# is never left in test mode.
try {
    $results = foreach ($title in $steps.Keys) {
        $command = Get-Command $steps[$title]
        if ($command.Parameters.ContainsKey('Context')) {
            Invoke-CheckStep -Title $title -Check $command -Context $context
        } else {
            Invoke-CheckStep -Title $title -Check $command
        }
    }
} finally {
    $null = Restore-RelayState -Context $context
}

$failures = @($results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "FAILED - $($failures.Count) check(s):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $($failure.Name)" -ForegroundColor Red }
    Write-Host ''
    exit 1
}

Write-Host 'All checks passed.' -ForegroundColor Green
Write-Host ''
