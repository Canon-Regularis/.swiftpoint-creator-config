function Get-RelayProcess {
    <#
    .SYNOPSIS
        The running relay processes. Callers wrap the result in @() to count it.
    .DESCRIPTION
        Matched by the entry script's file name on the AutoHotkey command line.
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    param()
    $leaf = Split-Path -Leaf (Get-RepoPath 'relay/swiftpoint-relay.ahk')
    Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$leaf*" }
}

function Test-RelayRunning {
    <#
    .SYNOPSIS
        True when at least one relay process is running.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return @(Get-RelayProcess).Count -gt 0
}

function Start-Relay {
    <#
    .SYNOPSIS
        Starts the relay. It is #SingleInstance Force, so a running one is
        replaced.
    .PARAMETER TestMode
        Start with --test: gestures show a tooltip instead of acting.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$AutoHotkeyPath,
        [switch]$TestMode
    )
    $relay = Get-RepoPath 'relay/swiftpoint-relay.ahk'
    $arguments = @('"{0}"' -f $relay)
    if ($TestMode) { $arguments += '--test' }
    if ($PSCmdlet.ShouldProcess($relay, 'Start relay')) {
        Start-Process -FilePath $AutoHotkeyPath -ArgumentList $arguments -WorkingDirectory $script:RepoRoot
    }
}

function Stop-Relay {
    <#
    .SYNOPSIS
        Stops every running relay process.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    foreach ($process in @(Get-RelayProcess)) {
        if ($PSCmdlet.ShouldProcess("pid $($process.ProcessId)", 'Stop relay')) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}
