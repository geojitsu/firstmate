#!/usr/bin/env bash
# fm-helm-poll.sh - one cheap read-only poll for a captain edit to the Helm
# board.
#
# Inert by default: a HARD no-op (exit 0, no output) unless config/helm.json
# exists. The watcher invokes this trusted repository script only after
# state/helm-board.check.sh matches its byte-static identity shim.
#
# Contract: "output => wake firstmate, silence => keep sleeping". It prints ONE
# line when the board changed; when a backlog change is pending, the line asks
# firstmate to force a reconciliation rather than silently losing the board
# edit. It never mutates the board or the backlog. It finishes well inside
# FM_CHECK_TIMEOUT. One 20-second deadline covers the whole paginated board
# read. When `timeout` is unavailable, a watchdog stops the `gh` request at
# that same deadline.
#
# Enable (firstmate, main home, once, alongside creating config/helm.json):
#   printf 'exec "%s/bin/fm-helm-poll.sh" "$@"\n' "$FM_ROOT" > state/helm-board.check.sh
#   chmod 0700 state/helm-board.check.sh
#   bin/fm-check-register.sh helm-board
# Retire with bin/fm-check-unregister.sh helm-board.
#
# Snapshot: state/.helm-board-poll (mode 0600) holds the last board signature.
# The signature (fm_helm_board_signature_program in bin/fm-helm-lib.sh, shared
# with the sync) folds, per card, the (Status, Priority, title, body) it shows,
# plus the card count. Any captain edit to those changes it.
#
# When a board and backlog change coincide, the poll emits a reconciliation wake.
# The forced sync leaves any field-level conflict for firstmate to resolve.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT_PATH="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_PATH="${FM_HOME:-$FM_ROOT_PATH}"
CONFIG_PATH="${FM_CONFIG_OVERRIDE:-$FM_HOME_PATH/config}"
DATA_PATH="${FM_DATA_OVERRIDE:-$FM_HOME_PATH/data}"
STATE_PATH="${FM_STATE_OVERRIDE:-$FM_HOME_PATH/state}"
CONFIG_FILE="$CONFIG_PATH/helm.json"
SECONDMATES_PATH="$DATA_PATH/secondmates.md"
SYNC_HASH_FILE="$STATE_PATH/.helm-sync-backlog.sha256"
POLL_FILE="$STATE_PATH/.helm-board-poll"
TMP_DIR=

poll_cleanup() {
  local status=$?
  [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf -- "$TMP_DIR"
  exit "$status"
}
trap poll_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Hard no-op when Helm is off.
[ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
[ -L "$POLL_FILE" ] && exit 0

# shellcheck source=bin/fm-helm-lib.sh
. "$SCRIPT_DIR/fm-helm-lib.sh"

CONFIG_JSON=$(sed -E '/^[[:space:]]*(\/\/|#)/d' "$CONFIG_FILE") || exit 0
OWNER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.owner | strings | select(length > 0)' 2>/dev/null) || exit 0
PROJECT_NUMBER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.number | numbers | select(. > 0)' 2>/dev/null) || exit 0

# A pending backlog change means the ordinary sync is about to run: stay quiet.
HOMES_TSV="$(fm_helm_discover_homes "$FM_HOME_PATH" "$SECONDMATES_PATH" 2>/dev/null)" || exit 0
BACKLOG_PATHS=()
while IFS=$'\t' read -r _hid _hpath; do
  [ -n "$_hpath" ] || continue
  BACKLOG_PATHS+=("$_hpath/data/backlog.md")
done <<EOF
$HOMES_TSV
EOF
[ "${#BACKLOG_PATHS[@]}" -gt 0 ] || exit 0
BACKLOG_HASH=$(fm_helm_combined_hash "${BACKLOG_PATHS[@]}" 2>/dev/null) || exit 0
BACKLOG_PENDING=1
if [ -f "$SYNC_HASH_FILE" ] && [ "$(sed -n '1p' "$SYNC_HASH_FILE" 2>/dev/null)" = "$BACKLOG_HASH" ]; then
  BACKLOG_PENDING=0
fi

AUTH_OUTPUT=$(gh auth status 2>&1) || exit 0
printf '%s\n' "$AUTH_OUTPUT" | grep -Eiq "(['\"]project['\"]|(^|[[:space:],])project([[:space:],]|$))" || exit 0

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-helm-poll.XXXXXX") || exit 0
BOARD_JSON="$TMP_DIR/board.json"

# shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
QUERY='query($owner:String!, $number:Int!, $cursor:String) {
  user(login:$owner) {
    projectV2(number:$number) {
      items(first:100, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content {
            __typename
            ... on DraftIssue { title body }
            ... on Issue { title body }
          }
          fieldValues(first:30) {
            nodes {
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2SingleSelectField { name } }
              }
            }
          }
        }
      }
    }
  }
}'

run_gh_bounded() {
  local seconds=$1 command_pid watchdog_pid status
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
    return
  fi
  "$@" &
  command_pid=$!
  ( sleep "$seconds"; kill "$command_pid" 2>/dev/null || true ) &
  watchdog_pid=$!
  wait "$command_pid"
  status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$status"
}

PAGE_COUNT=0
CURSOR=
PAGINATION_DEADLINE=$(( $(date +%s) + 20 ))
while :; do
  PAGE_COUNT=$((PAGE_COUNT + 1))
  [ "$PAGE_COUNT" -le 50 ] || exit 0
  PAGE_JSON="$TMP_DIR/board-page-$PAGE_COUNT.json"
  GH_ARGS=(
    --field "query=$QUERY"
    --field "owner=$OWNER"
    --field "number=$PROJECT_NUMBER"
  )
  [ -z "$CURSOR" ] || GH_ARGS+=(--field "cursor=$CURSOR")
  REMAINING=$(( PAGINATION_DEADLINE - $(date +%s) ))
  [ "$REMAINING" -gt 0 ] || exit 0
  run_gh_bounded "$REMAINING" gh api graphql "${GH_ARGS[@]}" >"$PAGE_JSON" 2>/dev/null || exit 0
  jq -e '(.errors // []) | length == 0' "$PAGE_JSON" >/dev/null 2>&1 || exit 0
  if [ "$PAGE_COUNT" -eq 1 ]; then
    mv -f -- "$PAGE_JSON" "$BOARD_JSON"
  else
    jq -s '.[0] as $all | .[1] as $page
      | $all
      | .data.user.projectV2.items.nodes += $page.data.user.projectV2.items.nodes
      | .data.user.projectV2.items.pageInfo = $page.data.user.projectV2.items.pageInfo' \
      "$BOARD_JSON" "$PAGE_JSON" >"$BOARD_JSON.next" 2>/dev/null || exit 0
    mv -f -- "$BOARD_JSON.next" "$BOARD_JSON" || exit 0
  fi
  if [ "$(jq -r '.data.user.projectV2.items.pageInfo.hasNextPage' "$BOARD_JSON")" = false ]; then
    break
  fi
  CURSOR=$(jq -r '.data.user.projectV2.items.pageInfo.endCursor // empty' "$BOARD_JSON")
  [ -n "$CURSOR" ] || exit 0
done

SIGNATURE=$(jq -r "$(fm_helm_board_signature_program)" "$BOARD_JSON" | fm_helm_sha256_stdin) || exit 0
[ -n "$SIGNATURE" ] || exit 0

store_signature() {
  local tmp
  tmp=$(mktemp "$TMP_DIR/poll.XXXXXX") || return 1
  printf '%s\n' "$SIGNATURE" >"$tmp" || return 1
  chmod 0600 "$tmp" || return 1
  mv -f -- "$tmp" "$POLL_FILE"
}

# First run (or a cleared snapshot): baseline silently, never wake.
if [ ! -f "$POLL_FILE" ]; then
  store_signature
  exit 0
fi
PREVIOUS=$(cat "$POLL_FILE" 2>/dev/null || true)
if [ "$SIGNATURE" = "$PREVIOUS" ]; then
  exit 0
fi

store_signature || exit 0

if [ "$BACKLOG_PENDING" -eq 1 ]; then
  printf 'check: Helm board and backlog both changed; run bin/fm-helm-sync.sh --force to reconcile\n'
  exit 0
fi

printf 'check: Helm board edited by the captain; run bin/fm-helm-sync.sh --force to reconcile\n'
