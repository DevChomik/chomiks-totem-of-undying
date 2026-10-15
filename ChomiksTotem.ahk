#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
ListLines(false)
KeyHistory(0)

;@Ahk2Exe-SetName Chomik's Totem of Undying
;@Ahk2Exe-SetDescription Chomik's Totem of Undying
;@Ahk2Exe-SetVersion 1.0.0
;@Ahk2Exe-SetMainIcon angel.ico
;@Ahk2Exe-AddResource logo.jpg
;@Ahk2Exe-AddResource icon.png

; ============================================================================
;  Chomik's Totem of Undying
;  When you join a Sol's RNG server that isn't your own private server, it
;  presses your macro's STOP key so the macro can't post biomes from there.
;  Reads Roblox's logs + launch command only - never touches the game.
;
;  Build: angel.ico, logo.jpg and icon.png next to this file, then compile
;  with Ahk2Exe using the v2 AutoHotkey64.exe base.
; ============================================================================

APP := "Chomik's Totem of Undying"
SOLS_PLACE_ID := "15532962292"
LOG_DIR := EnvGet("LOCALAPPDATA") "\Roblox\logs"
INI := A_AppData "\Chomik's Totem\settings.ini"
C_BG := "17181C", C_PANEL := "22242A", C_TEXT := "E8E6E3", C_DIM := "8A8F98"
C_GOLD := "F2C230", C_GREEN := "3DDC84"

; ------------------------------------------------------------------ state --
Armed := false, Popped := false, LastPopAt := 0, PopNote := ""
Known := Map()          ; every log file seen (to spot new Roblox windows)
Watch := Map()          ; logs being read -> bytes already read
Grew := Map()           ; log -> when it last grew
ProcInfo := Map()       ; log -> launch info of its Roblox window
JoinSeen := Map()       ; log -> a join already happened in it
MyJobs := Map()         ; job IDs known to be your server
LastLaunchType := "", LaunchAccessCode := "", Teleporting := false
CurrentJob := "", JoinCode := "", InSols := false, LastMine := false, LastPrivate := false

DirCreate(A_AppData "\Chomik's Totem")
MyCode := IniRead(INI, "Settings", "MyServerCode", "")

; -------------------------------------------------------------------- GUI --
A_IconTip := APP
g := Gui("-MaximizeBox", APP)
g.BackColor := C_BG, g.MarginX := 18, g.MarginY := 16
try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 20, "int*", 1, "int", 4)

if (logo := LoadLogo(260, 121))
    g.AddPicture("xm+90 ym w260 h121", "HBITMAP:" logo)
g.SetFont("s20 bold c" C_GOLD, "Segoe UI")
g.AddText("xm y+6 w440 Center", "Totem of Undying")
g.SetFont("s10 norm c" C_DIM)
g.AddText("xm y+0 w440 Center", "by Chomik  •  keeps you from getting banned")

g.SetFont("s17 bold")
statusTxt := g.AddText("xm y+20 w440 h46 Center +0x200 Background" C_PANEL)
g.SetFont("s9 norm")
statusSub := g.AddText("xm y+0 w440 h40 Center Background" C_PANEL)
g.SetFont("s10 bold c" C_TEXT)
armBtn := g.AddButton("xm y+10 w440 h34")
armBtn.OnEvent("Click", (*) => (Popped || !Armed) ? Arm() : Disarm())

g.SetFont("s9 bold c" C_GOLD)
g.AddText("xm y+18 w440", "YOUR MACRO'S STOP KEY")
g.SetFont("s10 norm c" C_TEXT)
stopHK := g.AddHotkey("xm y+8 w150 h26", IniRead(INI, "Settings", "StopKey", "F2"))
stopHK.OnEvent("Change", (*) => (IniWrite(stopHK.Value, INI, "Settings", "StopKey"), UpdateStatus()))
testBtn := g.AddButton("x+10 yp-1 w150 h28", "Test (sends in 3s)")
testBtn.OnEvent("Click", TestKey)

g.SetFont("s9 bold c" C_GOLD)
g.AddText("xm y+18 w440", "DISCORD WEBHOOK (OPTIONAL)")
g.SetFont("s9 norm c" C_TEXT)
hookEdit := g.AddEdit("xm y+8 w440 h24 -E0x200 Background" C_PANEL, CleanWebhook(IniRead(INI, "Settings", "Webhook", "")))
hookEdit.OnEvent("LoseFocus", SaveWebhook)

for hwnd, ctl in g                                  ; dark buttons/scrollbars
    if (ctl.Type = "Button" || ctl.Type = "Edit")
        try DllCall("uxtheme\SetWindowTheme", "ptr", hwnd, "str", "DarkMode_Explorer", "ptr", 0)
focusSink := g.AddEdit("x0 y0 w0 h0")               ; stray keys can't hit Arm
g.OnEvent("Close", (*) => (SaveWebhook(), ExitApp()))
g.Show("AutoSize")
focusSink.Focus()

; ------------------------------------------------------------------ start --
InitLogs()
UpdateStatus()                                      ; starts disarmed
SetTimer(Tick, 250)
try DllCall("psapi\EmptyWorkingSet", "ptr", -1)     ; drop start-up memory

; ===================================================================== UI ==
Arm() {
    global Armed := true, Popped := false, MyCode, LastMine
    ; No server saved yet: the one you're in when you arm becomes yours.
    if (MyCode = "" && InSols) {
        MyJobs[CurrentJob] := true, LastMine := true
        if (JoinCode != "")
            MyCode := JoinCode, IniWrite(MyCode, INI, "Settings", "MyServerCode")
    }
    UpdateStatus()
}

Disarm() {
    global Armed := false, Popped := false
    UpdateStatus()
}

UpdateStatus() {
    SetStateIcon(Popped ? "popped" : Armed ? "armed" : "off")
    if Popped {
        statusTxt.SetFont("c" C_GOLD), statusTxt.Value := "✦  TOTEM POPPED  ✦"
        statusSub.Value := PopNote "`nClick Re-arm when you're back in your server."
        armBtn.Text := "Re-arm"
    } else if Armed {
        statusTxt.SetFont("c" C_GREEN), statusTxt.Value := "●  ARMED"
        statusSub.Value := "Pops when you change servers (presses " KeyName(stopHK.Value) ")."
            . (MyCode != "" || LastMine ? "" : "`nYour server isn't set - join it and click Re-arm.")
        armBtn.Text := "Disarm"
    } else {
        statusTxt.SetFont("c" C_DIM), statusTxt.Value := "○  DISARMED"
        statusSub.Value := "Not protecting you right now.`nClick Arm once you're in your server."
        armBtn.Text := "Arm"
    }
}

; Counts down 3-2-1, then presses the stop key so you can check your macro
; stops (and that the webhook works).
TestKey(*) {
    testBtn.Enabled := false
    Countdown(3)
    Countdown(n) {
        if n {
            testBtn.Text := "Pressing in " n "..."
            SetTimer(() => Countdown(n - 1), -1000)
            return
        }
        SendStopKey()
        testBtn.Text := "Pressed " KeyName(stopHK.Value)
        SetTimer(() => SendWebhook("Totem test", "Pressed your macro's stop key ("
            . KeyName(stopHK.Value) ").", C_GREEN), -1)
        SetTimer(() => (testBtn.Text := "Test (sends in 3s)", testBtn.Enabled := true), -2000)
    }
}

; "^+F2" -> "Ctrl+Shift+F2"
KeyName(hk) {
    if (hk = "")
        return "no key set"
    out := ""
    while (hk != "" && (p := InStr("^!+#", SubStr(hk, 1, 1))))
        out .= ["Ctrl+", "Alt+", "Shift+", "Win+"][p], hk := SubStr(hk, 2)
    return out StrUpper(SubStr(hk, 1, 1)) SubStr(hk, 2)
}

; Keeps just the first webhook URL if one was pasted twice.
CleanWebhook(s) {
    s := Trim(s)
    return RegExMatch(s, "https://[\w.]*discord(?:app)?\.com/api/webhooks/\d+/[\w-]+?(?=https://|\s|$)", &m) ? m[0] : s
}

SaveWebhook(*) => IniWrite(hookEdit.Value, INI, "Settings", "Webhook")

; ========================================================== status icons ==
; The chomik with a status dot in the bottom-right corner: red = off,
; green = armed, yellow = popped. Used for the title bar, taskbar and tray.
SetStateIcon(state) {
    static current := "", small := Map(), big := 0, pad := ""
        , colors := Map("off", 0xFFE53935, "armed", 0xFF2ECC71, "popped", 0xFFFFC83D)
    if (state = current)
        return
    current := state
    if !small.Has(state)
        small[state] := MakeIcon(Round(16 * A_ScreenDPI / 96), colors[state])
    if !small[state]
        return
    ; The taskbar only redraws a button for an icon handle it hasn't seen,
    ; so the big icon is made fresh each time (and the old one freed).
    old := big, big := MakeIcon(Round(32 * A_ScreenDPI / 96), colors[state])
    SendMessage(0x80, 0, small[state], g)           ; WM_SETICON small: title bar
    SendMessage(0x80, 1, big, g)                    ; WM_SETICON big: taskbar, Alt+Tab
    if old
        DllCall("DestroyIcon", "ptr", old)
    TraySetIcon("HICON:*" small[state])
    pad := pad ? "" : " "                           ; invisible title change =
    DllCall("SetWindowText", "ptr", g.Hwnd, "str", APP pad)   ; taskbar redraws
}

MakeIcon(size, dot) {
    if !(bmp := DrawImage("icon.png", size, size, &gfx))
        return 0
    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", gfx, "int", 4)              ; anti-aliased
    d := size * 0.5, x := size - d - 0.5, ring := Max(1, size / 12)
    for i, argb in [0xFFFFFFFF, dot] {                                  ; white, then the colour
        inset := (i - 1) * ring
        DllCall("gdiplus\GdipCreateSolidFill", "uint", argb, "ptr*", &brush := 0)
        DllCall("gdiplus\GdipFillEllipse", "ptr", gfx, "ptr", brush, "float", x + inset, "float", x + inset
            , "float", d - 2 * inset, "float", d - 2 * inset)
        DllCall("gdiplus\GdipDeleteBrush", "ptr", brush)
    }
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", gfx)
    DllCall("gdiplus\GdipCreateHICONFromBitmap", "ptr", bmp, "ptr*", &hIcon := 0)
    DllCall("gdiplus\GdipDisposeImage", "ptr", bmp)
    return hIcon
}

; ================================================================ images ==
; Bytes of a file built into the exe (or next to the script when it isn't
; compiled), or 0 if it's missing.
ResData(name) {
    static RT_RCDATA := 10
    if !A_IsCompiled
        return FileExist(A_ScriptDir "\" name) ? FileRead(A_ScriptDir "\" name, "RAW") : 0
    if !(res := DllCall("FindResource", "ptr", 0, "str", StrUpper(name), "ptr", RT_RCDATA, "ptr"))
        return 0
    size := DllCall("SizeofResource", "ptr", 0, "ptr", res, "uint")
    data := DllCall("LockResource", "ptr", DllCall("LoadResource", "ptr", 0, "ptr", res, "ptr"), "ptr")
    buf := Buffer(size)
    DllCall("RtlMoveMemory", "ptr", buf, "ptr", data, "uptr", size)
    return buf
}

; A built-in image drawn (high quality) onto a new transparent w x h GDI+
; bitmap. Returns the bitmap, and its graphics in gfx for drawing on top;
; the caller frees both. Decoded images are kept for reuse.
DrawImage(name, w, h, &gfx) {
    static started := false, decoded := Map()
    if !started {
        DllCall("LoadLibrary", "str", "gdiplus", "ptr")
        si := Buffer(24, 0), NumPut("uint", 1, si)
        started := !DllCall("gdiplus\GdiplusStartup", "ptr*", &token := 0, "ptr", si, "ptr", 0)
    }
    if !decoded.Has(name) {
        src := 0     ; the stream stays alive with the bitmap (GDI+ reads it lazily)
        if (data := ResData(name)) && (stream := DllCall("shlwapi\SHCreateMemStream", "ptr", data, "uint", data.Size, "ptr"))
            DllCall("gdiplus\GdipCreateBitmapFromStream", "ptr", stream, "ptr*", &src)
        decoded[name] := src
    }
    if !decoded[name]
        return 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &bmp := 0)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", bmp, "ptr*", &gfx := 0)
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", gfx, "int", 7)           ; high-quality bicubic
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", gfx, "int", 4)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", gfx, "ptr", decoded[name], "int", 0, "int", 0, "int", w, "int", h)
    return bmp
}

; The logo at the exact pixel size for this screen's scaling (stays sharp).
LoadLogo(w, h) {
    w := Round(w * A_ScreenDPI / 96), h := Round(h * A_ScreenDPI / 96)
    if !(bmp := DrawImage("logo.jpg", w, h, &gfx))
        return 0
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", gfx)
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", bmp, "ptr*", &hbm := 0, "uint", 0xFF000000 | ("0x" C_BG))
    DllCall("gdiplus\GdipDisposeImage", "ptr", bmp)
    return hbm
}

; =============================================================== the pop ==
Pop(reason) {
    global Armed, Popped, LastPopAt, PopNote
    if (!Armed || A_TickCount - LastPopAt < 10000)
        return
    LastPopAt := A_TickCount
    SendStopKey()                                   ; first - every ms counts
    Armed := false, Popped := true
    PopNote := FormatTime(, "HH:mm:ss") " - " reason ", pressed " KeyName(stopHK.Value) "."
    UpdateStatus()
    SetTimer(() => SendWebhook("Totem popped", "Pressed your macro's stop key (" KeyName(stopHK.Value)
        . ") because " reason ".`nRe-arm the totem once you're back in your server.", C_GOLD), -1)
}

; SendLevel 1 lets other AutoHotkey macros' hotkeys see the key; it's held
; briefly so every kind of keyboard hook notices it.
SendStopKey() {
    hk := stopHK.Value, mods := ""
    if (hk = "")
        return
    while (hk != "" && InStr("^!+#", SubStr(hk, 1, 1)))
        mods .= SubStr(hk, 1, 1), hk := SubStr(hk, 2)
    SendLevel(1)
    SetKeyDelay(30, 60)
    SendEvent(mods "{" hk "}")
    SendLevel(0)
}

; Discord embed with the chomik icon + name at the top. The icon is uploaded
; with the message (multipart) and the embed points at it.
SendWebhook(title, text, color) {
    static icon := ResData("icon.png")
    if ((url := CleanWebhook(hookEdit.Value)) = "")
        return
    json := '{"embeds":[{"author":{"name":"' APP '"' (icon ? ',"icon_url":"attachment://icon.png"' : "")
        . '},"title":"' title '","description":"' StrReplace(StrReplace(StrReplace(text, "\", "\\"), '"', '\"'), "`n", "\n")
        . '","color":' Integer("0x" color) ',"timestamp":"' FormatTime(A_NowUTC, "yyyy-MM-dd'T'HH:mm:ss'Z'") '"}]}'
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(3000, 3000, 5000, 5000)
        req.Open("POST", url, false)
        if !icon {
            req.SetRequestHeader("Content-Type", "application/json")
            return req.Send(json)
        }
        b := "TotemBoundary" A_TickCount
        head := Utf8("--" b "`r`nContent-Disposition: form-data; name=`"payload_json`"`r`n"
            . "Content-Type: application/json`r`n`r`n" json "`r`n--" b "`r`n"
            . "Content-Disposition: form-data; name=`"files[0]`"; filename=`"icon.png`"`r`n"
            . "Content-Type: image/png`r`n`r`n")
        tail := Utf8("`r`n--" b "--`r`n")
        body := ComObjArray(0x11, head.Size + icon.Size + tail.Size)     ; byte array
        p := NumGet(ComObjValue(body), 8 + A_PtrSize, "ptr")             ; its data
        for part in [head, icon, tail]
            DllCall("RtlMoveMemory", "ptr", p, "ptr", part, "uptr", part.Size), p += part.Size
        req.SetRequestHeader("Content-Type", "multipart/form-data; boundary=" b)
        req.Send(body)
    }
}

; String -> Buffer of its UTF-8 bytes (no terminator).
Utf8(s) {
    buf := Buffer(StrPut(s, "UTF-8"))
    StrPut(s, buf, "UTF-8")
    buf.Size -= 1
    return buf
}

; ========================================================= which server? ==
; Links opened in the browser start a new Roblox window whose launch
; command names the server: accessCode=<server> for private servers,
; request=RequestGame / RequestGameJob for public ones.
RobloxLaunchInfo(maxAgeSec := 0) {
    info := {code: "", request: "", place: ""}
    cmd := "", newest := ""
    try {
        for p in ComObjGet("winmgmts:").ExecQuery("SELECT CommandLine, CreationDate FROM Win32_Process WHERE Name='RobloxPlayerBeta.exe'")
            if (StrCompare(p.CreationDate "", newest) > 0 && p.CommandLine != "")
                newest := p.CreationDate "", cmd := p.CommandLine ""
    }
    ; Only trust a window that was just started (when asked to).
    if (maxAgeSec && (newest = "" || DateDiff(A_Now, SubStr(newest, 1, 14), "Seconds") > maxAgeSec))
        return info
    if RegExMatch(cmd, "i)accessCode(?:%3D|=)([0-9a-f-]{36})", &m)
        info.code := StrLower(m[1])
    if RegExMatch(cmd, "i)request(?:%3D|=)(\w+)", &m)
        info.request := m[1]
    if RegExMatch(cmd, "i)placeId(?:%3D|=)(\d+)", &m)
        info.place := m[1]
    return info
}

; A new Roblox window appeared - check where it's going before it joins.
OnNewRobloxWindow(path) {
    info := ProcInfo[path] := RobloxLaunchInfo(15)
    if (info.place != "" && info.place != SOLS_PLACE_ID)
        return
    if (info.code != "" && info.code != MyCode)
        Pop("you're joining someone else's private server")
    else if (info.request = "RequestGame" || info.request = "RequestGameJob")
        Pop("you're joining a public server")
}

; ========================================================== log watching ==
; Only the log of the running Roblox window (and any new ones) is read.
; Old lines are skipped; the current log is replayed silently so the
; totem knows which server you're in right now.
InitLogs() {
    newest := "", newestTime := 0
    Loop Files LOG_DIR "\*_last.log" {
        Known[A_LoopFileFullPath] := true
        if (!InStr(A_LoopFileName, "CrashHandler") && A_LoopFileTimeCreated > newestTime)
            newestTime := A_LoopFileTimeCreated, newest := A_LoopFileFullPath
    }
    if (newest = "" || !ProcessExist("RobloxPlayerBeta.exe"))
        return
    ProcInfo[newest] := RobloxLaunchInfo()
    Watch[newest] := 0, Grew[newest] := A_TickCount
    ReadNew(newest, false)
}

Tick() {
    static n := 0
    if (Mod(++n, 2) = 1)                ; every 500 ms: new Roblox windows
        ScanForNew()
    for path in Watch.Clone()           ; every 250 ms: new lines
        ReadNew(path, true)
}

ScanForNew() {
    Loop Files LOG_DIR "\*_last.log" {
        path := A_LoopFileFullPath
        if Known.Has(path)
            continue
        Known[path] := true
        if InStr(A_LoopFileName, "CrashHandler")
            continue
        Watch[path] := 0, Grew[path] := A_TickCount
        OnNewRobloxWindow(path)
    }
    ; Stop reading logs that have been quiet for a minute (closed windows,
    ; launcher stubs) - but never the one that grew most recently.
    if (Watch.Count > 1) {
        latest := "", latestT := 0
        for path, t in Grew
            if (t > latestT)
                latest := path, latestT := t
        for path, t in Grew.Clone()
            if (path != latest && A_TickCount - t > 60000)
                Watch.Delete(path), Grew.Delete(path)
    }
}

; The file size in the folder listing goes stale while Roblox writes, so
; the file is opened to check for new lines.
ReadNew(path, live) {
    try f := FileOpen(path, "r")
    catch
        return
    size := f.Length, pos := Watch[path]
    if (size <= pos) {
        f.Close()
        return
    }
    f.Pos := pos
    buf := Buffer(size - pos)
    n := f.RawRead(buf)
    f.Close()
    last := n - 1                       ; only whole lines; the rest waits
    while (last >= 0 && NumGet(buf, last, "UChar") != 10)
        last--
    if (last < 0)
        return
    Watch[path] := pos + last + 1, Grew[path] := A_TickCount
    Loop Parse StrGet(buf, last + 1, "UTF-8"), "`n", "`r"
        if (A_LoopField != "")
            HandleLine(A_LoopField, path, live)
}

HandleLine(line, path, live) {
    global LastLaunchType, LaunchAccessCode, Teleporting, CurrentJob, JoinCode
        , InSols, LastMine, LastPrivate
    ; Joined from the Private Servers list inside Roblox: names the server.
    if InStr(line, '"functionName":"launchGame"') {
        LastLaunchType := RegExMatch(line, '"requestType":"(\w+)"', &m) ? m[1] : ""
        LaunchAccessCode := RegExMatch(line, '"accessCode":"([\w-]+)"', &m) ? StrLower(m[1]) : ""
        return
    }
    if RegExMatch(line, "! Joining game '([^']+)'", &m) {
        CurrentJob := m[1]
        return
    }
    if InStr(line, "[FLog::SessionTransitionFSM] Teleported") {
        Teleporting := true
        return
    }
    if !RegExMatch(line, "game_join_loadtime: placeid:(\d+).*referral_page:(\w*)", &m)
        return

    ; A join finished - is it your server?
    InSols := m[1] = SOLS_PLACE_ID, ref := m[2]
    first := !JoinSeen.Has(path)
    JoinSeen[path] := true
    code := LaunchAccessCode, request := LastLaunchType
    if (code = "" && request = "" && first && ProcInfo.Has(path))
        code := ProcInfo[path].code, request := ProcInfo[path].request
    teleport := Teleporting
    Teleporting := false, LastLaunchType := "", LaunchAccessCode := ""
    if !InSols {
        JoinCode := "", LastMine := false
        return
    }
    if (teleport || (ref = "" && !first)) {
        mine := LastMine, private := LastPrivate    ; game teleport / reconnect
    } else {
        mine := MyJobs.Has(CurrentJob) || (code != "" && code = MyCode)
        private := code != "" || request = "RequestPrivateGame"
            || ref = "RequestPrivateGame" || ref = "Server"
    }
    JoinCode := mine && code = "" ? MyCode : code
    LastMine := mine, LastPrivate := private
    if mine
        MyJobs[CurrentJob] := true
    else if live
        Pop(private ? "you joined someone else's private server" : "you joined a public server")
}
