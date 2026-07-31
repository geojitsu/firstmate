---
title: Captain-input capture crashed with an access violation in GdiplusShutdown
description: SaveClipboardImageAsPng ran a full GdiplusStartup/GdiplusShutdown cycle on every call, and OnClipboardChange fires twice per screenshot, so rapid repeated Startup/Shutdown cycles on one process corrupted the GDI+ token and crashed Shutdown itself.
---

## Symptom

After the `GdiplusStartup` status-check fix (see `2026-07-31-captain-input-gdiplus-startup-status-inverted.md`), the captain got a hard crash - a `0xc0000005` access violation - at the `finally` block's `DllCall("gdiplus\GdiplusShutdown", "ptr", pToken)` line, not just a reported failure status.

## Root cause

Every trace across all rounds of this investigation shows `OnClipboardChange` firing twice per single screenshot: Windows/Snip & Sketch does an intermediate clipboard write before the final one, and AutoHotkey's clipboard-change-listener binding sees both.
`SaveClipboardImageAsPng()` ran a full `GdiplusStartup` + `GdiplusShutdown` cycle on every single invocation, so a single screenshot triggered two back-to-back Startup/Shutdown cycles on the same process.
Rapid repeated Startup/Shutdown cycles on one process are not a safe GDI+ usage pattern - GDI+'s documented contract is to bracket Startup/Shutdown around the process's entire GDI+ usage, not each operation - and this is very likely what corrupted or invalidated the token, crashing `GdiplusShutdown` itself on the second cycle.

## Fix

`GdiplusStartup` now runs exactly once, at script load, before `OnClipboardChange` is registered; the token lives in a script-level `g_GdiPlusToken` variable.
`SaveClipboardImageAsPng()` no longer starts or stops GDI+ at all - it just uses the already-started process-wide session.
`OnExit(ShutdownGdiPlus)` calls `GdiplusShutdown` exactly once, when the script actually exits.
This is the standard correct AHK/GDI+ usage pattern (bracket the whole process, not each operation), not merely a crash workaround.

## Prevention

This class of bug - an expensive process-wide resource lifecycle (GDI+ startup/shutdown) scoped to a single operation instead of the process - had no automated test here and needed a live Windows crash to surface, since `OnClipboardChange` firing twice per capture is itself an OS/tool behavior that cannot be reproduced without the real Snip & Sketch flow.
The captain verifies this fix by running the updated script and confirming a screenshot upload succeeds end to end with no crash, including on a fast double-fire of the clipboard-change event.
