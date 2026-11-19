# The validation stages behind Get-BindingModel. Each stage throws on the first
# problem it finds, and the stages run in a fixed order, so a broken config
# always reports the same error first.

# A profile's buttons with inheritance applied, as an ordered map of button id
# to the button object from the JSON. An inheritance cycle is reported rather
# than followed.
function Resolve-BindingProfile {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
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
    $inherits = Get-OptionalProperty -InputObject $entry -Name 'inherits'
    if ($inherits) {
        $base = Resolve-BindingProfile -Config $Config -Id $inherits -Visited ($Visited + $Id)
        foreach ($key in $base.Keys) { $result[$key] = $base[$key] }
    }
    foreach ($property in $entry.buttons.PSObject.Properties) {
        if ($property.Name.StartsWith('_')) { continue }
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Assert-BindingHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $version = Get-OptionalProperty -InputObject $Config -Name 'version'
    if ($version -ne 2) {
        throw "bindings.json version '$version' is not supported; version 2 is required."
    }
    if ((Get-PropertyName -InputObject $Config.chordSets) -notcontains $Config.activeChordSet) {
        throw "activeChordSet '$($Config.activeChordSet)' is not defined in chordSets."
    }
}

# Validates every action and returns them as an ordered map of id to a flat
# action object, in file order.
function ConvertTo-ActionModel {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$Config)

    $ids = Get-PropertyName -InputObject $Config.actions
    $model = [ordered]@{}
    foreach ($id in $ids) {
        $action = $Config.actions.$id
        $kind = Get-OptionalProperty -InputObject $action -Name 'kind'
        if ($script:ActionKinds -notcontains $kind) {
            throw "Action '$id' has unknown kind '$kind'. Expected: $($script:ActionKinds -join ', ')."
        }
        if (-not (Get-OptionalProperty -InputObject $action -Name 'label')) {
            throw "Action '$id' has no label."
        }

        $url = [string](Get-OptionalProperty -InputObject $action -Name 'url' -Default '')
        $targets = @(Get-OptionalProperty -InputObject $action -Name 'targets' -Default @())
        $layer = [ordered]@{}
        switch ($kind) {
            'openUrl' {
                # The relay's rule, plus no backslash: the URL is written into
                # the links example as JSON without escaping.
                if (-not (Test-SafeUrl -Url $url) -or $url.Contains('\')) {
                    throw "Action '$id' has url '$url'; an http(s) URL with no spaces, quotes or backslashes is required."
                }
            }
            'launch' {
                if ($targets.Count -eq 0) {
                    throw "Action '$id' is a launch with no targets."
                }
            }
            'layer' {
                $map = Get-OptionalProperty -InputObject $action -Name 'layer'
                if ($null -eq $map) { throw "Layer action '$id' has no 'layer' map." }
                foreach ($direction in Get-PropertyName -InputObject $map) {
                    if ($script:Directions -notcontains $direction) {
                        throw "Layer '$id' has unknown direction '$direction'. Expected: $($script:Directions -join ', ')."
                    }
                    $target = $map.$direction
                    if ($ids -notcontains $target) {
                        throw "Layer '$id' $direction points at unknown action '$target'."
                    }
                    if ($script:LeafKinds -notcontains $Config.actions.$target.kind) {
                        throw "Layer '$id' $direction points at '$target', a $($Config.actions.$target.kind); layers cannot nest."
                    }
                }
                foreach ($direction in $script:Directions) {
                    $layer[$direction] = [string](Get-OptionalProperty -InputObject $map -Name $direction -Default '')
                }
            }
        }

        $model[$id] = [pscustomobject]@{
            Id      = $id
            Kind    = $kind
            Label   = $action.label
            Url     = $url
            Local   = [bool](Get-OptionalProperty -InputObject $action -Name 'local' -Default $false)
            Targets = [string[]]$targets
            Layer   = $layer
        }
    }
    return $model
}

# Validates every profile against the fifteen physical buttons and returns the
# profiles in file order, each with its buttons flattened.
function ConvertTo-ProfileModel {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Actions
    )

    $physicalIds = @($script:PhysicalButtons.Id)
    $profiles = foreach ($entry in $Config.profiles) {
        $buttons = Resolve-BindingProfile -Config $Config -Id $entry.id

        $missing = @($physicalIds | Where-Object { -not $buttons.Contains($_) })
        $unknown = @($buttons.Keys | Where-Object { $physicalIds -notcontains $_ })
        if ($missing.Count -gt 0) { throw "Profile '$($entry.id)' does not define: $($missing -join ', ')." }
        if ($unknown.Count -gt 0) { throw "Profile '$($entry.id)' defines unknown buttons: $($unknown -join ', '). Expected: $($physicalIds -join ', ')." }

        $flat = [ordered]@{}
        foreach ($buttonId in $physicalIds) {
            $spec = $buttons[$buttonId]
            $relay = Get-OptionalProperty -InputObject $spec -Name 'relay'
            $native = Get-OptionalProperty -InputObject $spec -Name 'native'
            if (($null -ne $relay) -eq ($null -ne $native)) {
                throw "Profile '$($entry.id)' button '$buttonId' needs exactly one of 'native' or 'relay'."
            }
            if ($null -ne $relay -and -not $Actions.Contains([string]$relay)) {
                throw "Profile '$($entry.id)' button '$buttonId' references unknown action '$relay'."
            }
            $flat[$buttonId] = [pscustomobject]@{
                Relay  = [string]$relay
                Native = [string]$native
                Hold   = [bool](Get-OptionalProperty -InputObject $spec -Name 'hold' -Default $false)
                Label  = [string](Get-OptionalProperty -InputObject $spec -Name 'label' -Default $native)
            }
        }

        [pscustomobject]@{
            Id              = $entry.id
            Label           = $entry.label
            ControlPanel    = $entry.controlPanel
            App             = [string](Get-OptionalProperty -InputObject $entry -Name 'app' -Default '')
            AppHint         = [string](Get-OptionalProperty -InputObject $entry -Name 'appHint' -Default '')
            IsGlobalDefault = $entry.controlPanel -eq 'Global Default'
            Buttons         = $flat
        }
    }

    $defaults = @($profiles | Where-Object { $_.IsGlobalDefault })
    if ($defaults.Count -ne 1) {
        throw "Exactly one profile must have controlPanel 'Global Default'; found $($defaults.Count)."
    }
    return @($profiles)
}

# An action that no button and no layer reaches is dead configuration.
function Assert-ActionReachable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Actions,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelayActionId
    )

    $reached = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in $RelayActionId) {
        [void]$reached.Add($id)
        foreach ($target in $Actions[$id].Layer.Values) {
            if ($target) { [void]$reached.Add($target) }
        }
    }
    $orphans = @($Actions.Keys | Where-Object { -not $reached.Contains($_) })
    if ($orphans.Count -gt 0) {
        throw "Actions defined but unreachable from any button or layer: $($orphans -join ', ')."
    }
}

# Every chord set is validated, not only the active one, so a fallback cannot
# rot unnoticed.
function Assert-ChordSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelayActionId
    )

    foreach ($setName in Get-PropertyName -InputObject $Config.chordSets) {
        $set = $Config.chordSets.$setName
        $keys = Get-PropertyName -InputObject $set
        $extra = @($keys | Where-Object { $RelayActionId -notcontains $_ })
        $absent = @($RelayActionId | Where-Object { $keys -notcontains $_ })
        if ($absent.Count -gt 0) { throw "chordSet '$setName' has no chord for: $($absent -join ', ')." }
        if ($extra.Count -gt 0) { throw "chordSet '$setName' has chords for unbound actions: $($extra -join ', ')." }

        $seen = @{}
        foreach ($key in $keys) {
            $chord = $set.$key
            foreach ($modifier in @($chord.mods)) {
                if (-not $script:ModifierToAhk.Contains($modifier)) {
                    throw "Unknown modifier '$modifier' in chordSet '$setName'. Expected: $($script:ModifierToAhk.Keys -join ', ')."
                }
            }
            # Keys must be distinct, not merely chords: each key also carries a
            # release hotkey, which ignores modifiers.
            if ($seen.ContainsKey([string]$chord.key)) {
                throw "Chord collision in chordSet '$setName': '$key' and '$($seen[[string]$chord.key])' share $($chord.key)."
            }
            $seen[[string]$chord.key] = $key
        }
    }
}

# The scalar sections. Numbers are kept as parsed, so they render exactly as
# they are written in the JSON.
function ConvertTo-SettingModel {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Config)

    $shot = $Config.screenshot
    if (@('jpg', 'png') -notcontains $shot.format) { throw "screenshot.format '$($shot.format)' must be jpg or png." }

    $turn = $Config.turn
    if ($turn.counts -isnot [int] -and $turn.counts -isnot [long]) { throw 'turn.counts must be an integer.' }
    if ($turn.counts -eq 0) { throw 'turn.counts must be non-zero.' }
    if ($turn.steps -lt 1) { throw 'turn.steps must be at least 1.' }
    if ($turn.stepDelayMs -lt 0) { throw 'turn.stepDelayMs must be non-negative.' }

    return [pscustomobject]@{
        Timing     = [pscustomobject]@{
            RepeatWindowMs = $Config.timing.repeatWindowMs
            LayerTimeoutMs = $Config.timing.layerTimeoutMs
        }
        Relay      = [pscustomobject]@{
            RunHidden = [bool]$Config.relay.runHidden
            LogFile   = [string]$Config.relay.logFile
            LinksFile = [string]$Config.relay.linksFile
        }
        Screenshot = [pscustomobject]@{
            Script    = [string]$shot.script
            Format    = [string]$shot.format
            SaveDir   = [string]$shot.saveDir
            Clipboard = [bool]$shot.clipboard
        }
        Turn       = [pscustomobject]@{
            Counts      = $turn.counts
            Steps       = $turn.steps
            StepDelayMs = $turn.stepDelayMs
        }
    }
}

# Every place a relay action is bound, as "Profile: Button" joined with "; ".
function Get-ChordLocation {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object[]]$Profiles,
        [Parameter(Mandatory)][string]$ActionId
    )

    $places = foreach ($entry in $Profiles) {
        foreach ($button in $script:PhysicalButtons) {
            if ($entry.Buttons[$button.Id].Relay -eq $ActionId) { "$($entry.Label): $($button.Label)" }
        }
    }
    return (@($places) -join '; ')
}

# One chord per relay action, from the active chord set, in relay-action order.
function ConvertTo-ChordModel {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Actions,
        [Parameter(Mandatory)][object[]]$Profiles,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelayActionId
    )

    $chordSet = $Config.chordSets.($Config.activeChordSet)
    $chords = foreach ($id in $RelayActionId) {
        $chord = $chordSet.$id
        $mods = @($chord.mods)
        $prefix = ($mods | ForEach-Object { $script:ModifierToAhk[$_] }) -join ''

        # A chord with no modifiers takes the wildcard, so it still fires while
        # a game holds Ctrl (sprint) or Shift (sneak). A chord with modifiers
        # does not, since the wildcard would also swallow the plain key. The
        # release hotkey is always a wildcard: modifiers may be released first.
        $hotkey = if ($mods.Count -eq 0) { "*$($chord.key)" } else { "$prefix$($chord.key)" }

        # Modifiers are released in the reverse order of their press.
        $released = for ($i = $mods.Count - 1; $i -ge 0; $i--) { "{$($script:ModifierToSend[$mods[$i]]) up}" }

        [pscustomobject]@{
            Id       = $id
            Hotkey   = $hotkey
            UpHotkey = "~*$($chord.key) up"
            Display  = (@($mods) + @($chord.key)) -join ' + '
            Key      = $chord.key
            ModsDown = ($mods | ForEach-Object { "{$($script:ModifierToSend[$_]) down}" }) -join ''
            ModsUp   = @($released) -join ''
            Where    = Get-ChordLocation -Profiles $Profiles -ActionId $id
            Kind     = $Actions[$id].Kind
        }
    }

    $dupes = @($chords | Group-Object -Property Hotkey | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count -gt 0) {
        throw "Chord collision: $($dupes.Name -join ', ') is assigned to more than one action."
    }
    return @($chords)
}
