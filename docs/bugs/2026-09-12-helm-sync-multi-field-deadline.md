---
title: Helm sync exhausted its per-run write budget
description: One GitHub request per card field let a multi-field reconciliation exceed its fixed deadline before publishing its acknowledgement.
---

## Symptom

New and newly changed Helm cards could stop after one field write.
The sync reported a failed field update or card creation, and did not update the poll signature, so later checks retried the same work.

## Root cause

`bin/fm-helm-sync.sh` applies a bounded deadline to the complete board read and reconciliation run.
The former implementation issued a separate pre-write read and GraphQL mutation for each changed field.
A card needing text plus several field updates could exhaust the deadline partway through its own writes.

## Fix

The sync now plans all changed fields for one card and sends them in one GraphQL mutation.
It performs one pre-write conflict read for an existing card, acknowledges every successful mutation in the local board view, and publishes the matching poll signature.

## Prevention

`tests/fm-helm-sync.test.sh` runs a multi-field card under a constrained request budget with deterministic GitHub-request latency.
The regression verifies every field, the synchronized result, and the updated poll signature.
