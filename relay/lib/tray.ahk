; Included by swiftpoint-relay.ahk. The tray icon and its menu.

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
