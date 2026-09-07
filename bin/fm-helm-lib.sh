#!/usr/bin/env bash
# fm-helm-lib.sh - shared helpers for the fleet-aware Helm board sync.
#
# Sourced by bin/fm-helm-sync.sh (the aggregator that writes the board) and by
# bin/fm-helm-poll.sh (the cheap read-only board-change poll). It owns:
#   - local fleet home discovery from data/secondmates.md,
#   - the one data/backlog.md parser, run once per discovered home,
#   - the combined debounce hash over every discovered home's backlog,
#   - small sha256 helpers.
#
# ## Remote homes
# Discovery here is local-only. It resolves each secondmate's on-disk home from
# data/secondmates.md and reads that home's data/backlog.md directly, so a new
# LOCAL secondmate is picked up on the next run with no extra wiring. A REMOTE
# secondmate entry ("(host: ...; root: ...; home: ...)") is skipped with a
# logged note: the aggregator cannot cheaply read its backlog over the wire.
# The planned path when the first remote secondmate appears is an owner marker
# written into each card body on create ("<!-- fm-home: <id> -->") so the remote
# home runs its own scoped fm-helm-sync.sh whose close-missing sweep only ever
# touches its own cards. That path is not built yet (YAGNI).
set -u

FM_HELM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$FM_HELM_LIB_DIR/fm-secondmate-registry-lib.sh"

# fm_helm_sha256_stdin - hash stdin, print the hex digest, or return 1.
fm_helm_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

# fm_helm_sha256_file <path> - hash a file, print the hex digest, or return 1.
fm_helm_sha256_file() {
  [ -f "$1" ] || return 1
  fm_helm_sha256_stdin <"$1"
}

# fm_helm_discover_homes <main-home> <secondmates.md>
# Print one "<id>\t<home-path>" line per home, main first ("main"), then every
# LOCAL secondmate in registry order. Remote entries are announced on stderr and
# skipped. A missing or unreadable registry yields just the main line.
fm_helm_discover_homes() {
  local main_home=$1 reg=$2 line
  printf 'main\t%s\n' "$main_home"
  [ -f "$reg" ] && [ -r "$reg" ] && [ ! -L "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      printf 'fm-helm-sync: skipping remote secondmate %s (see "Remote homes" in fm-helm-lib.sh)\n' \
        "$SECONDMATE_REGISTRY_ID" >&2
      continue
    fi
    case "$SECONDMATE_REGISTRY_HOME" in
      /*) ;;
      *) continue ;;
    esac
    printf '%s\t%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME"
  done <"$reg"
}

# fm_helm_combined_hash <backlog-path>...
# One digest over every backlog file, in the given order, with a boundary token
# between homes and an explicit marker for an absent file. Any change to any
# home's backlog changes this digest.
fm_helm_combined_hash() {
  local f
  {
    for f in "$@"; do
      if [ -f "$f" ] && [ ! -L "$f" ]; then
        cat -- "$f"
      else
        printf 'FM_HELM_MISSING_BACKLOG:%s' "$f"
      fi
      printf '\036--fm-helm-home-boundary--\036'
    done
  } | fm_helm_sha256_stdin
}

# fm_helm_backlog_parse_program - print the jq -Rn program that turns a
# data/backlog.md stream into a records array. One owner; both the aggregator's
# per-home parse and any future caller use this exact program.
fm_helm_backlog_parse_program() {
  cat <<'JQ'
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
JQ
}

# fm_helm_parse_home_backlog <home-id> <backlog-path> <out-json>
# Parse one home's data/backlog.md into <out-json>, tagging every record with
# {home_id, home_backlog}. Returns 1 on a parse failure or an unstructured /
# duplicate-id row, so the caller can fail open.
fm_helm_parse_home_backlog() {
  local home_id=$1 backlog=$2 out=$3 program
  program=$(fm_helm_backlog_parse_program)
  [ -f "$backlog" ] || return 1
  jq -Rn "$program" <"$backlog" >"$out.raw" || return 1
  jq -c --arg hid "$home_id" --arg bp "$backlog" \
    'map(. + {home_id:$hid, home_backlog:$bp})' "$out.raw" >"$out" || return 1
  jq -e 'all(.[]; .structured == true and (.id | test("^[A-Za-z0-9._-]+$")) and (.title | length > 0))' \
    "$out" >/dev/null 2>&1 || return 1
  jq -e 'map(.id) | group_by(.) | all(length == 1)' "$out" >/dev/null 2>&1 || return 1
  return 0
}
