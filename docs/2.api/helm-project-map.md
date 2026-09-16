---
title: Helm Project Map Command
description: Command reference for managing per-project Helm GitHub Project routing.
icon: 'i-heroicons-command-line'
tags: ['helm', 'cli']
---

## Overview

`fm-helm-project-map.sh` is the direct CLI for inspecting and changing the
main-home Helm routing map. It uses `gh-axi` for board lookup, creation, schema
provisioning, and card relocation.

## Usage

```bash
bin/fm-helm-project-map.sh list [--counts]
bin/fm-helm-project-map.sh link <project> [<title>] [--owner <login>] [--existing <owner>/<number>]
bin/fm-helm-project-map.sh move <project> [<title>] [--owner <login>] [--existing <owner>/<number>] [--default] [--yes]
bin/fm-helm-project-map.sh unlink <project>
bin/fm-helm-project-map.sh sync
```

## API Reference

### `list [--counts]`

Prints every registered project and its default or mapped destination. `--counts`
adds a live Project item count.

### `link <project>`

Creates or reuses and provisions a board, then changes future routing. It does
not relocate existing cards.

### `move <project>`

Requires `--yes` for a non-interactive relocation. `--default` selects the
configured default board. Confirmed moves are resumable.

### `unlink <project>`

Removes the mapping and sends future cards to the default board without moving
existing cards.

### `sync`

Runs the routing reconciliation immediately.

## Notes

Mapping keys must be registered project names. A missing key means the default
board; a missing or malformed configuration refuses direct management commands.
