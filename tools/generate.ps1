<#
.SYNOPSIS
    Generates relay/bindings.generated.ahk, docs/control-panel-entry-sheet.md and
    config/links.local.example.json from config/bindings.json. It is to be run
    after any edit to that file.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/_common.ps1"

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ConfigPath  = Join-Path $RepoRoot 'config/bindings.json'
$AhkOut      = Join-Path $RepoRoot 'relay/bindings.generated.ahk'
$SheetOut    = Join-Path $RepoRoot 'docs/control-panel-entry-sheet.md'
$ExampleOut  = Join-Path $RepoRoot 'config/links.local.example.json'

$LeafKinds   = @('captureScreen', 'launch', 'openUrl', 'turn')
$AllKinds    = $LeafKinds + @('layer')
$Directions  = @('left', 'right', 'up', 'down')
# \z, not $: in .NET, $ also matches before a final newline.
$UrlPattern  = '^https?://[^\s"\\]+\z'

# --- helpers ----------------------------------------------------------------

# AHK v2 escapes with a backtick and doubles quotes inside strings. Backslashes
# are literal, so Windows paths need no handling. Note that anything emitted
# into the relay is required to be ASCII; see the encoding note in tools/ci.ps1.
function ConvertTo-AhkString([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if (-not (Test-AsciiOnly $Value)) {
        throw "Non-ASCII text cannot be emitted into the relay: '$Value'. Spell it in ASCII (e.g. '180 degree', not the degree sign)."
    }
    # A raw line break would end the string literal and break the include.
    if ($Value -match '[\x00-\x1F\x7F]') {
        throw "Control characters cannot be emitted into the relay: '$($Value.Trim())'."
    }
    return $Value.Replace('`', '``').Replace('"', '""')
}

function ConvertTo-AhkBool($Value) {
    if ($Value) { return 'true' } else { return 'false' }
}

# The value of an optional property, or $Default when it is absent. Under
# StrictMode plain access to a missing property is a terminating error.
function Get-Prop($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and @($Object.PSObject.Properties.Name) -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

# The non-comment property names of a JSON object, in file order.
function Get-Key($Object) {
    return @($Object.PSObject.Properties.Name | Where-Object { -not $_.StartsWith('_') })
}

$ModifierToAhk  = [ordered]@{ 'Ctrl' = '^'; 'Alt' = '!'; 'Shift' = '+'; 'Win' = '#' }
$ModifierToSend = @{ 'Ctrl' = 'Ctrl'; 'Alt' = 'Alt'; 'Shift' = 'Shift'; 'Win' = 'LWin' }

# Emitted paths stay repo-relative; the relay resolves them against its own
# location at runtime. Note that an absolute path would bake one machine's
# layout into a committed file, so a clone would point at the author's home.
function ConvertTo-EmittedPath([string]$Relative) {
    return $Relative -replace '/', '\'
}

# --- load config ------------------------------------------------------------

if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$config     = Get-Content -Raw -Encoding UTF8 -LiteralPath $ConfigPath | ConvertFrom-Json
$sourceHash = Get-ConfigHash -Path $ConfigPath

if ((Get-Prop $config 'version') -ne 2) {
    throw "bindings.json version '$(Get-Prop $config 'version')' is not supported; version 2 is required."
}

$activeSet = $config.activeChordSet
if ((Get-Key $config.chordSets) -notcontains $activeSet) {
    throw "activeChordSet '$activeSet' is not defined in chordSets."
}

# --- actions ----------------------------------------------------------------

$actionIds = Get-Key $config.actions
foreach ($id in $actionIds) {
    $action = $config.actions.$id
    $kind   = Get-Prop $action 'kind'
    if ($AllKinds -notcontains $kind) {
        throw "Action '$id' has unknown kind '$kind'. Expected: $($AllKinds -join ', ')."
    }
    if (-not (Get-Prop $action 'label')) {
        throw "Action '$id' has no label."
    }
    switch ($kind) {
        'openUrl' {
            if ((Get-Prop $action 'url' '') -notmatch $UrlPattern) {
                throw "Action '$id' has url '$(Get-Prop $action 'url' '')'; an http(s) URL with no spaces, quotes or backslashes is required."
            }
        }
        'launch' {
            if (@(Get-Prop $action 'targets' @()).Count -eq 0) {
                throw "Action '$id' is a launch with no targets."
            }
        }
        'layer' {
            $layer = Get-Prop $action 'layer'
            if ($null -eq $layer) { throw "Layer action '$id' has no 'layer' map." }
            foreach ($direction in Get-Key $layer) {
                if ($Directions -notcontains $direction) {
                    throw "Layer '$id' has unknown direction '$direction'. Expected: $($Directions -join ', ')."
                }
                $target = $layer.$direction
                if ($actionIds -notcontains $target) {
                    throw "Layer '$id' $direction points at unknown action '$target'."
                }
                if ($LeafKinds -notcontains $config.actions.$target.kind) {
                    throw "Layer '$id' $direction points at '$target', a $($config.actions.$target.kind); layers cannot nest."
                }
            }
        }
    }
}

# --- profiles ---------------------------------------------------------------

$physicalIds = @((Get-PhysicalButton).Id)
$profileModel = foreach ($entry in $config.profiles) {
    $buttons = Resolve-BindingProfile -Config $config -Id $entry.id

    $missing = @($physicalIds | Where-Object { -not $buttons.Contains($_) })
    $unknown = @($buttons.Keys | Where-Object { $physicalIds -notcontains $_ })
    if ($missing.Count -gt 0) { throw "Profile '$($entry.id)' does not define: $($missing -join ', ')." }
    if ($unknown.Count -gt 0) { throw "Profile '$($entry.id)' defines unknown buttons: $($unknown -join ', '). Expected: $($physicalIds -join ', ')." }

    foreach ($buttonId in $physicalIds) {
        $spec     = $buttons[$buttonId]
        $hasRelay = $null -ne (Get-Prop $spec 'relay')
        $hasNative = $null -ne (Get-Prop $spec 'native')
        if ($hasRelay -eq $hasNative) {
            throw "Profile '$($entry.id)' button '$buttonId' needs exactly one of 'native' or 'relay'."
        }
        if ($hasRelay -and $actionIds -notcontains $spec.relay) {
            throw "Profile '$($entry.id)' button '$buttonId' references unknown action '$($spec.relay)'."
        }
    }

    [pscustomobject]@{
        Id           = $entry.id
        Label        = $entry.label
        ControlPanel = $entry.controlPanel
        App          = Get-Prop $entry 'app' ''
        AppHint      = Get-Prop $entry 'appHint' ''
        Buttons      = $buttons
    }
}

$defaults = @($profileModel | Where-Object { $_.ControlPanel -eq 'Global Default' })
if ($defaults.Count -ne 1) {
    throw "Exactly one profile must have controlPanel 'Global Default'; found $($defaults.Count)."
}
$globalDefault = $defaults[0]

$relayIds = @(Get-RelayActionId -Config $config)

# An action that no button and no layer reaches is dead configuration.
$reached = [System.Collections.Generic.HashSet[string]]::new()
foreach ($id in $relayIds) {
    [void]$reached.Add($id)
    if ($config.actions.$id.kind -eq 'layer') {
        foreach ($direction in Get-Key $config.actions.$id.layer) {
            [void]$reached.Add($config.actions.$id.layer.$direction)
        }
    }
}
$orphans = @($actionIds | Where-Object { -not $reached.Contains($_) })
if ($orphans.Count -gt 0) {
    throw "Actions defined but unreachable from any button or layer: $($orphans -join ', ')."
}

# --- chord sets -------------------------------------------------------------

# Every set is validated, not only the active one, so a fallback cannot rot.
foreach ($setName in Get-Key $config.chordSets) {
    $set  = $config.chordSets.$setName
    $keys = Get-Key $set
    $extra   = @($keys | Where-Object { $relayIds -notcontains $_ })
    $absent  = @($relayIds | Where-Object { $keys -notcontains $_ })
    if ($absent.Count -gt 0) { throw "chordSet '$setName' has no chord for: $($absent -join ', ')." }
    if ($extra.Count -gt 0)  { throw "chordSet '$setName' has chords for unbound actions: $($extra -join ', ')." }

    $seen = @{}
    foreach ($key in $keys) {
        $chord = $set.$key
        foreach ($m in @($chord.mods)) {
            if (-not $ModifierToAhk.Contains($m)) {
                throw "Unknown modifier '$m' in chordSet '$setName'. Expected: $($ModifierToAhk.Keys -join ', ')."
            }
        }
        # Keys are required to be distinct, not merely chords: each key also
        # carries a release hotkey, which ignores modifiers.
        if ($seen.ContainsKey([string]$chord.key)) {
            throw "Chord collision in chordSet '$setName': '$key' and '$($seen[[string]$chord.key])' share $($chord.key)."
        }
        $seen[[string]$chord.key] = $key
    }
}

$chords = $config.chordSets.$activeSet

# --- scalar sections --------------------------------------------------------

$shot = $config.screenshot
if (@('jpg', 'png') -notcontains $shot.format) { throw "screenshot.format '$($shot.format)' must be jpg or png." }

$turn = $config.turn
if ($turn.counts -isnot [int] -and $turn.counts -isnot [long]) { throw 'turn.counts must be an integer.' }
if ($turn.counts -eq 0)    { throw 'turn.counts must be non-zero.' }
if ($turn.steps -lt 1)     { throw 'turn.steps must be at least 1.' }
if ($turn.stepDelayMs -lt 0) { throw 'turn.stepDelayMs must be non-negative.' }

# --- chord model, shared by every output ------------------------------------

function Get-Where([string]$ActionId) {
    $places = foreach ($p in $profileModel) {
        foreach ($button in Get-PhysicalButton) {
            $spec = $p.Buttons[$button.Id]
            if ((Get-Prop $spec 'relay') -eq $ActionId) { "$($p.Label): $($button.Label)" }
        }
    }
    return (@($places) -join '; ')
}

$chordModel = foreach ($id in $relayIds) {
    $chord = $chords.$id
    $mods  = @($chord.mods)
    $prefix = ($mods | ForEach-Object { $ModifierToAhk[$_] }) -join ''

    # A chord with no modifiers takes the wildcard, so it still fires while the
    # game holds Ctrl (sprint) or Shift (sneak). A chord with modifiers does not:
    # a wildcard there would also swallow the plain key. Note that the release
    # hotkey is always a wildcard, since modifiers may be released first.
    $hotkey = if ($mods.Count -eq 0) { "*$($chord.key)" } else { "$prefix$($chord.key)" }

    # Modifiers are released in the reverse order of their press.
    $released = for ($i = $mods.Count - 1; $i -ge 0; $i--) { "{$($ModifierToSend[$mods[$i]]) up}" }

    [pscustomobject]@{
        Id       = $id
        Hotkey   = $hotkey
        UpHotkey = "~*$($chord.key) up"
        Display  = (@($mods) + @($chord.key)) -join ' + '
        Key      = $chord.key
        ModsDown = ($mods | ForEach-Object { "{$($ModifierToSend[$_]) down}" }) -join ''
        ModsUp   = @($released) -join ''
        Where    = Get-Where $id
        Kind     = $config.actions.$id.kind
    }
}

$dupes = $chordModel | Group-Object Hotkey | Where-Object { $_.Count -gt 1 }
if ($dupes) {
    throw "Chord collision: $($dupes.Name -join ', ') is assigned to more than one action."
}

# --- relay/bindings.generated.ahk -------------------------------------------

$nl  = "`r`n"
$ahk = [System.Collections.Generic.List[string]]::new()
# No timestamp anywhere in the output: generation is deterministic, so CI can
# byte-compare a fresh run against the committed files.
$ahk.Add('; Generated by tools/generate.ps1 from config/bindings.json. Do not edit.')
$ahk.Add(";   chord set: $activeSet")
$ahk.Add('')
$ahk.Add("BINDINGS_SOURCE_HASH := `"$sourceHash`"")
$ahk.Add('')
$ahk.Add('TIMING := Map(')
$ahk.Add("    `"repeatWindowMs`", $($config.timing.repeatWindowMs),")
$ahk.Add("    `"layerTimeoutMs`", $($config.timing.layerTimeoutMs))")
$ahk.Add('')
$ahk.Add('RELAY := Map(')
$ahk.Add("    `"runHidden`", $(ConvertTo-AhkBool $config.relay.runHidden),")
$ahk.Add("    `"logFile`",   `"$(ConvertTo-AhkString (ConvertTo-EmittedPath $config.relay.logFile))`",")
$ahk.Add("    `"linksFile`", `"$(ConvertTo-AhkString (ConvertTo-EmittedPath $config.relay.linksFile))`")")
$ahk.Add('')
$ahk.Add('SCREENSHOT := Map(')
$ahk.Add("    `"script`",    `"$(ConvertTo-AhkString (ConvertTo-EmittedPath $shot.script))`",")
$ahk.Add("    `"format`",    `"$(ConvertTo-AhkString $shot.format)`",")
$ahk.Add("    `"saveDir`",   `"$(ConvertTo-AhkString $shot.saveDir)`",")
$ahk.Add("    `"clipboard`", $(ConvertTo-AhkBool $shot.clipboard))")
$ahk.Add('')
$ahk.Add('TURN := Map(')
$ahk.Add("    `"counts`",      $($turn.counts),")
$ahk.Add("    `"steps`",       $($turn.steps),")
$ahk.Add("    `"stepDelayMs`", $($turn.stepDelayMs))")
$ahk.Add('')
$ahk.Add('ACTIONS := Map(')

$actionBlocks = foreach ($id in $actionIds) {
    $a = $config.actions.$id
    $fields = [System.Collections.Generic.List[string]]::new()
    $fields.Add("        `"kind`",  `"$(ConvertTo-AhkString $a.kind)`"")
    $fields.Add("        `"label`", `"$(ConvertTo-AhkString $a.label)`"")
    switch ($a.kind) {
        'openUrl' {
            $fields.Add("        `"url`",   `"$(ConvertTo-AhkString $a.url)`"")
            $fields.Add("        `"local`", $(ConvertTo-AhkBool (Get-Prop $a 'local' $false))")
        }
        'launch' {
            $targets = (@($a.targets) | ForEach-Object { "`"$(ConvertTo-AhkString $_)`"" }) -join ', '
            $fields.Add("        `"targets`", [$targets]")
        }
        'layer' {
            foreach ($direction in $Directions) {
                $fields.Add("        `"$direction`", `"$(ConvertTo-AhkString (Get-Prop $a.layer $direction ''))`"")
            }
        }
    }
    "    `"$(ConvertTo-AhkString $id)`", Map($nl" + ($fields -join ",$nl") + ')'
}
$ahk.Add(($actionBlocks -join ",$nl"))
$ahk.Add(')')
$ahk.Add('')
$ahk.Add('BINDINGS := Map(')

$bindingBlocks = foreach ($c in $chordModel) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("    `"$(ConvertTo-AhkString $c.Hotkey)`", Map(")
    $lines.Add("        `"id`",       `"$(ConvertTo-AhkString $c.Id)`",")
    $lines.Add("        `"hotkey`",   `"$(ConvertTo-AhkString $c.Hotkey)`",")
    $lines.Add("        `"upHotkey`", `"$(ConvertTo-AhkString $c.UpHotkey)`",")
    $lines.Add("        `"display`",  `"$(ConvertTo-AhkString $c.Display)`",")
    $lines.Add("        `"key`",      `"$(ConvertTo-AhkString $c.Key)`",")
    $lines.Add("        `"modsDown`", `"$(ConvertTo-AhkString $c.ModsDown)`",")
    $lines.Add("        `"modsUp`",   `"$(ConvertTo-AhkString $c.ModsUp)`",")
    $lines.Add("        `"where`",    `"$(ConvertTo-AhkString $c.Where)`")")
    ($lines -join $nl)
}
$ahk.Add(($bindingBlocks -join ",$nl"))
$ahk.Add(')')
$ahk.Add('')

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $AhkOut) | Out-Null
Write-Utf8NoBom -Path $AhkOut -Content ($ahk -join $nl)

# --- config/links.local.example.json ----------------------------------------

# It is guaranteed that every URL here passed $UrlPattern, so none needs JSON
# escaping, and that the generator never reads links.local.json itself.
$localIds = @($actionIds | Where-Object {
    $config.actions.$_.kind -eq 'openUrl' -and (Get-Prop $config.actions.$_ 'local' $false)
})
$json = [System.Collections.Generic.List[string]]::new()
$json.Add('{')
$json.Add('  "_comment": "Generated by tools/generate.ps1. Copy to config/links.local.json (gitignored) and replace each placeholder with the real URL. Note that browser is optional: the full path of the browser linked to the Contest Management profile, so that a link does not move focus to another browser.",')
# The separators are joined, not appended, so that no entry is left with a
# trailing comma when there are no local links at all.
$entries = @('  "browser": ""') + @($localIds | ForEach-Object { "  `"$_`": `"$($config.actions.$_.url)`"" })
$json.Add(($entries -join ",$nl"))
$json.Add('}')
$json.Add('')
Write-Utf8NoBom -Path $ExampleOut -Content ($json -join $nl)

# --- docs/control-panel-entry-sheet.md --------------------------------------

function Get-NativeKey($Spec) {
    if ($null -eq $Spec) { return '' }
    $relay = Get-Prop $Spec 'relay'
    if ($relay) { return "relay|$relay" }
    return "native|$(Get-Prop $Spec 'native')|$(Get-Prop $Spec 'hold' $false)"
}

function Get-Program($Spec) {
    $relay = Get-Prop $Spec 'relay'
    if ($relay) {
        return "Keyboard: ``$(($chordModel | Where-Object Id -eq $relay).Display)``"
    }
    $native = Get-Prop $Spec 'native'
    if (Get-Prop $Spec 'hold' $false) { return "$native (held)" }
    return $native
}

function Get-AutoRelease($Spec) {
    $relay = Get-Prop $Spec 'relay'
    if ($relay) {
        if ($config.actions.$relay.kind -eq 'layer') { return '**Off**' } else { return 'On' }
    }
    if (Get-Prop $Spec 'hold' $false) { return '**Off**' }
    if ((Get-Prop $Spec 'native') -like 'Keyboard:*') { return 'On' }
    return '-'
}

function Get-Result($Spec, [string]$ButtonId) {
    $relay = Get-Prop $Spec 'relay'
    $text = if ($relay) { $config.actions.$relay.label } else { Get-Prop $Spec 'label' (Get-Prop $Spec 'native') }
    if ($relay -and $config.actions.$relay.kind -eq 'layer') {
        $text += '; see the scroll layers below'
    } elseif ($ButtonId -like '*TriggerPush') {
        $text += '; scroll layer unassigned'
    }
    return $text
}

$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# Swiftpoint Control Panel entry sheet')
$md.Add('')
$md.Add('<!-- Generated by tools/generate.ps1 from config/bindings.json. Do not edit. -->')
$md.Add('')
$md.Add("Chord set ``$activeSet``. A button marked **Keyboard: F..** emits that one key and nothing")
$md.Add('else; the relay resolves it. Every other button is programmed natively and never reaches the')
$md.Add('relay. Note that each relay key is unique across all profiles, so the relay need not know')
$md.Add('which profile is active.')
$md.Add('')
$md.Add('## Profiles')
$md.Add('')
$md.Add('| Profile | Control Panel profile | Linked app |')
$md.Add('|---|---|---|')
foreach ($p in $profileModel) {
    $app = if ($p.App) { "``$($p.App)``" }
           elseif ($p.AppHint) { "$($p.AppHint) (your choice)" }
           else { 'none: active wherever no sub-profile is' }
    $md.Add("| $($p.Label) | $($p.ControlPanel) | $app |")
}
$md.Add('')

foreach ($p in $profileModel) {
    $md.Add("## $($p.Label)")
    $md.Add('')
    if ($p -ne $globalDefault) {
        $md.Add("Sub-profile. A row marked *inherited* matches $($globalDefault.Label) and is left alone.")
        $md.Add('')
    }
    $md.Add('| Button | Program in Control Panel | Auto-Release Outputs | Result |')
    $md.Add('|---|---|---|---|')
    foreach ($button in Get-PhysicalButton) {
        $spec = $p.Buttons[$button.Id]
        if ($p -ne $globalDefault -and (Get-NativeKey $spec) -eq (Get-NativeKey $globalDefault.Buttons[$button.Id])) {
            $md.Add("| $($button.Label) | *inherited* | | $(Get-Result $spec $button.Id) |")
        } else {
            $md.Add("| $($button.Label) | $(Get-Program $spec) | $(Get-AutoRelease $spec) | $(Get-Result $spec $button.Id) |")
        }
    }
    $md.Add('')
}

$layers = @($chordModel | Where-Object Kind -eq 'layer')
if ($layers.Count -gt 0) {
    $md.Add('## Scroll layers')
    $md.Add('')
    $md.Add('While the trigger is held the wheel no longer scrolls: each direction opens its link at most')
    $md.Add('once per hold, and releasing the trigger produces no output. To repeat a direction, release')
    $md.Add('and push again.')
    $md.Add('')
    $md.Add('| Trigger held | Scroll left | Scroll right | Scroll forward | Scroll back |')
    $md.Add('|---|---|---|---|---|')
    foreach ($c in $layers) {
        $layer = $config.actions.$($c.Id).layer
        $cells = foreach ($direction in $Directions) {
            $target = Get-Prop $layer $direction
            if ($target) { $config.actions.$target.label } else { 'unassigned' }
        }
        $md.Add("| $($c.Where) (``$($c.Display)``) | $($cells -join ' | ') |")
    }
    $md.Add('')
}

$md.Add('## Steps')
$md.Add('')
$md.Add('1. Control Panel, then **Expert Mode** (bottom left).')
$md.Add("2. Select **Global Default** and program it from the **$($globalDefault.Label)** table.")
$md.Add('3. For each sub-profile: create it, link it to the app in the Profiles table, then program')
$md.Add('   every row not marked *inherited*.')
$md.Add('4. To program a button:')
$md.Add('   1. Click the button on the mouse diagram.')
$md.Add('   2. **+ Add mappings**, if it has none.')
$md.Add('   3. Click the output name (reads **Do Nothing**).')
$md.Add('   4. **Output Type**, then a keyboard or mouse output.')
$md.Add('   5. Enter the output. Note that the keyboard recorder cannot capture F13-F24 (no physical')
$md.Add('      key), so pick them from the key list.')
$md.Add('   6. Set **Auto-Release Outputs** as the table says.')
$md.Add('5. Confirm the mappings are in onboard flash (automatic in Control Panel 3.1.1.0+).')
$md.Add('')
$md.Add('## Held outputs')
$md.Add('')
$md.Add('A row with Auto-Release **Off** must press its output on **Press** and release it on')
$md.Add('**Release**. A held game key (sneak, sprint) depends on this, and so does a scroll layer:')
$md.Add('the relay leaves the layer only when the key goes up. With Auto-Release on, a layer trigger')
$md.Add('reads as an instant press and release, and the wheel keeps scrolling the page.')
$md.Add('')

$turnIds = @($chordModel | Where-Object Kind -eq 'turn')
if ($turnIds.Count -gt 0) {
    $md.Add('## Calibrating the 180 degree turn')
    $md.Add('')
    $md.Add("The turn moves the mouse by ``turn.counts`` = $($turn.counts) relative counts. Note that the")
    $md.Add('angle depends on the in-game sensitivity, so a change of sensitivity requires recalibration.')
    $md.Add('')
    $md.Add('1. Minecraft, **Options > Controls > Mouse Settings**: **Raw Input** on.')
    $md.Add('2. Press **F3** and note the yaw in the **Facing** line.')
    $md.Add('3. Press the turn button, and note the new yaw. Let *d* be the angle turned, in 0..360.')
    $md.Add('4. Set `turn.counts` to round(counts * 180 / *d*), run `tools/generate.ps1`, then')
    $md.Add('   tray icon > **Reload**.')
    $md.Add('')
}

$md.Add('## Contest links')
$md.Add('')
$md.Add('`config/bindings.json` holds placeholders only, since the repository is public. The real')
$md.Add('URLs go in `config/links.local.json`, which is gitignored:')
$md.Add('')
$md.Add('1. Copy `config/links.local.example.json` to `config/links.local.json`.')
$md.Add('2. Replace each placeholder. A key left out falls back to its placeholder, and the relay')
$md.Add('   logs a warning once.')
$md.Add('3. Optionally set `browser` to the full path of the browser linked to Contest Management.')
$md.Add('   Note that a link opened in a different browser moves focus there, and the profile')
$md.Add('   switches off.')
$md.Add('')
$md.Add('The relay re-reads the file on its next use; no reload is needed.')
$md.Add('')
$md.Add('## If a button does nothing')
$md.Add('')
$md.Add('Run `pwsh -File tools/verify.ps1 -Test` and watch for a tooltip.')
$md.Add('')
$md.Add('- **The selftest passes but the mouse shows no tooltip**: the Control Panel is not emitting')
$md.Add('  the key. If F13-F24 are not offered in its key list, set `activeChordSet` to')
$md.Add('  `"ctrlAltShift"` in `config/bindings.json`, re-run `tools/generate.ps1`, reload the relay')
$md.Add('  (tray icon > **Reload**), and reprogram. Note that the relay reads its bindings only when')
$md.Add('  it starts.')
$md.Add('- **The page scrolls while a layer trigger is held**: Auto-Release Outputs is on for that')
$md.Add('  trigger. Turn it off.')
$md.Add('- **A contest button opens a placeholder** (a `.example` page, or a Discord link with')
$md.Add('  `_ID` in it): its key is missing from `config/links.local.json`, or still holds the value')
$md.Add('  copied from the example.')
$md.Add('- **A native button acts in the wrong profile**: the sub-profile is not linked to the')
$md.Add('  focused app. Check the exe name in Task Manager, Details tab.')
$md.Add('')

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SheetOut) | Out-Null
Write-Utf8NoBom -Path $SheetOut -Content ($md -join $nl)

if (-not $Quiet) {
    Write-Host "Generated from config/bindings.json (chord set: $activeSet)" -ForegroundColor Green
    Write-Host '  relay/bindings.generated.ahk'
    Write-Host '  docs/control-panel-entry-sheet.md'
    Write-Host '  config/links.local.example.json'
    Write-Host ''
    foreach ($c in $chordModel) {
        Write-Host ("  {0,-26} {1,-16} {2}" -f $c.Display, $c.Id, $c.Where)
    }
}
