#!/usr/bin/env bash
# fm-helm-project-map.sh - manage per-project Helm board routing.
#
# Usage:
#   bin/fm-helm-project-map.sh list [--counts]
#   bin/fm-helm-project-map.sh link <local-project> [<title>] [--owner <login>] [--existing <owner>/<number>]
#   bin/fm-helm-project-map.sh move <local-project> [<title>] [--owner <login>] [--existing <owner>/<number>] [--default] [--yes]
#   bin/fm-helm-project-map.sh unlink <local-project>
#   bin/fm-helm-project-map.sh sync
#
# The main home's data/helm-project-map.json is the durable routing document.
# Board creation, lookup, and card relocation use gh-axi; ordinary card sync
# remains owned by fm-helm-sync.sh. A move records each add/create and delete
# boundary in state/helm-moves.tsv so an interrupted move resumes safely.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT_PATH="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_PATH="${FM_HOME:-$FM_ROOT_PATH}"
CONFIG_PATH="${FM_CONFIG_OVERRIDE:-$FM_HOME_PATH/config}"
DATA_PATH="${FM_DATA_OVERRIDE:-$FM_HOME_PATH/data}"
STATE_PATH="${FM_STATE_OVERRIDE:-$FM_HOME_PATH/state}"
CONFIG_FILE="$CONFIG_PATH/helm.json"
MAP_FILE="$DATA_PATH/helm-project-map.json"
CARDS_FILE="$STATE_PATH/helm-cards.tsv"
MOVES_FILE="$STATE_PATH/helm-moves.tsv"
LOCK_FILE="$STATE_PATH/.helm-sync.lock"
TMP_DIR=
LOCK_HELD=0
MOVE_TASKS=

map_cleanup() {
  local status=$?
  if [ "$LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$LOCK_FILE" 2>/dev/null || true
  fi
  [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"
  exit "$status"
}
trap map_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'fm-helm-project-map: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d'
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v gh-axi >/dev/null 2>&1 || fail "gh-axi is required"
[ -d "$DATA_PATH" ] && [ ! -L "$DATA_PATH" ] || fail "data directory is unavailable"
[ -d "$STATE_PATH" ] && [ ! -L "$STATE_PATH" ] || fail "state directory is unavailable"
[ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || fail "Helm is not configured (config/helm.json is absent)"

# shellcheck source=bin/fm-helm-lib.sh
. "$SCRIPT_DIR/fm-helm-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CONFIG_JSON=$(sed -E '/^[[:space:]]*(\/\/|#)/d' "$CONFIG_FILE") \
  || fail "could not read config/helm.json"
DEFAULT_OWNER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.owner | strings | select(length > 0)' 2>/dev/null) \
  || fail "config/helm.json has no owner"
DEFAULT_NUMBER=$(printf '%s\n' "$CONFIG_JSON" | jq -er '.number | numbers | select(. > 0)' 2>/dev/null) \
  || fail "config/helm.json has no number"

HOMES_TSV=$(fm_helm_discover_homes "$FM_HOME_PATH" "$DATA_PATH/secondmates.md" 2>/dev/null) \
  || fail "could not discover fleet homes"
HOME_PATHS=()
while IFS=$'\t' read -r _home_id home_path; do
  [ -n "$home_path" ] || continue
  HOME_PATHS+=("$home_path")
done <<EOF
$HOMES_TSV
EOF

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-helm-project-map.XXXXXX") \
  || fail "could not create temporary workspace"

map_load() {
  if [ -f "$MAP_FILE" ]; then
    [ ! -L "$MAP_FILE" ] || fail "refusing symlinked Helm routing state"
    jq -e '.version == 1 and ((.projects // {}) | type == "object") and ((.nudges // {}) | type == "object")' \
      "$MAP_FILE" >/dev/null 2>&1 || fail "data/helm-project-map.json is invalid"
    cp -- "$MAP_FILE" "$TMP_DIR/map.json" || fail "could not stage Helm routing state"
  else
    printf '%s\n' '{"version":1,"projects":{},"nudges":{}}' >"$TMP_DIR/map.json"
  fi
}

map_publish() {
  local tmp
  tmp=$(mktemp "$DATA_PATH/.helm-project-map.XXXXXX") || return 1
  chmod 0600 "$tmp" || return 1
  jq -S . "$TMP_DIR/map.json" >"$tmp" || return 1
  chmod 0600 "$tmp" && mv -f -- "$tmp" "$MAP_FILE"
}

project_registered() {
  local project=$1
  fm_helm_project_names "${HOME_PATHS[@]}" | awk -v p="$project" '$0 == p { found=1 } END { exit(found ? 0 : 1) }'
}

map_entry() {
  jq -c --arg p "$1" '.projects[$p] // null' "$TMP_DIR/map.json"
}

parse_board_ref() {
  local ref=$1
  case "$ref" in
    */*[!0-9]) return 1 ;;
    */*) BOARD_OWNER=${ref%/*}; BOARD_NUMBER=${ref##*/} ;;
    *) return 1 ;;
  esac
  [ -n "$BOARD_OWNER" ] && [ "$BOARD_NUMBER" -gt 0 ] 2>/dev/null
}

BOARD_OWNER=
BOARD_NUMBER=
BOARD_TITLE=
BOARD_URL=
BOARD_ID=
BOARD_OUTPUT=
PROJECT_SCHEMA_OPTION=other

board_view() {
  local owner=$1 number=$2 line
  BOARD_OUTPUT=$(gh-axi project view "$number" --owner "$owner" 2>&1) \
    || return 1
  BOARD_OWNER=$owner
  BOARD_NUMBER=$number
  BOARD_TITLE=$(printf '%s\n' "$BOARD_OUTPUT" | sed -n 's/^title: //p' | head -1 | sed 's/^"//; s/"$//')
  BOARD_URL=$(printf '%s\n' "$BOARD_OUTPUT" | sed -n 's/^url: //p' | head -1 | sed 's/^"//; s/"$//')
  BOARD_ID=$(printf '%s\n' "$BOARD_OUTPUT" | sed -n 's/^id: //p' | head -1)
  [ -n "$BOARD_ID" ] || return 1
  [ -n "$BOARD_TITLE" ] || BOARD_TITLE="$owner/$number"
  for line in "$BOARD_ID" "$BOARD_TITLE"; do [ -n "$line" ] || return 1; done
}

find_project_number() {
  local owner=$1 title=$2 listing
  listing=$(gh-axi project list --owner "$owner" --limit 1000 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v wanted="$title" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*[0-9]+,/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      n = line; sub(/,.*/, "", n)
      rest = line; sub(/^[^,]*,/, "", rest)
      if (substr(rest, 1, 1) == "\"") {
        sub(/^"/, "", rest); comma = index(rest, "\",")
        title = comma ? substr(rest, 1, comma - 1) : rest
      } else {
        comma = index(rest, ","); title = comma ? substr(rest, 1, comma - 1) : rest
      }
      if (trim(title) == wanted) print n
    }'
}

create_or_reuse_board() {  # <owner> <title> [existing-owner/number]
  local owner=$1 title=$2 existing=${3:-} number matches create_output
  if [ -n "$existing" ]; then
    parse_board_ref "$existing" || fail "invalid --existing board: $existing"
    board_view "$BOARD_OWNER" "$BOARD_NUMBER" \
      || fail "GitHub Project $existing does not resolve"
    return 0
  fi
  matches=$(find_project_number "$owner" "$title" || true)
  case "$matches" in
    *$'\n'*) fail "more than one GitHub Project named '$title'; use --existing OWNER/NUMBER" ;;
    '')
      create_output=$(gh-axi project create --owner "$owner" --title "$title" 2>&1) \
        || fail "could not create GitHub Project '$title' for $owner"
      number=$(printf '%s\n' "$create_output" | sed -n 's/.*\b\([0-9][0-9]*\)\b.*/\1/p' | tail -1)
      [ -n "$number" ] || number=$(find_project_number "$owner" "$title" || true)
      [ -n "$number" ] || fail "created GitHub Project '$title' but could not resolve its number"
      board_view "$owner" "$number" || fail "created GitHub Project $owner/$number does not resolve"
      ;;
    *) board_view "$owner" "$matches" || fail "GitHub Project $owner/$matches does not resolve" ;;
  esac
}

field_has_options() {  # <field-list> <field-name> <comma-separated-options>
  local listing=$1 field=$2 options=$3 option
  printf '%s\n' "$listing" | awk -v wanted="$field" '
    $1 == "name:" && substr($0, index($0, $2)) == wanted { found = 1 }
    END { exit(found ? 0 : 1) }' >/dev/null
  while IFS= read -r option; do
    [ -n "$option" ] || continue
    printf '%s\n' "$listing" | awk -v wanted="$field" -v option="$option" '
      $1 == "name:" { found = (substr($0, index($0, $2)) == wanted) }
      found && $1 == "options:" { value = $0; if (index(value, option ":") > 0) ok=1; found=0 }
      END { exit(ok ? 0 : 1) }' || return 1
  done < <(printf '%s' "$options" | tr ',' '\n')
}

ensure_schema() {
  local listing field options query option
  listing=$(gh-axi project field-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --limit 100 2>&1) \
    || fail "could not read Helm fields from $BOARD_OWNER/$BOARD_NUMBER"
  while IFS='|' read -r field options; do
    field_has_options "$listing" "$field" "$options" && continue
    if printf '%s\n' "$listing" | awk -v wanted="$field" '$1 == "name:" && substr($0, index($0, $2)) == wanted { found=1 } END { exit(found ? 0 : 1) }'; then
      fail "GitHub Project $BOARD_OWNER/$BOARD_NUMBER has an incomplete $field field; add the missing options before linking"
    fi
    [ -n "$BOARD_ID" ] || fail "GitHub Project $BOARD_OWNER/$BOARD_NUMBER has no id"
    # shellcheck disable=SC2016 # GraphQL variables must remain literal.
    query='mutation($projectId:ID!,$name:String!,$options:[String!]!){createProjectV2Field(input:{projectId:$projectId,dataType:SINGLE_SELECT,name:$name,singleSelectOptions:$options}){projectV2Field{id}}}'
    set --
    while IFS= read -r option; do
      [ -n "$option" ] || continue
      set -- "$@" --field "options[]=$option"
    done < <(printf '%s' "$options" | tr ',' '\n')
    gh-axi api graphql --field "query=$query" --field "projectId=$BOARD_ID" --field "name=$field" "$@" >/dev/null 2>&1 \
      || fail "could not create Helm field $field on $BOARD_OWNER/$BOARD_NUMBER"
    listing=$(gh-axi project field-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --limit 100 2>&1) \
      || fail "could not verify Helm field $field on $BOARD_OWNER/$BOARD_NUMBER"
    field_has_options "$listing" "$field" "$options" \
      || fail "Helm field $field on $BOARD_OWNER/$BOARD_NUMBER is still incomplete"
  done < <(
    printf '%s\n' \
      'Status|Queued,In flight,Waiting on you,Done' \
      'Priority|P0,P1,P2,P3,P4' \
      'Kind|ship,investigation,decision'
    printf 'Project|other,%s\n' "$PROJECT_SCHEMA_OPTION"
  )
}

map_link() {
  local project=$1 title=${2:-} owner=$DEFAULT_OWNER existing='' now
  [ -n "$project" ] || fail "link requires a local project name"
  project_registered "$project" || fail "local project '$project' is not registered in data/projects.md"
  [ -n "$title" ] || title="$project"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --owner) shift; [ "$#" -gt 0 ] || fail "--owner needs a login"; owner=$1 ;;
      --existing) shift; [ "$#" -gt 0 ] || fail "--existing needs OWNER/NUMBER"; existing=$1 ;;
      *) fail "unknown link argument: $1" ;;
    esac
    shift
  done
  PROJECT_SCHEMA_OPTION=$project
  create_or_reuse_board "$owner" "$title" "$existing"
  ensure_schema
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg p "$project" --arg owner "$BOARD_OWNER" --argjson number "$BOARD_NUMBER" \
    --arg title "$BOARD_TITLE" --arg url "$BOARD_URL" --arg now "$now" \
    '.projects[$p] = {owner:$owner,number:$number,title:$title,url:$url,state:"active",linked_at:$now,move:null,orphan_hold_task:null} | .nudges |= del(.[$p])' \
    "$TMP_DIR/map.json" >"$TMP_DIR/map.next" || fail "could not prepare the Helm routing entry"
  mv -f -- "$TMP_DIR/map.next" "$TMP_DIR/map.json"
  map_publish || fail "could not publish data/helm-project-map.json"
  printf 'linked: %s -> %s/%s "%s"\n' "$project" "$BOARD_OWNER" "$BOARD_NUMBER" "$BOARD_TITLE"
  printf 'link changes future cards only; use move %s --existing %s/%s --yes to relocate existing cards.\n' \
    "$project" "$BOARD_OWNER" "$BOARD_NUMBER"
  "$SCRIPT_DIR/fm-helm-sync.sh" || true
}

backlog_task_ids() {  # <project> <output-file>
  local project=$1 output=$2 home_id home backlog_out
  : >"$output"
  while IFS=$'\t' read -r home_id home; do
    backlog_out="$TMP_DIR/backlog-${home_id}.json"
    fm_helm_parse_home_backlog "$home_id" "$home/data/backlog.md" "$backlog_out" 2>/dev/null \
      || fail "could not parse $home/data/backlog.md"
    jq -r --arg p "$project" '.[] | select((.repo // "") == $p or (((.repo // "") | split("/"))[-1] == $p)) | .id' "$backlog_out" >>"$output" \
      || fail "could not find Helm tasks for $project"
  done <<EOF
$HOMES_TSV
EOF
  sort -u -o "$output" "$output"
}

move_ledger_publish() {
  local tmp=$TMP_DIR/moves.next
  cp -- "$TMP_DIR/moves.tsv" "$tmp" || return 1
  chmod 0600 "$tmp" || return 1
  mv -f -- "$tmp" "$MOVES_FILE"
}

move_ledger_update() {  # <task> <new-line>
  local task=$1 newline=$2 tmp
  tmp=$(mktemp "$TMP_DIR/moves.XXXXXX") || return 1
  awk -F '\t' -v t="$task" '$1 != t' "$TMP_DIR/moves.tsv" >"$tmp" || return 1
  printf '%s\n' "$newline" >>"$tmp" || return 1
  sort -t $'\t' -k1,1 "$tmp" >"$TMP_DIR/moves.sorted" || return 1
  mv -f -- "$TMP_DIR/moves.sorted" "$TMP_DIR/moves.tsv"
  move_ledger_publish
}

move_card_add() {  # <type> <content-node> <title> <body>
  local type=$1 content=$2 title=$3 body=$4 query response
  if [ "$type" = issue ]; then
    # shellcheck disable=SC2016 # GraphQL variables must remain literal.
    query='mutation($projectId:ID!,$contentId:ID!){addProjectV2ItemById(input:{projectId:$projectId,contentId:$contentId}){item{id}}}'
    response=$(gh-axi api graphql --field "query=$query" --field "projectId=$BOARD_ID" --field "contentId=$content" 2>/dev/null) \
      || return 1
    printf '%s\n' "$response" | jq -er '.data.addProjectV2ItemById.item.id' 2>/dev/null
  else
    # shellcheck disable=SC2016 # GraphQL variables must remain literal.
    query='mutation($projectId:ID!,$title:String!,$body:String!){addProjectV2DraftIssue(input:{projectId:$projectId,title:$title,body:$body}){projectItem{id}}}'
    response=$(gh-axi api graphql --field "query=$query" --field "projectId=$BOARD_ID" --field "title=$title" --field "body=$body" 2>/dev/null) \
      || return 1
    printf '%s\n' "$response" | jq -er '.data.addProjectV2DraftIssue.projectItem.id' 2>/dev/null
  fi
}

move_card_delete() {  # <owner> <number> <item-id>
  gh-axi project item-delete "$2" --owner "$1" --id "$3" >/dev/null 2>&1
}

# move_card_read_source <source-item-id> reads the current source content
# before a draft move. The identity cache is a routing index, not a board
# snapshot, so captain edits must travel with the card when it is relocated.
move_card_read_source() {
  local source_item=$1 source_json query
  # shellcheck disable=SC2016 # GraphQL variables must remain literal.
  query='query($itemId:ID!){node(id:$itemId){... on ProjectV2Item {content {__typename ... on DraftIssue {title body} ... on Issue {title body}}}}}'
  source_json=$(gh-axi api graphql --field "query=$query" --field "itemId=$source_item" 2>/dev/null) \
    || return 1
  MOVE_SOURCE_TYPE=$(jq -r '.data.node.content.__typename // empty' <<<"$source_json")
  MOVE_SOURCE_TITLE=$(jq -r '.data.node.content.title // empty' <<<"$source_json")
  MOVE_SOURCE_BODY=$(jq -r '.data.node.content.body // empty' <<<"$source_json")
  [ "$MOVE_SOURCE_TYPE" = DraftIssue ] || [ "$MOVE_SOURCE_TYPE" = Issue ] || return 1
  [ -n "$MOVE_SOURCE_TITLE" ] && [ -n "$MOVE_SOURCE_BODY" ]
}

# move_card_copy_fields <source-item-id> <destination-item-id> copies the
# current Helm single-select values before the source item is removed. Field
# and option ids are board-local, so resolve both sides by their stable names.
move_card_copy_fields() {
  local source_item=$1 destination_item=$2 source_json destination_json writes field_id option_id query
  # shellcheck disable=SC2016 # GraphQL variables must remain literal.
  local item_query='query($itemId:ID!){node(id:$itemId){... on ProjectV2Item {fieldValues(first:30){nodes{... on ProjectV2ItemFieldSingleSelectValue{name optionId field{... on ProjectV2SingleSelectField{name}}}}}}}}}'
  # shellcheck disable=SC2016 # GraphQL variables must remain literal.
  local project_query='query($projectId:ID!){node(id:$projectId){... on ProjectV2 {fields(first:100){nodes{... on ProjectV2SingleSelectField{id name options{id name}}}}}}}'
  source_json=$(gh-axi api graphql --field "query=$item_query" --field "itemId=$source_item" 2>/dev/null) \
    || return 1
  destination_json=$(gh-axi api graphql --field "query=$project_query" --field "projectId=$BOARD_ID" 2>/dev/null) \
    || return 1
  jq -e '.data.node != null and (.data.node.fieldValues.nodes | type == "array")' <<<"$source_json" >/dev/null 2>&1 \
    || return 1
  jq -e '.data.node != null and (.data.node.fields.nodes | type == "array")' <<<"$destination_json" >/dev/null 2>&1 \
    || return 1
  writes=$(jq -n --argjson source "$source_json" --argjson destination "$destination_json" '
    ($source.data.node.fieldValues.nodes // [])
    | map(. as $value
          | select(["Status", "Priority", "Kind", "Project"] | index($value.field.name) != null)
          | select(($value.name // "") != "")
          | {name:$value.field.name, value:$value.name}) as $values
    | ($destination.data.node.fields.nodes // []) as $fields
    | [ $values[] as $value
        | ([ $fields[]
            | select(.name == $value.name)
            | .options[]?
            | select(.name == $value.value)
            | {optionId:.id} ][0]) as $option
        | ([ $fields[] | select(.name == $value.name) ][0].id) as $field_id
        | select($option != null and ($field_id // "") != "")
        | {fieldId:$field_id, optionId:$option.optionId} ] as $writes
    | if ($writes | length) == ($values | length) then $writes else error("destination Helm field option is unavailable") end
  ' 2>/dev/null) || return 1
  # shellcheck disable=SC2016 # GraphQL variables must remain literal.
  query='mutation($projectId:ID!,$itemId:ID!,$fieldId:ID!,$optionId:String!){updateProjectV2ItemFieldValue(input:{projectId:$projectId,itemId:$itemId,fieldId:$fieldId,value:{singleSelectOptionId:$optionId}}){projectV2Item{id}}}'
  while IFS=$'\t' read -r field_id option_id; do
    [ -n "$field_id" ] && [ -n "$option_id" ] || continue
    gh-axi api graphql --field "query=$query" --field "projectId=$BOARD_ID" \
      --field "itemId=$destination_item" --field "fieldId=$field_id" --field "optionId=$option_id" \
      >/dev/null 2>&1 || return 1
  done < <(jq -r '.[] | [.fieldId, .optionId] | @tsv' <<<"$writes")
}

move_execute() {
  local task from_owner from_number from_item to_owner to_number to_item phase updated row type node title body new_item move_line
  local remaining=0
  while IFS= read -r move_line; do
    # Bash treats tab as IFS whitespace and would collapse the intentionally
    # empty destination-item field in a pending ledger row. Parse with a
    # non-whitespace separator after preserving the TSV boundaries.
    move_line=${move_line//$'\t'/$'\034'}
    IFS=$'\034' read -r task from_owner from_number from_item to_owner to_number to_item phase updated <<<"$move_line"
    [ -n "$task" ] || continue
    case $'\n'$MOVE_TASKS$'\n' in
      *$'\n'"$task"$'\n'*) ;;
      *) continue ;;
    esac
    [ "$phase" = complete ] && continue
    if [ "$phase" = pending ]; then
      row=$(awk -F '\t' -v t="$task" '$1 == t { print; exit }' "$CARDS_FILE" 2>/dev/null) || row=
      [ -n "$row" ] || { remaining=$((remaining + 1)); continue; }
      if ! move_card_read_source "$from_item"; then
        printf 'fm-helm-project-map: source card read failed for %s; it will resume\n' "$task" >&2
        remaining=$((remaining + 1)); continue
      fi
      type=$MOVE_SOURCE_TYPE
      node=$(printf '%s\n' "$row" | awk -F '\t' '{print $3}')
      title=$MOVE_SOURCE_TITLE
      body=$MOVE_SOURCE_BODY
      new_item=$(move_card_add "$type" "$node" "$title" "$body" || true)
      if [ -z "$new_item" ]; then
        printf 'fm-helm-project-map: destination add failed for %s; it will resume\n' "$task" >&2
        remaining=$((remaining + 1)); continue
      fi
      phase=dest-ready; to_item=$new_item; updated=$(date +%s)
      move_ledger_update "$task" "$task"$'\t'"$from_owner"$'\t'"$from_number"$'\t'"$from_item"$'\t'"$to_owner"$'\t'"$to_number"$'\t'"$to_item"$'\t'"$phase"$'\t'"$updated" \
        || fail "could not publish move progress for $task"
    fi
    if [ "$phase" = dest-ready ]; then
      if ! move_card_copy_fields "$from_item" "$to_item"; then
        printf 'fm-helm-project-map: destination fields failed for %s; it will resume\n' "$task" >&2
        remaining=$((remaining + 1)); continue
      fi
      if ! move_card_delete "$from_owner" "$from_number" "$from_item"; then
        printf 'fm-helm-project-map: source delete failed for %s; it will resume\n' "$task" >&2
        remaining=$((remaining + 1)); continue
      fi
      phase=complete; updated=$(date +%s)
      move_ledger_update "$task" "$task"$'\t'"$from_owner"$'\t'"$from_number"$'\t'"$from_item"$'\t'"$to_owner"$'\t'"$to_number"$'\t'"$to_item"$'\t'"$phase"$'\t'"$updated" \
        || fail "could not publish move completion for $task"
      if [ -f "$CARDS_FILE" ]; then
        awk -F '\t' -v t="$task" -v owner="$to_owner" -v number="$to_number" -v item="$to_item" -v epoch="$updated" \
          'BEGIN { OFS="\t" } $1 == t {$2=item; $9=epoch; $10=owner; $11=number} {print}' "$CARDS_FILE" >"$TMP_DIR/cards.next" \
          && chmod 0600 "$TMP_DIR/cards.next" && mv -f -- "$TMP_DIR/cards.next" "$CARDS_FILE"
      fi
    fi
  done <"$TMP_DIR/moves.tsv"
  printf '%s\n' "$remaining"
}

map_move() {
  local project=$1 title=${2:-} owner=$DEFAULT_OWNER existing='' default_dest='' yes=0 entry source_owner source_number count now ids
  [ -n "$project" ] || fail "move requires a local project name"
  map_load
  entry=$(map_entry "$project")
  if [ "$(printf '%s\n' "$entry" | jq -r '.state // empty')" = migrating ]; then
    destination_owner=$(printf '%s\n' "$entry" | jq -r '.owner')
    destination_number=$(printf '%s\n' "$entry" | jq -r '.number')
    source_owner=$(printf '%s\n' "$entry" | jq -r '.move.from.owner')
    source_number=$(printf '%s\n' "$entry" | jq -r '.move.from.number')
    BOARD_OWNER=$destination_owner; BOARD_NUMBER=$destination_number
    board_view "$BOARD_OWNER" "$BOARD_NUMBER" || fail "migration destination $BOARD_OWNER/$BOARD_NUMBER does not resolve"
    printf 'resuming confirmed move for %s -> %s/%s\n' "$project" "$BOARD_OWNER" "$BOARD_NUMBER"
    yes=1
  else
    project_registered "$project" || fail "local project '$project' is not registered in data/projects.md"
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --owner) shift; [ "$#" -gt 0 ] || fail "--owner needs a login"; owner=$1 ;;
        --existing) shift; [ "$#" -gt 0 ] || fail "--existing needs OWNER/NUMBER"; existing=$1 ;;
        --default) default_dest=1 ;;
        --yes) yes=1 ;;
        *) [ -z "$title" ] || fail "unknown move argument: $1"; title=$1 ;;
      esac
      shift
    done
    source_owner=$(printf '%s\n' "$entry" | jq -r '.owner // empty')
    source_number=$(printf '%s\n' "$entry" | jq -r '.number // empty')
    [ -n "$source_owner" ] || source_owner=$DEFAULT_OWNER
    [ -n "$source_number" ] || source_number=$DEFAULT_NUMBER
    if [ -n "$default_dest" ]; then
      BOARD_OWNER=$DEFAULT_OWNER; BOARD_NUMBER=$DEFAULT_NUMBER
      board_view "$BOARD_OWNER" "$BOARD_NUMBER" || fail "default Helm Project $BOARD_OWNER/$BOARD_NUMBER does not resolve"
    else
      [ -n "$title" ] || title="$project"
      PROJECT_SCHEMA_OPTION=$project
      create_or_reuse_board "$owner" "$title" "$existing"
      ensure_schema
    fi
  fi
  [ "$source_owner/$source_number" != "$BOARD_OWNER/$BOARD_NUMBER" ] || fail "source and destination boards are the same"
  ids="$TMP_DIR/task-ids"
  backlog_task_ids "$project" "$ids"
  MOVE_TASKS=$(cat -- "$ids")
  : >"$TMP_DIR/moves.tsv"
  [ -f "$MOVES_FILE" ] && [ ! -L "$MOVES_FILE" ] && cp -- "$MOVES_FILE" "$TMP_DIR/moves.tsv"
  awk -F '\t' -v ids_file="$ids" -v moves_file="$TMP_DIR/moves.tsv" \
    -v owner="$source_owner" -v number="$source_number" \
    -v dest_owner="$BOARD_OWNER" -v dest_number="$BOARD_NUMBER" -v epoch="$(date +%s)" \
    'FILENAME == ids_file { ids[$1]=1; next }
     FILENAME == moves_file { existing[$1]=1; next }
     NF >= 11 && ids[$1] && !existing[$1] && $10 == owner && $11 == number {
       print $1 "\t" owner "\t" number "\t" $2 "\t" dest_owner "\t" dest_number "\t\tpending\t" epoch
     }' "$ids" "$CARDS_FILE" 2>/dev/null >>"$TMP_DIR/moves.tsv" || true
  # The portable awk pipeline above intentionally keeps task selection local;
  # normalize and de-duplicate any rows already present from an earlier run.
  awk -F '\t' 'NF >= 8 { latest[$1]=$0 } END { for (id in latest) print latest[id] }' "$TMP_DIR/moves.tsv" \
    | sort -t $'\t' -k1,1 >"$TMP_DIR/moves.sorted"
  mv -f -- "$TMP_DIR/moves.sorted" "$TMP_DIR/moves.tsv"
  count=$(awk -F '\t' '$8 != "complete" { n++ } END { print n + 0 }' "$TMP_DIR/moves.tsv")
  printf 'move plan: %s -> %s; %s card(s)\n' "$source_owner/$source_number" "$BOARD_OWNER/$BOARD_NUMBER" "$count"
  if [ "$yes" -eq 0 ]; then
    printf 're-run with --yes to execute.\n'
    exit 0
  fi
  if ! fm_lock_try_acquire "$LOCK_FILE"; then
    fail "another Helm sync or move is already running"
  fi
  LOCK_HELD=1
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg p "$project" --arg owner "$BOARD_OWNER" --argjson number "$BOARD_NUMBER" \
    --arg from_owner "$source_owner" --argjson from_number "$source_number" --arg now "$now" \
    '.projects[$p] = ((.projects[$p] // {}) + {owner:$owner,number:$number,state:"migrating",move:{from:{owner:$from_owner,number:$from_number},to:{owner:$owner,number:$number},requested_at:$now,confirmed:true},orphan_hold_task:null})' \
    "$TMP_DIR/map.json" >"$TMP_DIR/map.next" || fail "could not prepare the migration mapping"
  mv -f -- "$TMP_DIR/map.next" "$TMP_DIR/map.json"
  map_publish || fail "could not publish the migration mapping"
  if ! chmod 0600 "$TMP_DIR/moves.tsv" || ! move_ledger_publish; then
    fail "could not publish state/helm-moves.tsv"
  fi
  remaining=$(move_execute)
  if [ "$remaining" -eq 0 ]; then
    jq --arg p "$project" '.projects[$p].state = "active" | .projects[$p].move = null' "$TMP_DIR/map.json" >"$TMP_DIR/map.next" \
      || fail "could not finish the migration mapping"
    mv -f -- "$TMP_DIR/map.next" "$TMP_DIR/map.json"
    map_publish || fail "could not publish the completed migration mapping"
  else
    printf 'move partial: %s card(s) remain; rerun move or sync to resume.\n' "$remaining"
  fi
  fm_lock_release "$LOCK_FILE" || fail "could not release the Helm move lock"
  LOCK_HELD=0
  "$SCRIPT_DIR/fm-helm-sync.sh" || true
}

map_unlink() {
  local project=$1
  map_load
  jq --arg p "$project" '.projects |= del(.[$p]) | .nudges |= del(.[$p])' "$TMP_DIR/map.json" >"$TMP_DIR/map.next" \
    || fail "could not prepare the unlink"
  mv -f -- "$TMP_DIR/map.next" "$TMP_DIR/map.json"
  map_publish || fail "could not publish data/helm-project-map.json"
  printf 'unlinked: %s -> default Helm board %s/%s\n' "$project" "$DEFAULT_OWNER" "$DEFAULT_NUMBER"
  printf 'unlink changes future cards only; use move %s --default --yes to relocate existing cards.\n' "$project"
  "$SCRIPT_DIR/fm-helm-sync.sh" || true
}

map_list() {
  local counts=0 project entry owner number title count
  [ "${1:-}" = --counts ] && counts=1
  map_load
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    entry=$(map_entry "$project")
    if [ "$(printf '%s\n' "$entry" | jq -r '.orphan_hold_task // empty')" != "" ]; then
      printf '%s  -> [NEEDS DECISION: see task %s]\n' "$project" "$(printf '%s\n' "$entry" | jq -r '.orphan_hold_task')"
      continue
    fi
    owner=$(printf '%s\n' "$entry" | jq -r '.owner // empty')
    number=$(printf '%s\n' "$entry" | jq -r '.number // empty')
    title=$(printf '%s\n' "$entry" | jq -r '.title // empty')
    if [ -n "$owner" ]; then
      printf '%s  -> %s/%s "%s"' "$project" "$owner" "$number" "$title"
    else
      printf '%s  -> default (%s/%s)' "$project" "$DEFAULT_OWNER" "$DEFAULT_NUMBER"
    fi
    if [ "$counts" -eq 1 ]; then
      count=0
      if [ -n "$owner" ]; then
        count=$(gh-axi project item-list "$number" --owner "$owner" --query "Project:$project" --limit 1000 2>/dev/null \
          | awk '/^[[:space:]]+[A-Za-z0-9_]+,/{n++} END{print n+0}')
      else
        count=$(gh-axi project item-list "$DEFAULT_NUMBER" --owner "$DEFAULT_OWNER" --query "Project:$project" --limit 1000 2>/dev/null \
          | awk '/^[[:space:]]+[A-Za-z0-9_]+,/{n++} END{print n+0}')
      fi
      printf '  [%s live cards]' "$count"
    fi
    printf '\n'
  done < <(fm_helm_project_names "${HOME_PATHS[@]}")
}

map_sync() {
  local force=${1:-}
  if [ "$force" = --force ]; then
    "$SCRIPT_DIR/fm-helm-reconcile.sh" --force
  else
    "$SCRIPT_DIR/fm-helm-reconcile.sh" --force
  fi
}

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
command=$1; shift
case "$command" in
  list) map_list "$@" ;;
  link)
    [ "$#" -gt 0 ] || fail "link requires a local project name"
    project=$1; shift; title=
    case "${1:-}" in --*) ;; '') ;; *) title=$1; shift ;; esac
    map_load
    map_link "$project" "$title" "$@"
    ;;
  move)
    [ "$#" -gt 0 ] || fail "move requires a local project name"
    project=$1; shift; title=
    case "${1:-}" in --*) ;; '') ;; *) title=$1; shift ;; esac
    map_move "$project" "$title" "$@"
    ;;
  unlink)
    [ "$#" -eq 1 ] || fail "unlink requires exactly one local project name"
    map_unlink "$1"
    ;;
  sync) [ "$#" -eq 0 ] || fail "sync takes no arguments"; map_sync ;;
  --help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
