---
name: context-compaction-advice
description: >-
  Give one quiet, thresholded compaction suggestion at safe firstmate task boundaries.
  It reads the measured context usage and never initiates compaction or drives the firstmate session.
user-invocable: false
metadata:
  internal: true
---

# Context compaction advice

This skill owns the conditional advice to compact a conversation when real transcript usage is high at a natural task seam.
It is intentionally a skill rather than an always-loaded `AGENTS.md` rule because it is needed only at the boundaries below and does not need to survive compaction.

## Trigger boundaries

Load this skill and perform one check after a task's cleanup completes.
Load this skill and perform one check after an investigation report has been written and completely read, immediately before treating that investigation as complete.
Load this skill and perform one check after a captain decision has been durably recorded and routed.
Load this skill and perform one check when an approach is explicitly abandoned.
Do not perform the check for ordinary progress, arbitrary turn ends, or a boundary that has not actually occurred.

## Procedure

Run `bin/fm-context-usage.sh --machine` from the effective Firstmate home and read the complete one-line result.
The command's transcript selection and window-resolution result are authoritative; do not select another transcript, add a counter, estimate usage, or infer a window size.
If the result is not `status=known` with `compact=1`, stay silent.
If the result is actionable, tell the captain exactly once in this conversation: `This is a good moment to compact the conversation: the current context is <percent>% full and a natural boundary has just been reached.`
Replace `<percent>` with the command's measured percentage and do not add a second explanation or a recurring reminder.
Remember within the current conversation that the advice was offered, and reset that ephemeral reminder only after compaction starts a new context episode.

This skill advises the captain only.
It never calls a compaction command, injects a prompt, types a key, sends input, or otherwise drives the firstmate's own session.
