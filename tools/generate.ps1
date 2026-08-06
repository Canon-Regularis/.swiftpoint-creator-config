<#
.SYNOPSIS
    Generates relay/bindings.generated.ahk and docs/control-panel-entry-sheet.md
    from config/bindings.json. Run after any edit to that file.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/_common.ps1"

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $RepoRoot 'config/bindings.json'
$AhkOut     = Join-Path $RepoRoot 'relay/bindings.generated.ahk'
$SheetOut   = Join-Path $RepoRoot 'docs/control-panel-entry-sheet.md'

# --- helpers ----------------------------------------------------------------

# AHK v2 escapes with a backtick and doubles quotes inside strings. Backslashes
# are literal, so Windows paths need no handling.
function ConvertTo-AhkString([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return $Value.Replace('`', '``').Replace('"', '""')
}

function ConvertTo-AhkBool($Value) {
    if ($Value) { return 'true' } else { return 'false' }
}

$ModifierToAhk = @{
    'Ctrl'  = '^'
    'Alt'   = '!'
    'Shift' = '+'
    'Win'   = '#'
}

function Get-AhkChord($Chord) {
    $prefix = ''
    foreach ($m in $Chord.mods) {
        if (-not $ModifierToAhk.ContainsKey($m)) {
            throw "Unknown modifier '$m' in bindings.json. Expected: $($ModifierToAhk.Keys -join ', ')"
        }
        $prefix += $ModifierToAhk[$m]
    }
    return $prefix + $Chord.key
}

function Get-DisplayChord($Chord) {
    return (@($Chord.mods) + @($Chord.key)) -join ' + '
}

# Emitted paths stay repo-relative; the relay resolves them against its own
# location at runtime. Absolute paths would bake one machine's layout into a
# committed file, so a clone would point at the author's home directory.
function ConvertTo-EmittedPath([string]$Relative) {
    return $Relative -replace '/', '\'
}

# --- load config ------------------------------------------------------------

if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$config     = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$sourceHash = Get-ConfigHash -Path $ConfigPath

$activeSet = $config.activeChordSet
if (@($config.chordSets.PSObject.Properties.Name) -notcontains $activeSet) {
    throw "activeChordSet '$activeSet' is not defined in chordSets."
}
$chords = $config.chordSets.$activeSet

function Get-ActionInfo($Action) {
    switch ($Action.action) {
        'scaffold' {
            $slot = $Action.slot
            if (@($config.slots.PSObject.Properties.Name) -notcontains $slot) {
                throw "Button references unknown slot '$slot'. Add it to the 'slots' section."
            }
            $slotCfg = $config.slots.$slot
            return [pscustomobject]@{
                Kind   = 'scaffold'
                Slot   = $slot
                Label  = $slotCfg.description
                Script = ConvertTo-EmittedPath $slotCfg.script
            }
        }
        'captureScreen' {
            return [pscustomobject]@{
                Kind = 'captureScreen'; Slot = ''
                Script = ConvertTo-EmittedPath $config.screenshot.script
                Label  = 'Full-screen capture to clipboard'
            }
        }
        'snipRecord' {
            return [pscustomobject]@{
                Kind = 'snipRecord'; Slot = ''; Script = ''
                Label = 'Start/stop screen recording (Win+Shift+R)'
            }
        }
        default {
            throw "Unknown action '$($Action.action)'. Expected: scaffold, captureScreen, snipRecord."
        }
    }
}

function Get-GestureName([string]$Mode) {
    switch ($Mode) {
        'tapDouble' { return @{ Primary = 'single tap'; Secondary = 'double tap' } }
        'tapHold'   { return @{ Primary = 'quick tap';  Secondary = "hold >= $($config.timing.holdMs)ms" } }
        default     { throw "Unknown button mode '$Mode'. Expected: tapDouble, tapHold." }
    }
}

# --- button model, shared by both outputs -----------------------------------

$buttons = foreach ($btn in $config.buttons) {
    if (@($chords.PSObject.Properties.Name) -notcontains $btn.chord) {
        throw "Button '$($btn.id)' references chord '$($btn.chord)', missing from chordSet '$activeSet'."
    }
    $chord = $chords.$($btn.chord)

    [pscustomobject]@{
        Id        = $btn.id
        Label     = $btn.label
        Mode      = $btn.mode
        Ahk       = Get-AhkChord $chord
        Display   = Get-DisplayChord $chord
        BaseKey   = $chord.key
        Gestures  = Get-GestureName $btn.mode
        Primary   = Get-ActionInfo $btn.primary
        Secondary = Get-ActionInfo $btn.secondary
    }
}

# Two buttons sharing a chord would silently shadow each other in AHK.
$dupes = $buttons | Group-Object Ahk | Where-Object { $_.Count -gt 1 }
if ($dupes) {
    throw "Chord collision: $($dupes.Name -join ', ') is assigned to more than one button."
}

# --- relay/bindings.generated.ahk -------------------------------------------

$ahk = [System.Collections.Generic.List[string]]::new()
# No timestamp anywhere in the output: generation is deterministic, so CI can
# byte-compare a fresh run against the committed files.
$ahk.Add('; Generated by tools/generate.ps1 from config/bindings.json. Do not edit.')
$ahk.Add(";   chord set: $activeSet")
$ahk.Add('')
$ahk.Add("BINDINGS_SOURCE_HASH := `"$sourceHash`"")
$ahk.Add('')
$ahk.Add('TIMING := Map(')
$ahk.Add("    `"doubleTapMs`",       $($config.timing.doubleTapMs),")
$ahk.Add("    `"holdMs`",            $($config.timing.holdMs),")
$ahk.Add("    `"modifierReleaseMs`", $($config.timing.modifierReleaseMs))")
$ahk.Add('')
$ahk.Add('RELAY := Map(')
$ahk.Add("    `"runHidden`", $(ConvertTo-AhkBool $config.relay.runHidden),")
$ahk.Add("    `"logFile`",   `"$(ConvertTo-AhkString (ConvertTo-EmittedPath $config.relay.logFile))`")")
$ahk.Add('')
$ahk.Add('SCREENSHOT := Map(')
$ahk.Add("    `"saveDir`", `"$(ConvertTo-AhkString $config.screenshot.saveDir)`")")
$ahk.Add('')
$ahk.Add('BINDINGS := Map(')

$buttonBlocks = foreach ($b in $buttons) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("    `"$(ConvertTo-AhkString $b.Ahk)`", Map(")
    $lines.Add("        `"id`",      `"$(ConvertTo-AhkString $b.Id)`",")
    $lines.Add("        `"label`",   `"$(ConvertTo-AhkString $b.Label)`",")
    $lines.Add("        `"base`",    `"$(ConvertTo-AhkString $b.BaseKey)`",")
    $lines.Add("        `"display`", `"$(ConvertTo-AhkString $b.Display)`",")
    $lines.Add("        `"mode`",    `"$(ConvertTo-AhkString $b.Mode)`",")

    foreach ($slotName in @('primary', 'secondary')) {
        $a       = if ($slotName -eq 'primary') { $b.Primary } else { $b.Secondary }
        $gesture = if ($slotName -eq 'primary') { $b.Gestures.Primary } else { $b.Gestures.Secondary }
        $comma   = if ($slotName -eq 'primary') { ',' } else { '' }
        $lines.Add("        `"$slotName`", Map(")
        $lines.Add("            `"action`",  `"$(ConvertTo-AhkString $a.Kind)`",")
        $lines.Add("            `"slot`",    `"$(ConvertTo-AhkString $a.Slot)`",")
        $lines.Add("            `"label`",   `"$(ConvertTo-AhkString $a.Label)`",")
        $lines.Add("            `"gesture`", `"$(ConvertTo-AhkString $gesture)`",")
        $lines.Add("            `"script`",  `"$(ConvertTo-AhkString $a.Script)`")$comma")
    }

    $lines.Add('    )')
    ($lines -join "`r`n")
}

$ahk.Add(($buttonBlocks -join ",`r`n"))
$ahk.Add(')')
$ahk.Add('')

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $AhkOut) | Out-Null
Write-Utf8NoBom -Path $AhkOut -Content ($ahk -join "`r`n")

# --- docs/control-panel-entry-sheet.md --------------------------------------

$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# Swiftpoint Control Panel entry sheet')
$md.Add('')
$md.Add('<!-- Generated by tools/generate.ps1 from config/bindings.json. Do not edit. -->')
$md.Add('')
$md.Add("Chord set ``$activeSet``. Each button emits one chord and nothing else; the relay resolves")
$md.Add('tap / double-tap / hold.')
$md.Add('')
$md.Add('## Chords to program')
$md.Add('')
$md.Add('| Button | Chord | Mode |')
$md.Add('|---|---|---|')
foreach ($b in $buttons) {
    $md.Add("| $($b.Label) | ``$($b.Display)`` | $($b.Mode) |")
}
$md.Add('')
$md.Add('## Resulting behaviour')
$md.Add('')
$md.Add('| Button | Gesture | Action |')
$md.Add('|---|---|---|')
foreach ($b in $buttons) {
    $md.Add("| $($b.Label) | $($b.Gestures.Primary) | $($b.Primary.Label) |")
    $md.Add("| $($b.Label) | $($b.Gestures.Secondary) | $($b.Secondary.Label) |")
}
$md.Add('')
$md.Add('## Steps')
$md.Add('')
$md.Add('1. Control Panel, then **Expert Mode** (bottom left).')
$md.Add('2. Select the **Global Default** profile. Sub-profiles inherit it unless they override.')
$md.Add('3. For each button in the table above:')
$md.Add('   1. Click the button on the mouse diagram.')
$md.Add('   2. **+ Add mappings**, if it has none.')
$md.Add('   3. Click the output name (reads **Do Nothing**).')
$md.Add('   4. **Output Type**, then a keyboard output.')
$md.Add('   5. Enter the chord.')
$md.Add('4. Confirm the mappings are in onboard flash (automatic in Control Panel 3.1.1.0+).')
$md.Add('')

$holdButtons = @($buttons | Where-Object { $_.Mode -eq 'tapHold' })
if ($holdButtons.Count -gt 0) {
    $md.Add('## Buttons needing the chord held')
    $md.Add('')
    foreach ($b in $holdButtons) {
        $md.Add("**$($b.Label)** (``$($b.Display)``): ``tapHold`` measures how long the key is down, so the")
        $md.Add('chord must be pressed on **Press** and released on **Release**. Turn off **Auto-Release')
        $md.Add('Outputs** for this mapping.')
        $md.Add('')
        $md.Add("If that isn't possible, set this button's ``mode`` to ``""tapDouble""`` in")
        $md.Add("``config/bindings.json`` and re-run ``tools/generate.ps1``; ``$($b.Secondary.Label)``")
        $md.Add('then moves to a double tap.')
        $md.Add('')
    }
}

$md.Add('## If a button does nothing')
$md.Add('')
$md.Add('Run `pwsh -File tools/verify.ps1 -Test` and watch for a tooltip.')
$md.Add('')
$md.Add('- **Tooltip from the keyboard but not the mouse**: the Control Panel is not emitting the')
$md.Add('  chord. Its keyboard recorder cannot capture F13-F15 (no physical key), so pick them from')
$md.Add('  the key list. If F13-F24 are not offered, set `activeChordSet` to `"f9"` in')
$md.Add('  `config/bindings.json`, re-run `tools/generate.ps1`, and reprogram.')
$md.Add('- **Two tooltips from one gesture**: raise `timing.doubleTapMs`.')
$md.Add('- **Hold never triggers**: see the Auto-Release note above.')
$md.Add('')

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SheetOut) | Out-Null
Write-Utf8NoBom -Path $SheetOut -Content ($md -join "`r`n")

if (-not $Quiet) {
    Write-Host "Generated from config/bindings.json (chord set: $activeSet)" -ForegroundColor Green
    Write-Host '  relay/bindings.generated.ahk'
    Write-Host '  docs/control-panel-entry-sheet.md'
    Write-Host ''
    foreach ($b in $buttons) {
        Write-Host ("  {0,-12} {1,-24} {2} / {3}" -f $b.Label, $b.Display, $b.Primary.Label, $b.Secondary.Label)
    }
}
