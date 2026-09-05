#!/usr/bin/env bash
# fm-helm-sync.sh - reconcile the optional Helm GitHub Project board.
#
# The local config/helm.json file is the opt-in.  When it is absent this script
# exits silently before reading the backlog, touching state, or making a network
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
# data/backlog.md is authoritative for task content: title, body, kind, repo,
# priority, and lifecycle section.  The board is authoritative only for the
# captain's dispatch request.  A card in the configured dispatch status while
# its backlog task is not yet In flight is a request for ordinary firstmate
# intake, never an instruction for this script to spawn a worker.
#
# This implementation reuses the existing "In flight" Status option by default
# as the dispatch request.  Set dispatch_status in config/helm.json if the
# board uses another option.  The same unhandled request is deduplicated by a
# durable marker and by the existing wake queue key.
#
# The normal Stop-hook path debounces all GitHub work on the SHA-256 hash of
# data/backlog.md.  Use --force for an explicit board read when the captain has
# edited a card without changing the backlog; --force still never calls
# bin/fm-spawn.sh and never deletes a card.
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
CONFIG_FILE="$CONFIG_PATH/helm.json"
HASH_FILE="$STATE_PATH/.helm-sync-backlog.sha256"
DISPATCH_FILE="$STATE_PATH/.helm-dispatch-requests"
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

if [ -L "$HASH_FILE" ] || [ -L "$DISPATCH_FILE" ]; then
  helm_fail_open "refusing symlinked Helm state"
fi

CONFIG_JSON=$(sed -E '/^[[:space:]]*(\/\/|#)/d' "$CONFIG_FILE") \
  || helm_fail_open "could not read config/helm.json"
OWNER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.owner | strings | select(length > 0)' 2>/dev/null) \
  || helm_fail_open "config/helm.json has no valid owner"
PROJECT_NUMBER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.number | numbers | select(. > 0)' 2>/dev/null) \
  || helm_fail_open "config/helm.json has no valid project number"
DISPATCH_STATUS=$(printf '%s\n' "$CONFIG_JSON" | jq -r '.dispatch_status // "In flight"' 2>/dev/null) \
  || helm_fail_open "config/helm.json is not valid JSON"
[ -n "$DISPATCH_STATUS" ] || helm_fail_open "config/helm.json has an empty dispatch_status"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

BACKLOG_HASH=$(sha256_file "$BACKLOG_PATH") \
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
GRAPHQL_QUERY='query($owner:String!, $number:Int!) {
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
      items(first:100) {
        pageInfo { hasNextPage }
        nodes {
          id
          content {
            __typename
            ... on DraftIssue { id title body }
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

if ! gh api graphql \
  --field "query=$GRAPHQL_QUERY" \
  --field "owner=$OWNER" \
  --field "number=$PROJECT_NUMBER" \
  >"$BOARD_JSON" 2>"$GH_ERROR"; then
  helm_fail_open "GitHub project read failed"
fi
if jq -e '(.errors // []) | length > 0' "$BOARD_JSON" >/dev/null 2>&1; then
  helm_fail_open "GitHub project read returned an error"
fi
if ! jq -e '.data.user.projectV2.id and (.data.user.projectV2.fields.pageInfo.hasNextPage == false) and (.data.user.projectV2.items.pageInfo.hasNextPage == false)' "$BOARD_JSON" >/dev/null 2>&1; then
  helm_fail_open "GitHub project was not found or exceeded the safe page bound"
fi

BACKLOG_JSON="$TMP_DIR/backlog.json"
if ! jq -Rn '
  def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
  def section_state:
    if . == "In flight" then "in_flight"
    elif . == "Queued" then "queued"
    elif . == "Done" then "done"
    else null end;
  def cap($rest; $re):
    (((($rest | capture($re)?) // {}) | .v) // null) as $v
    | if $v == null then null else ($v | trim) end;
  def metadata($rest; $key):
    cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
  def metadata_word($rest; $key):
    cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":?[[:space:]]+(?<v>[^,)]*)");
  def url_pattern: "https?://[^[:space:])\"<>]+";
  def strip_trailing_metadata:
    reduce range(0; 20) as $_ (.;
      sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind|hold-until):[[:space:]]*[^)]*|(?:since|merged|reported|done):?[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
  def strip_title_artifacts:
    sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
    | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
    | sub("[[:space:]]+-[[:space:]]+local main$"; "")
    | sub("[[:space:]]+local main$"; "")
    | sub("[[:space:]]+-[[:space:]]*$"; "");
  def clean_title:
    strip_trailing_metadata
    | strip_title_artifacts
    | gsub("[[:space:]]+"; " ")
    | trim;
  def title_of($rest):
    $rest
    | gsub("https?://[^[:space:])\"<>]+"; "")
    | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
    | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
    | clean_title;
  def blocked_by_ids($rest):
    [$rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0]]
    | reduce .[] as $id ([]; if index($id) == null then . + [$id] else . end);
  def row_match($line):
    ($line | (capture("^-[[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")? // null));
  reduce inputs as $line
    ({section:null, records:[], order:0};
     if ($line | test("^##[[:space:]]+")) then
       .section = (($line | sub("^##[[:space:]]+"; "") | trim) | section_state)
     elif .section == null or ($line | trim) == "" then
       .
     elif (row_match($line) != null) then
       (row_match($line)) as $m
       | .order += 1
       | .records += [{order:.order, state:.section, structured:true,
           id:($m.id | trim), checked:($m.check | test("[xX]")),
           title:title_of($m.rest), repo:metadata($m.rest; "repo"),
           kind:metadata($m.rest; "kind"), priority:metadata($m.rest; "priority"),
           hold_reason:metadata($m.rest; "hold"), hold_kind:metadata($m.rest; "hold-kind"),
           since:metadata_word($m.rest; "since"), merged:metadata_word($m.rest; "merged"),
           reported:metadata_word($m.rest; "reported"), done:metadata_word($m.rest; "done"),
           blocked_by_ids:blocked_by_ids($m.rest),
           pr_url:(([$m.rest | scan(url_pattern)] | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
           report_path:cap($m.rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
           body_lines:[]}]
     elif ($line | test("^[[:space:]]+")) and (.records | length) > 0 and .records[-1].structured then
       ($line | trim) as $body
       | if $body == "" then . else .records[-1].body_lines += [$body] end
     else
       .order += 1 | .records += [{order:.order, state:.section,
         structured:false, raw:$line}]
     end)
  | .records
' <"$BACKLOG_PATH" >"$BACKLOG_JSON"; then
  helm_fail_open "data/backlog.md could not be parsed"
fi
if ! jq -e 'all(.[]; .structured == true and (.id | test("^[A-Za-z0-9._-]+$")) and (.title | length > 0))' "$BACKLOG_JSON" >/dev/null 2>&1; then
  helm_fail_open "data/backlog.md contains an unstructured or invalid task row"
fi
if ! jq -e 'map(.id) | group_by(.) | all(length == 1)' "$BACKLOG_JSON" >/dev/null 2>&1; then
  helm_fail_open "data/backlog.md contains duplicate task ids"
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

record_kind() {
  case "$(jq -r '.kind // "ship"' <<<"$1")" in
    ship) printf '%s\n' ship ;;
    captain) printf '%s\n' decision ;;
    task|scout) printf '%s\n' investigation ;;
    *) return 1 ;;
  esac
}

record_project() {
  local repo
  repo=$(jq -r '.repo // ""' <<<"$1")
  case "$repo" in
    firetabs|geojitsu/firetabs) printf '%s\n' firetabs ;;
    BetterBlueToo|geojitsu/BetterBlueToo) printf '%s\n' BetterBlueToo ;;
    firstmate|geojitsu/firstmate) printf '%s\n' firstmate ;;
    *) printf '%s\n' other ;;
  esac
}

record_status() {
  local record=$1 section kind
  section=$(jq -r '.state' <<<"$record")
  kind=$(jq -r '.kind // "ship"' <<<"$record")
  if [ "$section" = "done" ]; then
    printf '%s\n' Done
  elif [ "$kind" = captain ]; then
    printf '%s\n' "Waiting on you"
  elif [ "$section" = in_flight ]; then
    printf '%s\n' "In flight"
  else
    printf '%s\n' Queued
  fi
}

write_card_body() {
  local record=$1 output=$2 id kind type repo priority filed hold blocked report pr line
  id=$(jq -r '.id' <<<"$record")
  kind=$(record_kind "$record") || return 1
  case "$kind" in
    ship) type='ship - produces a change and a PR' ;;
    investigation) type='investigation - produces knowledge, not code' ;;
    decision) type='decision - needs your call before anything moves' ;;
  esac
  repo=$(jq -r '.repo // "-"' <<<"$record")
  [ -n "$repo" ] || repo=-
  priority=$(jq -r '.priority // "3"' <<<"$record")
  case "$priority" in 1) priority=P1 ;; 2) priority=P2 ;; *) priority=P3 ;; esac
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
    printf '%b\n' "\n---\n_Source of truth: \`data/backlog.md\` in the firstmate home._\n"
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

record_count=$(jq 'length' "$BACKLOG_JSON")

while IFS= read -r record; do
  task_id=$(jq -r '.id' <<<"$record")
  title=$(jq -r '.title' <<<"$record")
  desired_project=$(record_project "$record")
  desired_kind=$(record_kind "$record") || helm_fail_open "unsupported kind for $task_id"
  desired_status=$(record_status "$record")
  case "$desired_project" in
    firetabs|BetterBlueToo|firstmate|other) ;;
    *) helm_fail_open "unsupported project for $task_id" ;;
  esac
  desired_priority=$(jq -r '.priority // "3"' <<<"$record")
  case "$desired_priority" in 1) desired_priority=P1 ;; 2) desired_priority=P2 ;; *) desired_priority=P3 ;; esac
  desired_project_option=$(option_id Project "$desired_project")
  desired_kind_option=$(option_id Kind "$desired_kind")
  desired_priority_option=$(option_id Priority "$desired_priority")
  [ -n "$desired_project_option" ] && [ -n "$desired_kind_option" ] && [ -n "$desired_priority_option" ] \
    || helm_fail_open "required Helm option is unavailable for $task_id"

  card=$(jq -c --arg id "$task_id" '
    [.data.user.projectV2.items.nodes[]
     | select(.content.__typename == "DraftIssue")
     | select((.content.body // "") | split("\n")[0] == ("`" + $id + "`"))] as $cards
    | if ($cards | length) == 1 then $cards[0]
      elif ($cards | length) == 0 then null
      else error("duplicate Helm cards") end
  ' "$BOARD_JSON") || helm_fail_open "duplicate Helm cards for $task_id"

  if [ "$card" = null ]; then
    body_file="$TMP_DIR/$task_id.body"
    write_card_body "$record" "$body_file" || helm_fail_open "could not build the card body for $task_id"
    body=$(cat "$body_file")
    item_id=$(create_draft "$title" "$body") || helm_fail_open "could not create the Helm card for $task_id"
    [ -n "$item_id" ] || helm_fail_open "GitHub did not return the new Helm card for $task_id"
    card=$(jq -nc --arg id "$item_id" '{id:$id, content:{id:"", title:"", body:""}, fieldValues:{nodes:[]}}')
  else
    item_id=$(jq -r '.id' <<<"$card")
    body_file="$TMP_DIR/$task_id.body"
    write_card_body "$record" "$body_file" || helm_fail_open "could not build the card body for $task_id"
    body=$(cat "$body_file")
    draft_id=$(jq -r '.content.id // empty' <<<"$card")
    current_title=$(jq -r '.content.title // empty' <<<"$card")
    current_body=$(jq -r '.content.body // empty' <<<"$card")
    if [ "$current_title" != "$title" ] || [ "$current_body" != "$body" ]; then
      [ -n "$draft_id" ] || helm_fail_open "Helm card $task_id has no draft issue id"
      update_draft "$draft_id" "$title" "$body" \
        || helm_fail_open "could not update the Helm card content for $task_id"
    fi
  fi

  current_status=$(current_option_name "$card" Status)
  current_status_id=$(current_option_id "$card" Status)
  dispatch_request=false
  if [ "$current_status_id" = "$DISPATCH_OPTION_ID" ] \
    && [ "$desired_status" != "$DISPATCH_STATUS" ] \
    && [ "$desired_status" != Done ]; then
    dispatch_request=true
    queue_dispatch_request "$task_id" "$item_id" \
      || helm_fail_open "could not enqueue the Helm dispatch request for $task_id"
  else
    marker_remove "$task_id" || helm_fail_open "could not clear the Helm dispatch marker for $task_id"
  fi
  if [ "$dispatch_request" = false ] && [ "$current_status" != "$desired_status" ]; then
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
  [ "$current_priority_id" = "$desired_priority_option" ] || \
    update_single_select "$item_id" "$PRIORITY_FIELD_ID" "$desired_priority_option" \
      || helm_fail_open "could not update Helm Priority for $task_id"
done < <(jq -c '.[]' "$BACKLOG_JSON")

if [ "$record_count" -gt 0 ]; then
  while IFS= read -r card; do
    item_id=$(jq -r '.id' <<<"$card")
    # shellcheck disable=SC2016 # Backticks are literal Markdown delimiters.
    task_id=$(jq -r '.content.body // ""' <<<"$card" | sed -n 's/^`\([^`][^`]*\)`$/\1/p')
    [ -n "$task_id" ] || continue
    record=$(record_for_id "$task_id")
    [ "$record" != null ] && continue
    current_status_id=$(current_option_id "$card" Status)
    [ "$current_status_id" = "$STATUS_DONE_ID" ] && continue
    update_single_select "$item_id" "$STATUS_FIELD_ID" "$STATUS_DONE_ID" \
      || helm_fail_open "could not close the missing Helm task $task_id"
    marker_remove "$task_id" || helm_fail_open "could not clear the Helm dispatch marker for $task_id"
  done < <(jq -c '.data.user.projectV2.items.nodes[] | select(.content.__typename == "DraftIssue")' "$BOARD_JSON")
fi

HASH_TMP=$(mktemp "$TMP_DIR/hash.XXXXXX") || helm_fail_open "could not stage Helm sync state"
printf '%s\n' "$BACKLOG_HASH" >"$HASH_TMP" || helm_fail_open "could not write Helm sync state"
chmod 0600 "$HASH_TMP" || helm_fail_open "could not protect Helm sync state"
mv -f -- "$HASH_TMP" "$HASH_FILE" || helm_fail_open "could not publish Helm sync state"
printf 'fm-helm-sync: synchronized\n'
