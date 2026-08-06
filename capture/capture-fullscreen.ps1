<#
.SYNOPSIS
    Captures the entire virtual screen to the clipboard, and optionally to a PNG.

.DESCRIPTION
    The relay calls this instead of sending Win+Shift+S. The Snipping Tool
    overlay opens in whatever mode was last used and ignores injected
    keystrokes, so a macro cannot make it capture the full screen. Doing the
    capture here is deterministic and needs no setup.

    Success is silent: the image on the clipboard is the confirmation. Failures
    log and toast.

.PARAMETER SaveDir
    Also write a timestamped PNG here. A relative path resolves against the
    repo root. Empty means clipboard only.

.PARAMETER NoClipboard
    Skip the clipboard. Used by the checks so a test run does not disturb it.

.EXAMPLE
    pwsh -File capture/capture-fullscreen.ps1
#>
[CmdletBinding()]
param(
    [string]$SaveDir,
    [switch]$NoClipboard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CaptureRepoRoot = Split-Path -Parent $PSScriptRoot
$CaptureLogFile  = Join-Path $CaptureRepoRoot 'logs/capture.log'

function Write-CaptureLog {
    param([Parameter(Mandatory)][string]$Message)
    $directory = Split-Path -Parent $CaptureLogFile
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $CaptureLogFile -Value $line
    Write-Host $line
}

function Show-CaptureToast {
    param([Parameter(Mandatory)][string]$Title, [string]$Message = '')
    try {
        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $notifyIcon.Icon    = [System.Drawing.SystemIcons]::Warning
        $notifyIcon.Visible = $true
        $notifyIcon.ShowBalloonTip(3000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::Warning)
        Start-Sleep -Seconds 3
        $notifyIcon.Dispose()
    } catch {
        Write-Verbose "Toast unavailable: $($_.Exception.Message)"
    }
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # VirtualScreen, not PrimaryScreen: covers every monitor, including ones
    # positioned left of or above the primary, which give negative origins.
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height

    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        } finally {
            $graphics.Dispose()
        }

        $savedTo = ''
        if ($SaveDir) {
            $directory = if ([System.IO.Path]::IsPathRooted($SaveDir)) {
                $SaveDir
            } else {
                Join-Path $CaptureRepoRoot $SaveDir
            }
            if (-not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Force -Path $directory | Out-Null
            }
            $savedTo = Join-Path $directory ('screenshot-{0}.png' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            $bitmap.Save($savedTo, [System.Drawing.Imaging.ImageFormat]::Png)
        }

        if (-not $NoClipboard) {
            # Both PowerShell editions start -File on an STA thread, which the
            # clipboard requires. Fail loudly rather than silently if that ever
            # stops being true.
            if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
                throw 'Clipboard needs an STA thread, but this host started MTA.'
            }
            [System.Windows.Forms.Clipboard]::SetImage($bitmap)
        }

        $target = if ($NoClipboard) { 'file only' } else { 'clipboard' }
        $suffix = if ($savedTo) { " + $savedTo" } else { '' }
        Write-CaptureLog ('captured {0}x{1} at {2},{3} -> {4}{5}' -f
            $bounds.Width, $bounds.Height, $bounds.Left, $bounds.Top, $target, $suffix)
    } finally {
        $bitmap.Dispose()
    }
} catch {
    Write-CaptureLog "ERROR $($_.Exception.Message)"
    Show-CaptureToast -Title 'Screenshot failed' -Message $_.Exception.Message
    exit 1
}
