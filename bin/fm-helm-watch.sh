#!/usr/bin/env bash
# fm-helm-watch.sh - watcher-check adapter for the optional Helm board sync.
#
# The main home's bootstrap installs state/helm-sync.check.sh as an authenticated
# watcher check while config/helm.json exists.  The watcher runs this adapter at
# its ordinary check cadence.  A successful or debounced sync is silent, so it
# never wakes firstmate, and so is a clean partial run (the sync's deadline
# arrived with cards still to write): the next check resumes it from the
# progress the sync already recorded.  A fail-open diagnostic, including a
# card write the sync could not land, is preserved on stdout: the watcher turns
# that output into a durable check wake instead of allowing a backlog item to
# disappear from the board silently.
#
# The underlying sync is the sole board writer and aggregates every local
# secondmate backlog, so this main-home check covers their transitions too.
#
# Usage: bin/fm-helm-watch.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! OUTPUT=$("$SCRIPT_DIR/fm-helm-sync.sh" 2>&1); then
  [ -n "$OUTPUT" ] || OUTPUT="fm-helm-sync: watcher invocation failed"
  printf '%s\n' "$OUTPUT"
  exit 0
fi

case "$OUTPUT" in
  ''|'fm-helm-sync: synchronized') exit 0 ;;
  'fm-helm-sync: partial: '*' cards remain') exit 0 ;;
  *) printf '%s\n' "$OUTPUT" ;;
esac
