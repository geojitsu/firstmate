---
title: Helm board sync failed its schema check on real fleet scale
description: jq rejected an unbounded desired-records array passed through argv, silently failing every board's schema check once a fleet's full card bodies grew past the per-argument limit.
---

## Symptom

`bin/fm-helm-sync.sh` reported every board "could not be reconciled" with "required Helm fields or options are unavailable", even though the board's Status, Project, Kind, and Priority fields and options were all present and correct.
The failure was silent about its real cause: the schema-check jq call's stderr is intentionally suppressed elsewhere for legitimate per-board diagnostics, so the actual `jq: Argument list too long` never surfaced.
Small local test fixtures never reproduced it; the real fleet's ~84+ live tasks with full card bodies did.

## Root cause

`process_board()` built the per-board schema check with `jq -r --argjson records "$(cat "$group_desired")" ...`, passing the whole board group's desired-records JSON as a single command-line argument.
Linux applies a 128 KiB maximum to an individual argument, independently of the total process argument limit - the same class of failure as [2026-09-05-fleet-snapshot-argv-limit](2026-09-05-fleet-snapshot-argv-limit.md).
A single real card's full body, let alone a whole board group's array of them, routinely exceeds that.

## Fix

The schema check now reads `$group_desired` with `--slurpfile records_wrap`, then unwraps it as `($records_wrap[0]) as $records` at the top of the jq program, matching the pattern the same file's plan-building call (`fm_helm_plan_program`, a few lines below) already used for the same file.
`bin/fm-helm-project-map.sh` and `bin/fm-helm-lib.sh` were audited for the same unsafe `--argjson "$(...)"` pattern; every other `--argjson` call in Helm's sync path passes a small, bounded value (project-name lists, single GraphQL item responses, and similar) well under the per-argument limit, so no other call needed changing.

## Prevention

`tests/fm-helm-sync.test.sh` ("the per-board schema check survives a desired-records array larger than ARG_MAX") builds a 100-card fleet whose combined desired-records JSON exceeds the 2 MiB total argv limit, with every card already matching its board twin so the run needs no writes and isolates the read path.
It asserts the backlog fixture is actually larger than that limit before trusting the run, and that the sync still reports `synchronized`.
