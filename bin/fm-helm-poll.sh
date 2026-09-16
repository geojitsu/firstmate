#!/usr/bin/env bash
# fm-helm-poll.sh - one cheap read-only poll for captain edits on Helm boards.
#
# Helm is inert until the main home's config/helm.json exists. The watcher runs
# this trusted repository script through state/helm-board.check.sh. Output wakes
# firstmate; silence keeps the watcher asleep. The poll never mutates a board or
# backlog. It stores one signature per owner/number in state/.helm-board-poll.
#
# Usage: bin/fm-helm-poll.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT_PATH="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_PATH="${FM_HOME:-$FM_ROOT_PATH}"
CONFIG_PATH="${FM_CONFIG_OVERRIDE:-$FM_HOME_PATH/config}"
DATA_PATH="${FM_DATA_OVERRIDE:-$FM_HOME_PATH/data}"
STATE_PATH="${FM_STATE_OVERRIDE:-$FM_HOME_PATH/state}"
CONFIG_FILE="$CONFIG_PATH/helm.json"
ROUTING_FILE="$DATA_PATH/helm-project-map.json"
SECONDMATES_PATH="$DATA_PATH/secondmates.md"
SYNC_HASH_FILE="$STATE_PATH/.helm-sync-backlog.sha256"
POLL_FILE="$STATE_PATH/.helm-board-poll"
CARDS_FILE="$STATE_PATH/helm-cards.tsv"
TMP_DIR=

poll_cleanup() {
  local status=$?
  [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf -- "$TMP_DIR"
  exit "$status"
}
trap poll_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
[ -L "$POLL_FILE" ] && exit 0
[ -L "$ROUTING_FILE" ] && exit 0

# shellcheck source=bin/fm-helm-lib.sh
. "$SCRIPT_DIR/fm-helm-lib.sh"

CONFIG_JSON=$(sed -E '/^[[:space:]]*(\/\/|#)/d' "$CONFIG_FILE") || exit 0
OWNER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.owner | strings | select(length > 0)' 2>/dev/null) || exit 0
PROJECT_NUMBER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.number | numbers | select(. > 0)' 2>/dev/null) || exit 0

HOMES_TSV="$(fm_helm_discover_homes "$FM_HOME_PATH" "$SECONDMATES_PATH" 2>/dev/null)" || exit 0
BACKLOG_PATHS=()
while IFS=$'\t' read -r _hid _hpath; do
  [ -n "$_hpath" ] || continue
  BACKLOG_PATHS+=("$_hpath/data/backlog.md")
done <<EOF
$HOMES_TSV
EOF
[ "${#BACKLOG_PATHS[@]}" -gt 0 ] || exit 0

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-helm-poll.XXXXXX") || exit 0
ROUTING_JSON="$TMP_DIR/routing.json"
if [ -f "$ROUTING_FILE" ]; then
  jq -e '.version == 1 and ((.projects // {}) | type == "object")' "$ROUTING_FILE" >/dev/null 2>&1 || exit 0
  cp -- "$ROUTING_FILE" "$ROUTING_JSON" || exit 0
else
  printf '%s\n' '{"version":1,"projects":{},"nudges":{}}' >"$ROUTING_JSON" || exit 0
fi
BACKLOG_HASH=$(fm_helm_combined_hash "${BACKLOG_PATHS[@]}" "$ROUTING_FILE" 2>/dev/null) || exit 0
BACKLOG_PENDING=1
if [ -f "$SYNC_HASH_FILE" ] && [ "$(sed -n '1p' "$SYNC_HASH_FILE" 2>/dev/null)" = "$BACKLOG_HASH" ]; then
  BACKLOG_PENDING=0
fi

AUTH_OUTPUT=$(gh auth status 2>&1) || exit 0
printf '%s\n' "$AUTH_OUTPUT" | grep -Eiq "(['\"]project['\"]|(^|[[:space:],])project([[:space:],]|$))" || exit 0

BOARD_KEYS_RAW="$TMP_DIR/board-keys.raw"
BOARD_KEYS_FILE="$TMP_DIR/board-keys.tsv"
{
  printf '%s\t%s\n' "$OWNER" "$PROJECT_NUMBER"
  jq -r '.projects // {} | to_entries[] | select((.value.state // "active") == "active" or (.value.state // "") == "migrating") | [.value.owner, (.value.number | tostring)] | @tsv' "$ROUTING_JSON"
  awk -F '\t' 'NF >= 11 && $10 != "" && $11 != "" { print $10 "\t" $11 }' "$CARDS_FILE" 2>/dev/null || true
} | awk -F '\t' '!seen[$1 SUBSEP $2]++' >"$BOARD_KEYS_RAW" || exit 0
{
  awk -F '\t' -v owner="$OWNER" -v number="$PROJECT_NUMBER" '$1 == owner && $2 == number' "$BOARD_KEYS_RAW"
  awk -F '\t' -v owner="$OWNER" -v number="$PROJECT_NUMBER" '$1 != owner || $2 != number' "$BOARD_KEYS_RAW" \
    | sort -t $'\t' -k1,1 -k2,2n
} >"$BOARD_KEYS_FILE" || exit 0
BOARD_COUNT=$(awk 'END { print NR + 0 }' "$BOARD_KEYS_FILE")
POLL_BUDGET=$((20 * BOARD_COUNT))
[ "$POLL_BUDGET" -le 120 ] || POLL_BUDGET=120
POLL_DEADLINE=$(( $(date +%s) + POLL_BUDGET ))

# shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
QUERY='query($owner:String!, $number:Int!, $cursor:String) {
  user(login:$owner) {
    projectV2(number:$number) {
      id
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

# shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
ORG_QUERY='query($owner:String!, $number:Int!, $cursor:String) {
  organization(login:$owner) {
    projectV2(number:$number) {
      id
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

BOARD_READ_SEQUENCE=0
read_board() {
  local owner=$1 number=$2 output=$3 query=$QUERY page_count=0 cursor='' page_json remaining
  local -a gh_args
  while :; do
    page_count=$((page_count + 1))
    [ "$page_count" -le 50 ] || return 1
    page_json="$TMP_DIR/board-page-$BOARD_READ_SEQUENCE-$page_count.json"
    gh_args=(--field "query=$query" --field "owner=$owner" --field "number=$number")
    [ -z "$cursor" ] || gh_args+=(--field "cursor=$cursor")
    remaining=$((POLL_DEADLINE - $(date +%s)))
    [ "$remaining" -gt 0 ] || return 1
    run_gh_bounded "$remaining" gh api graphql "${gh_args[@]}" >"$page_json" 2>/dev/null || return 1
    if jq -e '(.errors // []) | length > 0' "$page_json" >/dev/null 2>&1; then
      return 1
    fi
    if [ "$query" = "$ORG_QUERY" ]; then
      jq '.data.user.projectV2 = (.data.organization.projectV2 // null)' "$page_json" >"$page_json.normalized" || return 1
      mv -f -- "$page_json.normalized" "$page_json" || return 1
    fi
    if ! jq -e '.data.user.projectV2.id' "$page_json" >/dev/null 2>&1; then
      if [ "$query" = "$QUERY" ]; then
        query=$ORG_QUERY
        page_count=0
        cursor=
        continue
      fi
      return 1
    fi
    if [ "$page_count" -eq 1 ]; then
      cat -- "$page_json" >"$output" || return 1
    else
      jq -s '.[0] as $all | .[1] as $page
        | $all
        | .data.user.projectV2.items.nodes += $page.data.user.projectV2.items.nodes
        | .data.user.projectV2.items.pageInfo = $page.data.user.projectV2.items.pageInfo' \
        "$output" "$page_json" >"$output.next" || return 1
      mv -f -- "$output.next" "$output" || return 1
    fi
    if [ "$(jq -r '.data.user.projectV2.items.pageInfo.hasNextPage' "$output")" = false ]; then
      return 0
    fi
    cursor=$(jq -r '.data.user.projectV2.items.pageInfo.endCursor // empty' "$output")
    [ -n "$cursor" ] || return 1
  done
}

POLL_WORK="$TMP_DIR/poll-work.tsv"
: >"$POLL_WORK"
if [ -f "$POLL_FILE" ]; then
  while IFS= read -r poll_line || [ -n "$poll_line" ]; do
    case "$poll_line" in
      *$'\t'*) printf '%s\n' "$poll_line" >>"$POLL_WORK" ;;
      '') ;;
      *) printf '%s/%s\t%s\n' "$OWNER" "$PROJECT_NUMBER" "$poll_line" >>"$POLL_WORK" ;;
    esac
  done <"$POLL_FILE"
fi

store_poll() {
  local tmp
  tmp=$(mktemp "$TMP_DIR/poll.XXXXXX") || return 1
  cat -- "$POLL_WORK" >"$tmp" || return 1
  chmod 0600 "$tmp" || return 1
  mv -f -- "$tmp" "$POLL_FILE"
}

CHANGED=0
SUCCEEDED_BOARDS=0
FAILED_BOARDS=()
while IFS=$'\t' read -r board_owner board_number; do
  [ -n "$board_owner" ] && [ -n "$board_number" ] || continue
  BOARD_READ_SEQUENCE=$((BOARD_READ_SEQUENCE + 1))
  board_key="$board_owner/$board_number"
  board_json="$TMP_DIR/board-$BOARD_READ_SEQUENCE.json"
  if ! read_board "$board_owner" "$board_number" "$board_json"; then
    FAILED_BOARDS+=("$board_key")
    continue
  fi
  SUCCEEDED_BOARDS=$((SUCCEEDED_BOARDS + 1))
  signature=$(jq -r "$(fm_helm_board_signature_program)" "$board_json" | fm_helm_sha256_stdin) || continue
  [ -n "$signature" ] || continue
  previous=$(awk -F '\t' -v k="$board_key" '$1 == k { print $2; exit }' "$POLL_WORK")
  [ -z "$previous" ] || [ "$signature" = "$previous" ] || CHANGED=1
  poll_tmp=$(mktemp "$TMP_DIR/poll.XXXXXX") || exit 0
  awk -F '\t' -v k="$board_key" '$1 != k' "$POLL_WORK" >"$poll_tmp" || exit 0
  printf '%s\t%s\n' "$board_key" "$signature" >>"$poll_tmp" || exit 0
  mv -f -- "$poll_tmp" "$POLL_WORK" || exit 0
done <"$BOARD_KEYS_FILE"

if [ "${#FAILED_BOARDS[@]}" -gt 0 ]; then
  # Preserve successful board baselines and any edit they exposed, while a
  # failed board remains retryable on the next bounded poll.
  [ "$SUCCEEDED_BOARDS" -gt 0 ] || exit 0
fi
store_poll || exit 0
[ "$CHANGED" -eq 1 ] || exit 0
if [ "$BACKLOG_PENDING" -eq 1 ]; then
  printf 'check: Helm board and backlog both changed; run bin/fm-helm-sync.sh --force to reconcile\n'
else
  printf 'check: Helm board edited by the captain; run bin/fm-helm-sync.sh --force to reconcile\n'
fi
