---
title: Helm Sync Partial-Write Loop
description: Root cause and prevention for repeated board-edit wakes, partial writes, and duplicate Done cards.
tags: ['helm', 'github-projects', 'bug']
---

## Symptoms

The Helm poll check repeatedly reported that the captain edited the board. Forced syncs then failed on different cards, reported a varying number of remaining cards, and sometimes created a second card for a task that had just finished.

The reproduction is covered by the fixture-only shell and Python parity suites. The fixtures use owner `fixture-owner` and project numbers `999` or `1000`; they do not call the captain's board.

## Root cause

Four state transitions interacted:

1. A batched GraphQL mutation could apply one or more aliases and still return an error. The executor only recorded a landed patch after the whole mutation succeeded, so the poll baseline was computed from a stale snapshot. The next poll interpreted the sync's own partial progress as a captain edit.
2. Mutation stderr and GraphQL `errors` were discarded. Without pacing or bounded retry, secondary-limit responses surfaced only as “could not create or update,” and the deadline stopped a different card on each run.
3. The planner skipped the stale cached-item guard for `Done` records. Teardown retains Done backlog rows, so a delayed or partial board snapshot could enter the create path before the deleted phase wrote its tombstone.
4. `BOARD_WRITE_DETAIL` was only ever set on a failure path and never reset at the top of a card's write evaluation. Once one card in a board failed, the stale detail from that card carried into every later card's check in the same run, so healthy cards were counted as failed, never landed, and reported with another card's error text.

## Fix

The sync now spaces mutating requests, retries transient rate-limit and transport failures with bounded backoff, and includes the GraphQL or `gh api` diagnostic in the card and board failure messages. After any failed board write it rereads the board and acknowledges the poll signature only from that fresh snapshot; if the reread fails, the run remains partial and retryable.

The jq and Python planners now apply the stale cached-item guard to every retained backlog state, including `Done`. The deleted phase records the tombstone, while an existing marker still wins on a later read. These decisions are idempotent across forced reruns and preserve the durable cache/resume path.

`BOARD_WRITE_DETAIL` is now cleared at the start of each card's write evaluation in `bin/fm-helm-sync.sh`, so one card's failure can never mark a later, unrelated card as failed.

## Prevention

Run the focused checks with:

```bash
bin/fm-test-run.sh tests/fm-helm-sync.test.sh
bin/fm-test-run.sh tests/fm-helm-sync-python.test.sh
```

The shell regression injects a partial mutation with a secondary-limit response and verifies both the real error text and the absence of a self-triggered poll wake. A second shell regression fails only one card's write on a two-card board and asserts the other card's write still lands and is not reported as failed. The Python parity regression verifies that a stale cached `Done` item is skipped and tombstoned rather than recreated.
