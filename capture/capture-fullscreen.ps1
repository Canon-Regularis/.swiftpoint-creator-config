<#
.SYNOPSIS
    Captures the entire virtual screen to a timestamped image file, and to the
    clipboard.

.DESCRIPTION
    The relay calls this instead of sending Win+Shift+S. Note that the Snipping
    Tool overlay opens in whatever mode was last used and ignores injected
    keystrokes, so a macro cannot make it capture the full screen. Doing the
    capture here is deterministic and needs no setup.

    Success is silent: the image on the clipboard is the confirmation. Failures
    log and toast.

.PARAMETER SaveDir
    Where the file is written. Empty means Pictures\Screenshots. %VAR% is
    expanded, and a relative path resolves against the repo root.

.PARAMETER Format
    jpg or png.

.PARAMETER NoSave
    Skip the file; clipboard only.

.PARAMETER NoClipboard
    Skip the clipboard. Used by the checks, so a test run does not disturb it.

.EXAMPLE
    pwsh -File capture/capture-fullscreen.ps1 -Format jpg
#>
[CmdletBinding()]
param(
    [string]$SaveDir,
    [ValidateSet('jpg', 'png')][string]$Format = 'jpg',
    [switch]$NoSave,
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

# GetFolderPath, not $HOME\Pictures: it follows a OneDrive-redirected Pictures
# folder, which is where Windows itself saves screenshots.
function Resolve-SaveDirectory {
    param([string]$Requested)
    if (-not $Requested) {
        return (Join-Path ([System.Environment]::GetFolderPath('MyPictures')) 'Screenshots')
    }
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Requested)
    if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
    return (Join-Path $CaptureRepoRoot $expanded)
}

# Note that the JPEG is written at the GDI+ default quality. An explicit
# quality goes through ImageCodecInfo and EncoderParameters, and that pattern
# beside a screen grab is blocked by Defender's AMSI scan as malicious, so the
# script would not even parse.
function Save-Capture {
    param(
        [Parameter(Mandatory)][System.Drawing.Bitmap]$Bitmap,
        [Parameter(Mandatory)][string]$Path
    )
    $imageFormat = if ($Format -eq 'png') {
        [System.Drawing.Imaging.ImageFormat]::Png
    } else {
        [System.Drawing.Imaging.ImageFormat]::Jpeg
    }
    $Bitmap.Save($Path, $imageFormat)
}

# Per-monitor DPI awareness, set before any bounds are read. A DPI-unaware
# process sees a scaled display at its logical size (1536x864 for 1920x1080 at
# 125%), yet CopyFromScreen copies physical pixels, so the "full screen" would
# be only the top-left crop of it. Note that SetProcessDpiAwarenessContext
# needs Windows 10 1703+; earlier builds take the system-aware fallback.
function Enable-DpiAwareness {
    if (-not ('CaptureDpi.Native' -as [type])) {
        Add-Type -Namespace CaptureDpi -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
    }
    try {
        if ([CaptureDpi.Native]::SetProcessDpiAwarenessContext([IntPtr]-4)) { return }
    } catch {
        Write-Verbose "Per-monitor awareness unavailable: $($_.Exception.Message)"
    }
    [void][CaptureDpi.Native]::SetProcessDPIAware()
}

try {
    Enable-DpiAwareness
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # VirtualScreen, not PrimaryScreen: it covers every monitor, including those
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
        if (-not $NoSave) {
            $directory = Resolve-SaveDirectory -Requested $SaveDir
            if (-not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Force -Path $directory | Out-Null
            }
            $savedTo = Join-Path $directory ('screenshot-{0}.{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $Format)
            Save-Capture -Bitmap $bitmap -Path $savedTo
        }

        if (-not $NoClipboard) {
            # It is guaranteed that both PowerShell editions start -File on an
            # STA thread, which the clipboard requires. Should that ever cease
            # to hold, this fails loudly rather than silently.
            if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
                throw 'Clipboard needs an STA thread, but this host started MTA.'
            }
            [System.Windows.Forms.Clipboard]::SetImage($bitmap)
        }

        $targets = @()
        if ($savedTo) { $targets += $savedTo }
        if (-not $NoClipboard) { $targets += 'clipboard' }
        if ($targets.Count -eq 0) { $targets += 'nowhere (-NoSave -NoClipboard)' }
        Write-CaptureLog ('captured {0}x{1} at {2},{3} -> {4}' -f
            $bounds.Width, $bounds.Height, $bounds.Left, $bounds.Top, ($targets -join ' + '))
    } finally {
        $bitmap.Dispose()
    }
} catch {
    Write-CaptureLog "ERROR $($_.Exception.Message)"
    Show-CaptureToast -Title 'Screenshot failed' -Message $_.Exception.Message
    exit 1
}
