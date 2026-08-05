# Context usage verification

Audience: maintainer verification.

This record supports the measured context command and its thresholded compaction advice.
The command reads transcript usage records rather than estimating from turn count, tool calls, or output size.

## Window source

The Claude CLI 2.1.221 help surface was checked on 2026-08-04 and confirmed `--autocompact <auto|tokens>` accepts 100k-1M tokens.
The current Anthropic model documentation was checked on 2026-08-04 at https://docs.anthropic.com/en/docs/about-claude/models/overview.
That documentation identifies a 1M-token context window for Claude Opus 5 and the current Claude model families recognized by the command.
The command therefore uses 1,000,000 tokens for those model identifiers and exposes `FM_CONTEXT_WINDOW_TOKENS` plus `config/context-window-tokens` for an explicit alternate configuration.

## Live transcript measurement

The following command was run against the active Claude transcript on 2026-08-04.

```sh
FM_CONTEXT_USAGE_TRANSCRIPT=/home/geod/.claude/projects/-home-geod-firstmate/01ea665a-a325-4fce-9dc8-322aa46febac.jsonl \
  bin/fm-context-usage.sh
```

Observed output:

```text
context usage: 165428 tokens (16.5% of 1000000-token window; model claude-opus-5; transcript /home/geod/.claude/projects/-home-geod-firstmate/01ea665a-a325-4fce-9dc8-322aa46febac.jsonl)
```

The total is the newest record's `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.

## Boundary behavior

The recommended band is roughly 50-60% of the context window, with 50% as the actionable lower edge.
The `context-compaction-advice` skill checks the real measurement only after task cleanup, after an investigation report is written and read, after a captain decision is durably recorded, or when an approach is abandoned.
It remains silent below the band or when the transcript, usage record, or window is unknown.
It advises the captain once per context episode and never triggers, injects, types, or otherwise drives compaction.

## Deterministic regression coverage

```sh
tests/fm-context-usage.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

The regression suite covers exact transcript binding, newest usage selection, missing, empty, malformed, incomplete, unreadable, ambiguous, and unknown-window inputs, plus the configured window override and 50% threshold.
