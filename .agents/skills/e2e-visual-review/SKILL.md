---
name: e2e-visual-review
description: >-
  Fleet-wide convention for capturing visual evidence whenever a task actually runs a project's E2E test suite.
  Covers what to capture, where it goes as a named exception to worktree isolation, and the crewmate's responsibility boundary against firstmate's own review-page tooling.
  Loaded automatically via the ship brief for every ship task.
icon: 'i-heroicons-film'
user-invocable: false
metadata:
  internal: true
---

# e2e-visual-review

Load this on any task, ship or scout, that actually runs a project's E2E test suite as part of its work.
It defines what visual evidence to capture from that run, where to leave it, and where your responsibility ends.

## Scope

Applies only when your task actually executes a project's E2E test suite.
A project with no E2E test suite means this section is a no-op: do not add one, invent one, or run an unrelated test suite just to trigger this protocol.
Do not start a separate, redundant E2E run solely to record it; capture happens as part of the same run you were already performing for the task.

## What to capture

Framework-agnostic, using whatever the test framework already supports natively:

- Screenshots at meaningful checkpoints during the run (most frameworks already support this, e.g. Playwright's `page.screenshot()`).
- A full video recording of the run, if the framework has native support for it (e.g. Playwright's `recordVideo` option on `launch()`/`launchPersistentContext()`, Cypress's built-in video capture).
- If the framework has no native recording capability, screenshots alone are acceptable.
  Do not build a custom recording mechanism from scratch.

## Where it goes

Your project worktree is disposable and torn down after the task, so evidence must not be left only there.

Write every captured screenshot and video, plus a short `manifest.md` describing what each file shows and at what point in the run, to `data/<task-id>/e2e-review/` in the firstmate home.
This is a sibling location to the already-established `data/<task-id>/report.md` and the status file, both of which are named exceptions to "stay inside this worktree; modify nothing outside it".
This is a third such named exception, not a general license to write elsewhere.

## Your responsibility boundary

You do not invoke `lavish-axi` yourself or otherwise manage a Lavish review-session lifecycle.
Building or opening the actual review page from your evidence is firstmate's own operational job, not yours.
Your scope ends at producing well-located, well-labeled evidence, plus a one-line mention of the `data/<task-id>/e2e-review/` path in your `done`/status report so firstmate knows where to find it.
