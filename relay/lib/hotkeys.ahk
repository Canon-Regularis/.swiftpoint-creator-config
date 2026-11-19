; Included by swiftpoint-relay.ahk. Registers the chord and wheel hotkeys and
; turns key presses into actions.

; chord -> tick of the last press seen, cleared on release. A press inside
; TIMING["repeatWindowMs"] of the last one is key auto-repeat, not a new press.
DOWN_AT := Map()

RegisterHotkeys() {
    global BINDINGS, ACTIONS
    hasLayer := false
    for chord, cfg in BINDINGS {
        Hotkey(cfg["hotkey"], MakeDownHandler(chord))
        Hotkey(cfg["upHotkey"], MakeUpHandler(chord))
        if (ACTIONS[cfg["id"]]["kind"] = "layer")
            hasLayer := true
    }
    ; The wheel is intercepted only while a layer is held. When the condition is
    ; false the event passes through untouched, so scrolling elsewhere is
    ; unaffected.
    if (hasLayer) {
        HotIf(LayerActive)
        for name in ["WheelUp", "WheelDown", "WheelLeft", "WheelRight"]
            Hotkey("*" name, MakeWheelHandler(name))
        HotIf()
    }
}

; The chord is captured in a closure. AHK normalises the hotkey name it hands
; the callback, and any mismatch would be a silent lookup failure.
MakeDownHandler(chord) {
    return (*) => OnChordDown(chord)
}

MakeUpHandler(chord) {
    return (*) => OnChordUp(chord)
}

MakeWheelHandler(name) {
    return (*) => OnLayerWheel(name)
}

; Every handler below starts with Critical, so it runs to completion before the
; next key or wheel event is handled. A thread becomes interruptible after
; 15ms, and a log write can take longer than that, so without it a release
; could be handled halfway through the press before it.

; Every action fires on press. A held key auto-repeats its press, so a press
; within the repeat window of the last one only refreshes the timers. If the
; release is ever lost, a press after the window is treated as new.
OnChordDown(chord) {
    global BINDINGS, ACTIONS, DOWN_AT, TIMING, ACTIVE_LAYER, LAYER_DEADLINE
    Critical
    now := A_TickCount
    if (DOWN_AT.Has(chord) && now - DOWN_AT[chord] < TIMING["repeatWindowMs"]) {
        DOWN_AT[chord] := now
        if (ACTIVE_LAYER = chord)
            LAYER_DEADLINE := now + TIMING["layerTimeoutMs"]
        return
    }
    DOWN_AT[chord] := now

    cfg := BINDINGS[chord]
    if (ACTIONS[cfg["id"]]["kind"] = "layer")
        EnterLayer(chord)
    else
        Fire(cfg["id"], cfg["display"])
}

OnChordUp(chord) {
    global DOWN_AT, ACTIVE_LAYER
    Critical
    if (DOWN_AT.Has(chord))
        DOWN_AT.Delete(chord)
    if (ACTIVE_LAYER = chord)
        ReleaseLayer()
}
