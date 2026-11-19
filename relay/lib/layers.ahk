; Included by swiftpoint-relay.ahk. Scroll layers: while a layer trigger is
; held, every wheel event is swallowed, and each direction fires its action at
; most once per hold. Releasing the trigger produces no output.

; The chord of the held layer trigger, or "" when no layer is active. Tracked
; here rather than read with GetKeyState: a hooked hotkey does not update the
; logical key state, and the physical state ignores the injected input the
; selftest relies on.
ACTIVE_LAYER := ""
LAYER_FIRED := Map()
LAYER_DEADLINE := 0

LayerActive(*) {
    global ACTIVE_LAYER
    return ACTIVE_LAYER != ""
}

; Makes chord the active layer. A layer already active is replaced in the same
; step, and logged as off for the given reason.
;
; State is changed before anything is logged. AHK evaluates the wheel's HotIf
; between statements, so if ACTIVE_LAYER were blank for even the length of a
; log write, a wheel event arriving then would pass through and scroll.
EnterLayer(chord, replacedReason := "superseded") {
    global ACTIVE_LAYER, LAYER_FIRED, LAYER_DEADLINE, TIMING, BINDINGS, TEST_MODE
    previous := ACTIVE_LAYER
    ACTIVE_LAYER := chord
    LAYER_FIRED := Map()
    LAYER_DEADLINE := A_TickCount + TIMING["layerTimeoutMs"]
    SetTimer(LayerWatchdog, 250)
    if (previous != "" && previous != chord)
        LogLayer(previous, "off (" replacedReason ")")
    LogLayer(chord, "on")
    if (TEST_MODE)
        ShowTip(BINDINGS[chord]["where"] "`nlayer on")
}

ExitLayer(reason) {
    global ACTIVE_LAYER
    if (ACTIVE_LAYER = "")
        return
    chord := ACTIVE_LAYER
    ACTIVE_LAYER := ""
    SetTimer(LayerWatchdog, 0)
    LogLayer(chord, "off (" reason ")")
}

; Called when the active layer's trigger is released. A second layer trigger
; pushed while the first is held takes the layer over; if the first is still
; held when the second is released, its layer is required to resume.
ReleaseLayer() {
    next := HeldLayer()
    if (next != "")
        EnterLayer(next, "release")
    else
        ExitLayer("release")
}

; The most recently pressed layer trigger still held, or "". Windows repeats
; only the most recently pressed key, so an earlier trigger sends no further
; press; the press it last recorded counts as held for as long as a layer may
; sit idle.
HeldLayer() {
    global DOWN_AT, BINDINGS, ACTIONS, TIMING
    best := ""
    for chord, at in DOWN_AT {
        if (ACTIONS[BINDINGS[chord]["id"]]["kind"] != "layer")
            continue
        if (A_TickCount - at >= TIMING["layerTimeoutMs"])
            continue
        if (best = "" || at > DOWN_AT[best])
            best := chord
    }
    return best
}

LogLayer(chord, state) {
    global BINDINGS, TEST_MODE
    WriteLog((TEST_MODE ? "TEST  " : "") "layer " BINDINGS[chord]["display"] " " state)
}

OnLayerWheel(name) {
    global ACTIVE_LAYER, LAYER_FIRED, LAYER_DEADLINE, TIMING, BINDINGS, ACTIONS
    static directions := Map("WheelUp", "up", "WheelDown", "down", "WheelLeft", "left", "WheelRight", "right")
    Critical    ; see the note in hotkeys.ahk
    if (ACTIVE_LAYER = "")
        return
    LAYER_DEADLINE := A_TickCount + TIMING["layerTimeoutMs"]

    direction := directions[name]
    cfg := BINDINGS[ACTIVE_LAYER]
    target := ACTIONS[cfg["id"]][direction]
    if (target = "" || LAYER_FIRED.Has(direction))
        return
    LAYER_FIRED[direction] := true
    Fire(target, cfg["display"] "/" direction)
}

; If the release of a layer trigger is lost, the wheel would stay captured
; everywhere. A layer that sees neither a wheel event nor a key repeat for
; TIMING["layerTimeoutMs"] is therefore left, and the loss is logged.
LayerWatchdog() {
    global ACTIVE_LAYER, LAYER_DEADLINE, DOWN_AT, BINDINGS
    Critical    ; see the note in hotkeys.ahk
    if (ACTIVE_LAYER = "" || A_TickCount < LAYER_DEADLINE)
        return
    chord := ACTIVE_LAYER
    WriteLog("WARN  layer " BINDINGS[chord]["display"] " timed out (release missed)")
    if (DOWN_AT.Has(chord))
        DOWN_AT.Delete(chord)
    ExitLayer("timeout")
}

CountLayers() {
    global BINDINGS, ACTIONS
    count := 0
    for chord, cfg in BINDINGS {
        if (ACTIONS[cfg["id"]]["kind"] = "layer")
            count++
    }
    return count
}
