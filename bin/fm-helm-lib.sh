#!/usr/bin/env bash
# fm-helm-lib.sh - shared helpers for the fleet-aware Helm board sync.
#
# Sourced by bin/fm-helm-sync.sh (the aggregator that writes the board) and by
# bin/fm-helm-poll.sh (the cheap read-only board-change poll). It owns:
#   - local fleet home discovery from data/secondmates.md,
#   - the one data/backlog.md parser, run once per discovered home,
#   - the combined debounce hash over every discovered home's backlog,
#   - the one board signature the poll and the sync both fold,
#   - the card renderer and the one-pass reconciliation planner the sync
#     executes (see "Plan format" below),
#   - small sha256 helpers.
#
# ## Plan format
# fm_helm_plan_program turns the rendered backlog union, the board, and the
# sync's private state files into one NUL-separated stream that the aggregator
# reads with plain `read -d ''`: no per-record jq call, no per-record awk.
# Every entry is exactly FM_HELM_PLAN_FIELDS (22) NUL-terminated fields, in
# order:
#   1 phase        error | record | missing | deleted
#   2 action       error: the fail-open message
#                  record: none | create | update | skip
#                  missing: close | wake | ignore
#                  deleted: retain | hold
#   3 task id
#   4 item id      board item node id ("" for a card not created yet)
#   5 cache line   the identity-cache row to keep ("" when the executor
#                  composes it after a creation)
#   6 draft id     non-empty => the update also rewrites title and body
#   7 title        desired card title
#   8 body         desired card body
#   9 field writes US-separated items of `fieldId RS name RS value RS optionId`
#  10 wakes        US-separated items of `key RS payload`
#  11 marker       "" | remove | request   (dispatch marker operation)
#  12 marker fp    the dispatch marker fingerprint for `request`
#  13 divergence  US-separated divergence marker operations
#  14 writeback    "" | 0-4: board Priority to write into the owning backlog
#  15 home path    the owning home (writeback and hold)
#  16 tombstone    "" | `task TAB item` deletion-tombstone row to retain
#  17 hold reason  the captain hold reason for a deleted live card
#  18 expected     compact JSON pre-write snapshot for the conflict guard
#  19 ack create   compact JSON board patch recorded once a creation lands
#  20 ack write    compact JSON board patch recorded once the write lands
#  21 fingerprint  the desired-state fingerprint
#  22 note         one stderr diagnostic line, or ""
# US is byte 0x1f and RS is byte 0x1e; no planned value contains either.
# Error entries always come first so the executor fails open before any write.
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
# Fields per plan entry; see "Plan format" above.
# shellcheck disable=SC2034 # consumed by bin/fm-helm-sync.sh's plan reader.
FM_HELM_PLAN_FIELDS=22
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
      # v1 is local-homes-only by design; remote-home sync is a separate approved task - see the Remote homes note in this header
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
           pr_url:(([$m.rest | scan(url_pattern)] | map(select(test("/pull/[1-9][0-9]*$") or test("/-/merge_requests/[1-9][0-9]*$"))) | .[0]) // null),
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

# fm_helm_sha256_files <dir> <prefix>
# Hash every "<prefix>*" file under <dir> in one process and print one
# "<name-without-prefix>\t<hex digest>" line per file. Prints nothing for an
# empty set; returns 1 when no SHA-256 utility is available.
fm_helm_sha256_files() {
  local dir=$1 prefix=$2
  (
    cd "$dir" || exit 1
    set -- "$prefix"*
    [ -e "$1" ] || exit 0
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -- "$@"
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 -- "$@"
    else
      exit 1
    fi
  ) | awk -v p="$prefix" '{ name = $2; sub("^" p, "", name); print name "\t" $1 }'
}

# fm_helm_board_signature_program - print the jq -r program that folds a board
# read into the one signature state/.helm-board-poll stores: the card count
# plus, per card, its id, Status, Priority, title, and body. The poll and the
# sync both use this exact program so a sync's own writes never read back as a
# captain edit.
fm_helm_board_signature_program() {
  cat <<'JQ'
  ([31] | implode) as $us
  | def fieldval($n): [.fieldValues.nodes[]? | select(.field.name == $n) | .name][0] // "";
  [ .data.user.projectV2.items.nodes[]
    | .id + $us + fieldval("Status") + $us + fieldval("Priority")
      + $us + ((.content.title // "") | @base64)
      + $us + ((.content.body // "") | @base64) ]
  | (length | tostring) + "\n" + (sort | join("\n"))
JQ
}

# fm_helm_landed_patch_program - print the jq program that applies the sync's
# landed board patches ($landed: "<item>\t<json>" lines, see fm-helm-sync.sh
# "Durable progress") to a board read, producing the board as the sync now
# believes it looks. Pipe into fm_helm_board_signature_program.
fm_helm_landed_patch_program() {
  cat <<'JQ'
  ($landed | split("\n") | map(select(. != "") | split("\t") | {item: .[0], patch: (.[1] | fromjson)})) as $patches
  | reduce $patches[] as $p (.;
      if $p.patch.new then
        .data.user.projectV2.items.nodes += [{id: $p.item, content: {title: $p.patch.title, body: $p.patch.body}, fieldValues: {nodes: []}}]
      else
        .data.user.projectV2.items.nodes |= map(
          if .id == $p.item then
            (if $p.patch.text then .content.title = $p.patch.title | .content.body = $p.patch.body else . end)
            | reduce $p.patch.fields[] as $f (.;
                .fieldValues.nodes |=
                  if any(.[]?; .field.name == $f.name) then
                    map(if .field.name == $f.name then .name = $f.value | .optionId = $f.option else . end)
                  else . + [{field: {name: $f.name}, name: $f.value, optionId: $f.option}] end)
          else . end)
      end)
JQ
}

# fm_helm_desired_program - print the jq program that renders every record of
# the fleet backlog union into its desired card: title, body, Status, Kind,
# Project, and Priority option names, plus the owning home path and any
# stderr note. Input: the union array. $report_ids: the task ids that have a
# data/<id>/report.md in the main home. Output: the same array with .desired
# and .home_path added to each record.
fm_helm_desired_program() {
  cat <<'JQ'
  def priority_name:
    if . == "0" then "P0" elif . == "1" then "P1" elif . == "2" then "P2"
    elif . == "3" then "P3" elif . == "4" then "P4" else "P3" end;
  def kind_of:
    if .hold_kind == "captain" and ((.hold_reason // "") != "") then "decision"
    elif ((.kind // "ship") == "task") or ((.kind // "ship") == "scout") then "investigation"
    else "ship" end;
  def status_of($kind):
    if .state == "done" then "Done"
    elif $kind == "decision" then "Waiting on you"
    elif .state == "in_flight" then "In flight"
    else "Queued" end;
  def project_of:
    (.repo // "") as $r
    | if $r == "firetabs" or $r == "geojitsu/firetabs" then "firetabs"
      elif $r == "BetterBlueToo" or $r == "geojitsu/BetterBlueToo" then "BetterBlueToo"
      elif $r == "firstmate" or $r == "geojitsu/firstmate" then "firstmate"
      elif $r == "nocout" or $r == "dc-noc/nocout" then "nocout"
      elif $r == "cryptoseacurrents" or $r == "copium/cryptoseacurrents" then "cryptoseacurrents"
      elif $r == "other" then "other"
      else null end;
  def type_line($kind):
    if $kind == "ship" then "ship - produces a change and a PR"
    elif $kind == "investigation" then "investigation - produces knowledge, not code"
    else "decision - needs your call before anything moves" end;
  def body_of($kind; $priority; $report):
    ((.repo // "-") | if . == "" then "-" else . end) as $repo
    | (.since // .reported // .done // .merged // "unknown") as $filed
    | (.hold_reason // "") as $hold
    | ((.blocked_by_ids // []) | join(", ")) as $blocked
    | (.pr_url // "") as $pr
    | "`" + .id + "`\n\n"
      + (if $kind == "decision" and $hold != "" then "## What you need to decide\n\n" + $hold + "\n\n" else "" end)
      + "## Facts\n\n"
      + "- **Repo:** " + $repo + "\n"
      + "- **Type:** " + type_line($kind) + "\n"
      + "- **Priority:** " + $priority + "\n"
      + "- **Filed:** " + $filed + "\n"
      + (if $blocked == "" then "" else "- **Blocked by:** " + $blocked + "\n" end)
      + (if $report == "" then "" else "- **Report:** `" + $report + "`\n" end)
      + (if $pr == "" then "" else "- **PR:** " + $pr + "\n" end)
      + "\n## Notes\n\n"
      + ((.body_lines // []) | map(. + "\n") | join(""))
      + "\n---\n_Source of truth: `data/backlog.md` in the owning firstmate home._";
  map(
    kind_of as $kind
    | ((.priority // "3") | priority_name) as $priority
    | project_of as $project
    | .id as $id
    | (if (.report_path // "") != "" then .report_path
       elif any($report_ids[]; . == $id) then "data/" + $id + "/report.md"
       else "" end) as $report
    | . + {
        home_path: ((.home_backlog // "") | sub("/data/backlog\\.md$"; "")),
        desired: {
          title: .title,
          body: body_of($kind; $priority; $report),
          status: status_of($kind),
          kind: $kind,
          project: ($project // "other"),
          priority_n: (.priority // "3"),
          priority: $priority,
          note: (if $project == null
                 then "fm-helm-sync: unsupported repository " + (.repo // "") + " for " + $id + "; using other"
                 else "" end)
        }
      })
JQ
}

# fm_helm_plan_program - print the jq -j program that computes the whole
# reconciliation plan in one pass. See "Plan format" in this file's header
# for the entry layout the executor reads.
# Input: the combined board read. Named inputs:
#   $desired[0]       fm_helm_desired_program output (--slurpfile)
#   $cards            prior state/helm-cards.tsv text (--rawfile)
#   $deleted          prior state/helm-deleted.tsv text (--rawfile)
#   $markers          state/.helm-dispatch-requests text (--rawfile)
#   $fps              "<task>\t<fingerprint>" lines (--rawfile)
#   $force            "1" on --force, else "0"
#   $dispatch_status  the configured dispatch Status option name
#   $now              the epoch second recorded in every cache row
#   $tsv_existed      "true" when the identity cache existed before this run
fm_helm_plan_program() {
  cat <<'JQ'
  ([0] | implode) as $nul
  | ([31] | implode) as $us
  | ([30] | implode) as $rs
  | . as $board
  | $desired[0] as $records
  | $board.data.user.projectV2.fields.nodes as $fields
  | def fid($f): [$fields[] | select(.name == $f and .__typename == "ProjectV2SingleSelectField") | .id][0] // "";
  def opt($f; $n): [$fields[] | select(.name == $f and .__typename == "ProjectV2SingleSelectField") | .options[]? | select(.name == $n) | .id][0] // "";
  def line1: (.content.body // "") | split("\n")[0];
  def fieldval($n): [.fieldValues.nodes[]? | select(.field.name == $n) | .name][0] // "";
  def fieldopt($n): [.fieldValues.nodes[]? | select(.field.name == $n) | .optionId][0] // "";
  def snapshot:
    {title: (.content.title // ""), body: (.content.body // ""),
     fields: ([.fieldValues.nodes[]?
       | {field: (.field.name // ""), name: (.name // ""), optionId: (.optionId // "")}
       | select(.field != "")] | sort_by(.field, .optionId, .name))}
    | tojson;
  def rows($text): $text | split("\n") | map(select(. != "") | split("\t"));
  def first_by($key): reduce .[] as $x ({}; if .[$x[$key]] == null then .[$x[$key]] = $x else . end);
  def priority_digit:
    if . == "P0" then "0" elif . == "P1" then "1" elif . == "P2" then "2"
    elif . == "P3" then "3" elif . == "P4" then "4" else "" end;
  def entry($o):
    [ $o.phase, $o.action, ($o.task // ""), ($o.item // ""), ($o.cache // ""), ($o.draft // ""),
      ($o.title // ""), ($o.body // ""),
      (($o.fields // []) | map(.id + $rs + .name + $rs + .value + $rs + .option) | join($us)),
      (($o.wakes // []) | map(.key + $rs + .payload) | join($us)),
      ($o.marker // ""), ($o.marker_fp // ""),
      (($o.divergence_ops // []) | map(.kind + $rs + .action + $rs + .item + $rs + .fp) | join($us)),
      ($o.writeback // ""), ($o.home // ""),
      ($o.tombstone // ""), ($o.hold // ""), ($o.expected // ""),
      ($o.ack_create // ""), ($o.ack_write // ""), ($o.fp // ""), ($o.note // "") ]
    | join($nul) + $nul;
  $board.data.user.projectV2.items.nodes as $items
  | (reduce $items[] as $i ({}; .[$i.id] = true)) as $item_set
  | (reduce $items[] as $i ({}; .[($i | line1)] = true)) as $line1_set
  | ($items | map(select(.content.__typename == "DraftIssue" or .content.__typename == "Issue"))) as $cards_all
  | (reduce $cards_all[] as $c ({}; .[($c | line1)] += [$c])) as $by_line1
  | (rows($cards) | map({task: (.[0] // ""), item: (.[1] // ""), node: (.[2] // ""), type: (.[3] // ""), status: (.[4] // ""), priority: (.[5] // ""), title: (.[6] // ""), body: (.[7] // ""), fp: (.[4] // ""), v2: (length >= 9)})) as $old_rows
  | ($old_rows | first_by("task")) as $old_by_task
  | (rows($deleted) | map({task: (.[0] // ""), line: join("\t")}) | first_by("task")) as $deleted_by_task
  | (rows($markers) | map({task: (.[0] // ""), item: (.[1] // ""), option: (.[2] // ""), fp: (.[3] // "")})) as $marker_rows
  | (rows($divergences) | map({kind: (.[0] // ""), task: (.[1] // ""), item: (.[2] // ""), fp: (.[3] // "")})) as $divergence_rows
  | (rows($fps) | map({task: (.[0] // ""), fp: (.[1] // "")}) | first_by("task")) as $fp_by_task
  | def has_marker($t): any($marker_rows[]; .task == $t);
  def marker_matches($t; $f): any($marker_rows[]; .task == $t and .fp == $f);
  def divergence_matches($k; $t; $i; $f): any($divergence_rows[]; .kind == $k and .task == $t and .item == $i and .fp == $f);
  def divergence_for($k; $t): [$divergence_rows[] | select(.kind == $k and .task == $t)][0];
  (reduce $records[] as $r ({}; .[$r.id] = $r)) as $record_by_id
  | fid("Status") as $status_field
  | fid("Project") as $project_field
  | fid("Kind") as $kind_field
  | fid("Priority") as $priority_field
  | opt("Status"; "Done") as $done_id
  | opt("Status"; "Waiting on you") as $waiting_id
  | opt("Status"; $dispatch_status) as $dispatch_option
  | def record_entries:
      [ $records[] as $r
        | $r.desired as $d
        | ($by_line1["`" + $r.id + "`"] // []) as $matches
        | ($fp_by_task[$r.id].fp // "") as $fp
        | $old_by_task[$r.id] as $old
        | opt("Project"; $d.project) as $po
        | opt("Kind"; $d.kind) as $ko
        | opt("Priority"; $d.priority) as $pro
        | opt("Status"; $d.status) as $so
        | if $po == "" or $ko == "" or $pro == "" then
            {phase: "error", action: ("required Helm option is unavailable for " + $r.id)}
          elif ($matches | length) > 1 then
            {phase: "error", action: ("duplicate Helm cards for " + $r.id)}
          elif ($matches | length) == 0 then
            if $deleted_by_task[$r.id] != null then
              {phase: "record", action: "skip", task: $r.id, tombstone: $deleted_by_task[$r.id].line, note: $d.note}
            elif $old != null and $r.state != "done" and $old.item != "" and ($item_set[$old.item] | not) then
              {phase: "record", action: "skip", task: $r.id, note: $d.note}
            else
              [ {id: $status_field, name: "Status", value: $d.status, option: $so},
                {id: $project_field, name: "Project", value: $d.project, option: $po},
                {id: $kind_field, name: "Kind", value: $d.kind, option: $ko},
                {id: $priority_field, name: "Priority", value: $d.priority, option: $pro} ] as $writes
              | {phase: "record", action: "create", task: $r.id, title: $d.title, body: $d.body,
                 cache: ($r.id + "\t\t\tdraft\t" + $so + "\t" + $pro + "\t" + ($d.title | @base64) + "\t" + ($d.body | @base64) + "\t" + $now),
                 fields: $writes, marker: (if has_marker($r.id) then "remove" else "" end),
                 home: $r.home_path, note: $d.note, fp: $fp,
                 expected: ({title: $d.title, body: $d.body, fields: []} | tojson),
                 ack_create: ({new: true, title: $d.title, body: $d.body} | tojson),
                 ack_write: ({new: false, text: false, fields: ($writes | map({name, value, option}))} | tojson)}
            end
          else
            $matches[0] as $card
            | ($card.content.__typename == "Issue") as $is_issue
            | ($card.content.id // "") as $node
            | ($d.title | @base64) as $dt
            | ($d.body | @base64) as $db
            | ($card.content.title // "") as $card_title
            | ($card.content.body // "") as $card_body
            | ($card.content.title // "" | @base64) as $ct
            | ($card.content.body // "" | @base64) as $cb
            | ($card | fieldopt("Status")) as $cs
            | ($card | fieldopt("Priority")) as $cp
            | (if $old != null and $old.v2 then $old.status else $cs end) as $bs
            | (if $old != null and $old.v2 then $old.priority else $cp end) as $bp
            | (if $old != null and $old.v2 then $old.title else $ct end) as $bt
            | (if $old != null and $old.v2 then $old.body else $cb end) as $bb
            | ($old == null or ($old.v2 | not)) as $rebuilt
            | ($rebuilt or $cs == $bs) as $status_normal
            | ($cs != $bs) as $status_board_changed
            | ($cs == $waiting_id and $status_board_changed) as $waiting_status_changed
            | (($cp != $bp) and ($pro == $bp)) as $priority_board_changed
            | (($ct != $bt) and ($dt == $bt)) as $title_board_changed
            | (($cb != $bb) and ($db == $bb)) as $body_board_changed
            | ($title_board_changed or $body_board_changed) as $text_board_changed
            | (($cs != $bs) and ($so != $bs) and ($cs != $so)) as $status_conflict
            | (($cp != $bp) and ($pro != $bp) and ($cp != $pro)) as $priority_conflict
            | (($ct != $bt) and ($dt != $bt) and ($ct != $dt)) as $title_conflict
            | (($cb != $bb) and ($db != $bb) and ($cb != $db)) as $body_conflict
            | ($title_conflict or $body_conflict) as $text_conflict
            | ($status_conflict or $priority_conflict or $text_conflict) as $conflict
            | ((($title_conflict | not) and ($ct != $dt) and ($title_board_changed | not))) as $title_write
            | ((($body_conflict | not) and ($cb != $db) and ($body_board_changed | not))) as $body_write
            | ($title_write or $body_write) as $text_write
            | (["status", $cs, $so] | tojson | @base64) as $status_conflict_fp
            | (["priority", $cp, $pro] | tojson | @base64) as $priority_conflict_fp
            | (["title", $ct, $dt] | tojson | @base64) as $title_fp
            | (["body", $cb, $db] | tojson | @base64) as $body_fp
            | ($title_board_changed or $title_conflict) as $title_edit
            | ($body_board_changed or $body_conflict) as $body_edit
            | ($title_edit and (divergence_matches("card-edit-title"; $r.id; $card.id; $title_fp) | not)) as $title_edit_wake
            | ($body_edit and (divergence_matches("card-edit-body"; $r.id; $card.id; $body_fp) | not)) as $body_edit_wake
            | (($status_conflict and (divergence_matches("conflict-status"; $r.id; $card.id; $status_conflict_fp) | not))
               or ($priority_conflict and (divergence_matches("conflict-priority"; $r.id; $card.id; $priority_conflict_fp) | not))
               or ($title_conflict and (divergence_matches("conflict-title"; $r.id; $card.id; $title_fp) | not))
               or ($body_conflict and (divergence_matches("conflict-body"; $r.id; $card.id; $body_fp) | not))) as $conflict_wake
            | ($r.id + "\t" + $card.id + "\t" + $node + "\t" + (if $is_issue then "issue" else "draft" end) + "\t" +
                (if $conflict then $bs elif $rebuilt or $status_normal or $cs == $so then $so elif $waiting_status_changed then $cs else $bs end) + "\t" +
                (if $conflict then $bp elif $rebuilt then $pro else (if $priority_board_changed then $cp else $pro end) end) + "\t" +
                (if $conflict then $bt elif $rebuilt or ($ct == $dt and $cb == $db) or ($text_board_changed | not) then $dt else $bt end) + "\t" +
                (if $conflict then $bb elif $rebuilt or ($ct == $dt and $cb == $db) or ($text_board_changed | not) then $db else $bb end) + "\t" + $now) as $cache
            | if $force == "0" and $old != null and $old.v2 and $old.status == $so and $old.priority == $pro and $old.title == $dt and $old.body == $db then
                {phase: "record", action: "none", task: $r.id, item: $card.id, cache: $cache, note: $d.note}
              else
                (if $is_issue then {draft: "", wakes: []}
                   elif $text_write and $node == "" then
                     {error: ("Helm card " + $r.id + " has no draft issue id"), wakes: []}
                   elif $text_write then
                     {draft: $node, wakes: (if $title_edit_wake or $body_edit_wake then [{key:("helm-card-edit:" + $r.id), payload:("check: captain edited Helm card " + $r.id + " text; reconcile it into the backlog")}] else [] end)}
                   elif $text_board_changed or $text_conflict then
                     {draft: "", wakes: (if $title_edit_wake or $body_edit_wake then [{key:("helm-card-edit:" + $r.id), payload:("check: captain edited Helm card " + $r.id + " text; reconcile it into the backlog")}] else [] end)}
                   else {draft: "", wakes: []} end) as $text
                | if $text.error != null then {phase: "error", action: $text.error}
                  else
                  ($card | fieldval("Status")) as $cur_status
                  | ($card | fieldopt("Status")) as $cur_status_id
                  | ($card | fieldval("Priority") | priority_digit) as $prio_from_board
                  | ($priority_board_changed and $prio_from_board != "") as $writeback
                  | ($cur_status_id == $dispatch_option and $status_board_changed and $d.status != $dispatch_status and $d.status != "Done") as $dispatch
                  | ($card.id + ":" + $dispatch_option) as $dispatch_fp
                  | (if $dispatch then
                       (if marker_matches($r.id; $dispatch_fp) then {marker: "", wakes: []}
                        else {marker: "request",
                              wakes: [{key: ("helm-dispatch:" + $r.id),
                                       payload: ("check: Helm dispatch request for " + $r.id + " (board item " + $card.id + ")")}]}
                        end)
                     else {marker: (if has_marker($r.id) then "remove" else "" end), wakes: []} end) as $disp
                  | ($cur_status_id + ":" + $so) as $waiting_fp
                  | (if ($dispatch | not) and $cur_status != $d.status and
                         $cur_status_id == $waiting_id and
                         ($status_board_changed or divergence_matches("status-waiting"; $r.id; $card.id; $waiting_fp)) then
                          {deferred: true, kind: "status-waiting", wakes: (if divergence_matches("status-waiting"; $r.id; $card.id; $waiting_fp) then [] else [{key: ("helm-status-waiting:" + $r.id),
                                                    payload: ("check: captain moved Helm card " + $r.id + " to Waiting on you; reconcile it into the backlog")}] end)}
                     elif ($dispatch | not) and $status_board_changed and $cur_status != $d.status then
                       (if $cur_status == "Done" and $d.status != "Done" then
                          {deferred: true, kind: "status-done", wakes: (if divergence_matches("status-done"; $r.id; $card.id; $cur_status_id) then [] else [{key: ("helm-status-done:" + $r.id),
                                                    payload: ("check: captain moved Helm card " + $r.id + " to Done while the task is live; confirm and reconcile")}] end)}
                        elif ($cur_status == "Queued" and ($d.status == "In flight" or $d.status == "Done"))
                             or ($cur_status == "In flight" and $d.status == "Done") then
                          {deferred: true, kind: "status-back", wakes: (if divergence_matches("status-back"; $r.id; $card.id; $cur_status_id) then [] else [{key: ("helm-status-back:" + $r.id),
                                                    payload: ("check: captain moved Helm card " + $r.id + " back to " + $cur_status + "; reconcile it into the backlog")}] end)}
                        else {deferred: false, kind: "", wakes: []} end)
                     else {deferred: false, wakes: []} end) as $st
                  | ( (if ($status_conflict | not) and ($dispatch | not) and ($st.deferred | not) and $status_normal and $cur_status != $d.status
                       then [{id: $status_field, name: "Status", value: $d.status, option: $so}] else [] end)
                    + (if ($card | fieldopt("Project")) != $po
                       then [{id: $project_field, name: "Project", value: $d.project, option: $po}] else [] end)
                    + (if ($card | fieldopt("Kind")) != $ko
                       then [{id: $kind_field, name: "Kind", value: $d.kind, option: $ko}] else [] end)
                    + (if ($priority_conflict | not) and ($writeback | not) and ($card | fieldopt("Priority")) != $pro
                       then [{id: $priority_field, name: "Priority", value: $d.priority, option: $pro}] else [] end) ) as $writes
                  | ($r.id + "\t" + $card.id + "\t" + $node + "\t" + (if $is_issue then "issue" else "draft" end) + "\t" +
                     (if any($writes[]; .name == "Status") then $so elif $status_conflict then $bs elif $waiting_status_changed then $cs elif $rebuilt or $status_normal or $cs == $so then $so else $bs end) + "\t" +
                     (if any($writes[]; .name == "Priority") then $pro elif $priority_conflict then $bp elif $rebuilt then $pro else (if $priority_board_changed then $cp else $pro end) end) + "\t" +
                     (if $title_write then $dt elif $title_conflict then $bt elif $rebuilt or $ct == $dt or ($title_board_changed | not) then $dt else $bt end) + "\t" +
                     (if $body_write then $db elif $body_conflict then $bb elif $rebuilt or $cb == $db or ($body_board_changed | not) then $db else $bb end) + "\t" + $now) as $cache
                  | {phase: "record",
                     action: (if $text.draft != "" or ($writes | length) > 0 then "update" else "none" end),
                     task: $r.id, item: $card.id, cache: $cache, draft: $text.draft,
                     title: (if $title_write then $d.title else $card_title end), body: (if $body_write then $d.body else $card_body end), fields: $writes,
                     wakes: ($text.wakes + $disp.wakes + $st.wakes
                       + (if $conflict_wake then [{key:("helm-card-edit:" + $r.id), payload:("check: Helm card " + $r.id + " changed on both board and backlog; reconcile the conflict")}] else [] end)),
                     divergence_ops: ((if $title_edit then [{kind:"card-edit-title", action:"keep", item:$card.id, fp:$title_fp}] elif divergence_for("card-edit-title"; $r.id) != null then [{kind:"card-edit-title", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if $body_edit then [{kind:"card-edit-body", action:"keep", item:$card.id, fp:$body_fp}] elif divergence_for("card-edit-body"; $r.id) != null then [{kind:"card-edit-body", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if $status_conflict then [{kind:"conflict-status", action:"keep", item:$card.id, fp:$status_conflict_fp}] elif divergence_for("conflict-status"; $r.id) != null then [{kind:"conflict-status", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if $priority_conflict then [{kind:"conflict-priority", action:"keep", item:$card.id, fp:$priority_conflict_fp}] elif divergence_for("conflict-priority"; $r.id) != null then [{kind:"conflict-priority", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if $title_conflict then [{kind:"conflict-title", action:"keep", item:$card.id, fp:$title_fp}] elif divergence_for("conflict-title"; $r.id) != null then [{kind:"conflict-title", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if $body_conflict then [{kind:"conflict-body", action:"keep", item:$card.id, fp:$body_fp}] elif divergence_for("conflict-body"; $r.id) != null then [{kind:"conflict-body", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if divergence_for("card-edit"; $r.id) != null then [{kind:"card-edit", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if divergence_for("conflict"; $r.id) != null then [{kind:"conflict", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if ($st.kind // "") == "status-back" then [{kind:"status-back", action:"keep", item:$card.id, fp:$cur_status_id}] elif divergence_for("status-back"; $r.id) != null then [{kind:"status-back", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if ($st.kind // "") == "status-done" then [{kind:"status-done", action:"keep", item:$card.id, fp:$cur_status_id}] elif divergence_for("status-done"; $r.id) != null then [{kind:"status-done", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if ($st.kind // "") == "status-waiting" then [{kind:"status-waiting", action:"keep", item:$card.id, fp:$waiting_fp}] elif divergence_for("status-waiting"; $r.id) != null then [{kind:"status-waiting", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if divergence_for("new-card"; $r.id) != null then [{kind:"new-card", action:"remove", item:$card.id, fp:""}] else [] end)
                       + (if divergence_for("card-deleted"; $r.id) != null then [{kind:"card-deleted", action:"remove", item:$card.id, fp:""}] else [] end)),
                     marker: $disp.marker, marker_fp: $dispatch_fp,
                     writeback: (if $writeback then $prio_from_board else "" end),
                     home: $r.home_path, note: $d.note, fp: $fp,
                     expected: ($card | snapshot),
                     ack_write: ({new: false, text: ($text.draft != ""), title: (if $title_write then $d.title else $card_title end), body: (if $body_write then $d.body else $card_body end),
                                  fields: ($writes | map({name, value, option}))} | tojson)}
                  end
              end
          end ];
    def missing_entries:
      if ($records | length) == 0 then [] else
      [ $cards_all[] as $c
        | ($c | line1) as $l1
        | (if ($l1 | test("^`.+`$")) then $l1[1:-1] else "" end) as $tid
        | if $tid == "" or ($tid | test("^[A-Za-z0-9._-]+$") | not) then
            {phase: "missing", action: "ignore", item: $c.id,
             note: ("fm-helm-sync: ignoring board item " + $c.id + ": body line 1 is not a task id")}
          elif $record_by_id[$tid] != null then empty
          elif ($c | fieldopt("Status")) == $done_id then empty
          elif $tsv_existed == "true" and $old_by_task[$tid] == null then
            {phase: "missing", action: "wake", task: $tid, item: $c.id,
             wakes: (if divergence_matches("new-card"; $tid; $c.id; $c.id) then [] else [{key: ("helm-new-card:" + $tid),
                      payload: ("check: captain added Helm card " + $tid + " with no backlog task; run intake")}]
             end), divergence_ops: [{kind:"new-card", action:"keep", item:$c.id, fp:$c.id}
             ]}
          else
            {phase: "missing", action: "close", task: $tid, item: $c.id,
             fields: [{id: $status_field, name: "Status", value: "Done", option: $done_id}],
             marker: (if has_marker($tid) then "remove" else "" end),
             expected: ($c | snapshot),
             ack_write: ({new: false, text: false, fields: [{name: "Status", value: "Done", option: $done_id}]} | tojson)}
          end ]
      end;
    def deleted_entries:
      if $tsv_existed != "true" then [] else
      [ $old_rows[] as $o
        | if $o.task == "" or $o.item == "" then empty
          elif $item_set[$o.item] then empty
          elif $line1_set["`" + $o.task + "`"] then empty
          else
            $record_by_id[$o.task] as $rec
            | if $rec == null then empty
              elif $rec.state == "done" or ($rec.hold_kind // "") == "captain" then
                {phase: "deleted", action: "retain", task: $o.task, tombstone: ($o.task + "\t" + $o.item)}
              else
                (if $rec.state == "in_flight" then
                   "the task is In flight: cancel it (stop the worker, then Done), mark it done, or was the card deleted by mistake"
                 elif ($rec.hold_reason // "") != "" or (($rec.blocked_by_ids // []) | length) > 0 then
                   "the task is blocked or held: cancel it (Done), mark it done, or was the card deleted by mistake"
                 else
                   "the task is queued: cancel it (Done), mark it done, or was the card deleted by mistake" end) as $choices
                | {phase: "deleted", action: "hold", task: $o.task, item: $o.item, home: $rec.home_path,
                   hold: ("Helm card deleted; " + $choices + "."), tombstone: ($o.task + "\t" + $o.item),
                   wakes: (if divergence_matches("card-deleted"; $o.task; $o.item; $o.item) then [] else [{key: ("helm-card-deleted:" + $o.task),
                            payload: ("check: captain deleted Helm card " + $o.task + " (" + $choices + ")")}]
                   end), divergence_ops: [{kind:"card-deleted", action:"keep", item:$o.item, fp:$o.item}]}
              end
          end ]
      end;
    (record_entries + missing_entries + deleted_entries) as $all
    | ([$all[] | select(.phase == "error")] + [$all[] | select(.phase != "error")])[]
    | entry(.)
JQ
}
