#!/usr/bin/env bash
# fm-helm-reconcile.sh - slowly reconcile Helm routing and board drift.
#
# Usage: bin/fm-helm-reconcile.sh [--force]
#
# This is the third, self-throttled Helm watcher check. It verifies every
# mapped board, records title drift, raises broken mappings through the existing
# captain-hold primitive, resumes confirmed moves, and then asks the ordinary
# multi-board sync to reconcile item drift across all boards.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT_PATH="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_PATH="${FM_HOME:-$FM_ROOT_PATH}"
CONFIG_PATH="${FM_CONFIG_OVERRIDE:-$FM_HOME_PATH/config}"
DATA_PATH="${FM_DATA_OVERRIDE:-$FM_HOME_PATH/data}"
STATE_PATH="${FM_STATE_OVERRIDE:-$FM_HOME_PATH/state}"
CONFIG_FILE="$CONFIG_PATH/helm.json"
MAP_FILE="$DATA_PATH/helm-project-map.json"
LAST_FILE="$STATE_PATH/.helm-reconcile-last"
LOCK_FILE="$STATE_PATH/.helm-sync.lock"
TMP_DIR=
LOCK_HELD=0

reconcile_cleanup() {
  local status=$?
  if [ "$LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$LOCK_FILE" 2>/dev/null || true
  fi
  [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"
  exit "$status"
}
trap reconcile_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'fm-helm-reconcile: %s\n' "$*" >&2
  exit 0
}

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --help|-h)
      sed -n '2,/^set -u$/p' "$0" | sed '$d'
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

[ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || exit 0
[ -d "$DATA_PATH" ] && [ ! -L "$DATA_PATH" ] || fail "data directory is unavailable"
[ -d "$STATE_PATH" ] && [ ! -L "$STATE_PATH" ] || fail "state directory is unavailable"
command -v jq >/dev/null 2>&1 || exit 0
command -v gh-axi >/dev/null 2>&1 || exit 0

# shellcheck source=bin/fm-helm-lib.sh
. "$SCRIPT_DIR/fm-helm-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CONFIG_JSON=$(sed -E '/^[[:space:]]*(\/\/|#)/d' "$CONFIG_FILE") || fail "could not read config/helm.json"
DEFAULT_OWNER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.owner | strings | select(length > 0)' 2>/dev/null) || exit 0
DEFAULT_NUMBER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.number | numbers | select(. > 0)' 2>/dev/null) || exit 0
INTERVAL_HOURS=$(printf '%s\n' "$CONFIG_JSON" | jq -r '.reconcile_interval_hours // 6' 2>/dev/null)
case "$INTERVAL_HOURS" in ''|*[!0-9]*) INTERVAL_HOURS=6 ;; esac
NOW=$(date +%s)
if [ "$FORCE" -eq 0 ] && [ -f "$LAST_FILE" ] && [ ! -L "$LAST_FILE" ]; then
  LAST=$(sed -n '1p' "$LAST_FILE" 2>/dev/null)
  case "$LAST" in
    ''|*[!0-9]*) ;;
    *) [ $((NOW - LAST)) -lt $((INTERVAL_HOURS * 3600)) ] && exit 0 ;;
  esac
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-helm-reconcile.XXXXXX") || fail "could not create temporary workspace"
fm_lock_try_acquire "$LOCK_FILE" || fail "another Helm sync or map operation is already running"
LOCK_HELD=1
if [ -f "$MAP_FILE" ]; then
  [ ! -L "$MAP_FILE" ] || fail "refusing symlinked Helm routing state"
  jq -e '.version == 1 and ((.projects // {}) | type == "object") and ((.nudges // {}) | type == "object")' \
    "$MAP_FILE" >/dev/null 2>&1 || fail "data/helm-project-map.json is invalid"
  cp -- "$MAP_FILE" "$TMP_DIR/map.json" || fail "could not stage Helm routing state"
else
  printf '%s\n' '{"version":1,"projects":{},"nudges":{}}' >"$TMP_DIR/map.json"
fi

publish_map() {
  local tmp
  tmp=$(mktemp "$DATA_PATH/.helm-project-map.XXXXXX") || return 1
  jq -S . "$TMP_DIR/map.json" >"$tmp" || return 1
  chmod 0600 "$tmp" && mv -f -- "$tmp" "$MAP_FILE"
}

record_orphan() {  # <project> <reason>
  local project=$1 reason=$2 existing id
  existing=$(jq -r --arg p "$project" '.projects[$p].orphan_hold_task // empty' "$TMP_DIR/map.json")
  [ -n "$existing" ] && return 0
  id=$(fm_helm_raise_mapping_orphan "$FM_HOME_PATH" "$project" "$reason" 2>/dev/null) \
    || { printf 'fm-helm-reconcile: could not create captain hold for %s\n' "$project" >&2; return 1; }
  jq --arg p "$project" --arg id "$id" '.projects[$p].orphan_hold_task = $id' "$TMP_DIR/map.json" >"$TMP_DIR/map.next" \
    || return 1
  mv -f -- "$TMP_DIR/map.next" "$TMP_DIR/map.json"
  return 0
}

BOARD_TITLE=
board_view() {  # <owner> <number>
  local output
  output=$(gh-axi project view "$2" --owner "$1" 2>/dev/null) || return 1
  BOARD_TITLE=$(printf '%s\n' "$output" | sed -n 's/^title: //p' | head -1 | sed 's/^"//; s/"$//')
  [ -n "$BOARD_TITLE" ] || BOARD_TITLE="$1/$2"
}

# Verify local-project names against every local home registry. The mapping is
# intentionally main-home-owned, but its keys route the fleet-wide backlog union.
HOMES_TSV=$(fm_helm_discover_homes "$FM_HOME_PATH" "$DATA_PATH/secondmates.md" 2>/dev/null) || fail "could not discover fleet homes"
HOME_PATHS=()
while IFS=$'\t' read -r _home_id home_path; do
  [ -n "$home_path" ] && HOME_PATHS+=("$home_path")
done <<EOF
$HOMES_TSV
EOF
REGISTERED=$(fm_helm_project_names "${HOME_PATHS[@]}" | sort -u)
MAP_DIRTY=0

while IFS=$'\t' read -r project owner number title state _hold; do
  [ -n "$project" ] || continue
  if ! printf '%s\n' "$REGISTERED" | awk -v p="$project" '$0 == p { ok=1 } END { exit(ok ? 0 : 1) }'; then
    reason="local project '$project' no longer appears in the project registry (renamed or removed); its Helm routing to $owner/$number is orphaned - point the new project name at this board, send it to the Helm default, or confirm it should be dropped"
    record_orphan "$project" "$reason" && MAP_DIRTY=1
    continue
  fi
  if ! board_view "$owner" "$number"; then
    reason="the GitHub Project $owner/$number backing local project '$project' no longer resolves (renamed away from that number, or deleted by hand) - point '$project' at a different existing board, let me create a new one, or send it back to the Helm default"
    record_orphan "$project" "$reason" && MAP_DIRTY=1
    continue
  fi
  if [ "$title" != "$BOARD_TITLE" ]; then
    jq --arg p "$project" --arg board_title "$BOARD_TITLE" '.projects[$p].title = $board_title' "$TMP_DIR/map.json" >"$TMP_DIR/map.next" \
      || fail "could not record title drift for $project"
    mv -f -- "$TMP_DIR/map.next" "$TMP_DIR/map.json"
    MAP_DIRTY=1
  fi
done < <(jq -r '.projects // {} | to_entries[] | [.key,.value.owner,(.value.number|tostring),(.value.title // ""),(.value.state // "active"),(.value.orphan_hold_task // "")] | @tsv' "$TMP_DIR/map.json")

if ! board_view "$DEFAULT_OWNER" "$DEFAULT_NUMBER"; then
  fm_wake_append check helm-default-board "check: Helm default board $DEFAULT_OWNER/$DEFAULT_NUMBER could not be resolved" >/dev/null 2>&1 || true
else
  # A default-board read is also the cheap source for the optional live-card
  # nudge. The full cross-board item reconciliation remains in fm-helm-sync.sh.
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    jq -e --arg p "$project" '.projects[$p] == null' "$TMP_DIR/map.json" >/dev/null 2>&1 || continue
    live_count=$(gh-axi project item-list "$DEFAULT_NUMBER" --owner "$DEFAULT_OWNER" --query "Project:$project" --limit 1000 2>/dev/null \
      | awk '/^[[:space:]]+[A-Za-z0-9_]+,/{n++} END{print n+0}')
    old_enough=0
    added=$(fm_helm_project_added_date "$project" "${HOME_PATHS[@]}")
    if [ -n "$added" ] && added_epoch=$(date -d "$added" +%s 2>/dev/null); then
      [ $((NOW - added_epoch)) -ge 2592000 ] && old_enough=1
    fi
    [ "$live_count" -ge 5 ] || [ "$old_enough" -eq 1 ] || continue
    last_nudge=$(jq -r --arg p "$project" '.nudges[$p].last_nudged_at // 0' "$TMP_DIR/map.json")
    [ "$last_nudge" -gt 0 ] 2>/dev/null && [ $((NOW - last_nudge)) -lt 2592000 ] && continue
    fm_wake_append check "helm-nudge:$project" "check: local project '$project' has $live_count live cards in the Helm default board; consider giving it its own GitHub Project (fm-helm-project-map.sh link $project)" >/dev/null 2>&1 || true
    jq --arg p "$project" --argjson now "$NOW" '.nudges[$p] = {last_nudged_at:$now,nudge_count:((.nudges[$p].nudge_count // 0) + 1)}' "$TMP_DIR/map.json" >"$TMP_DIR/map.next" \
      || fail "could not record the Helm nudge for $project"
    mv -f -- "$TMP_DIR/map.next" "$TMP_DIR/map.json"
    MAP_DIRTY=1
  done < <(printf '%s\n' "$REGISTERED")
fi

if [ "$MAP_DIRTY" -ne 0 ] && ! publish_map; then
  fail "could not publish Helm reconciliation state"
fi
fm_lock_release "$LOCK_FILE" || fail "could not release the Helm routing lock"
LOCK_HELD=0

# A confirmed migration is an already-approved operation. Continue it without
# asking for a second confirmation, then let the ordinary sync reconcile item
# existence on every board (including cards that drifted or vanished by hand).
while IFS= read -r project; do
  [ -n "$project" ] || continue
  "$SCRIPT_DIR/fm-helm-project-map.sh" move "$project" --yes >/dev/null 2>&1 \
    || printf 'fm-helm-reconcile: move resume failed for %s\n' "$project" >&2
done < <(jq -r '.projects // {} | to_entries[] | select(.value.state == "migrating" and .value.move.confirmed == true) | .key' "$TMP_DIR/map.json")

printf '%s\n' "$NOW" >"$TMP_DIR/last"
if ! chmod 0600 "$TMP_DIR/last" || ! mv -f -- "$TMP_DIR/last" "$LAST_FILE"; then
  fail "could not publish reconcile cadence"
fi
"$SCRIPT_DIR/fm-helm-sync.sh" --force >/dev/null 2>&1 || true
