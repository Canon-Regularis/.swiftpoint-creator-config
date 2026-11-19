; Relay selftest. Drives every chord and every scroll layer synthetically, and
; prints one "EXPECT <line>" to stdout for each TEST line the relay must log in
; return. tools/ci.ps1 compares the two, in order and in number.
;
; Run:  AutoHotkey.exe /ErrorStdOut tools\relay-selftest.ahk --relay-in-test-mode
;
; It is required that the relay is already running with --test. In normal mode
; these keys would launch real apps, open real links and turn the mouse, so the
; script refuses to run without the flag.

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include %A_ScriptDir%\..\relay\bindings.generated.ahk

confirmed := false
for arg in A_Args {
    if (arg = "--relay-in-test-mode")
        confirmed := true
}
if (!confirmed) {
    FileAppend("refused: start the relay with --test, then pass --relay-in-test-mode`n", "**")
    ExitApp(2)
}

; Both are needed, or nothing fires and there is no error: at send level 0 the
; relay's hotkeys ignore input from another script, and a chord's modifiers are
; recognised only as real down/up events.
SendMode("Event")
SendLevel(1)

; The relay's keyboard and mouse hooks are installed on a thread of their own,
; so they may still be starting when its start line is logged. A press sent
; before then is lost silently.
Sleep(1000)

Expect(line) {
    FileAppend("EXPECT " line "`n", "*")
}

Gap() {
    Sleep(70)
}

; A press, two auto-repeats and a release. The relay must ignore the repeats,
; so exactly one line is expected per chord.
PressHeld(cfg) {
    Send(cfg["modsDown"] "{" cfg["key"] " down}")
    Gap()
    Loop 2 {
        Send("{" cfg["key"] " down}")
        Gap()
    }
    Send("{" cfg["key"] " up}" cfg["modsUp"])
    Gap()
}

wildcardDone := false
for chord, cfg in BINDINGS {
    if (ACTIONS[cfg["id"]]["kind"] = "layer")
        continue
    PressHeld(cfg)
    Expect(cfg["display"] " -> " cfg["id"])

    ; The first chord without modifiers is pressed once more under a held
    ; LCtrl, as a game holds it for sprint, to prove the wildcard.
    if (!wildcardDone && cfg["modsDown"] = "") {
        wildcardDone := true
        Send("{LCtrl down}")
        Gap()
        PressHeld(cfg)
        Send("{LCtrl up}")
        Gap()
        Expect(cfg["display"] " -> " cfg["id"])
    }
}

; Each layer: trigger down, three wheel events per direction (only the first of
; which may fire), trigger up, then one wheel event that must pass through and
; produce nothing.
wheels := [["left", "WheelLeft"], ["right", "WheelRight"], ["up", "WheelUp"], ["down", "WheelDown"]]
for chord, cfg in BINDINGS {
    layer := ACTIONS[cfg["id"]]
    if (layer["kind"] != "layer")
        continue
    Send(cfg["modsDown"] "{" cfg["key"] " down}")
    Expect("layer " cfg["display"] " on")
    Gap()
    for pair in wheels {
        Loop 3 {
            Send("{" pair[2] "}")
            Gap()
        }
        if (layer[pair[1]] != "")
            Expect(cfg["display"] "/" pair[1] " -> " layer[pair[1]])
    }
    Send("{" cfg["key"] " up}" cfg["modsUp"])
    Expect("layer " cfg["display"] " off (release)")
    Gap()
    Send("{WheelDown}")
    Gap()
}

; Overlapping layers: the first trigger held, the second pushed and released
; over it. It is required that the first layer resumes, fresh, on that release.
layerChords := []
for chord, cfg in BINDINGS {
    if (ACTIONS[cfg["id"]]["kind"] = "layer")
        layerChords.Push(cfg)
}
if (layerChords.Length >= 2) {
    first := layerChords[1]
    second := layerChords[2]
    Send(first["modsDown"] "{" first["key"] " down}")
    Expect("layer " first["display"] " on")
    Gap()
    Send(second["modsDown"] "{" second["key"] " down}")
    Expect("layer " first["display"] " off (superseded)")
    Expect("layer " second["display"] " on")
    Gap()
    Send("{WheelUp}")
    if (ACTIONS[second["id"]]["up"] != "")
        Expect(second["display"] "/up -> " ACTIONS[second["id"]]["up"])
    Gap()
    Send("{" second["key"] " up}" second["modsUp"])
    Expect("layer " second["display"] " off (release)")
    Expect("layer " first["display"] " on")
    Gap()
    Send("{WheelUp}")
    if (ACTIONS[first["id"]]["up"] != "")
        Expect(first["display"] "/up -> " ACTIONS[first["id"]]["up"])
    Gap()
    Send("{" first["key"] " up}" first["modsUp"])
    Expect("layer " first["display"] " off (release)")
    Gap()
}

; The relay handles each event on its own thread; this leaves it time to log
; the last of them before the caller reads the log.
Sleep(1500)
ExitApp(0)
