#!/usr/bin/env bash
# Behavior tests for Helm routing, the resumable move ledger, and reconciliation.
# Every GitHub fixture below uses an obviously fake owner and board number.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-helm-lib.sh"
MAP="$ROOT/bin/fm-helm-project-map.sh"
RECONCILE="$ROOT/bin/fm-helm-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-helm-project-map)

seed_home() {  # <case-dir>
  local case_dir=$1
  mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
  printf '%s\n' '{"owner":"fixture-owner","number":999}' >"$case_dir/home/config/helm.json"
  cat >"$case_dir/home/data/projects.md" <<'EOF'
# Projects
- alpha [no-mistakes] - Alpha (added 2026-09-01)
- beta [no-mistakes] - Beta (added 2026-09-01)
EOF
  cat >"$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] alpha-task - Alpha task (repo: alpha) (kind: ship) (since: 2026-09-10)
## Done
EOF
}

write_empty_board() {  # <path>
  jq -n '
    {data:{user:{projectV2:{id:"project-board",fields:{pageInfo:{hasNextPage:false},nodes:[
      {__typename:"ProjectV2SingleSelectField",id:"status-field",name:"Status",options:[
        {id:"queued-status",name:"Queued"},{id:"flight-status",name:"In flight"},
        {id:"waiting-status",name:"Waiting on you"},{id:"done-status",name:"Done"}]},
      {__typename:"ProjectV2SingleSelectField",id:"project-field",name:"Project",options:[
        {id:"alpha-project",name:"alpha"},{id:"beta-project",name:"beta"},{id:"other-project",name:"other"}]},
      {__typename:"ProjectV2SingleSelectField",id:"kind-field",name:"Kind",options:[
        {id:"ship-kind",name:"ship"},{id:"investigation-kind",name:"investigation"},{id:"decision-kind",name:"decision"}]},
      {__typename:"ProjectV2SingleSelectField",id:"priority-field",name:"Priority",options:[
        {id:"p0-priority",name:"P0"},{id:"p1-priority",name:"P1"},{id:"p2-priority",name:"P2"},
        {id:"p3-priority",name:"P3"},{id:"p4-priority",name:"P4"}]}]},
      items:{pageInfo:{hasNextPage:false},nodes:[]}}}}}' >"$1"
}

install_sync_gh() {  # <case-dir>
  local case_dir=$1 fb
  fb=$(fm_fakebin "$case_dir")
  cat >"$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'fake-gh ' >>"$FM_HELM_GH_LOG"
printf '%s' "$*" | tr '\n' ' ' >>"$FM_HELM_GH_LOG"
printf '\n' >>"$FM_HELM_GH_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' "Token scopes: 'project', 'repo'"
  exit 0
fi
if [ "${1:-}" = api ]; then
  case "$*" in
    *addProjectV2DraftIssue*)
      jq -n '{data:{addProjectV2DraftIssue:{projectItem:{id:"sync-created-item",content:{__typename:"DraftIssue",id:"sync-created-draft",title:"created",body:"created"}}}}}' ;;
    *updateProjectV2DraftIssue*|*updateProjectV2ItemFieldValue*)
      jq -n '{data:{updateProjectV2DraftIssue:{draftIssue:{id:"sync-created-draft"}},updateProjectV2ItemFieldValue:{projectV2Item:{id:"sync-created-item"}}}}' ;;
    *'node(id:'*)
      jq -n '{data:{node:{id:"sync-created-item",content:{__typename:"DraftIssue",id:"sync-created-draft",title:"created",body:"created"},fieldValues:{nodes:[]}}}}' ;;
    *) cat "$FM_HELM_BOARD_JSON" ;;
  esac
  exit 0
fi
exit 1
SH
  chmod +x "$fb/gh"
  printf '%s\n' "$fb"
}

assert_fake_tools() {  # <fake-bin>
  local fb=$1 actual
  actual=$(PATH="$fb:$PATH" command -v gh)
  [ "$actual" = "$fb/gh" ] || fail "gh is not shadowed by the fail-closed test fake: $actual"
  actual=$(PATH="$fb:$PATH" command -v gh-axi)
  [ "$actual" = "$fb/gh-axi" ] || fail "gh-axi is not shadowed by the fail-closed test fake: $actual"
}

run_sync_case() {  # <case-dir> <fakebin> <board-json>
  mkdir -p "$1/gh-config"
  GH_CONFIG_DIR="$1/gh-config" GH_HOST=127.0.0.1:9 \
    FM_HOME="$1/home" FM_ROOT_OVERRIDE="$ROOT" FM_HELM_GH_LOG="$1/gh.log" \
    FM_HELM_BOARD_JSON="$3" PATH="$2:$PATH" "$ROOT/bin/fm-helm-sync.sh" --force
}

assert_fake_log() {  # <case-dir>
  local log line
  for log in "$1"/gh.log "$1"/gh-axi.log; do
    [ -f "$log" ] || continue
    while IFS= read -r line; do
      case "$line" in
        fake-gh\ *|fake-gh-axi\ *) ;;
        *) fail "unexpected non-fake GitHub log entry: $line" ;;
      esac
    done <"$log"
  done
}

# A registered project and a second registered project may share the default
# board; only an unknown repo falls into the existing `other` field bucket.
case_dir="$TMP_ROOT/routing"
seed_home "$case_dir"
write_empty_board "$case_dir/board.json"
jq -n '{version:1,projects:{alpha:{owner:"fixture-org",number:998,state:"active"}},nudges:{}}' \
  >"$case_dir/home/data/helm-project-map.json"
jq -n '[
  {id:"alpha-task",title:"Alpha",repo:"alpha",state:"queued",kind:"ship",priority:"3",body_lines:[],home_backlog:"/tmp/home/data/backlog.md"},
  {id:"beta-task",title:"Beta",repo:"beta",state:"queued",kind:"ship",priority:"3",body_lines:[],home_backlog:"/tmp/home/data/backlog.md"},
  {id:"unknown-task",title:"Unknown",repo:"unregistered",state:"queued",kind:"ship",priority:"3",body_lines:[],home_backlog:"/tmp/home/data/backlog.md"}
]' >"$case_dir/records.json"
desired=$(FM_ROOT_OVERRIDE="$ROOT" bash -c \
  '. "$1"; jq --slurpfile routing "$2/home/data/helm-project-map.json" \
    --argjson registered "[\"alpha\",\"beta\"]" --arg default_owner fixture-owner --argjson default_number 999 \
    --argjson report_ids "[]" "$(fm_helm_desired_program)" "$3"' \
  _ "$LIB" "$case_dir" "$case_dir/records.json")
printf '%s\n' "$desired" | jq -e '
  .[0].desired.project == "alpha" and .[0].desired.board == {owner:"fixture-org",number:998} and
  .[1].desired.project == "beta" and .[1].desired.board == {owner:"fixture-owner",number:999} and
  .[2].desired.project == "other" and .[2].desired.board == {owner:"fixture-owner",number:999}
' >/dev/null || fail "dynamic project registry lookup or board routing is wrong"
pass "registered projects route to their mapped boards and unknown repos use other"

# Exercise the grouped sync itself: it must read the configured default and the
# mapped board in one run, even though only the mapped project has a card.
fb=$(install_sync_gh "$case_dir")
PATH="$fb:$PATH" command -v gh | grep -Fx "$fb/gh" >/dev/null \
  || fail "sync test did not install its fail-closed gh fake"
: >"$case_dir/gh.log"
run_sync_case "$case_dir" "$fb" "$case_dir/board.json" >/dev/null 2>&1 \
  || fail "multi-board sync exited nonzero"
grep -F 'owner=fixture-owner' "$case_dir/gh.log" >/dev/null \
  || fail "multi-board sync did not read the configured default board"
grep -F 'owner=fixture-org' "$case_dir/gh.log" >/dev/null \
  || fail "multi-board sync did not read the mapped board"
pass "sync reads and processes the default and mapped board groups"

install_gh_axi() {  # <case-dir> <missing-board:yes|no>
  local case_dir=$1 missing=${2:-no} fb
  fb=$(fm_fakebin "$case_dir")
  cat >"$fb/gh-axi" <<SH
#!/usr/bin/env bash
set -u
printf 'fake-gh-axi ' >>"\$FM_HELM_GH_AXI_LOG"
printf '%s' "\$*" | tr '\n' ' ' >>"\$FM_HELM_GH_AXI_LOG"
printf '\n' >>"\$FM_HELM_GH_AXI_LOG"
if [ "\${1:-}" = project ] && [ "\${2:-}" = view ]; then
  if [ "$missing" = yes ] && [ "\${5:-}" = fixture-org ] && [ "\${3:-}" = 998 ]; then exit 1; fi
  if [ "\${5:-}" = fixture-org ] && [ "\${3:-}" = 997 ]; then
    printf '%s\n' 'id: beta-board' 'title: Beta Board Renamed' 'url: https://github.com/orgs/fixture-org/projects/997'
  else
    printf '%s\n' 'id: helm-board' 'title: Helm Default' 'url: https://github.com/users/fixture-owner/projects/999'
  fi
  exit 0
fi
if [ "\${1:-}" = project ] && [ "\${2:-}" = field-list ]; then
  printf '%s\n' \
    'id: status-field' 'name: Status' 'options: "Queued:queued,In flight:flight,Waiting on you:waiting,Done:done"' \
    'id: priority-field' 'name: Priority' 'options: "P0:p0,P1:p1,P2:p2,P3:p3,P4:p4"' \
    'id: kind-field' 'name: Kind' 'options: "ship:ship,investigation:investigation,decision:decision"' \
    'id: project-field' 'name: Project' 'options: "other:other,alpha:alpha,beta:beta"'
  exit 0
fi
if [ "\${1:-}" = project ] && [ "\${2:-}" = item-list ]; then exit 0; fi
if [ "\${1:-}" = project ] && [ "\${2:-}" = item-delete ]; then
  [ -z "\${FM_HELM_FAIL_DELETE:-}" ] || exit 1
  exit 0
fi
if [ "\${1:-}" = api ]; then
  case "\$*" in
    *'items(first:100,after:\$cursor)'* )
      if [ -n "\${FM_HELM_DUPLICATE_SOURCE:-}" ]; then
        jq -n '{data:{node:{items:{nodes:[
          {id:"old-item",content:{__typename:"DraftIssue",id:"old-draft",body:"\`alpha-task\`\\n\\nCaptain body"}},
          {id:"duplicate-item",content:{__typename:"DraftIssue",id:"duplicate-draft",body:"\`alpha-task\`\\n\\nDuplicate body"}}
        ],pageInfo:{hasNextPage:false,endCursor:null}}}}}'
      else
        jq -n '{data:{node:{items:{nodes:[{id:"old-item",content:{__typename:"DraftIssue",id:"old-draft",body:"\`alpha-task\`\\n\\nCaptain body"}}],pageInfo:{hasNextPage:false,endCursor:null}}}}}'
      fi ;;
    *'itemId=old-item'* )
      jq -n '{data:{node:{content:{__typename:"DraftIssue",title:"Captain-edited Alpha",body:"\`alpha-task\`\\n\\nCaptain body"},fieldValues:{nodes:[
        {name:"Queued",optionId:"queued-status",field:{name:"Status"}},
        {name:"P3",optionId:"p3-priority",field:{name:"Priority"}},
        {name:"ship",optionId:"ship-kind",field:{name:"Kind"}},
        {name:"alpha",optionId:"alpha-project",field:{name:"Project"}}
      ]}}}}' ;;
    *'fields(first:100)'* )
      jq -n '{data:{node:{fields:{nodes:[
        {__typename:"ProjectV2SingleSelectField",id:"dest-status-field",name:"Status",options:[
          {id:"dest-queued-status",name:"Queued",color:"GRAY",description:""},
          {id:"dest-flight-status",name:"In flight",color:"GRAY",description:""},
          {id:"dest-waiting-status",name:"Waiting on you",color:"GRAY",description:""},
          {id:"dest-done-status",name:"Done",color:"GRAY",description:""}]},
        {__typename:"ProjectV2SingleSelectField",id:"dest-priority-field",name:"Priority",options:[
          {id:"dest-p0-priority",name:"P0",color:"GRAY",description:""},
          {id:"dest-p1-priority",name:"P1",color:"GRAY",description:""},
          {id:"dest-p2-priority",name:"P2",color:"GRAY",description:""},
          {id:"dest-p3-priority",name:"P3",color:"GRAY",description:""},
          {id:"dest-p4-priority",name:"P4",color:"GRAY",description:""}]},
        {__typename:"ProjectV2SingleSelectField",id:"dest-kind-field",name:"Kind",options:[
          {id:"dest-ship-kind",name:"ship",color:"GRAY",description:""},
          {id:"dest-investigation-kind",name:"investigation",color:"GRAY",description:""},
          {id:"dest-decision-kind",name:"decision",color:"GRAY",description:""}]},
        {__typename:"ProjectV2SingleSelectField",id:"dest-project-field",name:"Project",options:[
          {id:"dest-other-project",name:"other",color:"GRAY",description:""},
          {id:"dest-alpha-project",name:"alpha",color:"GRAY",description:""}]}
      ]}}}}' ;;
    *addProjectV2DraftIssue*) jq -n '{data:{addProjectV2DraftIssue:{projectItem:{id:"moved-item"}}}}' ;;
    *) jq -n '{data:{}}' ;;
  esac
exit 0
fi
exit 1
SH
  cat >"$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
  printf 'fake-gh ' >>"$FM_HELM_GH_LOG"
  printf '%s' "$*" | tr '\n' ' ' >>"$FM_HELM_GH_LOG"
  printf '\n' >>"$FM_HELM_GH_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' "Token scopes: 'project', 'repo'"
  exit 0
fi
if [ "${1:-}" = api ]; then
  cat "$FM_HELM_BOARD_JSON"
  exit 0
fi
exit 1
SH
  chmod +x "$fb/gh-axi"
  chmod +x "$fb/gh"
  printf '%s\n' "$fb"
}

# A confirmed move records add/delete boundaries and finishes with the cache on
# the destination board. The final sync is faked only at the GitHub boundary.
case_dir="$TMP_ROOT/move"
seed_home "$case_dir"
write_empty_board "$case_dir/board.json"
title_b64=$(printf '%s' 'Alpha task' | base64 | tr -d '\n')
# shellcheck disable=SC2016 # backticks are card-body literals, not expansions.
body_b64=$(printf '%s' '`alpha-task`\n\nBody' | base64 | tr -d '\n')
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  alpha-task old-item old-draft draft queued-status p3-priority "$title_b64" "$body_b64" 1 fixture-owner 999 \
  >"$case_dir/home/state/helm-cards.tsv"
jq -n '{version:1,projects:{alpha:{owner:"fixture-owner",number:999,title:"Alpha",state:"active",linked_at:"2026-09-10T00:00:00Z",move:null,orphan_hold_task:null}},nudges:{}}' \
  >"$case_dir/home/data/helm-project-map.json"
fb=$(install_gh_axi "$case_dir" no)
assert_fake_tools "$fb"
mkdir -p "$case_dir/gh-config"
FM_HELM_FAIL_DELETE=1 FM_HELM_GH_AXI_LOG="$case_dir/gh-axi.log" FM_HELM_GH_LOG="$case_dir/gh.log" \
  GH_CONFIG_DIR="$case_dir/gh-config" GH_HOST=127.0.0.1:9 FM_HELM_BOARD_JSON="$case_dir/board.json" PATH="$fb:$PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  "$MAP" move alpha --existing fixture-org/998 --yes >/dev/null 2>&1 \
  || fail "confirmed move exited nonzero"
grep -F 'api graphql' "$case_dir/gh-axi.log" >/dev/null \
  || fail "move did not add the destination item"
grep -F 'title=Captain-edited Alpha' "$case_dir/gh-axi.log" >/dev/null \
  || fail "move did not copy the source card's current title"
# shellcheck disable=SC2016 # backticks are card-body literals, not expansions.
grep -F 'body=`alpha-task`' "$case_dir/gh-axi.log" >/dev/null \
  || fail "move did not copy the source card's current body"
grep -F 'updateProjectV2ItemFieldValue' "$case_dir/gh-axi.log" >/dev/null \
  || fail "move did not copy current field values to the destination item"
grep -F $'alpha-task\tfixture-owner\t999\told-item\tfixture-org\t998\tmoved-item\tdest-ready' \
  "$case_dir/home/state/helm-moves.tsv" >/dev/null \
  || fail "a failed source delete did not leave a resumable destination-ready ledger row"
jq -e '.projects.alpha.state == "migrating" and .projects.alpha.move.confirmed == true and .projects.alpha.number == 998' \
  "$case_dir/home/data/helm-project-map.json" >/dev/null \
  || fail "a partial move did not retain its confirmed migration mapping"

FM_HELM_GH_AXI_LOG="$case_dir/gh-axi.log" FM_HELM_GH_LOG="$case_dir/gh.log" \
  GH_CONFIG_DIR="$case_dir/gh-config" GH_HOST=127.0.0.1:9 FM_HELM_BOARD_JSON="$case_dir/board.json" PATH="$fb:$PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  "$MAP" move alpha --yes >/dev/null 2>&1 \
  || fail "resuming the confirmed move exited nonzero"
grep -F 'item-delete 999 --owner fixture-owner --id old-item' "$case_dir/gh-axi.log" >/dev/null \
  || fail "resuming the move did not delete the source item"
jq -e '.projects.alpha.state == "active" and .projects.alpha.move == null and .projects.alpha.number == 998' \
  "$case_dir/home/data/helm-project-map.json" >/dev/null \
  || fail "move did not finish the routing mapping"
grep -F $'alpha-task\tmoved-item\told-draft' "$case_dir/home/state/helm-cards.tsv" >/dev/null \
  || fail "move did not update the cache to the destination item"
grep -F $'alpha-task\tfixture-owner\t999\told-item\tfixture-org\t998\tmoved-item\tcomplete' \
  "$case_dir/home/state/helm-moves.tsv" >/dev/null \
  || fail "move ledger did not retain its complete add/delete history"
pass "confirmed moves preserve card history in the resumable ledger"

# A rebuilt cache must not make a confirmed move overlook source-board cards.
case_dir="$TMP_ROOT/cacheless-move"
seed_home "$case_dir"
write_empty_board "$case_dir/board.json"
jq -n '{version:1,projects:{alpha:{owner:"fixture-owner",number:999,title:"Alpha",state:"active",linked_at:"2026-09-10T00:00:00Z",move:null,orphan_hold_task:null}},nudges:{}}' \
  >"$case_dir/home/data/helm-project-map.json"
fb=$(install_gh_axi "$case_dir" no)
assert_fake_tools "$fb"
mkdir -p "$case_dir/gh-config"
FM_HELM_FAIL_DELETE=1 FM_HELM_GH_AXI_LOG="$case_dir/gh-axi.log" FM_HELM_GH_LOG="$case_dir/gh.log" \
  GH_CONFIG_DIR="$case_dir/gh-config" GH_HOST=127.0.0.1:9 FM_HELM_BOARD_JSON="$case_dir/board.json" PATH="$fb:$PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  "$MAP" move alpha --existing fixture-org/998 --yes >/dev/null 2>&1 \
  || fail "cacheless confirmed move exited nonzero"
grep -F $'alpha-task\tfixture-owner\t999\told-item\tfixture-org\t998\tmoved-item\tdest-ready' \
  "$case_dir/home/state/helm-moves.tsv" >/dev/null \
  || fail "cacheless move did not discover and stage the source card"
grep -F $'alpha-task\told-item\told-draft\tdraft' "$case_dir/home/state/helm-cards.tsv" >/dev/null \
  || fail "cacheless move did not rebuild the source card identity"
pass "cacheless moves discover live source cards"

case_dir="$TMP_ROOT/cacheless-duplicate-move"
seed_home "$case_dir"
write_empty_board "$case_dir/board.json"
jq -n '{version:1,projects:{alpha:{owner:"fixture-owner",number:999,title:"Alpha",state:"active",linked_at:"2026-09-10T00:00:00Z",move:null,orphan_hold_task:null}},nudges:{}}' \
  >"$case_dir/home/data/helm-project-map.json"
fb=$(install_gh_axi "$case_dir" no)
assert_fake_tools "$fb"
mkdir -p "$case_dir/gh-config"
if FM_HELM_DUPLICATE_SOURCE=1 FM_HELM_GH_AXI_LOG="$case_dir/gh-axi.log" FM_HELM_GH_LOG="$case_dir/gh.log" \
  GH_CONFIG_DIR="$case_dir/gh-config" GH_HOST=127.0.0.1:9 FM_HELM_BOARD_JSON="$case_dir/board.json" PATH="$fb:$PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  "$MAP" move alpha --existing fixture-org/998 --yes >/dev/null 2>&1; then
  fail "cacheless duplicate source move unexpectedly succeeded"
fi
jq -e '.projects.alpha.state == "active" and .projects.alpha.number == 999' \
  "$case_dir/home/data/helm-project-map.json" >/dev/null \
  || fail "duplicate source move changed the routing mapping"
[ ! -e "$case_dir/home/state/helm-cards.tsv" ] \
  || fail "duplicate source move rebuilt a partial card cache"
[ ! -e "$case_dir/home/state/helm-moves.tsv" ] \
  || fail "duplicate source move published a partial move ledger"
pass "cacheless moves reject duplicate source cards"

# Linking a second project onto a board another project already linked must
# add the missing Project option, not refuse the board as "incomplete"
# (spec decision 6: several mapping entries sharing one board is normal).
case_dir="$TMP_ROOT/shared-board-link"
seed_home "$case_dir"
write_empty_board "$case_dir/board.json"
jq -n '{version:1,projects:{alpha:{owner:"fixture-org",number:998,title:"Shared Board",state:"active",linked_at:"2026-09-10T00:00:00Z",move:null,orphan_hold_task:null}},nudges:{}}' \
  >"$case_dir/home/data/helm-project-map.json"
fb=$(fm_fakebin "$case_dir")
cat >"$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf 'fake-gh-axi ' >>"$FM_HELM_GH_AXI_LOG"
printf '%s' "$*" | tr '\n' ' ' >>"$FM_HELM_GH_AXI_LOG"
printf '\n' >>"$FM_HELM_GH_AXI_LOG"
if [ "${1:-}" = project ] && [ "${2:-}" = view ]; then
  printf '%s\n' 'id: shared-board' 'title: Shared Board' 'url: https://github.com/orgs/fixture-org/projects/998'
  exit 0
fi
if [ "${1:-}" = project ] && [ "${2:-}" = item-list ]; then exit 0; fi
if [ "${1:-}" = api ]; then
  case "$*" in
    *'node(id:$projectId)'*)
      jq -n '{data:{node:{fields:{nodes:[
        {__typename:"ProjectV2SingleSelectField",id:"status-field",name:"Status",options:[
          {id:"queued-status",name:"Queued",color:"GRAY",description:""},
          {id:"flight-status",name:"In flight",color:"GRAY",description:""},
          {id:"waiting-status",name:"Waiting on you",color:"GRAY",description:""},
          {id:"done-status",name:"Done",color:"GRAY",description:""}]},
        {__typename:"ProjectV2SingleSelectField",id:"priority-field",name:"Priority",options:[
          {id:"p0-priority",name:"P0",color:"GRAY",description:""},{id:"p1-priority",name:"P1",color:"GRAY",description:""},
          {id:"p2-priority",name:"P2",color:"GRAY",description:""},{id:"p3-priority",name:"P3",color:"GRAY",description:""},
          {id:"p4-priority",name:"P4",color:"GRAY",description:""}]},
        {__typename:"ProjectV2SingleSelectField",id:"kind-field",name:"Kind",options:[
          {id:"ship-kind",name:"ship",color:"GRAY",description:""},{id:"investigation-kind",name:"investigation",color:"GRAY",description:""},
          {id:"decision-kind",name:"decision",color:"GRAY",description:""}]},
        {__typename:"ProjectV2SingleSelectField",id:"project-field",name:"Project",options:[
          {id:"other-project",name:"other",color:"GRAY",description:""},
          {id:"alpha-project",name:"alpha",color:"GRAY",description:""}]}
      ]}}}}' ;;
    *createProjectV2Field*|*updateProjectV2Field*)
      declare -A opt_name=()
      for arg in "$@"; do
        case "$arg" in
          name[0-9]*=*) idx=${arg%%=*}; idx=${idx#name}; opt_name[$idx]=${arg#*=} ;;
        esac
      done
      options='[]'
      for idx in "${!opt_name[@]}"; do
        options=$(jq -c --arg name "${opt_name[$idx]}" '. + [{name:$name}]' <<<"$options")
      done
      jq -n --argjson options "$options" '{data:{updateProjectV2Field:{projectV2Field:{options:$options}}}}' ;;
    *) jq -n '{data:{}}' ;;
  esac
  exit 0
fi
exit 1
SH
cat >"$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'fake-gh ' >>"$FM_HELM_GH_LOG"
printf '%s' "$*" | tr '\n' ' ' >>"$FM_HELM_GH_LOG"
printf '\n' >>"$FM_HELM_GH_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf "%s\n" "Token scopes: 'project', 'repo'"
  exit 0
fi
if [ "${1:-}" = api ]; then cat "$FM_HELM_BOARD_JSON"; exit 0; fi
exit 1
SH
chmod +x "$fb/gh-axi" "$fb/gh"
assert_fake_tools "$fb"
mkdir -p "$case_dir/gh-config"
: >"$case_dir/gh-axi.log"; : >"$case_dir/gh.log"
FM_HELM_GH_AXI_LOG="$case_dir/gh-axi.log" FM_HELM_GH_LOG="$case_dir/gh.log" \
  GH_CONFIG_DIR="$case_dir/gh-config" GH_HOST=127.0.0.1:9 FM_HELM_BOARD_JSON="$case_dir/board.json" PATH="$fb:$PATH" \
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  "$MAP" link beta --existing fixture-org/998 >/dev/null 2>&1 \
  || fail "linking a second project onto an already-linked board exited nonzero"
grep -F 'updateProjectV2Field' "$case_dir/gh-axi.log" >/dev/null \
  || fail "link did not provision the missing Project option on the shared board"
grep -F 'name0=other' "$case_dir/gh-axi.log" >/dev/null \
  || fail "provisioning the shared board's Project field dropped its existing 'other' option"
jq -e '.projects.alpha.number == 998 and .projects.beta.number == 998 and .projects.beta.state == "active"' \
  "$case_dir/home/data/helm-project-map.json" >/dev/null \
  || fail "a second project did not join the first project's board in the mapping"
pass "linking a second project onto an already-linked board provisions its option instead of refusing"

# Reconciliation covers two sides of a broken mapping through the existing
# captain-hold path: a board that disappeared and a local project that left the
# registry. It also refreshes title drift on another board in the same pass.
case_dir="$TMP_ROOT/reconcile"
seed_home "$case_dir"
write_empty_board "$case_dir/board.json"
jq -n '{version:1,projects:{alpha:{owner:"fixture-org",number:998,title:"Alpha Board",state:"active",linked_at:"2026-09-10T00:00:00Z",move:null,orphan_hold_task:null},beta:{owner:"fixture-org",number:997,title:"Old Beta Title",state:"active",linked_at:"2026-09-10T00:00:00Z",move:null,orphan_hold_task:null},ghost:{owner:"fixture-owner",number:999,title:"Ghost Board",state:"active",linked_at:"2026-09-10T00:00:00Z",move:null,orphan_hold_task:null}},nudges:{}}' \
  >"$case_dir/home/data/helm-project-map.json"
fb=$(install_gh_axi "$case_dir" yes)
assert_fake_tools "$fb"
mkdir -p "$case_dir/holds"
mkdir -p "$case_dir/gh-config"
cat >"$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '%s\n' '0.2.5' ;;
  update) [ "${2:-}" = --help ] && printf '%s\n' '--archive-body' ;;
  mv) [ "${2:-}" = --help ] && printf '%s\n' 'tasks-axi mv <id> [<id>...]' ;;
  hold)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' '--kind captain'
    else
      : >"$FM_HELM_HOLD_DIR/${2:-unknown}"
    fi
    ;;
  add)
    file=
    previous=
    for arg in "$@"; do
      [ "$previous" = --file ] && file=$arg
      previous=$arg
    done
    [ -z "$file" ] || printf '%s\n' "- [ ] ${2:-unknown} - ${3:-hold} (repo: fixture-firstmate) (kind: decision) (since: 2026-09-16)" >>"$file"
    : >"$FM_HELM_HOLD_DIR/${2:-unknown}"
    ;;
  show)
    if [ -e "$FM_HELM_HOLD_DIR/${2:-unknown}" ]; then
      printf '%s\n' '  state: queued' '  held: yes' '  hold_kind: captain' '  title: Helm routing hold' '  body: -'
    else
      exit 1
    fi
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$fb/tasks-axi"
FM_HELM_GH_AXI_LOG="$case_dir/gh-axi.log" FM_HELM_GH_LOG="$case_dir/gh.log" \
  GH_CONFIG_DIR="$case_dir/gh-config" GH_HOST=127.0.0.1:9 FM_HELM_HOLD_DIR="$case_dir/holds" FM_HELM_BOARD_JSON="$case_dir/board.json" PATH="$fb:$PATH" \
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" "$RECONCILE" --force >"$case_dir/reconcile.out" 2>&1 \
  || fail "cross-board reconciliation exited nonzero"
jq -e '
  .projects.alpha.orphan_hold_task == "helm-map-alpha" and
  .projects.ghost.orphan_hold_task == "helm-map-ghost" and
  .projects.beta.title == "Beta Board Renamed"
' "$case_dir/home/data/helm-project-map.json" >/dev/null \
  || fail "cross-board orphan or title drift was not reconciled"
grep -F 'helm-map-alpha' "$case_dir/home/data/backlog.md" >/dev/null \
  || fail "missing mapped board did not use the existing captain-hold path"
grep -F 'helm-map-ghost' "$case_dir/home/data/backlog.md" >/dev/null \
  || fail "unregistered mapped project did not use the existing captain-hold path"
pass "cross-board orphan and drift reconciliation uses captain holds"
for case_dir in "$TMP_ROOT"/*; do
  [ -d "$case_dir" ] || continue
  assert_fake_log "$case_dir"
done
pass "all Helm routing tests used only the fail-closed GitHub fakes"
