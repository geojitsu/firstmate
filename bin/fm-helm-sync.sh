#!/usr/bin/env bash
# fm-helm-sync.sh - reconcile the optional Helm GitHub Project boards with the
# whole fleet's backlog.
#
# The local config/helm.json file is the opt-in.  When it is absent this script
# exits silently before reading any backlog, touching state, or making a network
# call.
#
# ## Fleet-aware
# The sync runs from the main home only and is the single writer of the boards.
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
# discovered home's data/backlog.md plus data/helm-project-map.json, stored in
# state/.helm-sync-backlog.sha256.  Use --force for an explicit board read when
# the captain has edited a card without changing any backlog; --force still
# never calls bin/fm-spawn.sh and never deletes a card.
# Each board gets the existing 25-second work budget within a total cap of 120
# seconds. The paginated board reads and card writes share the total deadline,
# while each board receives its own slice in stable default-first order. The
# script uses `timeout` when available and otherwise stops each request with a
# watchdog at the same deadline. When the deadline arrives with
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
# watcher's check timeout has already recorded what it did.  Between draft
# creation and its field write, a card row has its identity and desired text
# but blank Status and Priority baselines.  After the field write lands, the
# sync publishes the complete per-field baseline.  The debounce hash and the
# deletion tombstones are published only by a complete run.
# The per-board poll signatures (state/.helm-board-poll) are republished at every
# non-fail-open exit from the board as read plus the "landed patches" recorded
# for each successful write, so the sync's own writes never read back as a
# captain edit; bin/fm-helm-lib.sh's fm_helm_landed_patch_program owns the patch
# shape.
#
# ## Identity cache
# state/helm-cards.tsv (mode 0600) maps every synced card:
#   <task-id> <item-id> <content-node-id> <draft|issue> <status-option>
#   <priority-option> <title-base64> <body-base64> <last-seen-epoch>
#   <board-owner> <board-number>
# Version 1 rows with one opaque fingerprint are migrated by adopting the
# board-current values as their baseline, so migration cannot fabricate a
# divergence.  A missing baseline is rebuilt the same way without a wake.  The
# cache is not truth: every card carries `<task-id>` as body line 1.  A card
# whose body line 1 is not a
# recognised `<id>` is refused and logged, never touched.
# State files under `.helm-*` retain an acknowledgement fingerprint for each
# unresolved field divergence.  The sync removes an acknowledgement after that
# field no longer diverges, so repeated forced reads do not requeue its wake.
# The same shape debounces the unsupported-repository fallback note (kind
# `unsupported-repo`, keyed on task id and the exact `repo:` value): it prints
# once per task per distinct value instead of on every full replan, and fires
# again only when that task's `repo:` value actually changes.
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
ROUTING_FILE="$DATA_PATH/helm-project-map.json"
HASH_FILE="$STATE_PATH/.helm-sync-backlog.sha256"
DISPATCH_FILE="$STATE_PATH/.helm-dispatch-requests"
DIVERGENCE_FILES=(
  "$STATE_PATH/.helm-card-edit"
  "$STATE_PATH/.helm-card-edit-title"
  "$STATE_PATH/.helm-card-edit-body"
  "$STATE_PATH/.helm-status-back"
  "$STATE_PATH/.helm-status-done"
  "$STATE_PATH/.helm-status-waiting"
  "$STATE_PATH/.helm-conflict"
  "$STATE_PATH/.helm-conflict-status"
  "$STATE_PATH/.helm-conflict-priority"
  "$STATE_PATH/.helm-conflict-title"
  "$STATE_PATH/.helm-conflict-body"
  "$STATE_PATH/.helm-new-card"
  "$STATE_PATH/.helm-card-deleted"
  "$STATE_PATH/.helm-unsupported-repo"
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
TOTAL_DEADLINE_SECONDS=120

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
  || [ -L "$ROUTING_FILE" ] \
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

RETAIN_OWNER=
RETAIN_NUMBER=
RETAIN_PROJECT=${FM_HELM_RETAIN_PROJECT:-}
case "${FM_HELM_RETAIN_BOARD:-}" in
  */*) RETAIN_OWNER=${FM_HELM_RETAIN_BOARD%/*}; RETAIN_NUMBER=${FM_HELM_RETAIN_BOARD##*/} ;;
esac
case "$RETAIN_OWNER/$RETAIN_NUMBER" in
  /*|*//*|*/|*' '*|*/*[!0-9]*) RETAIN_OWNER=; RETAIN_NUMBER=; RETAIN_PROJECT= ;;
esac

if [ -f "$ROUTING_FILE" ]; then
  jq -e '.version == 1 and ((.projects // {}) | type == "object") and ((.nudges // {}) | type == "object")' \
    "$ROUTING_FILE" >/dev/null 2>&1 \
    || helm_fail_open "data/helm-project-map.json is not valid Helm routing JSON"
fi

# Discover every local home and build the combined debounce hash.
HOMES_TSV="$(fm_helm_discover_homes "$FM_HOME_PATH" "$SECONDMATES_PATH")" \
  || helm_fail_open "could not discover fleet homes"
BACKLOG_PATHS=()
HOME_PATHS=()
while IFS=$'\t' read -r home_id home_path; do
  [ -n "$home_path" ] || continue
  HOME_PATHS+=("$home_path")
  BACKLOG_PATHS+=("$home_path/data/backlog.md")
done <<EOF
$HOMES_TSV
EOF
[ "${#BACKLOG_PATHS[@]}" -gt 0 ] || helm_fail_open "no fleet home resolved"

BACKLOG_HASH=$(fm_helm_combined_hash "${BACKLOG_PATHS[@]}" "$ROUTING_FILE") \
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
BOARDS_DIR="$TMP_DIR/boards"
mkdir -p "$BOARDS_DIR" || helm_fail_open "could not create Helm board workspace"
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
ORG_GRAPHQL_QUERY='query($owner:String!, $number:Int!, $cursor:String) {
  organization(login:$owner) {
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

TOTAL_DEADLINE=

# read_board <owner> <number> <output>
# Read one board into the normalized shape consumed by the planner. User-owned
# boards use the first query; organization-owned boards use its fallback.
read_board() {
  local owner=$1 number=$2 output=$3 query=$GRAPHQL_QUERY page_count=0 cursor='' page_json remaining
  local -a gh_args
  while :; do
    page_count=$((page_count + 1))
    [ "$page_count" -le 50 ] || return 1
    page_json="$TMP_DIR/board-page-$BOARD_READ_SEQUENCE-$page_count.json"
    gh_args=(--field "query=$query" --field "owner=$owner" --field "number=$number")
    [ -z "$cursor" ] || gh_args+=(--field "cursor=$cursor")
    remaining=$(( TOTAL_DEADLINE - $(date +%s) ))
    [ "$remaining" -gt 0 ] || return 1
    run_gh_bounded "$remaining" gh api graphql "${gh_args[@]}" >"$page_json" 2>"$GH_ERROR" || return 1
    if jq -e '(.errors // []) | length > 0' "$page_json" >/dev/null 2>&1; then
      return 1
    fi
    if [ "$query" = "$ORG_GRAPHQL_QUERY" ]; then
      jq '.data.user.projectV2 = (.data.organization.projectV2 // null)' "$page_json" >"$page_json.normalized" \
        || return 1
      mv -f -- "$page_json.normalized" "$page_json" || return 1
    fi
    if ! jq -e '.data.user.projectV2.id and (.data.user.projectV2.fields.pageInfo.hasNextPage == false)' "$page_json" >/dev/null 2>&1; then
      if [ "$query" = "$GRAPHQL_QUERY" ]; then
        query=$ORG_GRAPHQL_QUERY
        page_count=0
        cursor=
        continue
      fi
      return 1
    fi
    if [ "$page_count" -eq 1 ]; then
      cp -- "$page_json" "$output" || return 1
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

# helm_graphql_call <field-args...> - the bounded `gh api graphql` call
# fm_helm_ensure_field_options uses to provision a missing Project option on
# the current board. Requires SYNC_DEADLINE to already be set for that board.
helm_graphql_call() {
  local remaining
  remaining=$(( SYNC_DEADLINE - $(date +%s) ))
  [ "$remaining" -gt 0 ] || return 1
  run_gh_bounded "$remaining" gh api graphql "$@"
}

# missing_project_options <board-json> <desired-json> - print the comma
# joined desired Project names this board's Project field has no option for.
missing_project_options() {
  jq -r --slurpfile records "$2" '
    ($records[0] | map(.desired.project) | unique) as $wanted
    | [.data.user.projectV2.fields.nodes[]? | select(.name == "Project" and .__typename == "ProjectV2SingleSelectField") | .options[]?.name] as $have
    | ($wanted - $have) | join(",")
  ' "$1"
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
# into that board's poll signature so the sync's own writes never read back as
# edits.
LANDED=
BOARD_JSON=
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

# publish_progress - republish the current board signature from the board as
# read plus its landed patches, and keep a stopped forced run forced on its
# next run.
publish_progress() {
  local signature board_key poll_tmp
  [ -n "$BOARD_JSON" ] && [ -n "$LANDED" ] || return 0
  signature=$(jq -r --rawfile landed "$LANDED" \
    "$(fm_helm_landed_patch_program) | $(fm_helm_board_signature_program)" "$BOARD_JSON" \
    | fm_helm_sha256_stdin) || return 1
  [ -n "$signature" ] || return 1
  board_key="$BOARD_OWNER/$BOARD_NUMBER"
  poll_tmp=$(mktemp "$TMP_DIR/poll.XXXXXX") || return 1
  awk -F '\t' -v k="$board_key" '$1 != k' "$POLL_WORK" >"$poll_tmp" || return 1
  printf '%s\t%s\n' "$board_key" "$signature" >>"$poll_tmp" || return 1
  mv -f -- "$poll_tmp" "$POLL_WORK" || return 1
  publish_file "$POLL_WORK" "$POLL_FILE" || return 1
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

# cache_remove_row <task-id> - remove one card identity after the board confirms
# it was deleted or intentionally suppressed.
cache_remove_row() {
  local task_id=$1 tmp
  tmp=$(mktemp "$TMP_DIR/cache.XXXXXX") || return 1
  awk -F '\t' -v t="$task_id" '$1 != t' "$CACHE_WORK" >"$tmp" || return 1
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
ROUTING_JSON="$TMP_DIR/routing.json"
if [ -f "$ROUTING_FILE" ]; then
  cp -- "$ROUTING_FILE" "$ROUTING_JSON" || helm_fail_open "could not stage Helm routing state"
else
  printf '%s\n' '{"version":1,"projects":{},"nudges":{}}' >"$ROUTING_JSON" \
    || helm_fail_open "could not stage Helm routing defaults"
fi
REGISTERED_PROJECTS=$(fm_helm_project_names "${HOME_PATHS[@]}" \
  | jq -Rsc 'split("\n") | map(select(length > 0))') \
  || helm_fail_open "could not read the project registry"

# A mapping key that no longer appears in any local registry is a broken
# boundary, not an instruction to silently route future cards to the default.
# Use the existing captain-hold primitive and persist its back-reference so the
# slower reconciliation check does not mint the same hold repeatedly.
ROUTING_DIRTY=0
while IFS= read -r orphan_project; do
  [ -n "$orphan_project" ] || continue
  orphan_hold=$(jq -r --arg p "$orphan_project" '.projects[$p].orphan_hold_task // empty' "$ROUTING_JSON")
  [ -n "$orphan_hold" ] && continue
  orphan_owner=$(jq -r --arg p "$orphan_project" '.projects[$p].owner // ""' "$ROUTING_JSON")
  orphan_number=$(jq -r --arg p "$orphan_project" '.projects[$p].number // 0' "$ROUTING_JSON")
  orphan_reason="local project '$orphan_project' no longer appears in the project registry (renamed or removed); its Helm routing to $orphan_owner/$orphan_number is orphaned - point the new project name at this board, send it to the Helm default, or confirm it should be dropped"
  orphan_hold=$(fm_helm_raise_mapping_orphan "$FM_HOME_PATH" "$orphan_project" "$orphan_reason" 2>/dev/null) \
    || continue
  jq --arg p "$orphan_project" --arg id "$orphan_hold" \
    '.projects[$p].orphan_hold_task = $id' "$ROUTING_JSON" >"$TMP_DIR/routing.next" \
    || helm_fail_open "could not record the orphaned Helm mapping for $orphan_project"
  mv -f -- "$TMP_DIR/routing.next" "$ROUTING_JSON"
  ROUTING_DIRTY=1
done < <(jq -r --argjson registered "$REGISTERED_PROJECTS" \
  '.projects // {} | to_entries[] as $e | select(($registered | index($e.key)) == null) | $e.key' "$ROUTING_JSON")
if [ "$ROUTING_DIRTY" -eq 1 ]; then
  publish_file "$ROUTING_JSON" "$ROUTING_FILE" \
    || helm_fail_open "could not publish Helm routing state"
fi
jq --slurpfile routing "$ROUTING_JSON" --argjson registered "$REGISTERED_PROJECTS" \
  --arg default_owner "$OWNER" --argjson default_number "$PROJECT_NUMBER" \
  --argjson report_ids "$REPORT_IDS" "$(fm_helm_desired_program)" "$BACKLOG_JSON" >"$DESIRED_JSON" \
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

BOARD_INDEX=0
BOARD_READ_SEQUENCE=0
BOARD_FAILURES=()
BOARDS_SUCCEEDED=0
BOARD_OWNER=
BOARD_NUMBER=
FAILED=0
REMAINING=0
EXHAUSTED=0
GUARD_CONFLICT=0
CONFLICT_WAKE=0

board_failure() {
  local key=$1 reason=$2
  local existing
  for existing in "${BOARD_FAILURES[@]}"; do
    [ "$existing" = "$key" ] && return 0
  done
  BOARD_FAILURES+=("$key")
  # Keep board-read failures fail-open. The final diagnostic is surfaced by
  # the watcher adapter, while a transient network failure must not create a
  # durable wake or partial baseline.
  : "$reason"
}

publish_board_failure_wakes() {
  local key
  [ "$BOARDS_SUCCEEDED" -gt 0 ] || return 0
  for key in "${BOARD_FAILURES[@]}"; do
    fm_wake_append check "helm-board-failure:$key" \
      "check: Helm board $key could not be reconciled; retry the board-specific sync" \
      || helm_fail_open "could not enqueue Helm board failure for $key"
  done
}

process_board() {
  local owner=$1 number=$2 key="$1/$2" board_file group_desired
  local board_now board_budget schema_ok missing_projects
  BOARD_WRITE_FAILURE=0
  BOARD_OWNER=$owner
  BOARD_NUMBER=$number
  BOARD_INDEX=$((BOARD_INDEX + 1))
  BOARD_READ_SEQUENCE=$((BOARD_READ_SEQUENCE + 1))
  board_file="$BOARDS_DIR/board-$BOARD_INDEX.json"
  BOARD_JSON=
  LANDED=
  if ! read_board "$owner" "$number" "$board_file"; then
    board_failure "$key" "GitHub project read failed"
    return 0
  fi
  BOARDS_SUCCEEDED=$((BOARDS_SUCCEEDED + 1))
  BOARD_JSON="$board_file"
  LANDED="$TMP_DIR/landed-$BOARD_INDEX.tsv"
  : >"$LANDED"
  board_now=$(date +%s)
  board_budget=$((board_now + SYNC_DEADLINE_SECONDS))
  [ "$board_budget" -le "$TOTAL_DEADLINE" ] || board_budget=$TOTAL_DEADLINE
  SYNC_DEADLINE=$board_budget
  PROJECT_ID=$(jq -r '.data.user.projectV2.id' "$BOARD_JSON")
  STATUS_FIELD_ID=$(field_id Status)
  PROJECT_FIELD_ID=$(field_id Project)
  KIND_FIELD_ID=$(field_id Kind)
  PRIORITY_FIELD_ID=$(field_id Priority)
  if [ -z "$STATUS_FIELD_ID" ] || [ -z "$PROJECT_FIELD_ID" ] || [ -z "$KIND_FIELD_ID" ] || [ -z "$PRIORITY_FIELD_ID" ]; then
    board_failure "$key" "required Helm fields are unavailable"
    publish_progress || helm_fail_open "could not publish Helm board acknowledgement"
    return 0
  fi
  DISPATCH_OPTION_ID=$(option_id Status "$DISPATCH_STATUS")
  group_desired="$TMP_DIR/desired-$BOARD_INDEX.json"
  jq --arg owner "$owner" --argjson number "$number" --arg retain_owner "$RETAIN_OWNER" --argjson retain_number "${RETAIN_NUMBER:-0}" --arg retain_project "$RETAIN_PROJECT" --rawfile cards "$CACHE_WORK" \
    '($cards | split("\n") | map(select(. != "") | split("\t"))
      | map(select(length >= 11 and .[9] == $owner and (.[10] | tonumber) == $number) | .[0])) as $historical
     | map(. as $record
           | select(($record.desired.board.owner == $owner and $record.desired.board.number == $number)
                   or ($retain_owner == $owner and $retain_number == $number and $record.desired.project == $retain_project)
                   or (($historical | index($record.id)) != null)))' \
    "$DESIRED_JSON" >"$group_desired" \
    || helm_fail_open "could not group desired Helm cards"
  # One jq pass computes both the base-schema verdict and any Project options
  # a registered-but-unmapped project's card needs (fm_helm_desired_program's
  # project_of puts its own name in the Project bucket, and the board's
  # Project field may not have that option yet) so the per-board hot path
  # stays a single jq call, same as before this check grew a second part.
  schema_ok=false missing_projects=
  IFS=$'\t' read -r schema_ok missing_projects < <(jq -r --argjson records "$(cat "$group_desired")" --arg dispatch "$DISPATCH_STATUS" '
    .data.user.projectV2.fields.nodes as $fields
    | (def has_option($field; $name): any($fields[]; .name == $field and .__typename == "ProjectV2SingleSelectField" and any(.options[]?; .name == $name));
       any($fields[]; .name == "Status" and .__typename == "ProjectV2SingleSelectField")
       and any($fields[]; .name == "Project" and .__typename == "ProjectV2SingleSelectField")
       and any($fields[]; .name == "Kind" and .__typename == "ProjectV2SingleSelectField")
       and any($fields[]; .name == "Priority" and .__typename == "ProjectV2SingleSelectField")
       and all((["Queued", "In flight", "Waiting on you", "Done", $dispatch] | unique)[]; has_option("Status"; .))
       and all(["P0", "P1", "P2", "P3", "P4"][]; has_option("Priority"; .))
       and all(["ship", "investigation", "decision"][]; has_option("Kind"; .))) as $ok
    | ([$fields[] | select(.name == "Project" and .__typename == "ProjectV2SingleSelectField") | .options[]?.name]) as $have
    | [$ok, (($records | map(.desired.project) | unique) - $have | join(","))] | @tsv
  ' "$BOARD_JSON" 2>/dev/null)
  if [ "$schema_ok" != true ]; then
    board_failure "$key" "required Helm fields or options are unavailable"
    publish_progress || helm_fail_open "could not publish Helm board acknowledgement"
    return 0
  fi
  if [ -n "$missing_projects" ]; then
    if ! fm_helm_ensure_field_options helm_graphql_call "$PROJECT_ID" Project "$missing_projects"; then
      board_failure "$key" "could not provision the Project field option for $missing_projects"
      publish_progress || helm_fail_open "could not publish Helm board acknowledgement"
      return 0
    fi
    BOARD_READ_SEQUENCE=$((BOARD_READ_SEQUENCE + 1))
    if ! read_board "$owner" "$number" "$board_file"; then
      board_failure "$key" "GitHub project re-read after provisioning failed"
      publish_progress || helm_fail_open "could not publish Helm board acknowledgement"
      return 0
    fi
    BOARD_JSON="$board_file"
    PROJECT_ID=$(jq -r '.data.user.projectV2.id' "$BOARD_JSON")
    STATUS_FIELD_ID=$(field_id Status)
    PROJECT_FIELD_ID=$(field_id Project)
    KIND_FIELD_ID=$(field_id Kind)
    PRIORITY_FIELD_ID=$(field_id Priority)
    DISPATCH_OPTION_ID=$(option_id Status "$DISPATCH_STATUS")
    if [ -n "$(missing_project_options "$BOARD_JSON" "$group_desired")" ]; then
      board_failure "$key" "Project field option for $missing_projects is still missing after provisioning"
      publish_progress || helm_fail_open "could not publish Helm board acknowledgement"
      return 0
    fi
  fi
  PLAN="$TMP_DIR/plan-$BOARD_INDEX.nul"
  jq -j --slurpfile desired "$group_desired" \
    --rawfile cards "$CACHE_WORK" --rawfile deleted "$OLD_DELETED" --rawfile markers "$OLD_MARKERS" \
    --rawfile divergences "$OLD_DIVERGENCES" \
    --rawfile fps "$FPS" \
    --arg force "$FORCE" --arg dispatch_status "$DISPATCH_STATUS" --arg now "$NOW_EPOCH" \
    --arg tsv_existed "$TSV_EXISTED" --arg retain_source "$( [ "$owner" = "$RETAIN_OWNER" ] && [ "$number" = "$RETAIN_NUMBER" ] && printf 1 || printf 0 )" --arg retain_project "$RETAIN_PROJECT" --arg board_owner "$owner" --argjson board_number "$number" \
    --arg default_owner "$OWNER" --argjson default_number "$PROJECT_NUMBER" \
    "$(fm_helm_plan_program)" "$BOARD_JSON" >"$PLAN" \
    || { board_failure "$key" "could not plan the board reconciliation"; publish_progress || helm_fail_open "could not publish Helm board acknowledgement"; return 0; }

# Execute the plan. Each entry is FM_HELM_PLAN_FIELDS NUL-terminated fields.
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
    board_failure "$key" "$action"
    publish_progress || helm_fail_open "could not publish Helm board acknowledgement"
    return 0
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
      cache_remove_row "$task_id" || helm_fail_open "could not remove the deleted Helm identity"
      apply_divergence_ops "$divergence_ops" || helm_fail_open "could not update Helm divergence memory"
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
      cache_remove_row "$task_id" || helm_fail_open "could not remove the retained Helm identity"
      continue
      ;;
    deleted:hold)
      backlog_hold_for_captain "$home_path" "$task_id" "$hold_reason" \
        || helm_fail_open "could not hold deleted Helm task $task_id"
      printf '%s\n' "$tombstone" >>"$NEW_DELETED"
      cache_remove_row "$task_id" || helm_fail_open "could not remove the deleted Helm identity"
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
    cache_publish_row "$task_id" "$cache_row" \
      || helm_fail_open "could not publish the Helm identity cache"
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
      BOARD_WRITE_FAILURE=1
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
    BOARD_WRITE_FAILURE=1
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
    cache_remove_row "$task_id" || helm_fail_open "could not remove the closed Helm identity"
    [ "$marker" != remove ] || marker_remove "$task_id" \
      || helm_fail_open "could not clear the Helm dispatch marker for $task_id"
    continue
  fi
  if [ "$action" = create ]; then
    cache_row=$complete_cache_row
  fi
  cache_publish_row "$task_id" "$cache_row" || helm_fail_open "could not publish the Helm identity cache"
done
exec 3<&-
publish_progress || helm_fail_open "could not publish Helm board acknowledgement"
if [ "$BOARD_WRITE_FAILURE" -eq 1 ]; then
  board_failure "$key" "one or more board writes failed"
fi
}

# Stable board order keeps the configured default responsive, then processes
# linked boards by owner and number. Old cache rows keep an empty desired group
# alive long enough to read the board that still owns their cards.
BOARD_KEYS_RAW="$TMP_DIR/board-keys.raw"
BOARD_KEYS_FILE="$TMP_DIR/board-keys.tsv"
{
  if [ -n "$RETAIN_OWNER" ]; then
    printf '%s\t%s\n' "$RETAIN_OWNER" "$RETAIN_NUMBER"
  fi
  printf '%s\t%s\n' "$OWNER" "$PROJECT_NUMBER"
  jq -r '.[] | [.desired.board.owner, (.desired.board.number | tostring)] | @tsv' "$DESIRED_JSON"
  awk -F '\t' -v owner="$OWNER" -v number="$PROJECT_NUMBER" \
    'NF >= 11 && $10 != "" && $11 != "" { print $10 "\t" $11 }' "$OLD_CARDS"
} | awk -F '\t' '!seen[$1 SUBSEP $2]++' >"$BOARD_KEYS_RAW" \
  || helm_fail_open "could not build the Helm board groups"
{
  awk -F '\t' -v owner="$RETAIN_OWNER" -v number="$RETAIN_NUMBER" '$1 == owner && $2 == number' "$BOARD_KEYS_RAW"
  awk -F '\t' -v owner="$RETAIN_OWNER" -v number="$RETAIN_NUMBER" -v default_owner="$OWNER" -v default_number="$PROJECT_NUMBER" '$1 == default_owner && $2 == default_number && !($1 == owner && $2 == number)' "$BOARD_KEYS_RAW"
  awk -F '\t' -v owner="$RETAIN_OWNER" -v number="$RETAIN_NUMBER" -v default_owner="$OWNER" -v default_number="$PROJECT_NUMBER" '!($1 == owner && $2 == number) && !($1 == default_owner && $2 == default_number) { print }' "$BOARD_KEYS_RAW" \
    | sort -t $'\t' -k1,1 -k2,2n
} >"$BOARD_KEYS_FILE" || helm_fail_open "could not order the Helm board groups"
BOARD_COUNT=$(wc -l <"$BOARD_KEYS_FILE")
TOTAL_BUDGET=$((SYNC_DEADLINE_SECONDS * BOARD_COUNT))
[ "$TOTAL_BUDGET" -le "$TOTAL_DEADLINE_SECONDS" ] || TOTAL_BUDGET=$TOTAL_DEADLINE_SECONDS
TOTAL_DEADLINE=$(( $(date +%s) + TOTAL_BUDGET ))

while IFS=$'\t' read -r board_owner board_number; do
  [ -n "$board_owner" ] && [ -n "$board_number" ] || continue
  process_board "$board_owner" "$board_number"
done <"$BOARD_KEYS_FILE"

publish_board_failure_wakes

if [ "$CONFLICT_WAKE" -eq 1 ]; then
  printf 'check: Helm board and backlog both changed; reconcile the affected card(s)\n'
  exit 0
fi

if [ "$GUARD_CONFLICT" -eq 1 ]; then
  printf 'check: Helm board and backlog both changed; run bin/fm-helm-sync.sh --force to reconcile\n'
  exit 0
fi
if [ "${#BOARD_FAILURES[@]}" -gt 0 ]; then
board_failure_list=$(IFS=', '; printf '%s' "${BOARD_FAILURES[*]}")
  printf 'fm-helm-sync: %s board(s) could not be reconciled: %s\n' "${#BOARD_FAILURES[@]}" "$board_failure_list"
fi
if [ $((FAILED + REMAINING)) -gt 0 ]; then
  printf 'fm-helm-sync: partial: %s cards remain\n' $((FAILED + REMAINING))
  exit 0
fi
if [ "${#BOARD_FAILURES[@]}" -gt 0 ]; then
  exit 0
fi

# A complete run: publish the whole refreshed identity cache, the deletion
# tombstones, the debounce hash, and the poll signature.
if [ -s "$CACHE_WORK" ] || [ "$TSV_EXISTED" = true ]; then
  jq -r '.[].id' "$BACKLOG_JSON" >"$TMP_DIR/backlog-ids" \
    || helm_fail_open "could not stage the Helm task identities"
  awk -F '\t' 'NR == FNR { ids[$1] = 1; next } ids[$1]' \
    "$TMP_DIR/backlog-ids" "$CACHE_WORK" | sort -u >"$TMP_DIR/cards.sorted" \
    || helm_fail_open "could not stage the Helm identity cache"
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
rm -f -- "$RESUME_FILE"

printf 'fm-helm-sync: synchronized\n'
