---
title: Captain-input capture hung silently after Critical was added for reentrancy
description: Critical, added to block a reentrant OnClipboardChange callback, was then implicated in a total hang with no TrayTip at all; removed because the g_CaptureInProgress flag already fully solves the reentrancy problem on its own.
---

## Symptom

After the reentrancy fix (see `2026-07-31-captain-input-clipboard-callback-reentrancy.md`) and the `GdiplusShutdown` removal (see `2026-07-31-captain-input-gdiplus-shutdown-removed.md`), the captain reported no `TrayTip` appearing at all after the one screenshot that had worked, and consecutive screenshots stopped triggering entirely.
Every failure path in this script already ends in a `TrayTip`, so total silence meant execution was never reaching any of them - a genuine hang, not a caught failure.

## Root cause

The leading theory was that `Critical`, added in the reentrancy fix as defense in depth alongside `g_CaptureInProgress`, was interacting badly with `RunWait`'s message-pumping wait.
AHK v2's own `Critical` documentation confirms `Critical` changes exactly when buffered events are allowed to start new threads (the message-check-interval setting), and separate AHK community discussion documents real deadlocks arising from `Critical` threads combined with waiting functions.
The official docs are more nuanced than a flat "Critical blocks RunWait" claim - they state that wait functions like `Sleep`/`WinWait` still check messages regardless of the message-check-interval setting - but the underlying mechanism `Critical` changes (deferring buffered events instead of dispatching them) is squarely the kind of interaction that can produce a stuck wait, and it lines up with a hang that started exactly when `Critical` was introduced.

`g_CaptureInProgress` does not depend on any of this scheduling nuance to work: any reentrant call hits `if g_CaptureInProgress return` immediately, before touching clipboard or GDI+ state, regardless of how or when AHK schedules threads.
`Critical` was therefore redundant on top of an already-sufficient fix, and carried this hang risk for no corresponding safety benefit.

## Fix

Removed the `Critical` statement from `CaptainInputCapture()` entirely.
The `g_CaptureInProgress` guard (check-then-set, cleared in a `try`/`finally` so it always clears) remains as the sole reentrancy protection.

## Prevention

This class of bug - an added-for-safety statement itself becoming the cause of a worse failure - is why defense-in-depth additions should be reconsidered once evidence shows the primary fix (`g_CaptureInProgress`) is already sufficient on its own, rather than assumed harmless by default.
No automated test exists here: reproducing this requires a live Windows AHK v2 process and the real Snip & Sketch double-clipboard-write behavior, which CI cannot provide.
The captain verifies this fix by running the updated script and confirming repeated captures each produce a `TrayTip` and keep triggering, with no hang.
