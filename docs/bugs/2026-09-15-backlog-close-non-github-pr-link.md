---
title: Crash-recovery close wedged on a non-GitHub PR link
description: A GitLab merge-request link recorded in a pending backlog close made bootstrap's crash-recovery replay fail forever.
---

## Symptom

A teardown for a GitLab-hosted project recorded `state/<id>.backlog-close` with a GitLab merge-request link (`.../-/merge_requests/<number>`) as the `--pr` value, then crashed before replaying the close.
Every later `bin/fm-bootstrap.sh` crash-recovery replay then failed with `error: Task pr link must be an http(s) pull request URL ending in /pull/<number>`, wedging the close forever until it was closed by hand.

## Root cause

`bin/fm-backlog-transition-lib.sh`'s `fm_backlog_done` passed a close's recorded `--pr` link straight to `tasks-axi done`.
tasks-axi's own `--pr` validator only accepts an http(s) URL ending in `/pull/<number>` (GitHub's shape); it rejects any other host's PR/MR link, including GitLab's `/-/merge_requests/<number>` shape, with a `VALIDATION_ERROR`.
The pending-close record's own validator (`fm_backlog_close_marker_validate`) is deliberately a generic http(s)-URL check, so it staged the link without complaint; the rejection only surfaced later, inside `tasks-axi done` itself, on both the live close and every crash-recovery replay attempt.

See also [Helm sync dropped non-GitHub PR links](2026-09-14-helm-sync-multi-host-pr-link.md), a related but distinct bug: that one was Helm's own card renderer dropping a GitLab link before display, while this one is tasks-axi's own `--pr` validator rejecting one outright.

## Fix

`fm_backlog_done` now detects that specific rejection from tasks-axi's own error text and exit status, then retries the same link recorded via `--note` instead of `--pr`.
A GitHub-shaped link is unaffected.
Because `bin/fm-teardown.sh`'s live close and `fm_backlog_close_marker_replay`'s crash-recovery replay both call this one function, the fallback applies identically either way.
tasks-axi's own `--pr` validator is unchanged; this is a firstmate-side workaround, not a fix to tasks-axi itself.

## Prevention

`tests/fm-backlog-atomicity.test.sh` closes a task with a GitHub-shaped PR link (unchanged `--pr` behavior) and with a GitLab-shaped one (the `--note` fallback), on both the live teardown path and the bootstrap replay path.
