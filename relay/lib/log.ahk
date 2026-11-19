; Included by swiftpoint-relay.ahk. The log file, one-off warnings, and
; on-screen feedback.

; Warnings already logged, by key, so each is written once.
WARNED := Map()

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

WarnOnce(key, message) {
    global WARNED
    if (WARNED.Has(key))
        return
    WARNED[key] := true
    WriteLog(message)
}

; Forgets which warnings were logged, so they can be logged again.
ResetWarnings() {
    global WARNED
    WARNED := Map()
}

ShowTip(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -1800)
}

Notify(title, message) {
    TrayTip(message, title)
}
