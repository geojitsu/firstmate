---
title: Captain-input capture hung on ssh mv because of missing -n -T flags
description: The hidden, console-less ssh mv calls could block trying to read stdin or negotiate a pseudo-terminal that never arrives; -n -T fixes it. This is the real cause of every prior "works once, then hangs with no TrayTip" report - Critical/RunWait was a plausible but ultimately incorrect theory.
---

## Symptom

After every prior fix in this file's history - including removing `Critical` (see `2026-07-31-captain-input-critical-hang.md`) - the script still, on some runs, worked once and then hung with no `TrayTip` at all, requiring a captain to diagnose with a different tool.

## Root cause

The `ssh` calls used to publish the uploaded PNG/JSON (`ssh "user@host" mv ...`) were launched hidden, with no console (`RunWait(..., , "Hide")`).
Without `-n` (redirect stdin from `/dev/null`) or `-T` (disable pseudo-terminal allocation), `ssh` can block indefinitely trying to read from a stdin that a hidden, console-less process never provides, or negotiating a pty that never arrives.
`scp` does not have this problem and needed no change.

The prior investigation (`2026-07-31-captain-input-critical-hang.md`) theorized this was an AHK `Critical`/`RunWait` message-pump interaction - a reasonable hypothesis given the documented hazards of `Critical` combined with waiting functions, and given the hang first became visible in the same round `Critical` was added.
That theory was disproven when removing `Critical` did not fix the hang: the real cause was this much simpler and entirely unrelated `ssh` stdin/pty issue, present since the very first version of this script's upload logic.

## Fix

Both `ssh mv` calls (png publish and json publish) now pass `-n -T`.
`scp` calls are unchanged - `-n`/`-T` are ssh-specific interactive-session flags with no equivalent need for a file-copy-only invocation.

Also added in this round: `ExitApp(1)` if `GdiplusStartup` itself fails (previously only a `TrayTip`, leaving the script running in a broken state), and an outer `catch as err` around the whole `CaptainInputCapture` body reporting any unexpected error via `TrayTip` with the error message, file, and line - so an as-yet-unseen failure mode surfaces a diagnosable message instead of another silent hang or unexplained crash.

Captain-verified: 3 real screenshots delivered end to end through the full channel (upload, publish, JSON envelope) with this fix in place.

## Prevention

This class of bug - a documented `ssh`-specific default (interactive pty/stdin negotiation) misbehaving under a hidden, non-interactive launch - is a known `ssh` gotcha independent of AHK, and is why the `-n -T` flags exist.
No automated test exists here: it requires a live Windows AHK v2 process and a real SSH round trip to reproduce, which CI cannot provide.
This entry supersedes the `Critical`/`RunWait` theory in `2026-07-31-captain-input-critical-hang.md` as the actual root cause of the "works once, then hangs" family of reports across this file's history.
