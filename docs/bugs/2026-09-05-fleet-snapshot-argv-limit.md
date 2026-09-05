---
title: Fleet snapshot failed on large JSON inputs
description: jq rejected unbounded JSON passed through argv, preventing both snapshot output modes from handling valid large state.
---

## Symptom

`bin/fm-fleet-snapshot.sh --secondmate-home-summary` failed with `jq: Argument list too long` when a valid backlog grew large.
The same failure could occur in `--json` for a large backlog, status event, or secondmate home summary.

## Root cause

The snapshot assembled JSON in shell variables and supplied unbounded document values to jq on argv.
Linux applies a 128 KiB maximum to an individual argument, independently of the total process argument limit.

## Fix

The snapshot stages unbounded JSON documents in one private temporary directory and jq reads them with `--slurpfile`.
Exit cleanup removes that directory on success and failure.

## Prevention

`tests/fm-fleet-snapshot-view.test.sh` covers both output modes with oversized backlog and status-event inputs, and the full snapshot path with an oversized secondmate summary.
The regression asserts valid JSON and verifies that the staging directory is empty after each successful run.
