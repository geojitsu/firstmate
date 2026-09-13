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
# ## Plan once, then write
# One run reads the board once (paginated), parses every home's backlog once,
# and computes the whole reconciliation as ONE plan through the jq programs in
# bin/fm-helm-lib.sh ("Plan format" there owns the entry layout).  The loop
# below only executes plan entries: a wake, a marker, a backlog write-back, or
# the one GitHub read-then-mutate a card needs.  Local work is therefore a
# handful of processes per run, not dozens per backlog row, so a fleet-sized
# backlog plans in well under a second and the run budget is spent on writes.
#
# ## Debounce and run budget
# The watcher-check path debounces all GitHub work on one SHA-256 hash over every
# discovered home's data/backlog.md, stored in
# state/.helm-sync-backlog.sha256.  Use --force for an explicit board read when
# the captain has edited a card without changing any backlog; --force still
# never calls bin/fm-spawn.sh and never deletes a card.
# One 25-second deadline covers the whole run: the paginated board read and every
# card write.  The script uses `timeout` when available and otherwise stops each
# request with a watchdog at the same deadline.  When the deadline arrives with
# card writes still planned, or a card's own write failed, the run stops cleanly,
# keeps everything it already landed (see "Durable progress"), prints one
# `fm-helm-sync: partial: N cards remain` line, and exits 0; the next run plans
# again from the recorded state and continues.  A --force run that reaches this
# partial path leaves state/.helm-sync-resume so the next run is forced too and
# the captain's board edits on the cards it never reached still get their
# reconciliation wakes instead of a backlog push.  helm_fail_open remains the exit for config, auth,
# parse, and other failures that stop the run before or between card writes.
#
# ## Durable progress
# Every landed card write updates that card's row in state/helm-cards.tsv at
# once, atomically, so a run cut off by its deadline, a failed request, or the
# watcher's check timeout has already recorded what it did.  A card created but
# not yet field-written carries an empty fingerprint, which makes the next run
# compare it against the board and finish it.  The debounce hash and the
# deletion tombstones are published only by a complete run.
# The board poll signature (state/.helm-board-poll) is republished at every
# non-fail-open exit from the board as read plus the "landed patches" recorded
# for each successful write, so the sync's own writes never read back as a
# captain edit; bin/fm-helm-lib.sh's fm_helm_landed_patch_program owns the patch
# shape.
#
# ## Identity cache
# state/helm-cards.tsv (mode 0600) maps every synced card:
#   <task-id> <item-id> <content-node-id> <draft|issue> <status-option>
#   <priority-option> <title-base64> <body-base64> <last-seen-epoch>
# Version 1 rows with one opaque fingerprint are migrated by adopting the
# board-current values as their baseline, so migration cannot fabricate a
# divergence.  A missing baseline is handled the same way and produces one
# summary wake listing the rebuilt task ids.  The cache is not truth: every card
# carries `<task-id>` as body line 1.  A card whose body line 1 is not a
# recognised `<id>` is refused and logged, never touched.
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
DIVERGENCE_FILES=(
  "$STATE_PATH/.helm-card-edit"
  "$STATE_PATH/.helm-status-back"
  "$STATE_PATH/.helm-status-done"
  "$STATE_PATH/.helm-new-card"
  "$STATE_PATH/.helm-card-deleted"
)
CARDS_FILE="$STATE_PATH/helm-cards.tsv"
DELETED_FILE="$STATE_PATH/helm-deleted.tsv"
POLL_FILE="$STATE_PATH/.helm-board-poll"
RESUME_FILE="$STATE_PATH/.helm-sync-resume"
LOCK_FILE="$STATE_PATH/.helm-sync.lock"
TMP_DIR=
LOCK_HELD=false
FORCE=0
LANDED=
SYNC_DEADLINE_SECONDS=25

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

# Stop the run with one diagnostic and exit 0. Once any card write has landed,
# the poll signature is republished first so the next run does not mistake this
# run's own writes for a captain edit.
helm_fail_open() {
  printf 'fm-helm-sync: %s\n' "$1" >&2
  if [ -n "$LANDED" ] && [ -s "$LANDED" ]; then
    publish_progress || true
  fi
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

if [ -L "$HASH_FILE" ] || [ -L "$DISPATCH_FILE" ] || [ -L "$CARDS_FILE" ] || [ -L "$DELETED_FILE" ] \
  || [ -L "$POLL_FILE" ] || [ -L "$RESUME_FILE" ]; then
  helm_fail_open "refusing symlinked Helm state"
fi
for divergence_file in "${DIVERGENCE_FILES[@]}"; do
  [ -L "$divergence_file" ] && helm_fail_open "refusing symlinked Helm state"
done

# A forced run that stopped early asks the next run to stay forced.
if [ -f "$RESUME_FILE" ]; then
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

SYNC_DEADLINE=$(( $(date +%s) + SYNC_DEADLINE_SECONDS ))
PAGE_COUNT=0
CURSOR=
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
  REMAINING=$(( SYNC_DEADLINE - $(date +%s) ))
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

# guard_board_write <item-id> <expected-snapshot-json>
# Re-read one card immediately before writing it and compare against the
# snapshot the plan was computed from. Returns 1 on a read failure, 2 when the
# card changed underneath the plan (the caller stops the run with the existing
# reconciliation wake), 0 when the write may proceed.
guard_board_write() {
  local item_id=$1 expected=$2 remaining actual
  # Accepted containment: GitHub Projects has no conditional or versioned
  # mutation, so a captain edit can still land between this read and the write.
  # The next reverse poll detects that divergence and raises the reconcile wake.
  remaining=$(( SYNC_DEADLINE - $(date +%s) ))
  [ "$remaining" -gt 0 ] || return 1
  if ! run_gh_bounded "$remaining" gh api graphql \
    --field "query=$ITEM_GRAPHQL_QUERY" \
    --field "itemId=$item_id" >"$TMP_RESPONSE" 2>"$TMP_RESPONSE_ERROR"; then
    return 1
  fi
  actual=$(jq -c '
    if ((.errors // []) | length) > 0 or .data.node == null then error("board read failed") else .data.node end
    | {title:(.content.title // ""),
       body:(.content.body // ""),
       fields:([.fieldValues.nodes[]?
         | {field:(.field.name // ""),name:(.name // ""),optionId:(.optionId // "")}
         | select(.field != "")]
         | sort_by(.field, .optionId, .name))}' "$TMP_RESPONSE" 2>/dev/null) || return 1
  [ "$expected" = "$actual" ] || return 2
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

US=$'\037'
RS=$'\036'
SPLIT=()

# split_items <US-separated string> - fill SPLIT with the items (builtins only).
split_items() {
  local s=$1
  SPLIT=()
  [ -n "$s" ] || return 0
  while :; do
    case "$s" in
      *"$US"*)
        SPLIT+=("${s%%"$US"*}")
        s=${s#*"$US"}
        ;;
      *)
        SPLIT+=("$s")
        break
        ;;
    esac
  done
}

# write_card <item-id> <draft-id> <title> <body> <field-writes>
# One mutation carrying the card's text update (when a draft id is given) and
# every planned field write.
write_card() {
  local item_id=$1 draft_id=$2 title=$3 body=$4 i vars='' ops='' field_id option_id rest
  local -a args=()
  split_items "$5"
  [ -n "$draft_id" ] || [ "${#SPLIT[@]}" -gt 0 ] || return 0
  if [ -n "$draft_id" ]; then
    vars="\$draftIssueId:ID!, \$title:String!, \$body:String!"
    ops="draft:updateProjectV2DraftIssue(input:{draftIssueId:\$draftIssueId,title:\$title,body:\$body}){draftIssue{id}}"
    args+=(--field "draftIssueId=$draft_id" --field "title=$title" --field "body=$body")
  fi
  if [ "${#SPLIT[@]}" -gt 0 ]; then
    vars="${vars:+$vars, }\$projectId:ID!, \$itemId:ID!"
    args+=(--field "projectId=$PROJECT_ID" --field "itemId=$item_id")
    for ((i = 0; i < ${#SPLIT[@]}; i++)); do
      field_id=${SPLIT[$i]%%"$RS"*}
      rest=${SPLIT[$i]#*"$RS"}
      option_id=${rest##*"$RS"}
      vars="$vars, \$f$i:ID!, \$o$i:String!"
      ops="$ops w$i:updateProjectV2ItemFieldValue(input:{projectId:\$projectId,itemId:\$itemId,fieldId:\$f$i,value:{singleSelectOptionId:\$o$i}}){projectV2Item{id}}"
      args+=(--field "f$i=$field_id" --field "o$i=$option_id")
    done
  fi
  graphql_mutation "mutation($vars){$ops}" "${args[@]}"
}

# first_field_name <field-writes> - the name of the first planned field write,
# for the "could not update Helm <Field>" diagnostic.
first_field_name() {
  local first rest
  split_items "$1"
  [ "${#SPLIT[@]}" -gt 0 ] || { printf '\n'; return 0; }
  first=${SPLIT[0]}
  rest=${first#*"$RS"}
  printf '%s\n' "${rest%%"$RS"*}"
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
    --field "projectId=$PROJECT_ID" \
    --field "title=$title" \
    --field "body=$body" \
    || return 1
  CREATED_ITEM_ID=$(jq -r '.data.addProjectV2DraftIssue.projectItem.id // empty' "$TMP_RESPONSE") || return 1
  [ -n "$CREATED_ITEM_ID" ]
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

# publish_file <content-file> <target> - atomic mode-0600 publish inside the
# state directory (same filesystem, so the rename is atomic).
publish_file() {
  local src=$1 target=$2 tmp
  tmp=$(mktemp "$STATE_PATH/.helm-publish.XXXXXX") || return 1
  if ! cp -- "$src" "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Board patches recorded for every landed write ("<item>\t<json>" lines), folded
# into the poll signature so the sync's own writes never read back as edits.
LANDED="$TMP_DIR/landed.tsv"
: >"$LANDED"

# publish_progress - republish the poll signature from the board as read plus
# the landed patches, and keep a stopped forced run forced on its next run.
publish_progress() {
  local signature
  signature=$(jq -r --rawfile landed "$LANDED" \
    "$(fm_helm_landed_patch_program) | $(fm_helm_board_signature_program)" "$BOARD_JSON" \
    | fm_helm_sha256_stdin) || return 1
  [ -n "$signature" ] || return 1
  printf '%s\n' "$signature" >"$TMP_DIR/poll" || return 1
  publish_file "$TMP_DIR/poll" "$POLL_FILE" || return 1
  if [ "$FORCE" -eq 1 ]; then
    : >"$TMP_DIR/resume" && publish_file "$TMP_DIR/resume" "$RESUME_FILE" || return 1
  fi
}

# Prior identity cache: absent => first run / rebuild-from-board, so treat every
# current card as known and raise no new-card or deletion wakes this run.
TSV_EXISTED=false
OLD_CARDS="$TMP_DIR/old-cards.tsv"
: >"$OLD_CARDS"
if [ -f "$CARDS_FILE" ]; then
  TSV_EXISTED=true
  cat -- "$CARDS_FILE" >"$OLD_CARDS" 2>/dev/null || : >"$OLD_CARDS"
fi
# The working copy of the cache: prior rows, replaced row by row as writes land.
CACHE_WORK="$TMP_DIR/cache-work.tsv"
cp -- "$OLD_CARDS" "$CACHE_WORK" || helm_fail_open "could not stage the Helm identity cache"
# Rows a complete run publishes as the whole new cache.
NEW_CARDS="$TMP_DIR/new-cards.tsv"
: >"$NEW_CARDS"
OLD_DELETED="$TMP_DIR/old-deleted.tsv"
: >"$OLD_DELETED"
if [ -f "$DELETED_FILE" ]; then
  cat -- "$DELETED_FILE" >"$OLD_DELETED" 2>/dev/null || : >"$OLD_DELETED"
fi
NEW_DELETED="$TMP_DIR/new-deleted.tsv"
: >"$NEW_DELETED"
OLD_MARKERS="$TMP_DIR/old-markers.tsv"
: >"$OLD_MARKERS"
if [ -f "$DISPATCH_FILE" ]; then
  cat -- "$DISPATCH_FILE" >"$OLD_MARKERS" 2>/dev/null || : >"$OLD_MARKERS"
fi
OLD_DIVERGENCES="$TMP_DIR/old-divergences.tsv"
: >"$OLD_DIVERGENCES"
for divergence_file in "${DIVERGENCE_FILES[@]}"; do
  divergence_kind=${divergence_file##*/.helm-}
  [ -f "$divergence_file" ] || continue
  awk -F '\t' -v k="$divergence_kind" 'NF >= 3 { print k "\t" $1 "\t" $2 "\t" $3 }' "$divergence_file" >>"$OLD_DIVERGENCES"
done
NOW_EPOCH=$(date +%s)

# cache_publish_row <task-id> <row> - replace one card's row in the working
# cache and publish the whole cache atomically, so the row survives any later
# interruption of this run.
cache_publish_row() {
  local task_id=$1 row=$2 tmp
  tmp=$(mktemp "$TMP_DIR/cache.XXXXXX") || return 1
  { awk -F '\t' -v t="$task_id" '$1 != t' "$CACHE_WORK" && printf '%s\n' "$row"; } >"$tmp" || return 1
  mv -f -- "$tmp" "$CACHE_WORK" || return 1
  publish_file "$CACHE_WORK" "$CARDS_FILE"
}

# Wake keys already queued, plus every key this run raises: one wake per key.
RAISED_KEYS=$'\n'"$(fm_wake_queued_keys check)"$'\n'

# raise_wakes <wakes-field> - enqueue each planned wake not already queued.
raise_wakes() {
  local i pair key payload
  split_items "$1"
  for ((i = 0; i < ${#SPLIT[@]}; i++)); do
    pair=${SPLIT[$i]}
    key=${pair%%"$RS"*}
    payload=${pair#*"$RS"}
    case "$RAISED_KEYS" in
      *$'\n'"$key"$'\n'*) continue ;;
    esac
    fm_wake_append check "$key" "$payload" || return 1
    RAISED_KEYS="$RAISED_KEYS$key"$'\n'
  done
}

apply_divergence_ops() {
  local op kind rest op_action item fp file tmp
  split_items "$1"
  for op in "${SPLIT[@]}"; do
    [ -n "$op" ] || continue
    kind=${op%%"$RS"*}; rest=${op#*"$RS"}
    op_action=${rest%%"$RS"*}; rest=${rest#*"$RS"}
    item=${rest%%"$RS"*}; fp=${rest#*"$RS"}
    file="$STATE_PATH/.helm-$kind"
    tmp=$(mktemp "$TMP_DIR/divergence.XXXXXX") || return 1
    if [ -f "$file" ]; then awk -F '\t' -v t="$task_id" '$1 != t' "$file" >"$tmp" || return 1; fi
    if [ "$op_action" = keep ]; then printf '%s\t%s\t%s\n' "$task_id" "$item" "$fp" >>"$tmp" || return 1; fi
    chmod 0600 "$tmp" && mv -f -- "$tmp" "$file" || return 1
  done
}

# Render every record's desired card, fingerprint it, and compute the plan.
record_count=$(jq 'length' "$BACKLOG_JSON")
REPORT_IDS='[]'
report_ids=()
while IFS= read -r report_id; do
  [ -n "$report_id" ] || continue
  [ -f "$DATA_PATH/$report_id/report.md" ] && report_ids+=("$report_id")
done < <(jq -r '.[].id' "$BACKLOG_JSON")
if [ "${#report_ids[@]}" -gt 0 ]; then
  REPORT_IDS=$(jq -nc '$ARGS.positional' --args "${report_ids[@]}") \
    || helm_fail_open "could not index task reports"
fi
DESIRED_JSON="$TMP_DIR/desired.json"
jq --argjson report_ids "$REPORT_IDS" "$(fm_helm_desired_program)" "$BACKLOG_JSON" >"$DESIRED_JSON" \
  || helm_fail_open "could not render the Helm cards"

# Fingerprint = sha256(status, priority, project, kind, title, sha256(body)),
# NUL-joined: the same value the previous per-record implementation stored, so
# an existing cache keeps skipping unchanged cards.
FP_DIR="$TMP_DIR/fp"
mkdir -p "$FP_DIR" || helm_fail_open "could not stage Helm fingerprints"
BODY_HASHES="$TMP_DIR/body-hashes.tsv"
FPS="$TMP_DIR/fingerprints.tsv"
: >"$BODY_HASHES"
: >"$FPS"
if [ "$record_count" -gt 0 ]; then
  while IFS= read -r -d '' fp_id && IFS= read -r -d '' fp_body; do
    printf '%s' "$fp_body" >"$FP_DIR/body-$fp_id"
  done < <(jq -j '([0] | implode) as $nul | .[] | .id, $nul, .desired.body, $nul' "$DESIRED_JSON")
  fm_helm_sha256_files "$FP_DIR" body- >"$BODY_HASHES"
  [ -s "$BODY_HASHES" ] || helm_fail_open "could not fingerprint the Helm cards"
  while IFS= read -r -d '' fp_id && IFS= read -r -d '' fp_status && IFS= read -r -d '' fp_priority \
    && IFS= read -r -d '' fp_project && IFS= read -r -d '' fp_kind && IFS= read -r -d '' fp_title \
    && IFS= read -r -d '' fp_body_hash; do
    printf '%s\0%s\0%s\0%s\0%s\0%s' "$fp_status" "$fp_priority" "$fp_project" "$fp_kind" "$fp_title" "$fp_body_hash" \
      >"$FP_DIR/fp-$fp_id"
  done < <(jq -j --rawfile hashes "$BODY_HASHES" '
    ([0] | implode) as $nul
    | ($hashes | split("\n") | map(select(. != "") | split("\t")) | map({key: .[0], value: .[1]}) | from_entries) as $h
    | .[] | .id, $nul, .desired.status, $nul, .desired.priority, $nul, .desired.project, $nul, .desired.kind, $nul,
      .desired.title, $nul, ($h[.id] // ""), $nul' "$DESIRED_JSON")
  fm_helm_sha256_files "$FP_DIR" fp- >"$FPS"
  [ -s "$FPS" ] || helm_fail_open "could not fingerprint the Helm cards"
fi

PLAN="$TMP_DIR/plan.nul"
jq -j --slurpfile desired "$DESIRED_JSON" \
  --rawfile cards "$OLD_CARDS" --rawfile deleted "$OLD_DELETED" --rawfile markers "$OLD_MARKERS" \
  --rawfile divergences "$OLD_DIVERGENCES" \
  --rawfile fps "$FPS" \
  --arg force "$FORCE" --arg dispatch_status "$DISPATCH_STATUS" --arg now "$NOW_EPOCH" \
  --arg tsv_existed "$TSV_EXISTED" \
  "$(fm_helm_plan_program)" "$BOARD_JSON" >"$PLAN" \
  || helm_fail_open "could not plan the Helm reconciliation"

# Execute the plan. Each entry is FM_HELM_PLAN_FIELDS NUL-terminated fields.
FAILED=0
REMAINING=0
EXHAUSTED=0
GUARD_CONFLICT=0
CONFLICT_WAKE=0
E=()

read_entry() {
  local i
  for ((i = 0; i < FM_HELM_PLAN_FIELDS; i++)); do
    IFS= read -r -u 3 -d '' "E[$i]" || return 1
  done
}

budget_left() {
  [ $(( SYNC_DEADLINE - $(date +%s) )) -gt 0 ]
}

# land <item-id> <patch-json> - record one landed write for the poll signature.
land() {
  printf '%s\t%s\n' "$1" "$2" >>"$LANDED"
}

exec 3<"$PLAN"
while read_entry; do
  phase=${E[0]} action=${E[1]} task_id=${E[2]} item_id=${E[3]} cache_row=${E[4]} draft_id=${E[5]}
  title=${E[6]} body=${E[7]} field_writes=${E[8]} wakes=${E[9]} marker=${E[10]} marker_fp=${E[11]}
  divergence_ops=${E[12]} writeback=${E[13]} home_path=${E[14]} tombstone=${E[15]} hold_reason=${E[16]} expected=${E[17]}
  ack_create=${E[18]} ack_write=${E[19]} fingerprint=${E[20]} note=${E[21]}
  [ -z "$note" ] || printf '%s\n' "$note" >&2
  if [ "$phase" = error ]; then
    helm_fail_open "$action"
  fi
  if [ "$EXHAUSTED" -eq 1 ]; then
    case "$action" in create|update|close) REMAINING=$((REMAINING + 1)) ;; esac
    continue
  fi
  case "$phase:$action" in
    summary:info)
      raise_wakes "$wakes" || helm_fail_open "could not enqueue the Helm baseline summary"
      continue
      ;;
    record:skip)
      [ -z "$tombstone" ] || printf '%s\n' "$tombstone" >>"$NEW_DELETED"
      continue
      ;;
    record:none|record:create|record:update)
      if [ -n "$writeback" ]; then
        # Priority: on a forced read, a valid board Priority that differs from
        # the backlog is a captain edit -> write it back and do not push over it.
        if ! backlog_write_priority "$home_path" "$task_id" "$writeback"; then
          raise_wakes "helm-priority:$task_id${RS}check: captain changed Helm card $task_id Priority; reconcile it into the backlog" \
            || helm_fail_open "could not enqueue the Helm Priority reconciliation for $task_id"
          helm_fail_open "could not write Helm Priority for $task_id"
        fi
      fi
      raise_wakes "$wakes" || helm_fail_open "could not enqueue the Helm wake for $task_id"
      case "$wakes" in *"changed on both board and backlog"*) CONFLICT_WAKE=1 ;; esac
      apply_divergence_ops "$divergence_ops" || helm_fail_open "could not update Helm divergence memory"
      case "$marker" in
        remove) marker_remove "$task_id" || helm_fail_open "could not clear the Helm dispatch marker for $task_id" ;;
        request) marker_replace "$task_id" "$item_id" "$DISPATCH_OPTION_ID" "$marker_fp" \
          || helm_fail_open "could not record the Helm dispatch request for $task_id" ;;
      esac
      ;;
    missing:ignore|missing:wake)
      raise_wakes "$wakes" || helm_fail_open "could not enqueue the new Helm card $task_id"
      apply_divergence_ops "$divergence_ops" || helm_fail_open "could not update Helm divergence memory"
      continue
      ;;
    missing:close)
      ;;
    deleted:retain)
      printf '%s\n' "$tombstone" >>"$NEW_DELETED"
      continue
      ;;
    deleted:hold)
      backlog_hold_for_captain "$home_path" "$task_id" "$hold_reason" \
        || helm_fail_open "could not hold deleted Helm task $task_id"
      printf '%s\n' "$tombstone" >>"$NEW_DELETED"
      raise_wakes "$wakes" \
        || printf 'fm-helm-sync: could not enqueue the Helm card deletion for %s\n' "$task_id" >&2
      apply_divergence_ops "$divergence_ops" \
        || helm_fail_open "could not update Helm divergence memory"
      continue
      ;;
    *)
      helm_fail_open "unrecognised plan entry $phase:$action"
      ;;
  esac

  if [ "$action" = none ]; then
    printf '%s\n' "$cache_row" >>"$NEW_CARDS"
    continue
  fi
  if ! budget_left; then
    EXHAUSTED=1
    REMAINING=$((REMAINING + 1))
    continue
  fi
  if [ "$action" = create ]; then
    if ! create_draft "$title" "$body"; then
      printf 'fm-helm-sync: could not create the Helm card for %s\n' "$task_id" >&2
      FAILED=$((FAILED + 1))
      continue
    fi
    item_id=$CREATED_ITEM_ID
    land "$item_id" "$ack_create"
    complete_cache_row=$(printf '%s\n' "$cache_row" | awk -F '\t' -v i="$item_id" 'BEGIN { OFS="\t" } {$2=i; print}')
    cache_row=$(printf '%s\n' "$cache_row" | awk -F '\t' -v i="$item_id" 'BEGIN { OFS="\t" } {$2=i; $5=""; $6=""; print}')
    cache_publish_row "$task_id" "$cache_row" \
      || helm_fail_open "could not publish the Helm identity cache"
  fi
  guard_board_write "$item_id" "$expected"
  guard_status=$?
  if [ "$guard_status" -eq 2 ]; then
    GUARD_CONFLICT=1
    break
  fi
  if [ "$guard_status" -ne 0 ] || ! write_card "$item_id" "$draft_id" "$title" "$body" "$field_writes"; then
    FAILED=$((FAILED + 1))
    if [ "$action" = close ]; then
      printf 'fm-helm-sync: could not close the missing Helm task %s\n' "$task_id" >&2
    elif [ -n "$field_writes" ]; then
      printf 'fm-helm-sync: could not update Helm %s for %s\n' "$(first_field_name "$field_writes")" "$task_id" >&2
    else
      printf 'fm-helm-sync: could not update the Helm card content for %s\n' "$task_id" >&2
    fi
    continue
  fi
  land "$item_id" "$ack_write"
  if [ "$action" = close ]; then
    [ "$marker" != remove ] || marker_remove "$task_id" \
      || helm_fail_open "could not clear the Helm dispatch marker for $task_id"
    continue
  fi
  if [ "$action" = create ]; then
    cache_row=$complete_cache_row
  fi
  cache_publish_row "$task_id" "$cache_row" || helm_fail_open "could not publish the Helm identity cache"
  printf '%s\n' "$cache_row" >>"$NEW_CARDS"
done
exec 3<&-

if [ "$CONFLICT_WAKE" -eq 1 ]; then
  printf 'check: Helm board and backlog both changed; reconcile the affected card(s)\n'
  exit 0
fi

if [ "$GUARD_CONFLICT" -eq 1 ]; then
  publish_progress || helm_fail_open "could not publish Helm board acknowledgement"
  printf 'check: Helm board and backlog both changed; run bin/fm-helm-sync.sh --force to reconcile\n'
  exit 0
fi
if [ $((FAILED + REMAINING)) -gt 0 ]; then
  publish_progress || helm_fail_open "could not publish Helm board acknowledgement"
  printf 'fm-helm-sync: partial: %s cards remain\n' $((FAILED + REMAINING))
  exit 0
fi

# A complete run: publish the whole refreshed identity cache, the deletion
# tombstones, the debounce hash, and the poll signature.
if [ -s "$NEW_CARDS" ] || [ "$TSV_EXISTED" = true ]; then
  sort -u "$NEW_CARDS" >"$TMP_DIR/cards.sorted" || helm_fail_open "could not stage the Helm identity cache"
  publish_file "$TMP_DIR/cards.sorted" "$CARDS_FILE" || helm_fail_open "could not publish the Helm identity cache"
fi

if [ -s "$NEW_DELETED" ]; then
  sort -u "$NEW_DELETED" >"$TMP_DIR/deleted.sorted" || helm_fail_open "could not stage Helm deletion state"
  publish_file "$TMP_DIR/deleted.sorted" "$DELETED_FILE" || helm_fail_open "could not publish Helm deletion state"
else
  rm -f -- "$DELETED_FILE"
fi

printf '%s\n' "$BACKLOG_HASH" >"$TMP_DIR/hash" || helm_fail_open "could not write Helm sync state"
publish_file "$TMP_DIR/hash" "$HASH_FILE" || helm_fail_open "could not publish Helm sync state"

FORCE=0
publish_progress || helm_fail_open "could not publish Helm board acknowledgement"
rm -f -- "$RESUME_FILE"

printf 'fm-helm-sync: synchronized\n'
