; Swiftpoint Creator relay.
; Each mouse button sends one fixed chord; this resolves tap / double-tap / hold.
;
; Run:  AutoHotkey.exe relay\swiftpoint-relay.ahk
; Test: AutoHotkey.exe relay\swiftpoint-relay.ahk --test    (tooltip only, no actions)

#Requires AutoHotkey v2.0
#SingleInstance Force
#Include %A_ScriptDir%\bindings.generated.ahk

Persistent()

; Paths in bindings.generated.ahk are repo-relative so the generated file stays
; machine-independent. This script lives in relay/, one level below the root.
REPO_ROOT := RegExReplace(A_ScriptDir, "\\[^\\]+$")

TEST_MODE := false
for arg in A_Args {
    if (arg = "--test" || arg = "-t")
        TEST_MODE := true
}

; chord -> timer callback waiting to see whether a second tap arrives
PENDING := Map()

InitTray()
RegisterHotkeys()
WriteLog("relay started (test=" (TEST_MODE ? "on" : "off") ", chords=" BINDINGS.Count ")")

; ---------------------------------------------------------------------------

RegisterHotkeys() {
    global BINDINGS
    for chord, cfg in BINDINGS
        Hotkey(chord, MakeChordHandler(chord))
}

; Capture the chord in a closure. AHK normalises the hotkey name it hands the
; callback, and any mismatch would be a silent lookup failure.
MakeChordHandler(chord) {
    return (*) => OnChord(chord)
}

OnChord(chord) {
    global BINDINGS
    if (!BINDINGS.Has(chord))
        return
    cfg := BINDINGS[chord]
    if (cfg["mode"] = "tapHold")
        HandleTapHold(chord, cfg)
    else
        HandleTapDouble(chord, cfg)
}

; Needs the chord held for as long as the button is held, so Auto-Release
; Outputs must be off in the Control Panel. Fires on release.
HandleTapHold(chord, cfg) {
    global TIMING
    start := A_TickCount
    KeyWait(cfg["base"], "T5")          ; T5 so a stuck key can't wedge the thread
    held := A_TickCount - start
    Fire(cfg, held >= TIMING["holdMs"] ? "secondary" : "primary")
}

; Defer the tap action; a second press inside the window cancels it.
; Not the A_PriorHotkey idiom: that fires the tap action first and the
; double-tap action second, which would run two scaffolds.
HandleTapDouble(chord, cfg) {
    global PENDING, TIMING
    if (PENDING.Has(chord)) {
        SetTimer(PENDING[chord], 0)
        PENDING.Delete(chord)
        Fire(cfg, "secondary")
        return
    }
    callback := () => OnSingleTapElapsed(chord)
    PENDING[chord] := callback
    SetTimer(callback, -TIMING["doubleTapMs"])
}

OnSingleTapElapsed(chord) {
    global PENDING, BINDINGS
    if (!PENDING.Has(chord))
        return
    PENDING.Delete(chord)
    Fire(BINDINGS[chord], "primary")
}

; ---------------------------------------------------------------------------

Fire(cfg, which) {
    global TEST_MODE
    action := cfg[which]

    if (TEST_MODE) {
        ShowTip(cfg["label"] "  —  " action["gesture"] "`n" action["label"])
        WriteLog("TEST  " cfg["id"] " / " action["gesture"] " -> " action["label"])
        return
    }

    WriteLog(cfg["id"] " / " action["gesture"] " -> " action["label"])

    switch action["action"] {
        case "scaffold":       RunScaffold(action)
        case "snipScreenshot": SnipScreenshot()
        case "snipRecord":     SnipRecord()
        default:               WriteLog("ERROR unknown action: " action["action"])
    }
}

RunScaffold(action) {
    global RELAY
    script := RepoPath(action["script"])
    if (!FileExist(script)) {
        Notify("Scaffold script missing", script)
        WriteLog("ERROR missing script: " script)
        return
    }
    command := Format('"{1}" -NoProfile -ExecutionPolicy Bypass -File "{2}"', PwshPath(), script)
    try {
        Run(command, , RELAY["runHidden"] ? "Hide" : "")
    } catch as err {
        Notify("Scaffold failed to launch", err.Message)
        WriteLog("ERROR launching " script ": " err.Message)
    }
}

; The chord's own Ctrl/Alt/Shift can still be down here; sending Win+Shift+S
; underneath them produces a different combination.
WaitModifiersUp() {
    global TIMING
    timeout := "T" (TIMING["modifierReleaseMs"] / 1000)
    for key in ["Ctrl", "Alt", "Shift", "LWin"]
        KeyWait(key, timeout)
}

SnipScreenshot() {
    global SNIP, TIMING
    WaitModifiersUp()
    Send("#+s")

    ; With the overlay's mode set to Full screen by hand, the keystroke above is
    ; the whole macro. forceMode drives the Alt+M menu instead.
    if (!SNIP["forceMode"])
        return

    Sleep(TIMING["snipOverlayMs"])
    Send("!m")
    Sleep(TIMING["snipMenuMs"])
    Loop (SNIP["modeIndex"])     ; parenthesised so it parses as a count, not a Loop sub-command
        Send("{Right}")
    Send("{Enter}")
}

; Win+Shift+R toggles, so the same gesture starts and stops.
SnipRecord() {
    WaitModifiersUp()
    Send("#+r")
}

; ---------------------------------------------------------------------------

RepoPath(relative) {
    global REPO_ROOT
    return REPO_ROOT "\" relative
}

PwshPath() {
    static cached := ""
    if (cached != "")
        return cached
    for candidate in [A_ProgramFiles "\PowerShell\7\pwsh.exe",
                      EnvGet("LOCALAPPDATA") "\Microsoft\WindowsApps\pwsh.exe"] {
        if (FileExist(candidate)) {
            cached := candidate
            return cached
        }
    }
    cached := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
    return cached
}

; Not named Log: AHK v2 has a built-in Log() and the name is unusable.
WriteLog(message) {
    global RELAY
    try {
        logFile := RepoPath(RELAY["logFile"])
        directory := RegExReplace(logFile, "\\[^\\]+$")
        if (directory != "" && !DirExist(directory))
            DirCreate(directory)
        FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "  " message "`n", logFile, "UTF-8")
    } catch {
    }
}

ShowTip(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -1800)
}

Notify(title, message) {
    TrayTip(message, title)
}

ShowBindings() {
    global BINDINGS, TEST_MODE
    lines := "Swiftpoint Creator relay" (TEST_MODE ? "  [TEST MODE]" : "") "`n`n"
    for chord, cfg in BINDINGS {
        lines .= cfg["label"] "   (" cfg["display"] ")`n"
        lines .= "    " cfg["primary"]["gesture"] "  ->  " cfg["primary"]["label"] "`n"
        lines .= "    " cfg["secondary"]["gesture"] "  ->  " cfg["secondary"]["label"] "`n`n"
    }
    MsgBox(lines, "Bindings", "Iconi")
}

OpenLog() {
    global RELAY
    logFile := RepoPath(RELAY["logFile"])
    if (FileExist(logFile))
        Run('notepad.exe "' logFile '"')
    else
        Notify("No log yet", logFile)
}

InitTray() {
    global TEST_MODE
    A_IconTip := "Swiftpoint Creator Relay" (TEST_MODE ? " [TEST]" : "")
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Swiftpoint Creator Relay", (*) => 0)
    tray.Disable("Swiftpoint Creator Relay")
    tray.Add()
    tray.Add("Show bindings", (*) => ShowBindings())
    tray.Add("Open log", (*) => OpenLog())
    tray.Add()
    tray.Add("Reload", (*) => Reload())
    tray.Add("Exit", (*) => ExitApp())
    tray.Default := "Show bindings"
}
