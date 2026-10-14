---
title: Helm sync stopped on duplicate board cards
description: A duplicate task identity on the Helm board collapsed into a generic board failure and blocked unrelated cards from syncing.
---

## Symptom

On 2026-10-13, `fm-helm-sync.sh` reported `1 board(s) could not be reconciled: geojitsu/2` while Project 2 remained readable and GitHub rate limits were healthy.
The live read-only board listing contained three cards for `firetabs-mirror-grouped-tab-reappears-001`: two cards with the `firetabs` project and one card with the fallback `other` project.
The identity cache contained only the intended `firetabs` card, so the duplicate task identity was the first meaningful divergence.

## Root cause

`fm_helm_plan_program` deliberately emits a planner error when more than one board card has the same task-id marker.
The executor in `bin/fm-helm-sync.sh` discarded that error text, recorded only the board key, and returned from `process_board` before executing later healthy plan entries.
That made the watcher alert generic and caused the same malformed card to block the whole board on every retry.

## Fix

Board failures now retain their phase and reason, such as `geojitsu/2: plan: duplicate Helm cards for firetabs-mirror-grouped-tab-reappears-001`.
Planner errors are isolated to the bad plan entry so unrelated cards continue through the ordinary reconciliation loop.
Board-level wake publication remains deduplicated by board while multiple failure reasons remain visible in the final diagnostic.
A plan-only failure still publishes the successful reconciliation/debounce state, so an unchanged malformed card does not wake the watcher again; a board or backlog change causes a fresh check.

## Prevention

`tests/fm-helm-sync.test.sh` adds a duplicate-card fixture that asserts the planner reason is surfaced and a healthy card on the same board still reaches `In flight`.
The fixture runs through the fake GitHub CLI, so it cannot mutate the captain's board.
The Python jq-parity suite continues to pass, preserving the existing planner behavior that identifies duplicate card identities.
