; Included by swiftpoint-relay.ahk. Resolves contest URLs against the
; gitignored overlay config\links.local.json.

; The parsed overlay, and a stamp of the version parsed.
LINKS := Map()
LINKS_STAMP := ""

; A local action takes its URL from the overlay when one is present and is a
; plain http(s) URL; otherwise the committed placeholder is used. Anything else
; is refused, since Run() would execute it.
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
        ; An absent file has already been reported once, as a whole.
        WarnOnce("missing:" id, "WARN  links: " id " missing, placeholder used")
    }
    origin := "placeholder"
    return action["url"]
}

; \z, not $: PCRE's $ also matches before a final newline. tools/ci.ps1 checks
; that this pattern matches the one in tools/SwiftpointConfig.
IsSafeUrl(url) {
    return RegExMatch(url, '^https?://[^\s"]+\z') > 0
}

; Re-reads the overlay only when its timestamp or size changes, so an edit
; takes effect on the next use with no reload. The generated example is a flat
; object of string values, so a pattern over "key": "value" pairs is enough
; and no JSON parser is needed.
LoadLocalLinks() {
    global RELAY, LINKS, LINKS_STAMP
    path := RepoPath(RELAY["linksFile"])
    stamp := FileExist(path) ? FileGetTime(path, "M") "/" FileGetSize(path) : "absent"
    if (stamp = LINKS_STAMP)
        return LINKS

    LINKS_STAMP := stamp
    LINKS := Map()
    ResetWarnings()
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
