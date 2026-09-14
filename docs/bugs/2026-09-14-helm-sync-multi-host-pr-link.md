---
title: Helm sync dropped non-GitHub PR links
description: Helm sync now preserves GitHub pull-request and GitLab merge-request URLs in card Facts sections.
---

## Symptom

Helm cards showed a `PR:` Facts line for GitHub pull-request URLs, but omitted the line for GitLab merge-request URLs even when `fm-helm-pr-check` had recorded the link in the backlog.

## Root cause

The backlog parser selected a PR URL only when it matched the GitHub-specific `/pull/<number>` path. GitLab's `/-/merge_requests/<number>` path therefore passed through as an ordinary backlog URL and was removed from the rendered card title without being retained for the Facts section.

## Fix

The parser now recognizes the canonical PR and MR URL shapes documented in [Helm board sync configuration](../configuration.md#helm-board-sync-confighelmjson). The existing card renderer continues to place a retained link in the Facts section.

## Prevention

`tests/fm-helm-sync.test.sh` creates cards from backlog rows containing both GitHub and GitLab links and asserts that each appears as a `PR:` Facts line. Keep new provider-specific URL shapes in this allowlist rather than accepting every URL from task notes.
