; Included by swiftpoint-relay.ahk. Repository paths and the interpreter the
; relay runs PowerShell scripts with.

; Paths in bindings.generated.ahk are repo-relative, so the generated file stays
; machine-independent. A_ScriptDir is the entry script's folder, relay\, one
; level below the root, even inside this include.
REPO_ROOT := RegExReplace(A_ScriptDir, "\\[^\\]+$")

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

; PowerShell 7 when present, otherwise Windows PowerShell 5.1. Mirrored by
; Find-PowerShell in tools/SwiftpointConfig, so the checks use the same one.
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
