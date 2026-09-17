#!/usr/bin/env bash
set -eu

# Coverage: python/helm_sync/tests/jq_parity.py imports the whole
# python/helm_sync package, so a change to any of its source files, or to the
# parity suite itself, is proven here via this file's own literal references
# (the generic changed-file selector maps any path by scanning test sources
# for a literal reference to it):
#   python/helm_sync/__init__.py
#   python/helm_sync/backlog.py
#   python/helm_sync/desired.py
#   python/helm_sync/fleet.py
#   python/helm_sync/model.py
#   python/helm_sync/planner.py
#   python/helm_sync/routing.py
#   python/helm_sync/settings.py
#   python/helm_sync/tests/jq_parity.py

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
if python3 -c "import pytest" >/dev/null 2>&1; then
  python3 -m pytest "$ROOT/python/helm_sync/tests/jq_parity.py"
else
  python3 "$ROOT/python/helm_sync/tests/jq_parity.py"
fi
