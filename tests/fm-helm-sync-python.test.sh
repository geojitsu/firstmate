#!/usr/bin/env bash
set -eu

# Coverage: tests/jq_parity.py imports the whole python/helm_sync package, so
# a change to any of its source files is proven here.
#   python/helm_sync/__init__.py
#   python/helm_sync/backlog.py
#   python/helm_sync/desired.py
#   python/helm_sync/fleet.py
#   python/helm_sync/model.py
#   python/helm_sync/planner.py
#   python/helm_sync/routing.py
#   python/helm_sync/settings.py

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
python3 "$ROOT/tests/jq_parity.py"
