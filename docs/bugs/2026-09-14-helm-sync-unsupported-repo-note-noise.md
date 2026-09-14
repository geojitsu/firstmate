---
title: Helm sync re-fired the same unsupported-repository note on every fleet check
description: An un-debounced diagnostic and a fragile watcher exact-match together turned one already-known fact into a near-continuous wake.
---

## Symptom

Almost every fleet check woke the captain with `fm-helm-sync: unsupported repository <repo> for <id>; using other`, for the same handful of tasks, over and over.
The mapping to the board's `other` bucket was correct every time - nothing was actually wrong - but the note fired again on nearly every check regardless.

## Root cause

Two independent gaps compounded:

- `fm_helm_desired_program` in `bin/fm-helm-lib.sh` sets a `note` on any record whose `repo:` does not match the fixed project allowlist, and `bin/fm-helm-sync.sh` printed that note unconditionally, for every plan record, on every run - unlike every other durable fact in this sync, which is debounced through a per-task marker (the divergence-memory files, `.helm-dispatch-requests`).
  The whole-fleet replan hash that gates a full plan covers the entire backlog, so any unrelated task's dispatch, teardown, priority, or note change invalidated it and reprinted this note for every already-known unsupported-repo task, even though nothing about them had changed.
- `bin/fm-helm-watch.sh` treated any output other than the three exact silent shapes (`''`, `fm-helm-sync: synchronized`, `partial: N cards remain`) as wake-worthy, so this note - and the equally benign `another Helm sync is already running` lock-contention message - turned an otherwise clean run into a wake.

## Fix

`fm_helm_plan_program` now debounces the note through the same divergence-memory shape as every other "already told you" marker in `bin/fm-helm-lib.sh`, keyed on task id and the exact `repo:` value (`state/.helm-unsupported-repo`, kind `unsupported-repo`).
The note text still surfaces once when a task's `repo:` value is first seen (or changes to a new unsupported value), and the underlying diagnostic prints only that once - not on every replan.

`bin/fm-helm-watch.sh` also no longer treats either informational message as wake-worthy on its own: it strips them from the sync's combined output before applying the existing silent-shape check, so a run that only emitted one of them alongside an otherwise-clean sync stays silent.

## Prevention

`tests/fm-helm-sync.test.sh` covers both pieces: an unsupported `repo:` value fires its note and leaves a durable marker on first sight, an unrelated backlog change that forces a full replan does not re-fire it, and changing the task's own `repo:` value does re-fire it with the new value.
It also covers the watcher staying silent on a run whose only unusual output is this note (even on a task's first sync) or the lock-contention message.
