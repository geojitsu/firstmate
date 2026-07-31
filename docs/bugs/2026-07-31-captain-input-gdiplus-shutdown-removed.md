---
title: Captain-input capture still crashed on exit after fixing reentrancy
description: GdiplusShutdown kept crashing (0xc0000005) at script exit even after the reentrancy fix eliminated concurrent captures, so the explicit shutdown call was removed - Windows reclaims GDI+ resources on process exit regardless.
---

## Symptom

The reentrancy fix (see `2026-07-31-captain-input-clipboard-callback-reentrancy.md`) worked - only one `CaptainInputCapture` invocation ran per screenshot, and reloading the script no longer crashed mid-capture.
But exiting/closing the script still crashed with the same `0xc0000005` access violation, this time consistently at `DllCall("gdiplus\GdiplusShutdown", "ptr", g_GdiPlusToken)` inside `ShutdownGdiPlus()`.

## Root cause

Undetermined precisely, and no longer worth chasing further: whatever was corrupting the GDI+ token was not (only) the reentrancy race fixed in the previous round, since the crash persisted with reentrancy already eliminated.
Rather than continue guessing at Windows/GDI+ internals across another round, the explicit `GdiplusShutdown` call was removed entirely.

## Fix

The top-level `GdiplusStartup` call remains (still required once, before any GDI+ call in `SaveClipboardImageAsPng`), but there is no longer any explicit `GdiplusShutdown` call, and the `OnExit(ShutdownGdiPlus)` registration and `ShutdownGdiPlus()` function are removed entirely.
This is safe: Windows fully reclaims all of a process's resources, including GDI+ state, when the process terminates, regardless of whether `GdiplusShutdown` was called explicitly - standard, documented OS behavior.
This script is only ever manually closed or reloaded by the captain (not a long-running service managing many short-lived GDI+ sessions), so there is no leak risk from skipping the call.

## Prevention

This class of bug - a resource-cleanup call itself becoming the crash site after its actual precondition (corrupted state from elsewhere) can no longer be reproduced - is hard to root-cause further without live Windows debugging tools this fleet does not have access to.
Given the fix is provably safe on its own terms (documented OS process-teardown behavior) rather than just a way to make the crash go away, removing the call was preferred over continuing to guess at the underlying corruption.
The captain verifies this fix by running the updated script and confirming it exits/reloads cleanly with no crash, after a normal capture.
