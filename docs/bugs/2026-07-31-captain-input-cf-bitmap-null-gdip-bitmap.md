---
title: Captain-input capture failed converting a non-null clipboard bitmap
description: GdipCreateBitmapFromHBITMAP returned a null bitmap from a non-null CF_BITMAP handle, because CF_BITMAP is a Windows-synthesized stub that can be degenerate; reading CF_DIB directly fixes it.
---

## Symptom

After the earlier `OpenClipboard`/`CloseClipboard` fix (see `2026-07-31-captain-input-clipboard-not-opened.md`), the captain's live AutoHotkey trace showed `OpenClipboard` succeeding and `GetClipboardData(CF_BITMAP)` returning a non-null handle, but the very next call - `DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", ...)` - still returned a null `pBitmap`.
This happened on both of the captain's capture attempts, so it was reproducible rather than a flake.

## Root cause

`CF_BITMAP` (format 2) is not itself stored on the clipboard by most capture tools (e.g. Snip & Sketch); Windows synthesizes it on demand from `CF_DIB`/`CF_DIBV5` once the clipboard is open.
That synthesized `HBITMAP` can come back as a zero-size or otherwise degenerate stub in some delay-rendering or scaling scenarios even though the handle itself is non-null, and `GdipCreateBitmapFromHBITMAP` then silently returns a null bitmap with no exception to catch.
The previous fix requested only `CF_BITMAP`, so it inherited this failure mode.

## Fix

`SaveClipboardImageAsPng()` now prefers `CF_DIB` (format 8): the actual `BITMAPINFOHEADER` + optional color table + pixel bytes, read via `GlobalLock`/`GlobalUnlock` and converted with `GdipCreateBitmapFromGdiDib` - the technique used by AHK's community `Gdip_All`/`WinClip` clipboard-to-image helpers, ported inline rather than added as a dependency.
It checks `IsClipboardFormatAvailable` for each format before calling `GetClipboardData`, and falls back to the original `CF_BITMAP` + `GdipCreateBitmapFromHBITMAP` path only when `CF_DIB` is not on the clipboard at all.
Every fallible step now surfaces its actual failure reason in the `TrayTip`: the `GpStatus` code GDI+ calls return as their own `DllCall` return value (0 = Ok), and `A_LastError` (AutoHotkey's automatic `GetLastError()` capture after a `DllCall`) for the failing Win32 clipboard calls.

## Prevention

This class of bug - a Windows-synthesized clipboard format silently degenerating - has no automated test here: the fix requires a live Windows clipboard to validate, which CI cannot provide.
The captain verifies this fix by running the updated script and confirming a screenshot upload succeeds end to end; if it still fails, the new per-step `TrayTip` diagnostics (GDI+ status code, Win32 last-error code) should identify the next failure point without another blind trace-guessing round.
