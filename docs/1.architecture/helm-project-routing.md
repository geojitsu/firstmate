---
title: Helm Project Routing
description: Routes each registered local project to its own or a shared GitHub Project board.
icon: 'i-heroicons-map'
tags: ['helm', 'github-projects', 'routing']
---

## Overview

Helm keeps `config/helm.json` as the default board and consults the main home's
`data/helm-project-map.json` for project-specific destinations. The sync parses
the fleet backlog once, groups desired cards by `(owner, number)`, and runs the
existing planner independently for each board. Multiple local projects may
intentionally share a mapped board.

## Usage

The mapping is managed by `bin/fm-helm-project-map.sh`:

```bash
bin/fm-helm-project-map.sh list
bin/fm-helm-project-map.sh link firetabs --existing geojitsu/5
bin/fm-helm-project-map.sh move firetabs --default --yes
bin/fm-helm-project-map.sh unlink firetabs
bin/fm-helm-project-map.sh sync
```

## API Reference

### `bin/fm-helm-sync.sh`

Reconciles all discovered local-home backlogs against their routed boards.

### `bin/fm-helm-poll.sh`

Stores and compares one signature per routed board.

### `bin/fm-helm-reconcile.sh`

Checks mapped-board existence and title drift, resumes confirmed moves, and
routes broken mappings through the existing captain-hold mechanism.

## Notes

`state/helm-cards.tsv` records the current board owner and number. An explicit
move uses `state/helm-moves.tsv` and adds or creates the destination card before
deleting the source card, so a crash leaves a resumable phase rather than an
ambiguous relocation. Routing uses project identity from `data/projects.md`; it
does not use checkout paths.
