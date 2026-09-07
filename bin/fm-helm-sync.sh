#!/usr/bin/env bash
# fm-helm-sync.sh - reconcile the optional Helm GitHub Project board with the
# whole fleet's backlog.
#
# The local config/helm.json file is the opt-in.  When it is absent this script
# exits silently before reading any backlog, touching state, or making a network
# call.
#
# Stop-hook wiring, documented for the captain to add to the untracked
# .claude/settings.local.json (do not edit .claude/settings.json):
#
#   {
#     "hooks": {
#       "Stop": [{
#         "hooks": [{
#           "type": "command",
#           "command": "[ -z \"${GROK_AGENT:-}${GROK_HOOK_EVENT:-}\" ] || exit 0; exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-helm-sync.sh"
#         }]
#       }]
#     }
#   }
#
# ## Fleet-aware
# The sync runs from the main home only and is the single writer of the board.
# It discovers every LOCAL secondmate home from data/secondmates.md, parses each
# home's data/backlog.md, and reconciles the union against the board.  A card is
# "missing" (and closed to Done) only when its task id is in NO home's backlog.
# Remote secondmate homes are out of scope for now; see "Remote homes" in
# bin/fm-helm-lib.sh.
#
# ## Field authority and conflict rule
# data/backlog.md in the owning home is authoritative for a card's content:
# title, body, kind, repo, priority, and lifecycle section.  The board is
# authoritative only for the captain's own edits, and only for the fields below,
# and only on an explicit --force read:
#   - Priority: a captain edit to the board Priority option is written straight
#     back into the owning backlog row's priority: metadata.
#   - Status -> the dispatch option: an existing "pick this up" request wake.
#   - Status -> Done on a live task, Status moved backwards, a title or body
#     edit, a brand-new captain card, a deleted card: each raises one check wake
#     for ordinary firstmate intake.  NONE of these mutate a backlog task
#     mechanically and NONE spawn a worker.
# On the normal (non --force) path the backlog always wins: card content is
# rewritten from the backlog and no board edit is accepted back.
#
# ## Debounce
# The normal Stop-hook path debounces all GitHub work on one SHA-256 hash over
# every discovered home's data/backlog.md, stored in
# state/.helm-sync-backlog.sha256.  Use --force for an explicit board read when
# the captain has edited a card without changing any backlog; --force still
# never calls bin/fm-spawn.sh and never deletes a card.
#
# ## Identity cache
# state/helm-cards.tsv (mode 0600) maps every synced card:
#   <task-id> <item-id> <content-node-id> <draft|issue> <field-fingerprint> <last-seen-epoch>
# It is a cache, not truth: when it is absent it is rebuilt from the board on
# the next run, because every card carries `<task-id>` as body line 1.  It is
# used for delete detection and to skip unchanged cards.  A card whose body line
# 1 is not a recognised `<id>` is refused and logged, never touched.
#
# ## Draft issues vs real issues
# The sync creates draft issues.  It also tolerates a card the captain converted
# to a real repo issue by hand: such a card keeps full board-field sync
# (Status/Priority/Project/Kind) but its title and body are never rewritten.
#
# Usage:
#   bin/fm-helm-sync.sh              reconcile after a backlog change
#   bin/fm-helm-sync.sh --force      read the board and reconcile explicitly
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT_PATH="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_PATH="${FM_HOME:-$FM_ROOT_PATH}"
CONFIG_PATH="${FM_CONFIG_OVERRIDE:-$FM_HOME_PATH/config}"
DATA_PATH="${FM_DATA_OVERRIDE:-$FM_HOME_PATH/data}"
STATE_PATH="${FM_STATE_OVERRIDE:-$FM_HOME_PATH/state}"
BACKLOG_PATH="${FM_BACKLOG_OVERRIDE:-$DATA_PATH/backlog.md}"
SECONDMATES_PATH="$DATA_PATH/secondmates.md"
CONFIG_FILE="$CONFIG_PATH/helm.json"
HASH_FILE="$STATE_PATH/.helm-sync-backlog.sha256"
DISPATCH_FILE="$STATE_PATH/.helm-dispatch-requests"
CARDS_FILE="$STATE_PATH/helm-cards.tsv"
DELETED_FILE="$STATE_PATH/helm-deleted.tsv"
LOCK_FILE="$STATE_PATH/.helm-sync.lock"
TMP_DIR=
LOCK_HELD=false
FORCE=0

helm_cleanup() {
  local status=$?
  if [ "$LOCK_HELD" = true ]; then
    fm_lock_release "$LOCK_FILE" 2>/dev/null || true
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf -- "$TMP_DIR"
  fi
  exit "$status"
}
trap helm_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

helm_fail_open() {
  printf 'fm-helm-sync: %s\n' "$1" >&2
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      ;;
    --help)
      sed -n '2,/^set -u$/p' "$0" | sed '$d'
      exit 0
      ;;
    *)
      helm_fail_open "unknown argument: $1"
      ;;
  esac
  shift
done

[ -f "$CONFIG_FILE" ] || exit 0
[ -r "$CONFIG_FILE" ] || helm_fail_open "config/helm.json is unreadable"
[ -f "$BACKLOG_PATH" ] || helm_fail_open "data/backlog.md is missing"

command -v jq >/dev/null 2>&1 || helm_fail_open "jq is unavailable"
command -v gh >/dev/null 2>&1 || helm_fail_open "gh is unavailable"

if [ -L "$HASH_FILE" ] || [ -L "$DISPATCH_FILE" ] || [ -L "$CARDS_FILE" ] || [ -L "$DELETED_FILE" ]; then
  helm_fail_open "refusing symlinked Helm state"
fi

# shellcheck source=bin/fm-helm-lib.sh
. "$SCRIPT_DIR/fm-helm-lib.sh"

CONFIG_JSON=$(sed -E '/^[[:space:]]*(\/\/|#)/d' "$CONFIG_FILE") \
  || helm_fail_open "could not read config/helm.json"
OWNER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.owner | strings | select(length > 0)' 2>/dev/null) \
  || helm_fail_open "config/helm.json has no valid owner"
PROJECT_NUMBER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.number | numbers | select(. > 0)' 2>/dev/null) \
  || helm_fail_open "config/helm.json has no valid project number"
DISPATCH_STATUS=$(printf '%s\n' "$CONFIG_JSON" | jq -r '.dispatch_status // "In flight"' 2>/dev/null) \
  || helm_fail_open "config/helm.json is not valid JSON"
[ -n "$DISPATCH_STATUS" ] || helm_fail_open "config/helm.json has an empty dispatch_status"

# Discover every local home and build the combined debounce hash.
HOMES_TSV="$(fm_helm_discover_homes "$FM_HOME_PATH" "$SECONDMATES_PATH")" \
  || helm_fail_open "could not discover fleet homes"
BACKLOG_PATHS=()
while IFS=$'\t' read -r home_id home_path; do
  [ -n "$home_path" ] || continue
  BACKLOG_PATHS+=("$home_path/data/backlog.md")
done <<EOF
$HOMES_TSV
EOF
[ "${#BACKLOG_PATHS[@]}" -gt 0 ] || helm_fail_open "no fleet home resolved"

BACKLOG_HASH=$(fm_helm_combined_hash "${BACKLOG_PATHS[@]}") \
  || helm_fail_open "no SHA-256 utility is available"
if [ "$FORCE" -eq 0 ] && [ -f "$HASH_FILE" ] && [ "$(sed -n '1p' "$HASH_FILE" 2>/dev/null)" = "$BACKLOG_HASH" ]; then
  exit 0
fi

AUTH_OUTPUT=$(gh auth status 2>&1) || helm_fail_open "GitHub authentication is unavailable"
if ! printf '%s\n' "$AUTH_OUTPUT" | grep -Eiq "(['\"]project['\"]|(^|[[:space:],])project([[:space:],]|$))"; then
  helm_fail_open "GitHub authentication lacks the project scope"
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-helm-sync.XXXXXX") \
  || helm_fail_open "could not create temporary workspace"
BOARD_JSON="$TMP_DIR/board.json"
GH_ERROR="$TMP_DIR/gh-error"

# shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
GRAPHQL_QUERY='query($owner:String!, $number:Int!, $cursor:String) {
  user(login:$owner) {
    projectV2(number:$number) {
      id
      fields(first:100) {
        pageInfo { hasNextPage }
        nodes {
          __typename
          ... on ProjectV2FieldCommon { id name }
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
      }
      items(first:100, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content {
            __typename
            ... on DraftIssue { id title body }
            ... on Issue { id title body number url }
          }
          fieldValues(first:30) {
            nodes {
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                optionId
                field { ... on ProjectV2SingleSelectField { name } }
              }
            }
          }
        }
      }
    }
  }
}'

PAGE_COUNT=0
CURSOR=
PAGINATION_DEADLINE=$(( $(date +%s) + 20 ))
while :; do
  PAGE_COUNT=$((PAGE_COUNT + 1))
  [ "$PAGE_COUNT" -le 50 ] || helm_fail_open "GitHub project has more than 5000 items"
  PAGE_JSON="$TMP_DIR/board-page-$PAGE_COUNT.json"
  GH_ARGS=(
    --field "query=$GRAPHQL_QUERY"
    --field "owner=$OWNER"
    --field "number=$PROJECT_NUMBER"
  )
  [ -z "$CURSOR" ] || GH_ARGS+=(--field "cursor=$CURSOR")
  REMAINING=$(( PAGINATION_DEADLINE - $(date +%s) ))
  [ "$REMAINING" -gt 0 ] || helm_fail_open "GitHub project pagination timed out"
  if command -v timeout >/dev/null 2>&1; then
    GH_COMMAND=(timeout "$REMAINING" gh api graphql "${GH_ARGS[@]}")
  else
    GH_COMMAND=(gh api graphql "${GH_ARGS[@]}")
  fi
  if ! "${GH_COMMAND[@]}" >"$PAGE_JSON" 2>"$GH_ERROR"; then
    helm_fail_open "GitHub project read failed"
  fi
  if jq -e '(.errors // []) | length > 0' "$PAGE_JSON" >/dev/null 2>&1; then
    helm_fail_open "GitHub project read returned an error"
  fi
  if ! jq -e '.data.user.projectV2.id and (.data.user.projectV2.fields.pageInfo.hasNextPage == false)' "$PAGE_JSON" >/dev/null 2>&1; then
    helm_fail_open "GitHub project fields exceeded the safe page bound"
  fi
  if [ "$PAGE_COUNT" -eq 1 ]; then
    mv -f -- "$PAGE_JSON" "$BOARD_JSON"
  else
    jq -s '.[0] as $all | .[1] as $page
      | $all
      | .data.user.projectV2.items.nodes += $page.data.user.projectV2.items.nodes
      | .data.user.projectV2.items.pageInfo = $page.data.user.projectV2.items.pageInfo' \
      "$BOARD_JSON" "$PAGE_JSON" >"$BOARD_JSON.next" \
      || helm_fail_open "could not combine GitHub project pages"
    mv -f -- "$BOARD_JSON.next" "$BOARD_JSON"
  fi
  if [ "$(jq -r '.data.user.projectV2.items.pageInfo.hasNextPage' "$BOARD_JSON")" = false ]; then
    break
  fi
  CURSOR=$(jq -r '.data.user.projectV2.items.pageInfo.endCursor // empty' "$BOARD_JSON")
  [ -n "$CURSOR" ] || helm_fail_open "GitHub project item page is missing its cursor"
done

# Parse every discovered home's backlog into one tagged union.
BACKLOG_JSON="$TMP_DIR/backlog.json"
UNION_PARTS=()
while IFS=$'\t' read -r home_id home_path; do
  [ -n "$home_id" ] || continue
  part="$TMP_DIR/backlog-$home_id.json"
  fm_helm_parse_home_backlog "$home_id" "$home_path/data/backlog.md" "$part" \
    || helm_fail_open "backlog for home $home_id could not be parsed"
  UNION_PARTS+=("$part")
done <<EOF
$HOMES_TSV
EOF

jq -s 'add' "${UNION_PARTS[@]}" >"$BACKLOG_JSON" \
  || helm_fail_open "could not build the fleet backlog union"
if ! jq -e 'map(.id) | group_by(.) | all(length == 1)' "$BACKLOG_JSON" >/dev/null 2>&1; then
  helm_fail_open "the same task id appears in more than one home's backlog"
fi

PROJECT_ID=$(jq -r '.data.user.projectV2.id' "$BOARD_JSON")

field_id() {
  jq -r --arg wanted "$1" \
    '[.data.user.projectV2.fields.nodes[] | select(.name == $wanted and .__typename == "ProjectV2SingleSelectField") | .id][0] // empty' \
    "$BOARD_JSON"
}

option_id() {
  jq -r --arg field "$1" --arg wanted "$2" \
    '[.data.user.projectV2.fields.nodes[] | select(.name == $field and .__typename == "ProjectV2SingleSelectField") | .options[] | select(.name == $wanted) | .id][0] // empty' \
    "$BOARD_JSON"
}

STATUS_FIELD_ID=$(field_id Status)
PROJECT_FIELD_ID=$(field_id Project)
KIND_FIELD_ID=$(field_id Kind)
PRIORITY_FIELD_ID=$(field_id Priority)
[ -n "$STATUS_FIELD_ID" ] && [ -n "$PROJECT_FIELD_ID" ] && [ -n "$KIND_FIELD_ID" ] && [ -n "$PRIORITY_FIELD_ID" ] \
  || helm_fail_open "required Helm fields are unavailable"

STATUS_QUEUED_ID=$(option_id Status "Queued")
STATUS_IN_FLIGHT_ID=$(option_id Status "In flight")
STATUS_WAITING_ID=$(option_id Status "Waiting on you")
STATUS_DONE_ID=$(option_id Status "Done")
DISPATCH_OPTION_ID=$(option_id Status "$DISPATCH_STATUS")
[ -n "$STATUS_QUEUED_ID" ] && [ -n "$STATUS_IN_FLIGHT_ID" ] && [ -n "$STATUS_WAITING_ID" ] && [ -n "$STATUS_DONE_ID" ] && [ -n "$DISPATCH_OPTION_ID" ] \
  || helm_fail_open "required Helm Status options are unavailable"

TMP_RESPONSE="$TMP_DIR/response.json"
TMP_RESPONSE_ERROR="$TMP_DIR/response.error"

graphql_mutation() {
  local query=$1
  shift
  if ! gh api graphql "$@" --field "query=$query" >"$TMP_RESPONSE" 2>"$TMP_RESPONSE_ERROR"; then
    return 1
  fi
  jq -e '(.errors // []) | length == 0' "$TMP_RESPONSE" >/dev/null 2>&1
}

update_single_select() {
  local item_id=$1 field=$2 option=$3
  # shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
  local query='mutation($projectId:ID!, $itemId:ID!, $fieldId:ID!, $optionId:String!) {
    updateProjectV2ItemFieldValue(input:{projectId:$projectId, itemId:$itemId, fieldId:$fieldId, value:{singleSelectOptionId:$optionId}}) {
      projectV2Item { id }
    }
  }'
  graphql_mutation "$query" \
    --field "projectId=$PROJECT_ID" \
    --field "itemId=$item_id" \
    --field "fieldId=$field" \
    --field "optionId=$option"
}

update_draft() {
  local draft_id=$1 title=$2 body=$3
  # shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
  local query='mutation($draftIssueId:ID!, $title:String!, $body:String!) {
    updateProjectV2DraftIssue(input:{draftIssueId:$draftIssueId, title:$title, body:$body}) {
      draftIssue { id }
    }
  }'
  graphql_mutation "$query" \
    --field "draftIssueId=$draft_id" \
    --field "title=$title" \
    --field "body=$body"
}

create_draft() {
  local title=$1 body=$2
  # shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
  local query='mutation($projectId:ID!, $title:String!, $body:String!) {
    addProjectV2DraftIssue(input:{projectId:$projectId, title:$title, body:$body}) {
      projectItem { id content { ... on DraftIssue { id } } }
    }
  }'
  graphql_mutation "$query" \
    --field "projectId=$PROJECT_ID" \
    --field "title=$title" \
    --field "body=$body" \
    || return 1
  jq -r '.data.addProjectV2DraftIssue.projectItem.id // empty' "$TMP_RESPONSE"
}

current_option_id() {
  local item_json=$1 field_name=$2
  jq -r --arg field "$field_name" \
    '[.fieldValues.nodes[]? | select(.field.name == $field) | .optionId][0] // empty' \
    <<<"$item_json"
}

current_option_name() {
  local item_json=$1 field_name=$2
  jq -r --arg field "$field_name" \
    '[.fieldValues.nodes[]? | select(.field.name == $field) | .name][0] // empty' \
    <<<"$item_json"
}

record_for_id() {
  jq -c --arg id "$1" '[.[] | select(.id == $id)][0] // null' "$BACKLOG_JSON"
}

record_home_path() {
  jq -r --arg id "$1" '[.[] | select(.id == $id) | .home_backlog][0] // empty' "$BACKLOG_JSON" \
    | sed 's#/data/backlog\.md$##'
}

record_kind() {
  local record=$1 hold_kind hold_reason
  hold_kind=$(jq -r '.hold_kind // empty' <<<"$record")
  hold_reason=$(jq -r '.hold_reason // empty' <<<"$record")
  if [ "$hold_kind" = captain ] && [ -n "$hold_reason" ]; then
    printf '%s\n' decision
    return 0
  fi
  case "$(jq -r '.kind // "ship"' <<<"$record")" in
    task|scout) printf '%s\n' investigation ;;
    *) printf '%s\n' ship ;;
  esac
}

record_project() {
  local repo
  repo=$(jq -r '.repo // ""' <<<"$1")
  case "$repo" in
    firetabs|geojitsu/firetabs) printf '%s\n' firetabs ;;
    BetterBlueToo|geojitsu/BetterBlueToo) printf '%s\n' BetterBlueToo ;;
    firstmate|geojitsu/firstmate) printf '%s\n' firstmate ;;
    nocout|dc-noc/nocout) printf '%s\n' nocout ;;
    cryptoseacurrents|copium/cryptoseacurrents) printf '%s\n' cryptoseacurrents ;;
    *) printf '%s\n' other ;;
  esac
}

record_status() {
  local record=$1 section kind
  section=$(jq -r '.state' <<<"$record")
  kind=$(record_kind "$record")
  if [ "$section" = "done" ]; then
    printf '%s\n' Done
  elif [ "$kind" = decision ]; then
    printf '%s\n' "Waiting on you"
  elif [ "$section" = in_flight ]; then
    printf '%s\n' "In flight"
  else
    printf '%s\n' Queued
  fi
}

# priority n (0-4, or unset) -> P<n>, lossless. Unset sorts as 3.
priority_option_name() {
  case "$1" in
    0) printf 'P0\n' ;;
    1) printf 'P1\n' ;;
    2) printf 'P2\n' ;;
    3) printf 'P3\n' ;;
    4) printf 'P4\n' ;;
    *) printf 'P3\n' ;;
  esac
}

# P<n> board option name -> n, or empty when not a recognised priority option.
priority_from_option() {
  case "$1" in
    P0) printf '0\n' ;;
    P1) printf '1\n' ;;
    P2) printf '2\n' ;;
    P3) printf '3\n' ;;
    P4) printf '4\n' ;;
    *) printf '\n' ;;
  esac
}

write_card_body() {
  local record=$1 output=$2 id kind type repo priority filed hold blocked report pr line
  id=$(jq -r '.id' <<<"$record")
  kind=$(record_kind "$record")
  case "$kind" in
    ship) type='ship - produces a change and a PR' ;;
    investigation) type='investigation - produces knowledge, not code' ;;
    decision) type='decision - needs your call before anything moves' ;;
  esac
  repo=$(jq -r '.repo // "-"' <<<"$record")
  [ -n "$repo" ] || repo=-
  priority=$(priority_option_name "$(jq -r '.priority // "3"' <<<"$record")")
  filed=$(jq -r '.since // .reported // .done // .merged // "unknown"' <<<"$record")
  hold=$(jq -r '.hold_reason // empty' <<<"$record")
  blocked=$(jq -r '(.blocked_by_ids // []) | join(", ")' <<<"$record")
  report=$(jq -r '.report_path // empty' <<<"$record")
  pr=$(jq -r '.pr_url // empty' <<<"$record")
  if [ -z "$report" ] && [ -f "$DATA_PATH/$id/report.md" ]; then
    report="data/$id/report.md"
  fi
  {
    printf '%s\n\n' "\`$id\`"
    if [ "$kind" = decision ] && [ -n "$hold" ]; then
      printf '## What you need to decide\n\n%s\n\n' "$hold"
    fi
    printf '## Facts\n\n'
    printf -- '- **Repo:** %s\n' "$repo"
    printf -- '- **Type:** %s\n' "$type"
    printf -- '- **Priority:** %s\n' "$priority"
    printf -- '- **Filed:** %s\n' "$filed"
    [ -z "$blocked" ] || printf -- '- **Blocked by:** %s\n' "$blocked"
    [ -z "$report" ] || printf -- '%s\n' "- **Report:** \`$report\`"
    [ -z "$pr" ] || printf -- '- **PR:** %s\n' "$pr"
    printf '\n## Notes\n\n'
    while IFS= read -r line; do
      printf '%s\n' "$line"
    done < <(jq -r '.body_lines[]?' <<<"$record")
    printf '%b\n' "\n---\n_Source of truth: \`data/backlog.md\` in the owning firstmate home._\n"
  } >"$output"
}

marker_matches() {
  local task_id=$1 fingerprint=$2
  [ -f "$DISPATCH_FILE" ] || return 1
  awk -F '\t' -v task="$task_id" -v fp="$fingerprint" '$1 == task && $4 == fp { found=1 } END { exit !found }' "$DISPATCH_FILE"
}

marker_replace() {
  local task_id=$1 item_id=$2 option=$3 fingerprint=$4 marker_tmp
  marker_tmp=$(mktemp "$TMP_DIR/marker.XXXXXX") || return 1
  if [ -f "$DISPATCH_FILE" ]; then
    awk -F '\t' -v task="$task_id" '$1 != task' "$DISPATCH_FILE" >"$marker_tmp" || return 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$task_id" "$item_id" "$option" "$fingerprint" >>"$marker_tmp" || return 1
  chmod 0600 "$marker_tmp" || return 1
  mv -f -- "$marker_tmp" "$DISPATCH_FILE"
}

marker_remove() {
  local task_id=$1 marker_tmp
  [ -f "$DISPATCH_FILE" ] || return 0
  marker_tmp=$(mktemp "$TMP_DIR/marker.XXXXXX") || return 1
  awk -F '\t' -v task="$task_id" '$1 != task' "$DISPATCH_FILE" >"$marker_tmp" || return 1
  chmod 0600 "$marker_tmp" || return 1
  mv -f -- "$marker_tmp" "$DISPATCH_FILE"
}

queue_has_key() {
  fm_wake_queued_keys check | grep -F -x -q -- "$1"
}

# Enqueue one check wake for firstmate, unless an unhandled one is already
# queued for the same key. Board-edit divergences use this: never mechanical.
queue_board_event() {
  local key=$1 payload=$2
  if queue_has_key "$key"; then
    return 0
  fi
  fm_wake_append check "$key" "$payload"
}

queue_dispatch_request() {
  local task_id=$1 item_id=$2 fingerprint key
  fingerprint="$item_id:$DISPATCH_OPTION_ID"
  key="helm-dispatch:$task_id"
  if marker_matches "$task_id" "$fingerprint"; then
    return 0
  fi
  if queue_has_key "$key"; then
    marker_replace "$task_id" "$item_id" "$DISPATCH_OPTION_ID" "$fingerprint"
    return $?
  fi
  fm_wake_append check "$key" \
    "check: Helm dispatch request for $task_id (board item $item_id)" || return 1
  marker_replace "$task_id" "$item_id" "$DISPATCH_OPTION_ID" "$fingerprint"
}

# Write one owning backlog row's priority from a captain board edit. Best effort:
# a failure is logged and retried on the next run rather than failing the sync.
backlog_write_priority() {
  local home=$1 task_id=$2 value=$3
  if ( cd "$home" 2>/dev/null && FM_HOME="$home" tasks-axi update "$task_id" --priority "$value" >/dev/null 2>&1 ); then
    return 0
  fi
  printf 'fm-helm-sync: could not write priority %s for %s in %s\n' "$value" "$task_id" "$home" >&2
  return 1
}

# Hold a task for the captain in its owning home after a card deletion. Idempotent.
backlog_hold_for_captain() {
  local home=$1 task_id=$2 reason=$3
  if ( cd "$home" 2>/dev/null && FM_HOME="$home" tasks-axi hold "$task_id" --kind captain --reason "$reason" >/dev/null 2>&1 ); then
    return 0
  fi
  printf 'fm-helm-sync: could not hold %s for the captain in %s\n' "$task_id" "$home" >&2
  return 1
}

fingerprint_of() {
  printf '%s\0%s\0%s\0%s\0%s\0%s' "$1" "$2" "$3" "$4" "$5" "$6" | fm_helm_sha256_stdin
}

export FM_ROOT_OVERRIDE="$FM_ROOT_PATH"
export FM_HOME="$FM_HOME_PATH"
export STATE="$STATE_PATH"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

mkdir -p "$STATE_PATH" || helm_fail_open "Helm state directory is unavailable"
if ! fm_lock_try_acquire "$LOCK_FILE"; then
  helm_fail_open "another Helm sync is already running"
fi
LOCK_HELD=true

# Prior identity cache: absent => first run / rebuild-from-board, so treat every
# current card as known and raise no new-card or deletion wakes this run.
TSV_EXISTED=false
OLD_CARDS="$TMP_DIR/old-cards.tsv"
: >"$OLD_CARDS"
if [ -f "$CARDS_FILE" ]; then
  TSV_EXISTED=true
  cat -- "$CARDS_FILE" >"$OLD_CARDS" 2>/dev/null || : >"$OLD_CARDS"
fi
NEW_CARDS="$TMP_DIR/new-cards.tsv"
: >"$NEW_CARDS"
OLD_DELETED="$TMP_DIR/old-deleted.tsv"
: >"$OLD_DELETED"
if [ -f "$DELETED_FILE" ]; then
  cat -- "$DELETED_FILE" >"$OLD_DELETED" 2>/dev/null || : >"$OLD_DELETED"
fi
NEW_DELETED="$TMP_DIR/new-deleted.tsv"
: >"$NEW_DELETED"
NOW_EPOCH=$(date +%s)

old_card_line() {
  awk -F '\t' -v t="$1" '$1 == t { print; exit }' "$OLD_CARDS"
}

old_deleted_line() {
  awk -F '\t' -v t="$1" '$1 == t { print; exit }' "$OLD_DELETED"
}

BOARD_ITEM_IDS="$TMP_DIR/board-item-ids"
jq -r '.data.user.projectV2.items.nodes[].id' "$BOARD_JSON" | sort -u >"$BOARD_ITEM_IDS" \
  || helm_fail_open "could not index current Helm cards"

record_count=$(jq 'length' "$BACKLOG_JSON")

while IFS= read -r record; do
  task_id=$(jq -r '.id' <<<"$record")
  home_path=$(record_home_path "$task_id")
  title=$(jq -r '.title' <<<"$record")
  desired_project=$(record_project "$record")
  desired_kind=$(record_kind "$record")
  desired_status=$(record_status "$record")
  case "$desired_project" in
    firetabs|BetterBlueToo|firstmate|nocout|cryptoseacurrents|other) ;;
    *) helm_fail_open "unsupported project for $task_id" ;;
  esac
  desired_priority_n=$(jq -r '.priority // "3"' <<<"$record")
  desired_priority=$(priority_option_name "$desired_priority_n")
  desired_project_option=$(option_id Project "$desired_project")
  desired_kind_option=$(option_id Kind "$desired_kind")
  desired_priority_option=$(option_id Priority "$desired_priority")
  [ -n "$desired_project_option" ] && [ -n "$desired_kind_option" ] && [ -n "$desired_priority_option" ] \
    || helm_fail_open "required Helm option is unavailable for $task_id"

  card=$(jq -c --arg id "$task_id" '
    [.data.user.projectV2.items.nodes[]
     | select(.content.__typename == "DraftIssue" or .content.__typename == "Issue")
     | select((.content.body // "") | split("\n")[0] == ("`" + $id + "`"))] as $cards
    | if ($cards | length) == 1 then $cards[0]
      elif ($cards | length) == 0 then null
      else error("duplicate Helm cards") end
  ' "$BOARD_JSON") || helm_fail_open "duplicate Helm cards for $task_id"

  body_file="$TMP_DIR/$task_id.body"
  write_card_body "$record" "$body_file" || helm_fail_open "could not build the card body for $task_id"
  body=$(cat "$body_file")
  body_hash=$(printf '%s' "$body" | fm_helm_sha256_stdin)
  fingerprint=$(fingerprint_of "$desired_status" "$desired_priority" "$desired_project" "$desired_kind" "$title" "$body_hash")

  if [ "$card" = null ]; then
    deleted_line=$(old_deleted_line "$task_id")
    if [ -n "$deleted_line" ]; then
      printf '%s\n' "$deleted_line" >>"$NEW_DELETED"
      continue
    fi
    old_line=$(old_card_line "$task_id")
    if [ -n "$old_line" ] && [ "$(jq -r '.state' <<<"$record")" != done ]; then
      old_item_id=$(printf '%s' "$old_line" | awk -F '\t' '{print $2}')
      if [ -n "$old_item_id" ] && ! grep -F -x -q -- "$old_item_id" "$BOARD_ITEM_IDS"; then
        continue
      fi
    fi
    item_id=$(create_draft "$title" "$body") || helm_fail_open "could not create the Helm card for $task_id"
    [ -n "$item_id" ] || helm_fail_open "GitHub did not return the new Helm card for $task_id"
    content_type=draft
    content_node_id=""
    card=$(jq -nc --arg id "$item_id" '{id:$id, content:{__typename:"DraftIssue", id:"", title:"", body:""}, fieldValues:{nodes:[]}}')
  else
    item_id=$(jq -r '.id' <<<"$card")
    content_typename=$(jq -r '.content.__typename' <<<"$card")
    content_node_id=$(jq -r '.content.id // empty' <<<"$card")
    if [ "$content_typename" = Issue ]; then
      content_type=issue
    else
      content_type=draft
    fi

    old_line=$(old_card_line "$task_id")
    old_fp=$(printf '%s' "$old_line" | awk -F '\t' '{print $5}')
    if [ "$FORCE" -eq 0 ] && [ -n "$old_line" ] && [ "$old_fp" = "$fingerprint" ]; then
      # Unchanged card and no forced board read: nothing to reconcile.
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$task_id" "$item_id" "$content_node_id" "$content_type" "$fingerprint" "$NOW_EPOCH" >>"$NEW_CARDS"
      continue
    fi

    current_title=$(jq -r '.content.title // empty' <<<"$card")
    current_body=$(jq -r '.content.body // empty' <<<"$card")
    if [ "$content_type" = issue ]; then
      : # real issues get field-only sync; never rewrite title or body.
    elif [ "$FORCE" -eq 1 ] && { [ "$current_title" != "$title" ] || [ "$current_body" != "$body" ]; }; then
      # A forced read found the card text diverged: the captain edited it.
      queue_board_event "helm-card-edit:$task_id" \
        "check: captain edited Helm card $task_id text; reconcile it into the backlog" \
        || helm_fail_open "could not enqueue the Helm card edit for $task_id"
    elif [ "$current_title" != "$title" ] || [ "$current_body" != "$body" ]; then
      draft_id=$content_node_id
      [ -n "$draft_id" ] || helm_fail_open "Helm card $task_id has no draft issue id"
      update_draft "$draft_id" "$title" "$body" \
        || helm_fail_open "could not update the Helm card content for $task_id"
    fi
  fi

  current_status=$(current_option_name "$card" Status)
  current_status_id=$(current_option_id "$card" Status)
  current_priority_name=$(current_option_name "$card" Priority)

  # Priority: on a forced read, a valid board Priority that differs from the
  # backlog is a captain edit -> write it back and do not push over it.
  priority_from_board=$(priority_from_option "$current_priority_name")
  push_priority=true
  if [ "$FORCE" -eq 1 ] && [ -n "$priority_from_board" ] && [ "$priority_from_board" != "$desired_priority_n" ]; then
    if ! backlog_write_priority "$home_path" "$task_id" "$priority_from_board"; then
      queue_board_event "helm-priority:$task_id" \
        "check: captain changed Helm card $task_id Priority; reconcile it into the backlog" \
        || helm_fail_open "could not enqueue the Helm Priority reconciliation for $task_id"
      helm_fail_open "could not write Helm Priority for $task_id"
    fi
    push_priority=false
  fi

  dispatch_request=false
  status_deferred=false
  if [ "$current_status_id" = "$DISPATCH_OPTION_ID" ] \
    && [ "$desired_status" != "$DISPATCH_STATUS" ] \
    && [ "$desired_status" != Done ]; then
    dispatch_request=true
    queue_dispatch_request "$task_id" "$item_id" \
      || helm_fail_open "could not enqueue the Helm dispatch request for $task_id"
  else
    marker_remove "$task_id" || helm_fail_open "could not clear the Helm dispatch marker for $task_id"
  fi

  if [ "$dispatch_request" = false ] && [ "$FORCE" -eq 1 ] && [ "$current_status" != "$desired_status" ]; then
    if [ "$current_status" = Done ] && [ "$desired_status" != Done ]; then
      status_deferred=true
      queue_board_event "helm-status-done:$task_id" \
        "check: captain moved Helm card $task_id to Done while the task is live; confirm and reconcile" \
        || helm_fail_open "could not enqueue the Helm status change for $task_id"
    elif { [ "$current_status" = Queued ] && { [ "$desired_status" = "In flight" ] || [ "$desired_status" = Done ]; }; } \
      || { [ "$current_status" = "In flight" ] && [ "$desired_status" = Done ]; }; then
      status_deferred=true
      queue_board_event "helm-status-back:$task_id" \
        "check: captain moved Helm card $task_id back to $current_status; reconcile it into the backlog" \
        || helm_fail_open "could not enqueue the Helm status change for $task_id"
    fi
  fi

  if [ "$dispatch_request" = false ] && [ "$status_deferred" = false ] && [ "$current_status" != "$desired_status" ]; then
    desired_status_option=$(option_id Status "$desired_status")
    update_single_select "$item_id" "$STATUS_FIELD_ID" "$desired_status_option" \
      || helm_fail_open "could not update Helm Status for $task_id"
  fi

  current_project_id=$(current_option_id "$card" Project)
  current_kind_id=$(current_option_id "$card" Kind)
  current_priority_id=$(current_option_id "$card" Priority)
  [ "$current_project_id" = "$desired_project_option" ] || \
    update_single_select "$item_id" "$PROJECT_FIELD_ID" "$desired_project_option" \
      || helm_fail_open "could not update Helm Project for $task_id"
  [ "$current_kind_id" = "$desired_kind_option" ] || \
    update_single_select "$item_id" "$KIND_FIELD_ID" "$desired_kind_option" \
      || helm_fail_open "could not update Helm Kind for $task_id"
  if [ "$push_priority" = true ]; then
    [ "$current_priority_id" = "$desired_priority_option" ] || \
      update_single_select "$item_id" "$PRIORITY_FIELD_ID" "$desired_priority_option" \
        || helm_fail_open "could not update Helm Priority for $task_id"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$task_id" "$item_id" "$content_node_id" "$content_type" "$fingerprint" "$NOW_EPOCH" >>"$NEW_CARDS"
done < <(jq -c '.[]' "$BACKLOG_JSON")

# Board cards whose id is in no home's backlog.
if [ "$record_count" -gt 0 ]; then
  while IFS= read -r card; do
    item_id=$(jq -r '.id' <<<"$card")
    body_line1=$(jq -r '(.content.body // "") | split("\n")[0]' <<<"$card")
    case "$body_line1" in
      '`'*'`') task_id=${body_line1#\`}; task_id=${task_id%\`} ;;
      *)
        printf 'fm-helm-sync: ignoring board item %s: body line 1 is not a task id\n' "$item_id" >&2
        continue
        ;;
    esac
    case "$task_id" in
      ''|*[!A-Za-z0-9._-]*)
        printf 'fm-helm-sync: ignoring board item %s: body line 1 is not a task id\n' "$item_id" >&2
        continue
        ;;
    esac
    record=$(record_for_id "$task_id")
    [ "$record" != null ] && continue

    current_status_id=$(current_option_id "$card" Status)
    # A Done card with no task is either a completed task's card or the captain
    # tidying his Done column: leave it alone either way.
    [ "$current_status_id" = "$STATUS_DONE_ID" ] && continue

    if [ "$TSV_EXISTED" = true ] && [ -z "$(old_card_line "$task_id")" ]; then
      # Never carded before and no backlog task: a brand-new captain card.
      queue_board_event "helm-new-card:$task_id" \
        "check: captain added Helm card $task_id with no backlog task; run intake" \
        || helm_fail_open "could not enqueue the new Helm card $task_id"
      continue
    fi

    update_single_select "$item_id" "$STATUS_FIELD_ID" "$STATUS_DONE_ID" \
      || helm_fail_open "could not close the missing Helm task $task_id"
    marker_remove "$task_id" || helm_fail_open "could not clear the Helm dispatch marker for $task_id"
  done < <(jq -c '.data.user.projectV2.items.nodes[] | select(.content.__typename == "DraftIssue" or .content.__typename == "Issue")' "$BOARD_JSON")
fi

# Delete detection: a previously synced card gone from the board.
if [ "$TSV_EXISTED" = true ]; then
  while IFS= read -r old_line; do
    [ -n "$old_line" ] || continue
    task_id=$(printf '%s' "$old_line" | awk -F '\t' '{print $1}')
    old_item_id=$(printf '%s' "$old_line" | awk -F '\t' '{print $2}')
    [ -n "$task_id" ] && [ -n "$old_item_id" ] || continue
    grep -F -x -q -- "$old_item_id" "$BOARD_ITEM_IDS" && continue
    jq -e --arg id "$task_id" '
      any(.data.user.projectV2.items.nodes[];
        (.content.body // "") | split("\n")[0] == ("`" + $id + "`"))
    ' "$BOARD_JSON" >/dev/null 2>&1 && continue

    record=$(record_for_id "$task_id")
    if [ "$record" = null ]; then
      continue   # card gone and no task: drop the stale line, nothing else.
    fi
    task_state=$(jq -r '.state' <<<"$record")
    if [ "$task_state" = "done" ]; then
      continue   # captain tidied a Done card: drop the line, no confirm.
    fi
    if [ "$(jq -r '.hold_kind // ""' <<<"$record")" = captain ]; then
      continue   # already held for the captain: firstmate has it, do not re-ring.
    fi

    home_path=$(record_home_path "$task_id")
    in_flight=$(jq -r 'if .state == "in_flight" then "yes" else "no" end' <<<"$record")
    held=$(jq -r 'if (.hold_reason // "") != "" or ((.blocked_by_ids // []) | length) > 0 then "yes" else "no" end' <<<"$record")
    if [ "$in_flight" = yes ]; then
      choices='the task is In flight: cancel it (stop the worker, then Done), mark it done, or was the card deleted by mistake'
    elif [ "$held" = yes ]; then
      choices='the task is blocked or held: cancel it (Done), mark it done, or was the card deleted by mistake'
    else
      choices='the task is queued: cancel it (Done), mark it done, or was the card deleted by mistake'
    fi
    reason="Helm card deleted; $choices."
    if ! backlog_hold_for_captain "$home_path" "$task_id" "$reason"; then
      helm_fail_open "could not hold deleted Helm task $task_id"
    fi
    printf '%s\t%s\n' "$task_id" "$old_item_id" >>"$NEW_DELETED"
    queue_board_event "helm-card-deleted:$task_id" \
      "check: captain deleted Helm card $task_id ($choices)" \
      || helm_fail_open "could not enqueue the Helm card deletion for $task_id"
  done <"$OLD_CARDS"
fi

# Publish the refreshed identity cache atomically.
if [ -s "$NEW_CARDS" ] || [ "$TSV_EXISTED" = true ]; then
  CARDS_TMP=$(mktemp "$TMP_DIR/cards.XXXXXX") || helm_fail_open "could not stage the Helm identity cache"
  sort -u "$NEW_CARDS" >"$CARDS_TMP" || helm_fail_open "could not stage the Helm identity cache"
  chmod 0600 "$CARDS_TMP" || helm_fail_open "could not protect the Helm identity cache"
  mv -f -- "$CARDS_TMP" "$CARDS_FILE" || helm_fail_open "could not publish the Helm identity cache"
fi

if [ -s "$NEW_DELETED" ]; then
  DELETED_TMP=$(mktemp "$TMP_DIR/deleted.XXXXXX") || helm_fail_open "could not stage Helm deletion state"
  sort -u "$NEW_DELETED" >"$DELETED_TMP" || helm_fail_open "could not stage Helm deletion state"
  chmod 0600 "$DELETED_TMP" || helm_fail_open "could not protect Helm deletion state"
  mv -f -- "$DELETED_TMP" "$DELETED_FILE" || helm_fail_open "could not publish Helm deletion state"
else
  rm -f -- "$DELETED_FILE"
fi

HASH_TMP=$(mktemp "$TMP_DIR/hash.XXXXXX") || helm_fail_open "could not stage Helm sync state"
printf '%s\n' "$BACKLOG_HASH" >"$HASH_TMP" || helm_fail_open "could not write Helm sync state"
chmod 0600 "$HASH_TMP" || helm_fail_open "could not protect Helm sync state"
mv -f -- "$HASH_TMP" "$HASH_FILE" || helm_fail_open "could not publish Helm sync state"
printf 'fm-helm-sync: synchronized\n'
