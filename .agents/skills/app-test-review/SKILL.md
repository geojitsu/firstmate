---
name: app-test-review
description: >-
  Firstmate's own procedure for building the captain's interactive review page from visual evidence a crewmate captured under data/<task-id>/e2e-review/.
  Covers when to build it, where the built page lives, what it must contain, and the lavish-axi mechanism used to build it.
  Load whenever a task's PR-ready or done report points at that evidence, before that captain-facing checkpoint.
icon: 'i-heroicons-play-circle'
user-invocable: false
metadata:
  internal: true
---

# app-test-review

Load this whenever a task's PR-ready or `done` report points at evidence under `data/<task-id>/e2e-review/`.
It defines when firstmate builds the captain's review page from that evidence, where the built page lives, what it must contain, and how it gets built.
Building the page is firstmate's own job; the crewmate skill `e2e-visual-review` never does this itself - see its "Your responsibility boundary" section.

## When

Build the review page whenever a task that left evidence at `data/<task-id>/e2e-review/` reaches a captain-facing checkpoint: PR ready or `done`.
This is the default review artifact for that change, not an optional extra reserved for explicit requests.
A task with no `data/<task-id>/e2e-review/` evidence means there is nothing to build; skip this silently.

## Where

Build the page at `.lavish/<project>/<type>-<task-id>/review.html` inside this firstmate home.
`<project>` is the project the task shipped against; `<type>` is `feature-review` or `bug-detection`, whichever best describes the nature of the change.
This location is captain-private, gitignored, and durable: it survives the crewmate's worktree teardown, unlike `data/<task-id>/e2e-review/` itself, which does not survive `/stow`-style long-term cleanup the same way.

## Contents

Embed every screenshot and video the crewmate captured directly in the page - inline as `data:` URIs or otherwise self-contained per Lavish's own constraints.
Never merely link to the evidence files in `data/<task-id>/e2e-review/`; that directory is not guaranteed to persist alongside the built page.
Read the crewmate's `manifest.md` for what each file shows and at what point in the run, and use it to caption and order the evidence.

## Mechanism

Build the page with `lavish-axi`, following its own conventions: run `lavish-axi playbook <playbook_id>` for relevant guidance (the `code`, `diagram`, or `comparison` playbooks may apply depending on what the evidence shows) and consult its help output rather than reinventing structure by hand.
This gives the captain the normal interactive Lavish review surface - annotation, queued feedback, and `lavish-axi poll` - rather than a static dump.
