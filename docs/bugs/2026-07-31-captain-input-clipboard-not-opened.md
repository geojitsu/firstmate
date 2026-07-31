---
title: Captain-input capture always failed silently
description: The Windows-side clipboard capture never opened the clipboard before reading it, so every screenshot capture failed before upload.
---

## Symptom

Running `bin/captain-input-windows-capture.ahk` on Windows and taking a screenshot (Snip & Sketch) produced no upload to the firstmate host and no visible error - nothing appeared under `state/captain-drop/` on the host side.

## Root cause

`SaveClipboardImageAsPng()` called the Win32 `GetClipboardData` API without first calling `OpenClipboard()`.
Per the Win32 clipboard contract, `GetClipboardData` returns null unless the calling thread has the clipboard open; this script never opened it, so `hBitmap` was always null and the function returned `false` on every call, before the GDI+ save step ever ran.
The caller (`CaptainInputCapture`) then returned early at its own `if !SaveClipboardImageAsPng(...)` check, so the upload/envelope steps never executed.

## Fix

`SaveClipboardImageAsPng()` now calls `OpenClipboard(0)` before `GetClipboardData` and `CloseClipboard()` in the same `finally` block that already shuts down GDI+.
It requests `CF_BITMAP` (format 2) only: per the Win32 standard-clipboard-formats documentation, Windows synthesizes `CF_BITMAP` from `CF_DIB`/`CF_DIBV5` automatically once the clipboard is open, so this also covers capture tools that populate only `CF_DIB`.
Each early-return path (`OpenClipboard` failure, no bitmap on the clipboard, GDI+ conversion failure, PNG write failure) now raises a `TrayTip` so a future failure is visible to the captain instead of producing no observable effect.

## Prevention

This class of bug - a Win32 API called without its required open/close bracket - has no automated test here: the fix requires a live Windows clipboard to validate, which CI cannot provide.
The captain verifies this fix by running the updated script and confirming a screenshot upload succeeds end to end.
