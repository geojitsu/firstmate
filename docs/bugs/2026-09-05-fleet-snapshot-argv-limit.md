---
title: Fleet snapshot failed on large backlog JSON
description: jq rejected an oversized backlog value passed through argv, preventing home-summary publication as the backlog grew.
---

## Symptom

`bin/fm-fleet-snapshot.sh --secondmate-home-summary` failed with `jq: Argument list too long` when the backlog reached 121,292 bytes.
The same input-passing pattern also existed in the full `--json` path.

## Root cause

The snapshot assembled JSON in shell variables and passed unbounded backlog, task, registry, or current-summary values to jq with `--argjson`.
Linux applies a 128 KiB maximum to an individual argument, independently of the total process argument limit.

## Fix

The affected jq filters now read unbounded JSON documents through private files supplied with `--slurpfile`.
The snapshot creates one mode-local staging directory and removes it from the existing exit cleanup path on both success and failure.

## Prevention

The fleet snapshot behavior suite now drives both output modes with a 2000-row backlog large enough to exceed the per-argument limit.
The regression asserts valid JSON and verifies that the staging directory is empty after each successful run.
