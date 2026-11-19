<#
.SYNOPSIS
    Captures the entire virtual screen to a timestamped image file, and to the
    clipboard.

.DESCRIPTION
    The relay calls this instead of sending Win+Shift+S. The Snipping Tool
    overlay opens in whatever mode was last used and ignores injected
    keystrokes, so a macro cannot make it capture the full screen. Capturing
    here is deterministic and needs no setup.

    Success is silent: the image on the clipboard is the confirmation. Failures
    log and toast.

    This script is standalone on purpose: the relay may run it under Windows
    PowerShell 5.1 on every screenshot, and it loads nothing it does not need.

.PARAMETER SaveDir
    Where the file is written. Empty means Pictures\Screenshots. %VAR% is
    expanded, and a relative path resolves against the repo root.

.PARAMETER Format
    jpg or png.

.PARAMETER NoSave
    Skip the file; clipboard only.

.PARAMETER NoClipboard
    Skip the clipboard. Used by the checks, so a test run does not disturb it.

.PARAMETER ResolveSaveDir
    Print the folder a capture would be saved in, and exit without capturing.
    tools/verify.ps1 uses this, so the folder rule lives only here.

.EXAMPLE
    pwsh -File capture/capture-fullscreen.ps1 -Format jpg
#>
[CmdletBinding()]
param(
    [string]$SaveDir,
    [ValidateSet('jpg', 'png')][string]$Format = 'jpg',
    [switch]$NoSave,
    [switch]$NoClipboard,
    [switch]$ResolveSaveDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CaptureRepoRoot = Split-Path -Parent $PSScriptRoot
$CaptureLogFile = Join-Path $CaptureRepoRoot 'logs/capture.log'

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
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Warning
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

# JPEGs use the GDI+ default quality. Setting a quality needs ImageCodecInfo
# and EncoderParameters, and that pattern next to a screen grab makes
# Defender's AMSI scan block the whole script as malicious.
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
# be only its top-left corner. SetProcessDpiAwarenessContext needs Windows 10
# 1703+; older builds fall back to system awareness.
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

if ($ResolveSaveDir) {
    Resolve-SaveDirectory -Requested $SaveDir
    return
}

try {
    Enable-DpiAwareness
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # VirtualScreen, not PrimaryScreen: it covers every monitor, including those
    # left of or above the primary, which give negative origins.
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
            # STA thread, which the clipboard requires. If that ever stops
            # holding, this fails loudly rather than silently.
            if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
                throw 'Clipboard needs an STA thread, but this host started MTA.'
            }
            [System.Windows.Forms.Clipboard]::SetImage($bitmap)
        }

        $targets = @()
        if ($savedTo) { $targets += $savedTo }
        if (-not $NoClipboard) { $targets += 'clipboard' }
        if ($targets.Count -eq 0) { $targets += 'nowhere (-NoSave -NoClipboard)' }
        $size = '{0}x{1} at {2},{3}' -f $bounds.Width, $bounds.Height, $bounds.Left, $bounds.Top
        Write-CaptureLog "captured $size -> $($targets -join ' + ')"
    } finally {
        $bitmap.Dispose()
    }
} catch {
    Write-CaptureLog "ERROR $($_.Exception.Message)"
    Show-CaptureToast -Title 'Screenshot failed' -Message $_.Exception.Message
    exit 1
}
