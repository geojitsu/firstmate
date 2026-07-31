---
title: Captain-input capture corrupted global state via a reentrant clipboard callback
description: OnClipboardChange fires twice per screenshot, and RunWait pumps messages while it waits, so a second notification could launch a concurrent CaptainInputCapture thread mid-upload; fixed with Critical plus an explicit reentrancy guard.
---

## Symptom

After one screenshot capture, subsequent clipboard changes stopped triggering the script at all, and reloading or exiting the script then crashed with the same `0xc0000005` access violation seen previously (see `2026-07-31-captain-input-gdiplus-shutdown-crash.md`), this time inside `ShutdownGdiPlus()` at script exit - well after the capture that actually corrupted things had already returned.

## Root cause

Every trace across every round of this investigation has shown `OnClipboardChange` firing `CaptainInputCapture` twice per single screenshot (Snip & Sketch writes an intermediate clipboard image before the final one).
`RunWait` pumps the Windows message queue while it blocks waiting for the `scp`/`ssh` child process to exit.
If the second clipboard-change notification arrives while the first `CaptainInputCapture` invocation is still mid-flight inside one of those `RunWait` calls, AHK can dispatch that second notification and launch a second, concurrent thread of the same function - two invocations touching the clipboard (`OpenClipboard`/`CloseClipboard`) and GDI+ objects at once.
AHK v2's own `OnClipboardChange` documentation names this exact hazard: "If the clipboard changes while a callback is already running, that notification event is lost. If this is undesirable, use `Critical`." - confirming this is a real, known AHK v2 behavior rather than a guess, and that `Critical` is the documented way to make AHK buffer/defer the second notification instead of dispatching it concurrently.
Two concurrent invocations racing on shared clipboard and GDI+ state is a plausible explanation for corrupted global state that only blows up later and unpredictably, including at shutdown long after the offending capture returned.

## Fix

`CaptainInputCapture()` now starts with `Critical`, so AHK buffers/defers a second clipboard-change notification instead of launching a concurrent thread while a capture is still running.
As explicit defense in depth in case any interruption gets through anyway, a global `g_CaptureInProgress` flag is checked at the top of the function; if a capture is already in progress the function returns immediately without touching the clipboard or GDI+ state, and the flag is set/cleared around a `try`/`finally` so it is always cleared even on an early return or failure path.

## Prevention

This class of bug - a message-pumping wait function inside an event callback opening a reentrancy window - had no automated test here: it requires the real Snip & Sketch double-clipboard-write behavior and a live Windows message queue to reproduce, which CI cannot provide.
Research came before the fix this round: the `OnClipboardChange` documentation was fetched and its exact reentrancy wording quoted above, rather than patching blind again after several rounds of guessing.
The captain verifies this fix by fully exiting (not just reloading) the currently-running broken instance first - it is already in the state this fix cannot repair retroactively - then running the updated script and confirming repeated captures keep working and the script exits cleanly with no crash.
