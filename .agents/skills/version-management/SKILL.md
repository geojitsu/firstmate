---
name: version-management
description: >-
  Fleet-wide semantic-versioning protocol for crewmates.
  Covers automatic PATCH/MINOR bumps from Conventional Commit types, escalating MAJOR/breaking bumps as an ask-user finding, and moving every version-bearing manifest together.
  Loaded automatically via the ship brief for every ship task.
icon: 'i-heroicons-tag'
user-invocable: false
metadata:
  internal: true
---

# version-management

Load this on every ship task, regardless of delivery tier.
It defines when to bump a version number, by how much, and when to stop and ask instead of guessing.

## Scheme

Semantic Versioning (`MAJOR.MINOR.PATCH`), driven by the Conventional Commit type on each commit landing on the branch: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`.

## Automatic bumps

Apply these yourself, in the same commit as the change they come from, never a follow-up commit:

- Any `fix:`, `perf:`, or `refactor:` commit that changes shipped behavior -> bump PATCH.
- Any `feat:` commit -> bump MINOR.
- A branch with only `docs:`, `test:`, `ci:`, or `chore:` commits -> no version bump at all.
- When both PATCH- and MINOR-triggering commits exist on the same branch, bump MINOR once; do not also bump PATCH.

## Escalation: breaking changes are never automatic

- A commit whose type/scope is followed by `!` (e.g. `feat!:`, `fix!:`), or that carries a `BREAKING CHANGE:` footer, signals a MAJOR bump.
- Do not apply a MAJOR bump yourself.
- Stop and append `needs-decision: version - breaking change detected, propose vX.0.0 - {one-line reason}` to the status file, exactly like any other ask-user finding; see `ask-user-authority` for the decision procedure firstmate applies.
- A change you genuinely cannot classify as breaking or not escalates the same way rather than guessing.

## Where the version lives

- Bump every version-bearing manifest the project actually has - `package.json`, the extension's `manifest.json`, `Cargo.toml`, `pyproject.toml`, `pubspec.yaml`, or any other that exists - together, in the same commit.
- If the project has no version-bearing manifest, there is nothing to bump; do not invent one.

## When

The bump is part of the same commit(s) that implement the change, before you report `done:` - never a separate later step.
