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

; GDI+ is started once for the whole process - the documented correct usage
; pattern is to bracket Startup around the process's entire GDI+ usage, not
; each operation. This script used to call GdiplusStartup/GdiplusShutdown on
; every SaveClipboardImageAsPng() invocation, and Windows/Snip & Sketch fires
; OnClipboardChange TWICE per screenshot (an intermediate clipboard write
; before the final one) - so that ran rapid repeated Startup/Shutdown cycles
; on the same process, which is not a safe GDI+ usage pattern.
;
; There is deliberately no explicit GdiplusShutdown call, even at exit: this
; script kept crashing (0xc0000005) inside an OnExit-registered
; GdiplusShutdown call even after the reentrancy fix eliminated concurrent
; captures, and Windows fully reclaims all GDI+ (and other process) resources
; on process termination regardless of whether GdiplusShutdown was called -
; standard, documented OS behavior, not a leak risk for a script that is only
; ever manually closed or reloaded by the captain. Skipping the call entirely
; is simpler and more robust than continuing to chase the exact corruption.
gdiplusStartupInput := Buffer(24, 0)
NumPut("uint", 1, gdiplusStartupInput, 0)  ; GdiplusVersion
gdiplusStartupStatus := DllCall("gdiplus\GdiplusStartup", "ptr*", &gdiplusToken := 0, "ptr", gdiplusStartupInput, "ptr", 0)
if (gdiplusStartupStatus != 0) {
    TrayTip("Captain input", "GDI+ failed to start (status " gdiplusStartupStatus ") - screenshot capture is disabled", 3)
    ExitApp(1)
}

; Reentrancy guard for CaptainInputCapture (see the function's own header
; comment for why this exists).
g_CaptureInProgress := false

OnClipboardChange(CaptainInputCapture)

CaptainInputCapture(DataType) {
    ; RunWait below pumps the Windows message queue while it waits for
    ; scp/ssh to exit, and every trace of this bug across every round has
    ; shown OnClipboardChange firing twice per single screenshot (Snip &
    ; Sketch writes an intermediate clipboard image before the final one).
    ; If the second notification arrives while the first invocation is
    ; still mid-flight inside a RunWait call, AHK can launch a second,
    ; concurrent thread of this same function - two invocations touching
    ; the clipboard and GDI+ objects at once, which is a plausible cause of
    ; the corrupted global state and crashes seen in earlier rounds (up to
    ; and including a crash inside ShutdownGdiPlus at script exit, long
    ; after the capture that corrupted things had returned).
    ;
    ; g_CaptureInProgress alone is a complete guard against this: any
    ; reentrant call hits the check below and returns immediately, before
    ; touching any clipboard or GDI+ state, regardless of AHK's thread
    ; scheduling. An earlier version of this fix also added Critical, on
    ; AHK v2's own OnClipboardChange documentation's recommendation for this
    ; exact hazard - but Critical was then implicated in a real hang (no
    ; TrayTip at all, all captures after the first going silently dead),
    ; and AHK's own docs on Critical/message-check-interval describe it
    ; changing exactly when buffered events are allowed to start new
    ; threads, which is squarely the kind of interaction the community
    ; separately documents producing deadlocks with waiting functions like
    ; RunWait. Since g_CaptureInProgress does not depend on any of that
    ; scheduling behavior to be correct, Critical was pure added risk on top
    ; of an already-sufficient fix, so it was removed.
    global g_CaptureInProgress
    if g_CaptureInProgress
        return
    g_CaptureInProgress := true
    try {
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
        ; temporary picture control - the simplest way to get PNG bytes on
        ; disk from AHK v2 without an extra imaging library.
        if !SaveClipboardImageAsPng(localPng)
            return

        remoteTmpPng := FM_REMOTE_DROP_DIR "/.tmp-" id ".png"
        remoteFinalPng := FM_REMOTE_DROP_DIR "/" id ".png"
        remoteTmpJson := FM_REMOTE_DROP_DIR "/.tmp-" id ".json"
        remoteFinalJson := FM_REMOTE_DROP_DIR "/" id ".json"

        ; 1. Upload the payload to a temp name, then atomically publish it
        ;    with a remote rename - never let the watcher see a
        ;    partially-written file. RunWait returns the child process's
        ;    exit code directly in AHK v2 - check each of the 4 scp/ssh
        ;    calls below and stop on the first failure, rather than
        ;    silently continuing past a failed upload step (a prior
        ;    version did this, and a failed json upload/publish went
        ;    unnoticed while the png still landed on the host).
        ;    The two ssh (not scp) calls pass -n -T: launched hidden with no
        ;    console, ssh can otherwise block trying to read stdin or
        ;    negotiate a pseudo-terminal that will never come - the actual
        ;    cause of every "works once, then hangs with no TrayTip" report
        ;    in this file's history. -n disables stdin, -T disables pty
        ;    allocation, both required only for the interactive `ssh`
        ;    invocations, not for `scp`.
        exitCode := RunWait('scp -q "' localPng '" "' FM_USER '@' FM_HOST ':' remoteTmpPng '"',, "Hide")
        if (exitCode != 0) {
            TrayTip("Captain input", "Screenshot capture failed: png upload failed (scp exit " exitCode ")", 3)
            return
        }
        exitCode := RunWait('ssh -n -T "' FM_USER '@' FM_HOST '" mv "' remoteTmpPng '" "' remoteFinalPng '"',, "Hide")
        if (exitCode != 0) {
            TrayTip("Captain input", "Screenshot capture failed: png publish failed (ssh mv exit " exitCode ")", 3)
            return
        }

        ; 2. Write the paired envelope last, the same atomic way - the
        ;    envelope landing under its final name is the "this drop is
        ;    complete" signal the watch script waits for.
        droppedAt := FormatTime(, "yyyy-MM-ddTHH:mm:ssZ")
        caption := ""  ; optionally prompt the captain for a one-line caption here
        envelope := '{"id":"' id '","type":"screenshot","path":"' remoteFinalPng '","caption":"' caption '","dropped_at":"' droppedAt '"}'
        localJson := tempDir "\" id ".json"
        FileAppend(envelope, localJson, "UTF-8")

        exitCode := RunWait('scp -q "' localJson '" "' FM_USER '@' FM_HOST ':' remoteTmpJson '"',, "Hide")
        if (exitCode != 0) {
            TrayTip("Captain input", "Screenshot capture failed: json upload failed (scp exit " exitCode ")", 3)
            return
        }
        exitCode := RunWait('ssh -n -T "' FM_USER '@' FM_HOST '" mv "' remoteTmpJson '" "' remoteFinalJson '"',, "Hide")
        if (exitCode != 0) {
            TrayTip("Captain input", "Screenshot capture failed: json publish failed (ssh mv exit " exitCode ")", 3)
            return
        }

        FileDelete(localPng)
        FileDelete(localJson)

        TrayTip("Captain input", "Screenshot sent to firstmate (" id ")", 1)
    } catch as err {
        TrayTip("Captain input", "Screenshot capture crashed: " err.Message " @ " err.File ":" err.Line, 3)
    } finally {
        g_CaptureInProgress := false
    }
}

; Minimal clipboard-image-to-PNG-file helper: reads the clipboard's raw DIB
; bytes and hands them to GDI+ directly, then saves as PNG. Requires no
; external .ahk library beyond AHK v2's built-in GDI+ startup, kept inline
; here so this stays a single-file script. Assumes GDI+ is already started
; for the process (see the top-level GdiplusStartup call) - this function
; must not start or shut down GDI+ itself.
;
; CF_BITMAP (format 2) is Windows-synthesized on demand from CF_DIB/CF_DIBV5
; and can come back as a degenerate stub in some delay-rendering or scaling
; scenarios even when the handle itself is non-null, silently failing
; GdipCreateBitmapFromHBITMAP - this is what broke on the captain's machine.
; CF_DIB (format 8) is the actual bytes (BITMAPINFOHEADER + optional color
; table + pixel bits) and converts reliably via GdipCreateBitmapFromGdiDib,
; the technique used by AHK's community Gdip_All/WinClip clipboard-to-image
; helpers - prefer it, and fall back to the CF_BITMAP path only if CF_DIB
; is not on the clipboard at all.
SaveClipboardImageAsPng(destPath) {
    clipboardOpen := false
    try {
        ; GetClipboardData requires the clipboard to be open first, or it
        ; always returns null - open it here rather than relying on a caller.
        clipboardOpen := DllCall("OpenClipboard", "ptr", 0)
        if !clipboardOpen {
            TrayTip("Captain input", "Screenshot capture failed: could not open clipboard (error " A_LastError ")", 3)
            return false
        }

        pBitmap := 0
        if DllCall("IsClipboardFormatAvailable", "uint", 8) {  ; CF_DIB
            hGlobal := DllCall("GetClipboardData", "uint", 8, "ptr")
            if !hGlobal {
                TrayTip("Captain input", "Screenshot capture failed: CF_DIB present but GetClipboardData returned null (error " A_LastError ")", 3)
            } else {
                pDIB := DllCall("GlobalLock", "ptr", hGlobal, "ptr")
                if !pDIB {
                    TrayTip("Captain input", "Screenshot capture failed: could not lock clipboard DIB (error " A_LastError ")", 3)
                } else {
                    ; BITMAPINFOHEADER: biSize@0 (UInt), biBitCount@14 (UShort),
                    ; biClrUsed@32 (UInt). Pixel bits start after the header
                    ; plus any color table (biClrUsed entries, or 2^biBitCount
                    ; when biClrUsed is 0 and the format is <=8bpp indexed).
                    biSize := NumGet(pDIB, 0, "uint")
                    biBitCount := NumGet(pDIB, 14, "ushort")
                    biClrUsed := NumGet(pDIB, 32, "uint")
                    colorTableEntries := biClrUsed ? biClrUsed : (biBitCount <= 8 ? (1 << biBitCount) : 0)
                    pPixels := pDIB + biSize + (colorTableEntries * 4)
                    dibStatus := DllCall("gdiplus\GdipCreateBitmapFromGdiDib", "ptr", pDIB, "ptr", pPixels, "ptr*", &pBitmap := 0)
                    DllCall("GlobalUnlock", "ptr", hGlobal)
                    if (dibStatus != 0) || !pBitmap {
                        TrayTip("Captain input", "Screenshot capture failed: GdipCreateBitmapFromGdiDib status " dibStatus, 3)
                        pBitmap := 0
                    }
                }
            }
        }

        if !pBitmap {
            if !DllCall("IsClipboardFormatAvailable", "uint", 2) {  ; CF_BITMAP
                TrayTip("Captain input", "Screenshot capture failed: no bitmap on clipboard (neither CF_DIB nor CF_BITMAP available)", 3)
                return false
            }
            hBitmap := DllCall("GetClipboardData", "uint", 2, "ptr")
            if !hBitmap {
                TrayTip("Captain input", "Screenshot capture failed: CF_BITMAP present but GetClipboardData returned null (error " A_LastError ")", 3)
                return false
            }
            hbitmapStatus := DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hBitmap, "ptr", 0, "ptr*", &pBitmap := 0)
            if (hbitmapStatus != 0) || !pBitmap {
                TrayTip("Captain input", "Screenshot capture failed: could not convert clipboard bitmap (GDI+ status " hbitmapStatus ")", 3)
                return false
            }
        }

        ; PNG encoder CLSID: {557cf406-1a04-11d3-9a73-0000f81ef32e}
        clsid := Buffer(16, 0)
        DllCall("ole32\CLSIDFromString", "wstr", "{557cf406-1a04-11d3-9a73-0000f81ef32e}", "ptr", clsid)
        saveStatus := DllCall("gdiplus\GdipSaveImageToFile", "ptr", pBitmap, "wstr", destPath, "ptr", clsid, "ptr", 0)
        DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
        saved := FileExist(destPath) ? true : false
        if !saved
            TrayTip("Captain input", "Screenshot capture failed: PNG file was not written (GDI+ save status " saveStatus ")", 3)
        return saved
    } finally {
        if clipboardOpen
            DllCall("CloseClipboard")
    }
}
