# SwiftpointConfig: loads and validates config/bindings.json, renders the
# generated files, and holds the helpers shared by the scripts in tools/.
#
# A caller's StrictMode and ErrorActionPreference do not cross into a module,
# so both are set here for every function below.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# tools/SwiftpointConfig/ sits two levels below the repository root.
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Every generated file uses CRLF regardless of the checkout's line endings.
$script:Crlf = "`r`n"

# A plain http(s) URL. Mirrors IsSafeUrl in relay/lib/links.ahk; tools/ci.ps1
# checks that the two stay identical. \z, not $: $ also matches before a final
# newline.
$script:SafeUrlPattern = '^https?://[^\s"]+\z'

# The fifteen physical inputs of the Creator, in the order every table lists
# them. Every profile defines exactly these ids.
$script:PhysicalButtons = @(
    [pscustomobject]@{ Id = 'lmb'; Label = 'Left click' }
    [pscustomobject]@{ Id = 'rmb'; Label = 'Right click' }
    [pscustomobject]@{ Id = 'leftFingertip'; Label = 'Left fingertip' }
    [pscustomobject]@{ Id = 'rightFingertip'; Label = 'Right fingertip' }
    [pscustomobject]@{ Id = 'frontEdge'; Label = 'Front edge' }
    [pscustomobject]@{ Id = 'rearEdge'; Label = 'Rear edge' }
    [pscustomobject]@{ Id = 'topThumb'; Label = 'Top thumb' }
    [pscustomobject]@{ Id = 'bottomThumb'; Label = 'Bottom thumb' }
    [pscustomobject]@{ Id = 'middle'; Label = 'Middle button' }
    [pscustomobject]@{ Id = 'scrollUp'; Label = 'Scroll forward' }
    [pscustomobject]@{ Id = 'scrollDown'; Label = 'Scroll back' }
    [pscustomobject]@{ Id = 'leftTriggerPush'; Label = 'Left trigger push' }
    [pscustomobject]@{ Id = 'leftTriggerPull'; Label = 'Left trigger pull' }
    [pscustomobject]@{ Id = 'rightTriggerPush'; Label = 'Right trigger push' }
    [pscustomobject]@{ Id = 'rightTriggerPull'; Label = 'Right trigger pull' }
)

$script:LeafKinds = @('captureScreen', 'launch', 'openUrl', 'turn')
$script:ActionKinds = $script:LeafKinds + @('layer')
$script:Directions = @('left', 'right', 'up', 'down')
$script:ModifierToAhk = [ordered]@{ 'Ctrl' = '^'; 'Alt' = '!'; 'Shift' = '+'; 'Win' = '#' }
$script:ModifierToSend = @{ 'Ctrl' = 'Ctrl'; 'Alt' = 'Alt'; 'Shift' = 'Shift'; 'Win' = 'LWin' }

# Exports are declared in the manifest, not here.
foreach ($folder in @('Private', 'Public')) {
    foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1') {
        . $file.FullName
    }
}
