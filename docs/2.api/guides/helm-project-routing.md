---
title: Configure Helm Project Routing
description: Worked example for linking local projects to GitHub Project boards.
icon: 'i-heroicons-map'
tags: ['helm', 'setup']
---

## Overview

Helm routing is opt-in. Configure a default board, register local projects in
their local home's `data/projects.md`, and use the mapping command when a
project needs a separate board or should share another board intentionally.

## Usage

```bash
cp docs/examples/helm.json.example config/helm.json
bin/fm-helm-project-map.sh link firetabs --owner geojitsu
bin/fm-helm-project-map.sh list
```

To relocate existing cards, resolve the destination first and then confirm the
operation explicitly:

```bash
bin/fm-helm-project-map.sh move firetabs --existing geojitsu/5 --yes
```

## API Reference

### `data/helm-project-map.json`

Version 1 uses a `projects` object keyed by registered project name, plus nudge
cooldowns under `nudges`. Project entries are `active` or `migrating`. The file
is main-home-only and mode `0600`.

## Notes

`link` and `unlink` affect future cards only. `move` is the only operation that
relocates existing cards, and it can resume from `state/helm-moves.tsv` after a
partial GitHub operation.
