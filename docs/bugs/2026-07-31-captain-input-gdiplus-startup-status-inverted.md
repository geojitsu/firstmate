---
title: Captain-input capture never actually initialized GDI+
description: GdiplusStartup's GpStatus return value was checked as a boolean, so a real failure (invalid, all-zero GdiplusStartupInput) passed through silently and every later GDI+ call ran against an uninitialized token.
---

## Symptom

After the `CF_DIB` fix (see `2026-07-31-captain-input-cf-bitmap-null-gdip-bitmap.md`), the captain tested PR #6 live and both `GdipCreateBitmapFromGdiDib` and `GdipCreateBitmapFromHBITMAP` reported GDI+ status 18 (`GdiplusNotInitialized`), regardless of which clipboard format path ran.
Since both independent conversion paths failed with the same "not initialized" status, the common ancestor - `GdiplusStartup` itself - was the actual point of failure, and had been since this script's original CF_BITMAP-only version (the earlier `GdipCreateBitmapFromHBITMAP` null-`pBitmap` symptom was consistent with this the whole time; it just had no status code captured to prove it).

## Root cause

Two compounding bugs in `SaveClipboardImageAsPng()`:

1. `if !DllCall("gdiplus\GdiplusStartup", ...)` treated the call's return value as a boolean, but `GdiplusStartup` returns a `GpStatus` where `0` means success.
   The check only reacted to a literal DllCall return of `0` - the success case - as falsy, and treated every nonzero (failure) status as truthy, i.e. as "not failed".
   That is backwards: it can never actually detect a `GdiplusStartup` failure, and always fell through to using a `pToken` that was never validly initialized.
2. `GdiplusStartupInput` was passed as `Buffer(24, 0)`, entirely zeroed. That struct's first field, `GdiplusVersion`, must be `1`; a `0` version is an invalid parameter and a very likely reason `GdiplusStartup` itself was failing.

With both bugs combined, `GdiplusStartup` was returning a real failure status (mis-detected as success by bug 1), `pToken` was never validly initialized, and every subsequent `gdiplus\*` `DllCall` in the function ran against an uninitialized GDI+ session and returned `GdiplusNotInitialized` (18).

## Fix

`SaveClipboardImageAsPng()` now builds `GdiplusStartupInput` in its own `Buffer(24, 0)` and sets `GdiplusVersion` (offset 0) to `1` via `NumPut` before the call, captures `GdiplusStartup`'s actual `GpStatus` return value, and checks it with `!= 0` instead of a bare boolean negation.
On a real startup failure it now reports the status code via `TrayTip` and returns `false` before entering the `try` block, so the `finally` block's `GdiplusShutdown` call - reached only once the function is inside that `try` - is never invoked against a token that was never successfully started.

## Prevention

This class of bug - a Win32/GDI+ status code checked as a boolean instead of compared to its success value - produced no visible symptom before diagnostic status-code logging existed for the downstream calls; the previous fix's "surface the real `GpStatus`" diagnostics for `GdipCreateBitmapFromGdiDib`/`GdipCreateBitmapFromHBITMAP` are what exposed this, one level up, on the captain's very next live test.
Still no automated test here: it requires a live Windows GDI+ session to validate, which CI cannot provide.
The captain verifies this fix the same way, by running the updated script and confirming a screenshot upload succeeds end to end.
