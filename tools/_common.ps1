# Shared helpers for tools/. Dot-source: . "$PSScriptRoot/_common.ps1"

$ToolsRepoRoot = Split-Path -Parent $PSScriptRoot

# The fifteen physical inputs of the Creator, in the order every table lists
# them. Note that a profile must define exactly these ids, no more and no fewer.
$PhysicalButtons = @(
    [pscustomobject]@{ Id = 'lmb';              Label = 'Left click' }
    [pscustomobject]@{ Id = 'rmb';              Label = 'Right click' }
    [pscustomobject]@{ Id = 'leftFingertip';    Label = 'Left fingertip' }
    [pscustomobject]@{ Id = 'rightFingertip';   Label = 'Right fingertip' }
    [pscustomobject]@{ Id = 'frontEdge';        Label = 'Front edge' }
    [pscustomobject]@{ Id = 'rearEdge';         Label = 'Rear edge' }
    [pscustomobject]@{ Id = 'topThumb';         Label = 'Top thumb' }
    [pscustomobject]@{ Id = 'bottomThumb';      Label = 'Bottom thumb' }
    [pscustomobject]@{ Id = 'middle';           Label = 'Middle button' }
    [pscustomobject]@{ Id = 'scrollUp';         Label = 'Scroll forward' }
    [pscustomobject]@{ Id = 'scrollDown';       Label = 'Scroll back' }
    [pscustomobject]@{ Id = 'leftTriggerPush';  Label = 'Left trigger push' }
    [pscustomobject]@{ Id = 'leftTriggerPull';  Label = 'Left trigger pull' }
    [pscustomobject]@{ Id = 'rightTriggerPush'; Label = 'Right trigger push' }
    [pscustomobject]@{ Id = 'rightTriggerPull'; Label = 'Right trigger pull' }
)

function Get-RepoRoot {
    return $ToolsRepoRoot
}

function Get-RepoPath {
    param([Parameter(Mandatory)][string]$Relative)
    return (Join-Path $ToolsRepoRoot $Relative)
}

function Get-PhysicalButton {
    return $PhysicalButtons
}

# Returns the AutoHotkey v2 interpreter path, or $null.
# Note that v1 is not accepted: the relay is v2-only syntax, and v1 fails with
# confusing parse errors rather than a clear version complaint.
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

    # The registry, not a recursive glob: walking Program Files costs minutes on
    # a cold cache.
    foreach ($key in @('HKLM:\SOFTWARE\AutoHotkey', 'HKCU:\SOFTWARE\AutoHotkey')) {
        $entry = Get-ItemProperty -Path $key -Name 'InstallDir' -ErrorAction SilentlyContinue
        # Under StrictMode a missing key or value is a terminating error on plain
        # property access, so its presence is checked first.
        if (-not $entry -or @($entry.PSObject.Properties.Name) -notcontains 'InstallDir') { continue }
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

# Mirrors PwshPath() in the relay, so the checks exercise the capture script
# with the same interpreter that will really run it. Note that PowerShell 7 is
# absent from a stock Windows install, so 'pwsh' is not guaranteed to be on PATH.
function Find-PowerShell {
    $candidates = @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe"
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $onPath = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    return "$env:WinDir\System32\WindowsPowerShell\v1.0\powershell.exe"
}

# Present Swiftpoint HID interfaces. VID_214E is Swiftpoint's vendor ID; the
# Creator enumerates several interfaces, and it is the Keyboard one that carries
# each chord to Windows.
# Status is filtered to OK so that ghost entries for previously connected
# Swiftpoint devices do not read as connected.
function Get-SwiftpointDevice {
    $devices = @(
        Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VID_214E' -and $_.Status -eq 'OK' }
    )
    return ,$devices
}

function Get-RelayProcess {
    $scriptPath = Get-RepoPath 'relay/swiftpoint-relay.ahk'
    $leaf = Split-Path -Leaf $scriptPath
    $found = @(
        Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$leaf*" }
    )
    # The leading comma stops PowerShell unwrapping an empty array to $null,
    # which would make .Count throw at every call site under StrictMode.
    return ,$found
}

# A profile's fifteen buttons with inheritance applied, as an ordered map of
# button id to button object. Note that keys starting with '_' are comments and
# are skipped, and that an inheritance cycle is reported rather than followed.
function Resolve-BindingProfile {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Id,
        [string[]]$Visited = @()
    )

    if ($Visited -contains $Id) {
        throw "Profile inheritance cycle: $(($Visited + $Id) -join ' -> ')."
    }
    $entry = @($Config.profiles | Where-Object { $_.id -eq $Id })
    if ($entry.Count -ne 1) {
        throw "Profile '$Id' is defined $($entry.Count) times; exactly once is required."
    }
    $entry = $entry[0]

    $result = [ordered]@{}
    if (@($entry.PSObject.Properties.Name) -contains 'inherits' -and $entry.inherits) {
        $base = Resolve-BindingProfile -Config $Config -Id $entry.inherits -Visited ($Visited + $Id)
        foreach ($key in $base.Keys) { $result[$key] = $base[$key] }
    }
    foreach ($property in $entry.buttons.PSObject.Properties) {
        if ($property.Name.StartsWith('_')) { continue }
        $result[$property.Name] = $property.Value
    }
    return $result
}

# Every action id bound to a button with "relay", in profile order and then
# button order, each exactly once. It is guaranteed that this is the set of
# chords the relay registers, so CI compares its start line against this count.
function Get-RelayActionId {
    param([Parameter(Mandatory)]$Config)

    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Config.profiles) {
        $buttons = Resolve-BindingProfile -Config $Config -Id $entry.id
        foreach ($button in $PhysicalButtons) {
            if (-not $buttons.Contains($button.Id)) { continue }
            $spec = $buttons[$button.Id]
            if (@($spec.PSObject.Properties.Name) -contains 'relay') {
                if (-not $ids.Contains([string]$spec.relay)) { $ids.Add([string]$spec.relay) }
            }
        }
    }
    return $ids.ToArray()
}

# Where the gitignored overlay of real contest URLs lives.
function Get-LinkOverlayPath {
    param([Parameter(Mandatory)]$Config)
    return (Get-RepoPath $Config.relay.linksFile)
}

# The parsed overlay, or $null when it is absent. Note that invalid JSON throws:
# the caller decides whether that is a failure.
function Read-LinkOverlay {
    param([Parameter(Mandatory)]$Config)
    $path = Get-LinkOverlayPath -Config $Config
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json)
}

# True when the string holds only 7-bit ASCII. Anything emitted into the relay
# must satisfy this; see the encoding note in tools/ci.ps1.
function Test-AsciiOnly {
    param([AllowEmptyString()][string]$Value)
    return -not ($Value -match '[^\x00-\x7F]')
}

# A hash of the config's content with line endings normalised.
#
# Not Get-FileHash: the checkout style (core.autocrlf) decides whether the
# working copy has LF or CRLF, so raw bytes would hash differently on different
# machines and the sync check would fail for no real reason. Note also the
# explicit UTF-8: Windows PowerShell 5.1 would otherwise decode a BOM-less file
# as ANSI, and any non-ASCII text would hash differently per edition.
function Get-ConfigHash {
    param([Parameter(Mandatory)][string]$Path)

    $normalized = (Get-Content -Raw -Encoding UTF8 -LiteralPath $Path) -replace "`r`n", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

# Writes UTF-8 with no BOM, identically on every PowerShell edition.
#
# Not Set-Content -Encoding UTF8: that means "with BOM" on Windows PowerShell 5.1
# and "without BOM" on PowerShell 7, so generated files would differ according
# to which edition ran the generator.
function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
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
    if ($Detail) { Write-Host "  - $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
}
