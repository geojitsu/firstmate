---
title: Captain-input capture silently dropped the JSON envelope on upload failure
description: The 4 scp/ssh RunWait calls that upload and publish the PNG and JSON never checked their exit codes, so a failed json leg went unnoticed while the png still landed on the host.
---

## Symptom

The captain confirmed the PNG uploads successfully and lands on the host with correct content, but the paired `.json` envelope never arrives - only the `.png` shows up under the drop directory, never a `.json`, on every attempt.

## Root cause

`CaptainInputCapture()` fires 4 `RunWait` calls - upload-then-publish for the PNG, then upload-then-publish for the JSON - and never captured or checked any of their exit codes.
`RunWait` returns the child process's exit code directly in AHK v2, but the calls were used purely for their blocking side effect, so a failing `scp` or `ssh mv` on any of the 4 steps was silently ignored and execution just continued to the next step (or, for the last step, to the final success `TrayTip`).
This made a failure on the json leg specifically invisible: the png steps evidently succeeded (the captain could read the screenshot content on the host), but whichever json step was failing produced no error and no trace of why the envelope never arrived.

## Fix

Each of the 4 `RunWait` calls now assigns its return value to `exitCode` and checks it immediately.
A nonzero exit stops the function right there with a `TrayTip` naming the exact failed step (`png upload failed (scp exit N)`, `png publish failed (ssh mv exit N)`, `json upload failed (scp exit N)`, `json publish failed (ssh mv exit N)`), instead of silently proceeding to the next step.
The existing "Screenshot sent to firstmate" `TrayTip` is now reached only after all 4 steps have genuinely succeeded.
On a failure return, the local temp files (`localPng`/`localJson`) are deliberately left in place rather than cleaned up, so they remain available as evidence for whatever the next diagnosis turns out to need.

## Prevention

This class of bug - a shelled-out command's exit code never inspected - had no automated test here: the fix requires a live SSH/`scp` round trip to a real host, which CI cannot provide.
The captain verifies this fix by running the updated script and confirming both the `.png` and its paired `.json` land on the host on a normal capture, and that a deliberately broken upload (e.g. wrong `FM_REMOTE_DROP_DIR`) now produces a `TrayTip` naming the exact failed step instead of a silent partial drop.
