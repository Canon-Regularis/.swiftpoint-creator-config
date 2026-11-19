; Swiftpoint Creator relay.
; Each relay button emits one fixed key; this script maps it to an action.
; Every other button is programmed natively in the Control Panel and never
; reaches it.
;
; Run:  AutoHotkey.exe relay\swiftpoint-relay.ahk
; Test: AutoHotkey.exe relay\swiftpoint-relay.ahk --test    (tooltip only, no actions)
;
; The code lives in lib\. Each include holds functions and the state they own,
; and no include's initial state depends on another's, so their order does not
; matter.

#Requires AutoHotkey v2.0
#SingleInstance Force
#Include %A_ScriptDir%\bindings.generated.ahk
#Include %A_ScriptDir%\lib\paths.ahk
#Include %A_ScriptDir%\lib\log.ahk
#Include %A_ScriptDir%\lib\links.ahk
#Include %A_ScriptDir%\lib\actions.ahk
#Include %A_ScriptDir%\lib\layers.ahk
#Include %A_ScriptDir%\lib\hotkeys.ahk
#Include %A_ScriptDir%\lib\tray.ahk

Persistent()

; A held layer trigger auto-repeats at about 30 presses per second, and a fast
; wheel spin adds as many again. Under the default limit (70 per 2s) AHK would
; interrupt with a modal warning, so the limit is raised well clear of both.
A_MaxHotkeysPerInterval := 1000
A_HotkeyInterval := 2000

TEST_MODE := false
for arg in A_Args {
    if (arg = "--test" || arg = "-t")
        TEST_MODE := true
}

if (TEST_MODE) {
    ; KeyHistory records nothing without the hooks. The README's troubleshooting
    ; and verify.ps1 -Test both point to it, to see what the mouse sends.
    InstallKeybdHook()
    InstallMouseHook()
}

InitTray()
RegisterHotkeys()
WriteLog("relay started (test=" (TEST_MODE ? "on" : "off") ", chords=" BINDINGS.Count
    ", layers=" CountLayers() ", links=" LinksSummary() ")")
