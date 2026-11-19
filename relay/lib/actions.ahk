; Included by swiftpoint-relay.ahk. What each action kind does.

; A URL itself is never logged: a local one may be private, and the log is not.
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

; The trailing backslash is stripped: before a closing quote it would escape
; the quote on the PowerShell command line.
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

; Moves the mouse by TURN["counts"] relative counts. MouseMove with "R" will
; not do: it sets an absolute position, which a game holding the cursor
; captured ignores. mouse_event injects a relative move, which raw input
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
