#!/usr/bin/env bash
# fm-helm-sync.sh - reconcile the optional Helm GitHub Project board with the
# whole fleet's backlog.
#
# The local config/helm.json file is the opt-in.  When it is absent this script
# exits silently before reading any backlog, touching state, or making a network
# call.
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
# On the normal (non --force) path the backlog wins unless the board changed
# since the poll baseline or an immediate pre-write reread finds a captain edit.
# Either conflict preserves the board item and emits the existing reconciliation
# wake; no board edit is accepted back mechanically.
#
# ## Debounce
# The watcher-check path debounces all GitHub work on one SHA-256 hash over every
# discovered home's data/backlog.md, stored in
# state/.helm-sync-backlog.sha256.  Use --force for an explicit board read when
# the captain has edited a card without changing any backlog; --force still
# never calls bin/fm-spawn.sh and never deletes a card.
# One 20-second deadline covers the whole paginated GitHub board read. The
# script uses `timeout` when available and otherwise stops the request with a
# watchdog at the same deadline.
#
# ## Identity cache
# state/helm-cards.tsv (mode 0600) maps every synced card:
#   <task-id> <item-id> <content-node-id> <draft|issue> <field-fingerprint> <last-seen-epoch>
# It is a cache, not truth: when it is absent it is rebuilt from the board on
# the next run, because every card carries `<task-id>` as body line 1.  It is
# used for delete detection and to skip unchanged cards.  A card whose body line
# 1 is not a recognised `<id>` is refused and logged, never touched.
# state/helm-deleted.tsv (mode 0600) retains a captain deletion tombstone while
# that task remains in any discovered backlog. It suppresses recreation even
# after the captain resolves the hold by marking the task Done. The tombstone
# drops when the task leaves the backlog union or when a card for it reappears.
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
POLL_FILE="$STATE_PATH/.helm-board-poll"
RESUME_FORCE_FILE="$STATE_PATH/.helm-sync-resume-force"
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

if [ -L "$HASH_FILE" ] || [ -L "$DISPATCH_FILE" ] || [ -L "$CARDS_FILE" ] || [ -L "$DELETED_FILE" ] || [ -L "$POLL_FILE" ] || [ -L "$RESUME_FORCE_FILE" ]; then
  helm_fail_open "refusing symlinked Helm state"
fi

# A partial forced run leaves this marker so the next run, however it is
# started, finishes that forced read before a completed run clears it.
if [ "$FORCE" -eq 0 ] && [ -f "$RESUME_FORCE_FILE" ]; then
  FORCE=1
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

# shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
ITEM_GRAPHQL_QUERY='query($itemId:ID!) {
  node(id:$itemId) {
    ... on ProjectV2Item {
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
}'

# One run's whole GitHub budget, board read and writes alike. It must fit
# inside the watcher's 30-second timeout; a run that needs more stops cleanly
# between cards and the next run continues.
SYNC_BUDGET_SECS=25
SYNC_DEADLINE=$(( $(date +%s) + SYNC_BUDGET_SECS ))
PAGE_COUNT=0
CURSOR=
PAGINATION_DEADLINE=$SYNC_DEADLINE
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
  if ! run_gh_bounded "$REMAINING" gh api graphql "${GH_ARGS[@]}" >"$PAGE_JSON" 2>"$GH_ERROR"; then
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

READ_SIGNATURE=$(jq -r '
  def fieldval($n): [.fieldValues.nodes[]? | select(.field.name == $n) | .name][0] // "";
  [ .data.user.projectV2.items.nodes[]
    | .id + "\u001f" + fieldval("Status") + "\u001f" + fieldval("Priority")
      + "\u001f" + ((.content.title // "") | @base64)
      + "\u001f" + ((.content.body // "") | @base64) ]
  | (length | tostring) + "\n" + (sort | join("\n"))
' "$BOARD_JSON" | fm_helm_sha256_stdin) || helm_fail_open "could not read Helm board signature"
if [ "$FORCE" -eq 0 ] && [ -f "$POLL_FILE" ] && [ "$(sed -n '1p' "$POLL_FILE" 2>/dev/null)" != "$READ_SIGNATURE" ]; then
  printf 'check: Helm board and backlog both changed; run bin/fm-helm-sync.sh --force to reconcile\n'
  exit 0
fi

ACK_BOARD_JSON="$TMP_DIR/ack-board.json"
cp "$BOARD_JSON" "$ACK_BOARD_JSON" || helm_fail_open "could not stage Helm board acknowledgement"

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
CREATED_ITEM_ID=

# One card as the guard compares it: text plus every named single-select value.
SNAPSHOT_JQ='{
  title:(.content.title // ""),
  body:(.content.body // ""),
  fields:([.fieldValues.nodes[]?
    | {field:(.field.name // ""),name:(.name // ""),optionId:(.optionId // "")}
    | select(.field != "")]
    | sort_by(.field, .optionId, .name))
}'

# guard_board_write <item-id> <expected-snapshot>
# One pre-write read of the card.  If it no longer matches the board read that
# planned this run's writes, the captain edited it meanwhile: leave the card
# alone and ask for a forced reconciliation.
# Accepted containment: GitHub Projects has no conditional or versioned
# mutation, so a captain edit can still land between this read and the write.
# The next reverse poll detects that divergence and raises the reconcile wake.
guard_board_write() {
  local item_id=$1 expected=$2 remaining actual
  remaining=$(( SYNC_DEADLINE - $(date +%s) ))
  [ "$remaining" -gt 0 ] || return 1
  if ! run_gh_bounded "$remaining" gh api graphql \
    --field "query=$ITEM_GRAPHQL_QUERY" \
    --raw-field "itemId=$item_id" >"$TMP_RESPONSE" 2>"$TMP_RESPONSE_ERROR"; then
    return 1
  fi
  jq -e '((.errors // []) | length == 0) and (.data.node != null)' "$TMP_RESPONSE" >/dev/null 2>&1 || return 1
  actual=$(jq -er ".data.node | ($SNAPSHOT_JQ) | tojson" "$TMP_RESPONSE") || return 1
  if [ "$expected" != "$actual" ]; then
    printf 'check: Helm board and backlog both changed; run bin/fm-helm-sync.sh --force to reconcile\n'
    exit 0
  fi
}

graphql_mutation() {
  local query=$1 remaining
  shift
  remaining=$(( SYNC_DEADLINE - $(date +%s) ))
  [ "$remaining" -gt 0 ] || return 1
  if ! run_gh_bounded "$remaining" gh api graphql "$@" --field "query=$query" >"$TMP_RESPONSE" 2>"$TMP_RESPONSE_ERROR"; then
    return 1
  fi
  jq -e '(.errors // []) | length == 0' "$TMP_RESPONSE" >/dev/null 2>&1
}

# ack_card <item-id> <new:0|1> <draft:0|1> <title> <body> [<field> <name> <option-id>]...
# The acknowledged board mirrors every write this run lands, so the poll
# signature published at the end (or at a partial stop) matches the board the
# next run reads instead of reporting this run's own writes as captain edits.
# One jq pass per card: append the card when this run created it, replace its
# text when that was written, then apply each field write in turn.
ack_card() {
  local item_id=$1 new=$2 draft=$3 title=$4 body=$5 next
  shift 5
  next="$ACK_BOARD_JSON.next"
  jq --arg item "$item_id" --arg new "$new" --arg draft "$draft" --arg title "$title" --arg body "$body" '
    ($ARGS.positional | [range(0; length; 3) as $i | {field: .[$i], name: .[$i + 1], optionId: .[$i + 2]}]) as $writes
    | .data.user.projectV2.items.nodes |=
        (if $new == "1" then . + [{id:$item,content:{title:$title,body:$body},fieldValues:{nodes:[]}}] else . end)
    | .data.user.projectV2.items.nodes |= map(
        if .id != $item then . else
          (if $draft == "1" then .content.title = $title | .content.body = $body else . end)
          | reduce $writes[] as $w (.;
              .fieldValues.nodes |=
                if any(.[]?; .field.name == $w.field) then
                  map(if .field.name == $w.field then .name = $w.name | .optionId = $w.optionId else . end)
                else . + [{field:{name:$w.field},name:$w.name,optionId:$w.optionId}] end)
        end)' "$ACK_BOARD_JSON" --args "$@" >"$next" && mv -f -- "$next" "$ACK_BOARD_JSON"
}

# Field writes planned for the card in hand.  write_card sends them all, with
# the card text when that changed too, as ONE GraphQL request: a card costs at
# most one pre-write read plus one mutation however many fields it needs, and
# a card this run just created needs no pre-write read at all.
PLAN_FIELD_IDS=()
PLAN_FIELD_OPTIONS=()
PLAN_FIELD_NAMES=()
PLAN_FIELD_VALUES=()

plan_field() {  # <field-id> <option-id> <field-name> <option-name>
  PLAN_FIELD_IDS+=("$1")
  PLAN_FIELD_OPTIONS+=("$2")
  PLAN_FIELD_NAMES+=("$3")
  PLAN_FIELD_VALUES+=("$4")
}

plan_reset() {
  PLAN_FIELD_IDS=()
  PLAN_FIELD_OPTIONS=()
  PLAN_FIELD_NAMES=()
  PLAN_FIELD_VALUES=()
}

# plan_names <draft-id-or-empty> - the planned writes as one diagnostic list.
plan_names() {
  local names=
  if [ "${#PLAN_FIELD_NAMES[@]}" -gt 0 ]; then
    names=$(IFS=,; printf '%s' "${PLAN_FIELD_NAMES[*]}")
    names=${names//,/, }
  fi
  [ -z "$1" ] || names="${names:+$names, }card text"
  printf '%s\n' "$names"
}

# write_card <item-id> <new:0|1> <draft-id-or-empty> <title> <body>
# Land every planned write for one card in one request, then mirror them, and
# the card itself when this run created it, into the acknowledged board.
# Returns 1 when nothing landed; the plan is kept so the caller's diagnostic
# names the writes.  Every variable travels as a raw string: a typed field
# would turn an all-digit option id into a number.
write_card() {
  local item_id=$1 new=$2 draft_id=$3 title=$4 body=$5 i vars='' ops=''
  local -a args=()
  if [ -n "$draft_id" ]; then
    # shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
    vars='$draftIssueId:ID!, $title:String!, $body:String!'
    # shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
    ops='draft: updateProjectV2DraftIssue(input:{draftIssueId:$draftIssueId, title:$title, body:$body}) { draftIssue { id } }'
    args+=(--raw-field "draftIssueId=$draft_id" --raw-field "title=$title" --raw-field "body=$body")
  fi
  if [ "${#PLAN_FIELD_IDS[@]}" -gt 0 ]; then
    # shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
    vars="${vars:+$vars, }"'$projectId:ID!, $itemId:ID!'
    args+=(--raw-field "projectId=$PROJECT_ID" --raw-field "itemId=$item_id")
    for i in "${!PLAN_FIELD_IDS[@]}"; do
      vars="$vars, \$f$i:ID!, \$o$i:String!"
      ops="$ops w$i: updateProjectV2ItemFieldValue(input:{projectId:\$projectId, itemId:\$itemId, fieldId:\$f$i, value:{singleSelectOptionId:\$o$i}}) { projectV2Item { id } }"
      args+=(--raw-field "f$i=${PLAN_FIELD_IDS[$i]}" --raw-field "o$i=${PLAN_FIELD_OPTIONS[$i]}")
    done
  fi
  if [ -z "$ops" ]; then
    [ "$new" = 0 ] || ack_card "$item_id" 1 0 "$title" "$body" || helm_fail_open "could not stage Helm board acknowledgement"
    return 0
  fi
  graphql_mutation "mutation($vars) {$ops }" "${args[@]}" || return 1
  local -a acks=()
  if [ "${#PLAN_FIELD_IDS[@]}" -gt 0 ]; then
    for i in "${!PLAN_FIELD_IDS[@]}"; do
      acks+=("${PLAN_FIELD_NAMES[$i]}" "${PLAN_FIELD_VALUES[$i]}" "${PLAN_FIELD_OPTIONS[$i]}")
    done
  fi
  ack_card "$item_id" "$new" "${draft_id:+1}" "$title" "$body" ${acks[@]+"${acks[@]}"} \
    || helm_fail_open "could not stage Helm board acknowledgement"
  plan_reset
  CARDS_WRITTEN=$((CARDS_WRITTEN + 1))
}

create_draft() {
  local title=$1 body=$2
  # shellcheck disable=SC2016 # GraphQL variables must remain literal for gh api.
  local query='mutation($projectId:ID!, $title:String!, $body:String!) {
    addProjectV2DraftIssue(input:{projectId:$projectId, title:$title, body:$body}) {
      projectItem {
        id
        content {
          __typename
          ... on DraftIssue { id title body }
        }
      }
    }
  }'
  graphql_mutation "$query" \
    --raw-field "projectId=$PROJECT_ID" \
    --raw-field "title=$title" \
    --raw-field "body=$body" \
    || return 1
  CREATED_ITEM_ID=$(jq -r '.data.addProjectV2DraftIssue.projectItem.id // empty' "$TMP_RESPONSE") || return 1
  [ -n "$CREATED_ITEM_ID" ]
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
  mv -f -- "$marker_tmp" "$DISPATCH_FILE" || return 1
  marker_tasks_reload
}

marker_remove() {
  local task_id=$1 marker_tmp
  [ -f "$DISPATCH_FILE" ] || return 0
  case "$MARKER_TASKS" in
    *"<$task_id>"*) ;;
    *) return 0 ;;
  esac
  marker_tmp=$(mktemp "$TMP_DIR/marker.XXXXXX") || return 1
  awk -F '\t' -v task="$task_id" '$1 != task' "$DISPATCH_FILE" >"$marker_tmp" || return 1
  chmod 0600 "$marker_tmp" || return 1
  mv -f -- "$marker_tmp" "$DISPATCH_FILE" || return 1
  marker_tasks_reload
}

# MARKER_TASKS lists every task with a dispatch marker as "<id>" tokens, so the
# per-record marker_remove decides in-shell instead of rewriting the file.
MARKER_TASKS=
marker_tasks_reload() {
  MARKER_TASKS=
  [ -f "$DISPATCH_FILE" ] || return 0
  MARKER_TASKS=$(awk -F '\t' '{ printf "<%s>", $1 }' "$DISPATCH_FILE")
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

decode_base64() {
  if printf '%s' "$1" | base64 --decode 2>/dev/null; then return 0; fi
  printf '%s' "$1" | base64 -D 2>/dev/null
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
marker_tasks_reload

retain_deleted_card() {
  printf '%s\t%s\n' "$1" "$2" >>"$NEW_DELETED"
}

# Task ids with a report under this home's data/, for the card's Report line.
REPORT_IDS='[]'
for report in "$DATA_PATH"/*/report.md; do
  [ -f "$report" ] || continue
  report=${report%/report.md}
  REPORT_IDS=$(jq -c --arg id "${report##*/}" '. + [$id]' <<<"$REPORT_IDS") \
    || helm_fail_open "could not index task reports"
done

# Everything a backlog record needs, derived in one jq pass over the backlog
# union, the board, and the prior caches.  One line per record, unit-separated
# so an empty column survives `read`, in this column order:
#   1 task id  2 owning home  3 state  4 hold kind  5 project supported (1/0)
#   6 raw repo  7-9 desired Project, Kind, Status names  10 priority n
#   11 desired Priority name  12-15 desired Project, Kind, Priority, Status
#   option ids  16 card state (none|one|dup)  17 item id  18 content type
#   19 content node id  20 card text differs (1/0)  21-22 current Status name
#   and option id  23 current Priority name  24-26 current Project, Kind,
#   Priority option ids  27-28 cached item id and fingerprint  29 cached item
#   still on the board (1/0)  30 deletion tombstone item id  31 guard snapshot
#   32 base64 of "<title>\n<body>"
# shellcheck disable=SC2016 # jq variables must remain literal.
RECORD_PLAN_JQ='
def rows($text): $text | split("\n") | map(select(length > 0) | split("\t"));
def fieldval($n): ([.fieldValues.nodes[]? | select(.field.name == $n)][0]) // {};
def snapshot: '"$SNAPSHOT_JQ"';
def project_name:
  (.repo // "") as $repo
  | if $repo | IN("firetabs", "geojitsu/firetabs") then "firetabs"
    elif $repo | IN("BetterBlueToo", "geojitsu/BetterBlueToo") then "BetterBlueToo"
    elif $repo | IN("firstmate", "geojitsu/firstmate") then "firstmate"
    elif $repo | IN("nocout", "dc-noc/nocout") then "nocout"
    elif $repo | IN("cryptoseacurrents", "copium/cryptoseacurrents") then "cryptoseacurrents"
    elif $repo == "other" then "other"
    else null end;
def kind_name:
  if (.hold_kind // "") == "captain" and (.hold_reason // "") != "" then "decision"
  elif (.kind // "ship") | IN("task", "scout") then "investigation"
  else "ship" end;
# priority n (0-4, or unset) -> P<n>, lossless. Unset sorts as 3.
def priority_name: (.priority // "3") | tostring | if IN("0", "1", "2", "3", "4") then "P" + . else "P3" end;
def status_name($kind):
  if .state == "done" then "Done"
  elif $kind == "decision" then "Waiting on you"
  elif .state == "in_flight" then "In flight"
  else "Queued" end;
def card_body($kind; $priority; $report):
  .id as $id
  | ((.repo // "-") | if . == "" then "-" else . end) as $repo
  | ({ship: "ship - produces a change and a PR",
      investigation: "investigation - produces knowledge, not code",
      decision: "decision - needs your call before anything moves"}[$kind]) as $type
  | (.since // .reported // .done // .merged // "unknown") as $filed
  | (.hold_reason // "") as $hold
  | ((.blocked_by_ids // []) | join(", ")) as $blocked
  | (.pr_url // "") as $pr
  | "`\($id)`\n\n"
    + (if $kind == "decision" and $hold != "" then "## What you need to decide\n\n\($hold)\n\n" else "" end)
    + "## Facts\n\n"
    + "- **Repo:** \($repo)\n"
    + "- **Type:** \($type)\n"
    + "- **Priority:** \($priority)\n"
    + "- **Filed:** \($filed)\n"
    + (if $blocked == "" then "" else "- **Blocked by:** \($blocked)\n" end)
    + (if $report == "" then "" else "- **Report:** `\($report)`\n" end)
    + (if $pr == "" then "" else "- **PR:** \($pr)\n" end)
    + "\n## Notes\n\n"
    + ([.body_lines[]? | . + "\n"] | join(""))
    + "\n---\n_Source of truth: `data/backlog.md` in the owning firstmate home._\n\n"
  | sub("\n+$"; "");
$board[0].data.user.projectV2.fields.nodes as $fields
| def option_id($field; $wanted):
    [$fields[] | select(.name == $field and .__typename == "ProjectV2SingleSelectField")
     | .options[] | select(.name == $wanted) | .id][0] // "";
  ($board[0].data.user.projectV2.items.nodes | map(.id)) as $item_ids
| ($board[0].data.user.projectV2.items.nodes
   | map(select(.content.__typename == "DraftIssue" or .content.__typename == "Issue"))) as $cards
| rows($old) as $old_rows
| rows($deleted) as $deleted_rows
| .[]
| . as $r
| kind_name as $kind
| priority_name as $priority
| status_name($kind) as $status
| project_name as $project_name
| ($project_name // "other") as $project
| ([$cards[] | select((.content.body // "") | split("\n")[0] == ("`" + $r.id + "`"))]) as $matches
| ($matches[0] // null) as $card
| ([$old_rows[] | select(.[0] == $r.id)][0] // []) as $old
| ([$deleted_rows[] | select(.[0] == $r.id)][0] // []) as $tombstone
| ((.report_path // "") | if . != "" then . elif ($reports | index($r.id)) != null then "data/\($r.id)/report.md" else "" end) as $report
| card_body($kind; $priority; $report) as $body
| [ $r.id,
    ((.home_backlog // "") | sub("/data/backlog\\.md$"; "")),
    (.state // ""),
    (.hold_kind // ""),
    (if $project_name == null then "0" else "1" end),
    (.repo // ""),
    $project, $kind, $status,
    ((.priority // "3") | tostring),
    $priority,
    option_id("Project"; $project), option_id("Kind"; $kind),
    option_id("Priority"; $priority), option_id("Status"; $status),
    (if ($matches | length) == 1 then "one" elif ($matches | length) == 0 then "none" else "dup" end),
    ($card.id // ""),
    (if $card == null then "" elif $card.content.__typename == "Issue" then "issue" else "draft" end),
    ($card.content.id // ""),
    (if $card == null then "0"
     elif ($card.content.title // "") == $r.title and ($card.content.body // "") == $body then "0"
     else "1" end),
    ($card | fieldval("Status").name // ""),
    ($card | fieldval("Status").optionId // ""),
    ($card | fieldval("Priority").name // ""),
    ($card | fieldval("Project").optionId // ""),
    ($card | fieldval("Kind").optionId // ""),
    ($card | fieldval("Priority").optionId // ""),
    ($old[1] // ""), ($old[4] // ""),
    (if ($old[1] // "") != "" and ($item_ids | index($old[1])) != null then "1" else "0" end),
    ($tombstone[1] // ""),
    (if $card == null then "" else ($card | snapshot | tojson) end),
    (($r.title + "\n" + $body) | @base64) ]
| join("")
'

RECORD_PLAN="$TMP_DIR/record-plan"
jq -r --slurpfile board "$BOARD_JSON" --rawfile old "$OLD_CARDS" --rawfile deleted "$OLD_DELETED" \
  --argjson reports "$REPORT_IDS" "$RECORD_PLAN_JQ" "$BACKLOG_JSON" >"$RECORD_PLAN" \
  || helm_fail_open "could not plan the Helm reconciliation"
record_count=$(jq 'length' "$BACKLOG_JSON")

# Budget a card's own writes need in the worst case (one pre-write read plus
# one mutation, or a creation plus one mutation) before this run stops cleanly.
CARD_WRITE_RESERVE=$(( SYNC_BUDGET_SECS / 4 ))
[ "$CARD_WRITE_RESERVE" -ge 2 ] || CARD_WRITE_RESERVE=2
CARDS_WRITTEN=0
PARTIAL=false

# True when the deadline cannot hold another card's writes and this run has
# already landed some: the run then stops between cards instead of failing
# mid-write, and the next run continues from the board as it now is.  A run
# that landed nothing keeps going so a fruitless run still reports its failure.
partial_stop_due() {
  [ "$CARDS_WRITTEN" -gt 0 ] || return 1
  [ $(( SYNC_DEADLINE - $(date +%s) )) -le "$CARD_WRITE_RESERVE" ] || return 1
  PARTIAL=true
}

while IFS=$'\x1f' read -r task_id home_path record_state _hold_kind project_supported repo \
    desired_project desired_kind desired_status desired_priority_n desired_priority \
    desired_project_option desired_kind_option desired_priority_option desired_status_option \
    card_state item_id content_type content_node_id text_differs \
    current_status current_status_id current_priority_name \
    current_project_id current_kind_id current_priority_id \
    old_item_id old_fp old_item_on_board tombstone_item_id expected_snapshot text_b64; do
  [ -n "$task_id" ] || helm_fail_open "could not plan the Helm reconciliation"
  [ "$project_supported" = 1 ] \
    || printf 'fm-helm-sync: unsupported repository %s for %s; using other\n' "$repo" "$task_id" >&2
  [ -n "$desired_project_option" ] && [ -n "$desired_kind_option" ] && [ -n "$desired_priority_option" ] && [ -n "$desired_status_option" ] \
    || helm_fail_open "required Helm option is unavailable for $task_id"
  [ "$card_state" != dup ] || helm_fail_open "duplicate Helm cards for $task_id"

  text=$(decode_base64 "$text_b64") || helm_fail_open "could not decode the card text for $task_id"
  title=${text%%$'\n'*}
  body=${text#*$'\n'}
  body_hash=$(printf '%s' "$body" | fm_helm_sha256_stdin)
  fingerprint=$(fingerprint_of "$desired_status" "$desired_priority" "$desired_project" "$desired_kind" "$title" "$body_hash")
  plan_reset
  created=0

  if [ "$card_state" = none ]; then
    if [ -n "$tombstone_item_id" ]; then
      retain_deleted_card "$task_id" "$tombstone_item_id"
      continue
    fi
    if [ -n "$old_item_id" ] && [ "$record_state" != "done" ] && [ "$old_item_on_board" = 0 ]; then
      continue   # the card was deleted: delete detection below owns it.
    fi
    if partial_stop_due; then
      break
    fi
    create_draft "$title" "$body" || helm_fail_open "could not create the Helm card for $task_id"
    item_id=$CREATED_ITEM_ID
    created=1
    content_type=draft
    content_node_id=""
    # A card that did not exist when the board was read has nothing a captain
    # could have edited since: its first field writes need no pre-write read.
    current_status=
    current_status_id=
    current_priority_name=
    current_project_id=
    current_kind_id=
    current_priority_id=
  elif [ "$FORCE" -eq 0 ] && [ -n "$old_fp" ] && [ "$old_fp" = "$fingerprint" ]; then
    # Unchanged card and no forced board read: nothing to reconcile.
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$task_id" "$item_id" "$content_node_id" "$content_type" "$fingerprint" "$NOW_EPOCH" >>"$NEW_CARDS"
    continue
  fi

  draft_write=
  if [ "$content_type" = issue ]; then
    : # real issues get field-only sync; never rewrite title or body.
  elif [ "$text_differs" = 1 ] && [ "$FORCE" -eq 1 ]; then
    # A forced read found the card text diverged: the captain edited it.
    queue_board_event "helm-card-edit:$task_id" \
      "check: captain edited Helm card $task_id text; reconcile it into the backlog" \
      || helm_fail_open "could not enqueue the Helm card edit for $task_id"
  elif [ "$text_differs" = 1 ]; then
    draft_write=$content_node_id
    [ -n "$draft_write" ] || helm_fail_open "Helm card $task_id has no draft issue id"
  fi

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
    plan_field "$STATUS_FIELD_ID" "$desired_status_option" Status "$desired_status"
  fi
  [ "$current_project_id" = "$desired_project_option" ] \
    || plan_field "$PROJECT_FIELD_ID" "$desired_project_option" Project "$desired_project"
  [ "$current_kind_id" = "$desired_kind_option" ] \
    || plan_field "$KIND_FIELD_ID" "$desired_kind_option" Kind "$desired_kind"
  if [ "$push_priority" = true ] && [ "$current_priority_id" != "$desired_priority_option" ]; then
    plan_field "$PRIORITY_FIELD_ID" "$desired_priority_option" Priority "$desired_priority"
  fi

  if [ "$created" = 1 ] || [ -n "$draft_write" ] || [ "${#PLAN_FIELD_IDS[@]}" -gt 0 ]; then
    if [ "$created" = 0 ]; then
      if partial_stop_due; then
        break
      fi
      guard_board_write "$item_id" "$expected_snapshot" \
        || helm_fail_open "could not read Helm card $task_id before writing it"
    fi
    write_card "$item_id" "$created" "$draft_write" "$title" "$body" \
      || helm_fail_open "could not update Helm $(plan_names "$draft_write") for $task_id"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$task_id" "$item_id" "$content_node_id" "$content_type" "$fingerprint" "$NOW_EPOCH" >>"$NEW_CARDS"
done <"$RECORD_PLAN"

# Board cards whose id is in no home's backlog, derived in one jq pass:
#   1 item id  2 body line 1  3 task id ("" when line 1 is not one)
#   4 has a backlog record (1/0)  5 current Status option id
#   6 cached before (1/0)  7 guard snapshot
# shellcheck disable=SC2016 # jq variables must remain literal.
ORPHAN_PLAN_JQ='
def rows($text): $text | split("\n") | map(select(length > 0) | split("\t"));
def fieldval($n): ([.fieldValues.nodes[]? | select(.field.name == $n)][0]) // {};
def snapshot: '"$SNAPSHOT_JQ"';
($backlog[0] | map(.id)) as $record_ids
| (rows($old) | map(.[0])) as $cached_ids
| .data.user.projectV2.items.nodes[]
| select(.content.__typename == "DraftIssue" or .content.__typename == "Issue")
| ((.content.body // "") | split("\n")[0]) as $line1
| ($line1 | if test("^`[A-Za-z0-9._-]+`$") then .[1:-1] else "" end) as $task_id
| [ .id, $line1, $task_id,
    (if $task_id != "" and ($record_ids | index($task_id)) != null then "1" else "0" end),
    (fieldval("Status").optionId // ""),
    (if $task_id != "" and ($cached_ids | index($task_id)) != null then "1" else "0" end),
    (snapshot | tojson) ]
| join("")
'

if [ "$PARTIAL" = false ] && [ "$record_count" -gt 0 ]; then
  ORPHAN_PLAN="$TMP_DIR/orphan-plan"
  jq -r --slurpfile backlog "$BACKLOG_JSON" --rawfile old "$OLD_CARDS" "$ORPHAN_PLAN_JQ" "$BOARD_JSON" >"$ORPHAN_PLAN" \
    || helm_fail_open "could not plan the Helm orphan sweep"
  while IFS=$'\x1f' read -r item_id _body_line1 task_id has_record current_status_id cached_before expected_snapshot; do
    if [ -z "$task_id" ]; then
      printf 'fm-helm-sync: ignoring board item %s: body line 1 is not a task id\n' "$item_id" >&2
      continue
    fi
    [ "$has_record" = 0 ] || continue

    # A Done card with no task is either a completed task's card or the captain
    # tidying his Done column: leave it alone either way.
    [ "$current_status_id" = "$STATUS_DONE_ID" ] && continue

    if [ "$TSV_EXISTED" = true ] && [ "$cached_before" = 0 ]; then
      # board-driven task creation is approved design - brief step 6 and scout report section 4 both specify that a captain-created card with no backlog task raises one check wake for ordinary firstmate intake
      # Never carded before and no backlog task: a brand-new captain card.
      queue_board_event "helm-new-card:$task_id" \
        "check: captain added Helm card $task_id with no backlog task; run intake" \
        || helm_fail_open "could not enqueue the new Helm card $task_id"
      continue
    fi

    if partial_stop_due; then
      break
    fi
    guard_board_write "$item_id" "$expected_snapshot" \
      || helm_fail_open "could not read Helm card $task_id before closing it"
    plan_reset
    plan_field "$STATUS_FIELD_ID" "$STATUS_DONE_ID" Status Done
    write_card "$item_id" 0 "" "" "" || helm_fail_open "could not close the missing Helm task $task_id"
    marker_remove "$task_id" || helm_fail_open "could not clear the Helm dispatch marker for $task_id"
  done <"$ORPHAN_PLAN"
fi

# Delete detection: a previously synced card gone from the board, derived in
# one jq pass over the prior cache:
#   1 task id  2 cached item id  3 task state ("" when the task is gone)
#   4 owning home  5 captain-held (1/0)  6 held or blocked (1/0)
# shellcheck disable=SC2016 # jq variables must remain literal.
DELETED_PLAN_JQ='
def rows($text): $text | split("\n") | map(select(length > 0) | split("\t"));
($board[0].data.user.projectV2.items.nodes) as $items
| ($items | map(.id)) as $item_ids
| ($items | map((.content.body // "") | split("\n")[0])) as $line1s
| rows($old)[]
| select(length >= 2 and .[0] != "" and .[1] != "")
| .[0] as $task_id
| select(($item_ids | index(.[1])) == null)
| select(($line1s | index("`" + $task_id + "`")) == null)
| ([$backlog[0][] | select(.id == $task_id)][0] // null) as $record
| [ $task_id, .[1],
    ($record.state // ""),
    (($record.home_backlog // "") | sub("/data/backlog\\.md$"; "")),
    (if ($record.hold_kind // "") == "captain" then "1" else "0" end),
    (if ($record.hold_reason // "") != "" or (($record.blocked_by_ids // []) | length) > 0 then "1" else "0" end) ]
| join("")
'

if [ "$PARTIAL" = false ] && [ "$TSV_EXISTED" = true ]; then
  DELETED_PLAN="$TMP_DIR/deleted-plan"
  jq -r --slurpfile board "$BOARD_JSON" --slurpfile backlog "$BACKLOG_JSON" --rawfile old "$OLD_CARDS" "$DELETED_PLAN_JQ" \
    <<<'null' >"$DELETED_PLAN" || helm_fail_open "could not plan the Helm deletion sweep"
  while IFS=$'\x1f' read -r task_id old_item_id task_state home_path captain_held held; do
    if [ -z "$task_state" ]; then
      continue   # card gone and no task: drop the stale line, nothing else.
    fi
    if [ "$task_state" = "done" ] || [ "$captain_held" = 1 ]; then
      retain_deleted_card "$task_id" "$old_item_id"
      continue
    fi

    if [ "$task_state" = in_flight ]; then
      choices='the task is In flight: cancel it (stop the worker, then Done), mark it done, or was the card deleted by mistake'
    elif [ "$held" = 1 ]; then
      choices='the task is blocked or held: cancel it (Done), mark it done, or was the card deleted by mistake'
    else
      choices='the task is queued: cancel it (Done), mark it done, or was the card deleted by mistake'
    fi
    reason="Helm card deleted; $choices."
    if ! backlog_hold_for_captain "$home_path" "$task_id" "$reason"; then
      helm_fail_open "could not hold deleted Helm task $task_id"
    fi
    retain_deleted_card "$task_id" "$old_item_id"
    queue_board_event "helm-card-deleted:$task_id" \
      "check: captain deleted Helm card $task_id ($choices)" \
      || printf 'fm-helm-sync: could not enqueue the Helm card deletion for %s\n' "$task_id" >&2
  done <"$DELETED_PLAN"
fi

publish_poll_signature() {
  local signature poll_tmp
  signature=$(jq -r '
    def fieldval($n): [.fieldValues.nodes[]? | select(.field.name == $n) | .name][0] // "";
    [ .data.user.projectV2.items.nodes[]
      | .id + "" + fieldval("Status") + "" + fieldval("Priority")
        + "" + ((.content.title // "") | @base64)
        + "" + ((.content.body // "") | @base64) ]
    | (length | tostring) + "\n" + (sort | join("\n"))
  ' "$ACK_BOARD_JSON" | fm_helm_sha256_stdin) || helm_fail_open "could not build Helm board acknowledgement"
  [ -n "$signature" ] || helm_fail_open "could not build Helm board acknowledgement"
  poll_tmp=$(mktemp "$TMP_DIR/poll.XXXXXX") || helm_fail_open "could not stage Helm board acknowledgement"
  printf '%s\n' "$signature" >"$poll_tmp" || helm_fail_open "could not write Helm board acknowledgement"
  chmod 0600 "$poll_tmp" || helm_fail_open "could not protect Helm board acknowledgement"
  mv -f -- "$poll_tmp" "$POLL_FILE" || helm_fail_open "could not publish Helm board acknowledgement"
}

if [ "$PARTIAL" = true ]; then
  # The cards written so far are acknowledged so the next run does not read
  # them as captain edits; the caches and debounce hash stay as they were so
  # that run reconciles the rest.
  publish_poll_signature
  if [ "$FORCE" -eq 1 ]; then
    : >"$RESUME_FORCE_FILE" || helm_fail_open "could not record the pending forced Helm read"
    chmod 0600 "$RESUME_FORCE_FILE" 2>/dev/null || true
  fi
  printf 'fm-helm-sync: partial: %s cards written before the run budget ran out; the next run continues\n' \
    "$CARDS_WRITTEN"
  exit 0
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

publish_poll_signature
rm -f -- "$RESUME_FORCE_FILE"

printf 'fm-helm-sync: synchronized\n'
