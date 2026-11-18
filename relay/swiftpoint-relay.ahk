; Swiftpoint Creator relay.
; Each relay button emits one fixed key; this script maps it to an action. Note
; that every other button is programmed natively in the Control Panel and never
; reaches this script.
;
; Run:  AutoHotkey.exe relay\swiftpoint-relay.ahk
; Test: AutoHotkey.exe relay\swiftpoint-relay.ahk --test    (tooltip only, no actions)

#Requires AutoHotkey v2.0
#SingleInstance Force
#Include %A_ScriptDir%\bindings.generated.ahk

Persistent()

; A held layer trigger auto-repeats at about 30 presses per second, and a fast
; wheel spin adds as many again. Under the default limit (70 per 2s) AHK would
; interrupt with a modal warning, so the limit is raised well clear of both.
A_MaxHotkeysPerInterval := 1000
A_HotkeyInterval := 2000

; Paths in bindings.generated.ahk are repo-relative, so the generated file stays
; machine-independent. It is guaranteed that this script lives in relay/, one
; level below the root.
REPO_ROOT := RegExReplace(A_ScriptDir, "\\[^\\]+$")

TEST_MODE := false
for arg in A_Args {
    if (arg = "--test" || arg = "-t")
        TEST_MODE := true
}

; chord -> tick of the last press seen, cleared on release. A press inside
; TIMING["repeatWindowMs"] of the last one is key auto-repeat, not a new press.
DOWN_AT := Map()

; The chord of the held layer trigger, or "" when no layer is active. Note that
; this is tracked here rather than read with GetKeyState: a hooked hotkey does
; not update the logical key state, and the physical state ignores the
; injected input the selftest relies on.
ACTIVE_LAYER := ""
LAYER_FIRED := Map()
LAYER_DEADLINE := 0

; Local links overlay: the parsed file, a stamp of the version parsed, and the
; warnings already logged for it.
LINKS := Map()
LINKS_STAMP := ""
WARNED := Map()

if (TEST_MODE) {
    ; KeyHistory records nothing without the hooks. Note that the README's
    ; troubleshooting and verify.ps1 -Test both direct the user to it, to see
    ; what the mouse actually sends.
    InstallKeybdHook()
    InstallMouseHook()
}

InitTray()
RegisterHotkeys()
WriteLog("relay started (test=" (TEST_MODE ? "on" : "off") ", chords=" BINDINGS.Count
    ", layers=" CountLayers() ", links=" LinksSummary() ")")

; ---------------------------------------------------------------------------

RegisterHotkeys() {
    global BINDINGS, ACTIONS
    hasLayer := false
    for chord, cfg in BINDINGS {
        Hotkey(cfg["hotkey"], MakeDownHandler(chord))
        Hotkey(cfg["upHotkey"], MakeUpHandler(chord))
        if (ACTIONS[cfg["id"]]["kind"] = "layer")
            hasLayer := true
    }
    ; The wheel is intercepted only while a layer is held. Note that when the
    ; condition is false the event passes through untouched, so scrolling
    ; elsewhere is unaffected.
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

; Every action fires on press. A held key auto-repeats its press, so a press
; within the repeat window of the last one only refreshes the timers. Should
; the release ever be lost, a press after the window is treated as new.
OnChordDown(chord) {
    global BINDINGS, ACTIONS, DOWN_AT, TIMING, ACTIVE_LAYER, LAYER_DEADLINE
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
    if (DOWN_AT.Has(chord))
        DOWN_AT.Delete(chord)
    if (ACTIVE_LAYER = chord) {
        ExitLayer("release")
        ResumeHeldLayer()
    }
}

; ---------------------------------------------------------------------------
; Scroll layers. While a layer trigger is held, every wheel event is swallowed,
; and each direction fires its action at most once per hold. Releasing the
; trigger produces no output.

LayerActive(*) {
    global ACTIVE_LAYER
    return ACTIVE_LAYER != ""
}

EnterLayer(chord) {
    global ACTIVE_LAYER, LAYER_FIRED, LAYER_DEADLINE, TIMING, BINDINGS, TEST_MODE
    if (ACTIVE_LAYER != "" && ACTIVE_LAYER != chord)
        ExitLayer("superseded")
    ACTIVE_LAYER := chord
    LAYER_FIRED := Map()
    LAYER_DEADLINE := A_TickCount + TIMING["layerTimeoutMs"]
    SetTimer(LayerWatchdog, 250)
    WriteLog((TEST_MODE ? "TEST  " : "") "layer " BINDINGS[chord]["display"] " on")
    if (TEST_MODE)
        ShowTip(BINDINGS[chord]["where"] "`nlayer on")
}

ExitLayer(reason) {
    global ACTIVE_LAYER, BINDINGS, TEST_MODE
    if (ACTIVE_LAYER = "")
        return
    chord := ACTIVE_LAYER
    ACTIVE_LAYER := ""
    SetTimer(LayerWatchdog, 0)
    WriteLog((TEST_MODE ? "TEST  " : "") "layer " BINDINGS[chord]["display"] " off (" reason ")")
}

; A second layer trigger pushed while the first is held takes the layer over.
; Should the first still be held when the second is released, its layer is
; required to resume. Note that Windows repeats only the most recently pressed
; key, so the first trigger sends no further press that could restore it; the
; press it last recorded counts as held for as long as a layer may sit idle.
ResumeHeldLayer() {
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
    if (best != "")
        EnterLayer(best)
}

OnLayerWheel(name) {
    global ACTIVE_LAYER, LAYER_FIRED, LAYER_DEADLINE, TIMING, BINDINGS, ACTIONS
    static directions := Map("WheelUp", "up", "WheelDown", "down", "WheelLeft", "left", "WheelRight", "right")
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

; Should the release of a layer trigger be lost, the wheel would stay captured
; everywhere. A layer that sees neither a wheel event nor a key repeat for
; TIMING["layerTimeoutMs"] is therefore left, and the loss is logged.
LayerWatchdog() {
    global ACTIVE_LAYER, LAYER_DEADLINE, DOWN_AT, BINDINGS
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

; ---------------------------------------------------------------------------

; Note that a URL itself is never logged: a local one may be private, and the
; log is not.
Fire(id, source) {
    global ACTIONS, TEST_MODE
    action := ACTIONS[id]

    url := ""
    suffix := ""
    if (action["kind"] = "openUrl") {
        url := ResolveUrl(id, action, &origin)
        if (action["local"])
            suffix := " (" origin ")"
    }

    if (TEST_MODE) {
        ShowTip(source "`n" action["label"] suffix)
        WriteLog("TEST  " source " -> " id suffix)
        return
    }

    WriteLog(source " -> " id suffix)

    switch action["kind"] {
        case "captureScreen": CaptureScreen()
        case "launch":        LaunchApp(action)
        case "openUrl":       OpenUrl(action, url)
        case "turn":          TurnAround()
        default:              WriteLog("ERROR unknown action kind: " action["kind"])
    }
}

; Launches a PowerShell script from the repo.
RunRepoScript(relativeScript, extraArgs := "") {
    global RELAY
    script := RepoPath(relativeScript)
    if (!FileExist(script)) {
        Notify("Script missing", script)
        WriteLog("ERROR missing script: " script)
        return
    }
    command := Format('"{1}" -NoProfile -ExecutionPolicy Bypass -File "{2}"{3}', PwshPath(), script, extraArgs)
    try {
        Run(command, , RELAY["runHidden"] ? "Hide" : "")
    } catch as err {
        Notify("Failed to launch", err.Message)
        WriteLog("ERROR launching " script ": " err.Message)
    }
}

; Note that the trailing backslash is stripped: before a closing quote it would
; escape the quote on the PowerShell command line.
CaptureScreen() {
    global SCREENSHOT
    extra := " -Format " SCREENSHOT["format"]
    if (SCREENSHOT["saveDir"] != "")
        extra .= Format(' -SaveDir "{1}"', RTrim(SCREENSHOT["saveDir"], "\"))
    if (!SCREENSHOT["clipboard"])
        extra .= " -NoClipboard"
    RunRepoScript(SCREENSHOT["script"], extra)
}

; The first target that launches wins. A target with a backslash is a path and
; is tried only when the file exists; a bare name is left to Windows to find.
LaunchApp(action) {
    for target in action["targets"] {
        path := ExpandEnv(target)
        if (InStr(path, "\") && !FileExist(path))
            continue
        try {
            Run(InStr(path, " ") ? '"' path '"' : path)
            return
        } catch {
            continue
        }
    }
    Notify("Nothing to launch", action["label"])
    WriteLog("ERROR no target of '" action["label"] "' could be launched")
}

OpenUrl(action, url) {
    browser := ""
    if (action["local"]) {
        links := LoadLocalLinks()
        if (links.Has("browser") && links["browser"] != "") {
            browser := ExpandEnv(links["browser"])
            if (!FileExist(browser)) {
                WarnOnce("browser", "WARN  links: browser not found, default browser used")
                browser := ""
            }
        }
    }
    try {
        if (browser != "")
            Run('"' browser '" "' url '"')
        else
            Run(url)
    } catch as err {
        Notify("Failed to open link", action["label"])
        WriteLog("ERROR opening '" action["label"] "': " err.Message)
    }
}

; A local action takes its URL from the overlay when one is present and is a
; plain http(s) URL; otherwise the committed placeholder is used. Note that
; anything else is refused, since Run() would execute it.
ResolveUrl(id, action, &origin) {
    global LINKS_STAMP
    if (!action["local"]) {
        origin := "fixed"
        return action["url"]
    }
    links := LoadLocalLinks()
    if (links.Has(id)) {
        if (IsSafeUrl(links[id])) {
            origin := "local"
            return links[id]
        }
        WarnOnce("bad:" id, "WARN  links: " id " is not an http(s) URL, placeholder used")
    } else if (LINKS_STAMP != "absent") {
        ; Note that an absent file has already been reported once, as a whole.
        WarnOnce("missing:" id, "WARN  links: " id " missing, placeholder used")
    }
    origin := "placeholder"
    return action["url"]
}

; \z, not $: PCRE's $ also matches before a final newline.
IsSafeUrl(url) {
    return RegExMatch(url, '^https?://[^\s"]+\z') > 0
}

; Re-reads the overlay only when its timestamp or size changes, so an edit
; takes effect on the next use with no reload. It is guaranteed by the
; generated example that the file is a flat object of string values, so a
; pattern over "key": "value" pairs suffices and no JSON parser is needed.
LoadLocalLinks() {
    global RELAY, LINKS, LINKS_STAMP, WARNED
    path := RepoPath(RELAY["linksFile"])
    stamp := FileExist(path) ? FileGetTime(path, "M") "/" FileGetSize(path) : "absent"
    if (stamp = LINKS_STAMP)
        return LINKS

    LINKS_STAMP := stamp
    LINKS := Map()
    WARNED := Map()
    if (stamp = "absent") {
        WarnOnce("file", "WARN  links: " RELAY["linksFile"] " absent, placeholders used")
        return LINKS
    }
    try {
        text := FileRead(path, "UTF-8")
    } catch as err {
        WriteLog("ERROR links: " err.Message)
        return LINKS
    }
    pos := 1
    while (pos := RegExMatch(text, '"([^"\\]+)"\s*:\s*"((?:[^"\\]|\\.)*)"', &m, pos)) {
        if (SubStr(m[1], 1, 1) != "_")
            LINKS[m[1]] := JsonUnescape(m[2])
        pos += m.Len
    }
    return LINKS
}

JsonUnescape(text) {
    text := StrReplace(text, "\\", Chr(1))
    text := StrReplace(text, '\"', '"')
    text := StrReplace(text, "\/", "/")
    return StrReplace(text, Chr(1), "\")
}

LinksSummary() {
    global ACTIONS
    links := LoadLocalLinks()
    total := 0
    found := 0
    for id, action in ACTIONS {
        if (action["kind"] = "openUrl" && action["local"]) {
            total++
            if (links.Has(id))
                found++
        }
    }
    return found "/" total " local"
}

WarnOnce(key, message) {
    global WARNED
    if (WARNED.Has(key))
        return
    WARNED[key] := true
    WriteLog(message)
}

; Moves the mouse by TURN["counts"] relative counts. Note that MouseMove with
; "R" is unsuitable: it sets an absolute position, which a game holding the
; cursor captured ignores. mouse_event injects a relative move, which raw input
; reports to the game as genuine motion.
TurnAround() {
    global TURN
    steps := Max(1, TURN["steps"])
    counts := TURN["counts"]
    per := Integer(counts / steps)
    Loop steps {
        dx := per + (A_Index = steps ? counts - per * steps : 0)
        DllCall("mouse_event", "UInt", 0x0001, "Int", dx, "Int", 0, "UInt", 0, "UPtr", 0)
        if (A_Index < steps && TURN["stepDelayMs"] > 0)
            Sleep(TURN["stepDelayMs"])
    }
}

; ---------------------------------------------------------------------------

RepoPath(relative) {
    global REPO_ROOT
    return REPO_ROOT "\" relative
}

; Expands %NAME% references from the environment, as the config's launch
; targets and the overlay's browser path use them.
ExpandEnv(text) {
    pos := 1
    while (pos := RegExMatch(text, "%([^%]+)%", &m, pos)) {
        value := EnvGet(m[1])
        text := SubStr(text, 1, pos - 1) value SubStr(text, pos + m.Len)
        pos += StrLen(value)
    }
    return text
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

; Not named Log: AHK v2 has a built-in Log(), so the name is unusable.
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
    global BINDINGS, ACTIONS, TEST_MODE
    lines := "Swiftpoint Creator relay" (TEST_MODE ? "  [TEST MODE]" : "") "`n`n"
    for chord, cfg in BINDINGS {
        action := ACTIONS[cfg["id"]]
        lines .= cfg["display"] "   " cfg["where"] "`n"
        lines .= "    ->  " action["label"] "`n"
        if (action["kind"] = "layer") {
            for direction in ["left", "right", "up", "down"] {
                if (action[direction] != "")
                    lines .= "        scroll " direction ":  " ACTIONS[action[direction]]["label"] "`n"
            }
        }
    }
    lines .= "`nContest links: " LinksSummary()
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
    if (TEST_MODE)
        tray.Add("Key history", (*) => KeyHistory())
    tray.Add()
    tray.Add("Reload", (*) => Reload())
    tray.Add("Exit", (*) => ExitApp())
    tray.Default := "Show bindings"
}
