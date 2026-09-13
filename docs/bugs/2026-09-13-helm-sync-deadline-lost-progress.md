---
title: Helm sync never finished and forgot its progress
description: Per-row local work exceeded the whole-run deadline on a fleet-sized backlog, and an aborted run published nothing.
---

## Symptom

From 2026-09-09 no Helm sync run finished.
Each run reported that it could not create or update one card, a different card each time, and the board fell further behind the backlog.
Cards created by an aborted run had no identity-cache row, and every later run started again from the same stale state.

## Root cause

`bin/fm-helm-sync.sh` applied one 25-second deadline to the whole run, but it computed each card's desired state and diff in bash, with dozens of `jq` and `awk` processes per backlog row.
A fleet-sized backlog needed about 70 seconds of local CPU before it reached its first write, so the deadline always expired first.
The identity cache, the debounce hash, and the poll signature were published only at the very end of a run, so an aborted run lost everything it had done.

## Fix

The sync now renders every card and computes the whole reconciliation in one `jq` pass (`fm_helm_desired_program` and `fm_helm_plan_program` in `bin/fm-helm-lib.sh`) and the bash loop only executes plan entries.
Every landed card write updates its `state/helm-cards.tsv` row at once.
A run that reaches its budget or cannot land a card request prints `partial: N cards remain` and exits 0.
An external interruption can end without that line, but the next run resumes from the recorded card rows.
A `--force` run that reaches the partial path leaves `state/.helm-sync-resume` so the next run stays forced.

## Prevention

`tests/fm-helm-sync.test.sh` runs a generated 100-row backlog against a 110-card board with a fake `gh` and no artificial latency, and requires one run to finish well inside the deadline and be idempotent.
It also cuts a run off after its first card creation, and kills one mid-write the way the watcher's check timeout does, and requires the created card to be recorded and the next run to resume without recreating it.
