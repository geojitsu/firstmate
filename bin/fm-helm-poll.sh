#!/usr/bin/env bash
# fm-helm-poll.sh - one cheap read-only poll for a captain edit to the Helm
# board.
#
# Inert by default: a HARD no-op (exit 0, no output) unless config/helm.json
# exists. The watcher invokes this trusted repository script only after
# state/helm-board.check.sh matches its byte-static identity shim.
#
# Contract: "output => wake firstmate, silence => keep sleeping". It prints ONE
# line only when the board changed AND no backlog change is pending (so the
# ordinary sync is not about to run anyway); firstmate then runs
# bin/fm-helm-sync.sh --force to read and reconcile the edit. It never mutates
# the board or the backlog. It finishes well inside FM_CHECK_TIMEOUT.
#
# Enable (firstmate, main home, once, alongside creating config/helm.json):
#   printf 'exec "%s/bin/fm-helm-poll.sh" "$@"\n' "$FM_ROOT" > state/helm-board.check.sh
#   chmod 0700 state/helm-board.check.sh
#   bin/fm-check-register.sh helm-board
# Retire with bin/fm-check-unregister.sh helm-board.
#
# Snapshot: state/.helm-board-poll (mode 0600) holds the last board signature.
# The signature folds, per card, the (Status, Priority, title, body) it shows,
# plus the card count. Any captain edit to those changes it.
#
# Known limitation: when a backlog change is pending at the same moment as a
# board edit, this poll re-baselines silently and the ordinary (non --force)
# sync rewrites the card from the backlog, so that one board edit is not read
# back. Re-applying it is a second board edit once the backlog is quiet.
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
QUERY='query($owner:String!, $number:Int!) {
  user(login:$owner) {
    projectV2(number:$number) {
      items(first:100) {
        pageInfo { hasNextPage }
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

# Bound the one network call well inside FM_CHECK_TIMEOUT; a timeout just means
# "no wake this cycle".
GH_TIMEOUT=()
command -v timeout >/dev/null 2>&1 && GH_TIMEOUT=(timeout 20)
"${GH_TIMEOUT[@]}" gh api graphql \
  --field "query=$QUERY" \
  --field "owner=$OWNER" \
  --field "number=$PROJECT_NUMBER" \
  >"$BOARD_JSON" 2>/dev/null || exit 0
jq -e '(.errors // []) | length == 0' "$BOARD_JSON" >/dev/null 2>&1 || exit 0
jq -e '.data.user.projectV2.items.pageInfo.hasNextPage == false' "$BOARD_JSON" >/dev/null 2>&1 || exit 0

SIGNATURE=$(jq -r '
  def fieldval($n): [.fieldValues.nodes[]? | select(.field.name == $n) | .name][0] // "";
  [ .data.user.projectV2.items.nodes[]
    | .id + "" + fieldval("Status") + "" + fieldval("Priority")
      + "" + ((.content.title // "") | @base64)
      + "" + ((.content.body // "") | @base64) ]
  | (length | tostring) + "\n" + (sort | join("\n"))
' "$BOARD_JSON" | fm_helm_sha256_stdin) || exit 0
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
  # Re-baselined above; the ordinary sync handles this cycle.
  exit 0
fi

printf 'check: Helm board edited by the captain; run bin/fm-helm-sync.sh --force to reconcile\n'
