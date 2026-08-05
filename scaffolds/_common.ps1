# Shared helpers for the scaffold slots. Dot-source: . "$PSScriptRoot/_common.ps1"
#
# The relay launches these hidden (relay.runHidden), so there is no console.
# Output goes to logs/scaffold.log.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScaffoldRepoRoot = Split-Path -Parent $PSScriptRoot
$ScaffoldLogFile  = Join-Path $ScaffoldRepoRoot 'logs/scaffold.log'

# Where new projects are created. Override with SWIFTPOINT_SCAFFOLD_ROOT.
function Get-ScaffoldRoot {
    if ($env:SWIFTPOINT_SCAFFOLD_ROOT) {
        return $env:SWIFTPOINT_SCAFFOLD_ROOT
    }
    return (Join-Path $HOME 'Projects')
}

function New-ScaffoldTargetPath {
    param(
        [Parameter(Mandatory)][string]$Slot,
        [string]$Name
    )
    if (-not $Name) {
        $Name = '{0}-{1}' -f $Slot, (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    return (Join-Path (Get-ScaffoldRoot) $Name)
}

function Write-ScaffoldLog {
    param([Parameter(Mandatory)][string]$Message)

    $directory = Split-Path -Parent $ScaffoldLogFile
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $ScaffoldLogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Show-ScaffoldToast {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Message = ''
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $notifyIcon.Icon    = [System.Drawing.SystemIcons]::Information
        $notifyIcon.Visible = $true
        $notifyIcon.ShowBalloonTip(3000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 3
        $notifyIcon.Dispose()
    } catch {
        Write-Verbose "Toast unavailable: $($_.Exception.Message)"
    }
}

# Placeholder body for a slot with no scaffold code yet. Exercises the full
# chain: button, chord, relay, gesture, script launch.
function Invoke-ScaffoldStub {
    param(
        [Parameter(Mandatory)][string]$Slot,
        [Parameter(Mandatory)][string]$Description
    )
    Write-ScaffoldLog "STUB  $Slot  ($Description)"
    Show-ScaffoldToast -Title "Swiftpoint: $Description" `
                       -Message "Slot '$Slot' fired. Stub only — add your code to scaffolds/$Slot.ps1"
}
