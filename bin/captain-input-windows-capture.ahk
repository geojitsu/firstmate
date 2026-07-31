; captain-input-windows-capture.ahk
;
; Reference AutoHotkey (v2) script the captain installs and runs on their OWN
; Windows machine. Firstmate never runs, deploys, or controls this script - it
; is not part of the fleet, it is the client half of the captain-input
; screenshot-drop channel described in docs/configuration.md ("Captain input").
;
; What it does: listens for the Windows clipboard to receive a new image (via
; OnClipboardChange, AutoHotkey's binding to the Win32 clipboard-change-listener
; API), saves that image to a temp file, uploads it to the firstmate host at a
; temp name, publishes it under its final name with an atomic remote rename
; (mirroring the same temp-then-rename discipline the host side already uses -
; see bin/fm-captain-input-watch.sh's header), then writes the paired JSON
; envelope the same atomic way.
;
; CAVEAT - read before relying on this: OnClipboardChange fires for anything
; that lands an image on the clipboard (Snip & Sketch / Win+Shift+S, PrtScn,
; third-party capture tools). Win+PrtScn specifically bypasses the clipboard
; and writes straight to a Pictures\Screenshots file - a clipboard listener
; never sees those captures. If that is your capture habit, this script's
; trigger needs to become a folder watch on Pictures\Screenshots instead; the
; body below (upload + envelope) is unchanged either way.
;
; Requirements on this Windows machine: AutoHotkey v2 (https://www.autohotkey.com/),
; an SSH client with scp on PATH (Windows 10/11 ship OpenSSH client by default;
; otherwise install the "OpenSSH Client" optional feature), and SSH key auth
; already set up to the firstmate host (this script never prompts for a
; password - SSH auth to that account IS the authorization boundary for this
; channel, see docs/configuration.md "Captain input").
;
; ---- fill these in for your setup -----------------------------------------
FM_HOST := "REPLACE_ME_host_or_alias"      ; e.g. "myserver" (an ~/.ssh/config Host entry is easiest)
FM_USER := "REPLACE_ME_ssh_user"           ; the account firstmate runs as on that host
FM_REMOTE_DROP_DIR := "REPLACE_ME_/absolute/path/to/firstmate/state/captain-drop"
; -----------------------------------------------------------------------------

#Requires AutoHotkey v2.0
#SingleInstance Force

OnClipboardChange(CaptainInputCapture)

CaptainInputCapture(DataType) {
    ; DataType: 0 = cleared, 1 = text, 2 = image/other binary format.
    if (DataType != 2)
        return
    if !ClipboardAll()
        return

    id := FormatTime(, "yyyyMMdd-HHmmss") "-" Random(1000, 9999)
    tempDir := A_Temp "\captain-input"
    DirCreate(tempDir)
    localPng := tempDir "\" id ".png"

    ; Save the clipboard image via a hidden GDI+ round trip through a
    ; temporary picture control - the simplest way to get PNG bytes on disk
    ; from AHK v2 without an extra imaging library.
    if !SaveClipboardImageAsPng(localPng)
        return

    remoteTmpPng := FM_REMOTE_DROP_DIR "/.tmp-" id ".png"
    remoteFinalPng := FM_REMOTE_DROP_DIR "/" id ".png"
    remoteTmpJson := FM_REMOTE_DROP_DIR "/.tmp-" id ".json"
    remoteFinalJson := FM_REMOTE_DROP_DIR "/" id ".json"

    ; 1. Upload the payload to a temp name, then atomically publish it with a
    ;    remote rename - never let the watcher see a partially-written file.
    RunWait('scp -q "' localPng '" "' FM_USER '@' FM_HOST ':' remoteTmpPng '"',, "Hide")
    RunWait('ssh "' FM_USER '@' FM_HOST '" mv "' remoteTmpPng '" "' remoteFinalPng '"',, "Hide")

    ; 2. Write the paired envelope last, the same atomic way - the envelope
    ;    landing under its final name is the "this drop is complete" signal
    ;    the watch script waits for.
    droppedAt := FormatTime(, "yyyy-MM-ddTHH:mm:ssZ")
    caption := ""  ; optionally prompt the captain for a one-line caption here
    envelope := '{"id":"' id '","type":"screenshot","path":"' remoteFinalPng '","caption":"' caption '","dropped_at":"' droppedAt '"}'
    localJson := tempDir "\" id ".json"
    FileAppend(envelope, localJson, "UTF-8")

    RunWait('scp -q "' localJson '" "' FM_USER '@' FM_HOST ':' remoteTmpJson '"',, "Hide")
    RunWait('ssh "' FM_USER '@' FM_HOST '" mv "' remoteTmpJson '" "' remoteFinalJson '"',, "Hide")

    FileDelete(localPng)
    FileDelete(localJson)

    TrayTip("Captain input", "Screenshot sent to firstmate (" id ")", 1)
}

; Minimal clipboard-image-to-PNG-file helper: draws the clipboard bitmap into
; a temporary GUI Picture control, then lets GDI+ (via a Gdip_ token, loaded
; on demand) save it as PNG. Requires no external .ahk library beyond AHK v2's
; built-in GDI+ startup, kept inline here so this stays a single-file script.
SaveClipboardImageAsPng(destPath) {
    if !DllCall("gdiplus\GdiplusStartup", "ptr*", &pToken := 0, "ptr", Buffer(24, 0), "ptr", 0)
        return false
    try {
        hBitmap := DllCall("GetClipboardData", "uint", 2, "ptr")  ; CF_BITMAP
        if !hBitmap
            return false
        DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hBitmap, "ptr", 0, "ptr*", &pBitmap := 0)
        if !pBitmap
            return false
        ; PNG encoder CLSID: {557cf406-1a04-11d3-9a73-0000f81ef32e}
        clsid := Buffer(16, 0)
        DllCall("ole32\CLSIDFromString", "wstr", "{557cf406-1a04-11d3-9a73-0000f81ef32e}", "ptr", clsid)
        DllCall("gdiplus\GdipSaveImageToFile", "ptr", pBitmap, "wstr", destPath, "ptr", clsid, "ptr", 0)
        DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
        return FileExist(destPath) ? true : false
    } finally {
        DllCall("gdiplus\GdiplusShutdown", "ptr", pToken)
    }
}
