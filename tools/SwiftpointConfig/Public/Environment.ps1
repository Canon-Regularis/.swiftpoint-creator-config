function Find-AutoHotkeyV2 {
    <#
    .SYNOPSIS
        The AutoHotkey v2 interpreter path, or $null.
    .DESCRIPTION
        v1 is not accepted: the relay is v2-only syntax, and v1 fails with
        confusing parse errors rather than a clear version complaint.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidates = @(
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe"
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey32.exe"
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe"
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey32.exe"
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe"
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey32.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    # The registry, not a recursive glob: walking Program Files takes minutes on
    # a cold cache.
    foreach ($key in @('HKLM:\SOFTWARE\AutoHotkey', 'HKCU:\SOFTWARE\AutoHotkey')) {
        $entry = Get-ItemProperty -Path $key -Name 'InstallDir' -ErrorAction SilentlyContinue
        $installDir = Get-OptionalProperty -InputObject $entry -Name 'InstallDir'
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

function Find-PowerShell {
    <#
    .SYNOPSIS
        The PowerShell the relay runs scripts with: PowerShell 7 when present,
        otherwise Windows PowerShell 5.1.
    .DESCRIPTION
        Mirrors PwshPath() in relay/lib/paths.ahk, so the checks exercise the
        capture script with the interpreter that really runs it. PowerShell 7
        is absent from a stock Windows install, so 'pwsh' may not be on PATH.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

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

function Get-SwiftpointDevice {
    <#
    .SYNOPSIS
        The connected Swiftpoint HID interfaces.
    .DESCRIPTION
        VID_214E is Swiftpoint's vendor ID. The Creator enumerates several
        interfaces; the Keyboard one carries each chord to Windows. Only status
        OK counts, so ghost entries for previously connected devices are left
        out. Callers wrap the result in @() to count it.
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    param()
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VID_214E' -and $_.Status -eq 'OK' }
}
