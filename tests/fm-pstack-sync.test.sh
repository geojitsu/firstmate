#!/usr/bin/env bash
# Behavior tests for the pinned pstack importer and generated brief catalog.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pstack-sync)
SOURCE="$TMP_ROOT/source"
DEST="$TMP_ROOT/dest"
CONFIG="$TMP_ROOT/fixture-lock.json"
mkdir -p "$SOURCE/pstack/skills/fixture/references" "$SOURCE/pstack/skills/excluded" "$DEST"
mkdir -p "$DEST/.agents/skills/principle-future-principle"
printf '%s\n' '---' 'name: principle-future-principle' 'description: fixture target' '---' \
  > "$DEST/.agents/skills/principle-future-principle/SKILL.md"

PIN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream"]["commit"])' "$ROOT/bin/fm-pstack-sync.lock.json")
printf '%s\n' "$PIN" > "$SOURCE/.pstack-source-commit"
cat > "$SOURCE/pstack/skills/fixture/SKILL.md" <<'EOF'
---
name: fixture
description: A small fixture skill used by the executable importer tests.
disable-model-invocation: true
model: cursor-test-model
---

# Fixture

See the **future-principle** principle skill.
The plain phrase future-principle is not a skill reference.
Use `per future-principle` when naming that principle in a code example.
The body is local fixture content, not an assertion of upstream prose.
EOF
printf '%s\n' '# Fixture reference' 'A reference file must be copied.' \
  'See the **future-principle** principle skill.' \
  > "$SOURCE/pstack/skills/fixture/references/note.md"
printf '%s\n' 'excluded' > "$SOURCE/pstack/skills/excluded/SKILL.md"

python3 - "$ROOT/bin/fm-pstack-sync.lock.json" "$CONFIG" <<'PY'
import json
import sys

source, destination = sys.argv[1:]
lock = json.load(open(source, encoding="utf-8"))
lock["allowlist"] = [{
    "name": "fixture",
    "tier": 2,
    "source": "skills/fixture",
    "include": ["SKILL.md", "references/**"],
}]
lock["excluded_components"] = ["excluded"]
lock["replacements"] = []
lock["post_replacements"] = []
lock["compatibility"]["skill_notes"] = {}
lock["index"] = {
    "path": "generated-index.md",
    "preamble": ["Fixture catalog."],
    "groups": [{"title": "Fixture", "skills": ["fixture"]}],
    "footer": [],
    "brief_budget": {"baseline_words": 10, "max_words": 100, "catalog_max_words": 50},
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(lock, handle, indent=2)
    handle.write("\n")
PY

run_sync() {
  "$ROOT/bin/fm-pstack-sync.sh" --root "$DEST" --config "$CONFIG" --source "$SOURCE" "$@"
}

test_import_converts_frontmatter_and_allowlist() {
  local out rc
  out=$(run_sync 2>&1); rc=$?
  expect_code 0 "$rc" "fixture import should succeed: $out"
  assert_present "$DEST/.agents/skills/fixture/SKILL.md" "allowlisted skill was not imported"
  assert_present "$DEST/.agents/skills/fixture/references/note.md" "allowlisted reference was not imported"
  assert_grep '**principle-future-principle**' "$DEST/.agents/skills/fixture/references/note.md" \
    "principle skill reference in references was not renamed"
  assert_absent "$DEST/.agents/skills/excluded/SKILL.md" "excluded skill was imported"
  assert_grep 'user-invocable: false' "$DEST/.agents/skills/fixture/SKILL.md" \
    "Cursor invocation frontmatter was not converted"
  assert_grep 'internal: true' "$DEST/.agents/skills/fixture/SKILL.md" \
    "internal Firstmate metadata was not added"
  assert_grep '**principle-future-principle**' "$DEST/.agents/skills/fixture/SKILL.md" \
    "principle skill reference was not renamed"
  assert_grep 'plain phrase future-principle' "$DEST/.agents/skills/fixture/SKILL.md" \
    "ordinary prose was rewritten as a skill reference"
  assert_grep 'per principle-future-principle' "$DEST/.agents/skills/fixture/SKILL.md" \
    "plain skill reference was not renamed"
  assert_no_grep 'disable-model-invocation' "$DEST/.agents/skills/fixture/SKILL.md" \
    "Cursor-only frontmatter was retained"
  assert_no_grep 'cursor-test-model' "$DEST/.agents/skills/fixture/SKILL.md" \
    "Cursor-only model configuration was retained"
  assert_grep 'fixture' "$DEST/generated-index.md" "generated catalog omitted the imported skill"
  assert_no_grep 'The body is local fixture content' "$DEST/generated-index.md" \
    "generated catalog injected the full skill body"
  mkdir -p "$DEST/.agents/skills/omitted"
  printf '%s\n' 'keep this local skill' > "$DEST/.agents/skills/omitted/SKILL.md"
  run_sync --check >/dev/null 2>&1 || fail "check should ignore omitted local skills"
  assert_present "$DEST/.agents/skills/omitted/SKILL.md" "sync deleted an omitted local skill"
  pass "fm-pstack-sync: allowlist and frontmatter conversion work"
}

test_pin_and_conflict_guards() {
  local out rc original_hash rerun_hash
  printf '%s\n' 'wrong-pin' > "$SOURCE/.pstack-source-commit"
  out=$(run_sync 2>&1); rc=$?
  expect_code 1 "$rc" "wrong source pin must fail: $out"
  assert_contains "$out" "is not locked commit" "wrong source pin error was not explicit"
  printf '%s\n' "$PIN" > "$SOURCE/.pstack-source-commit"

  original_hash=$(find "$DEST" -type f -print0 | sort -z | xargs -0 sha256sum)
  out=$(run_sync --check 2>&1); rc=$?
  expect_code 0 "$rc" "idempotent check should pass: $out"
  rerun_hash=$(find "$DEST" -type f -print0 | sort -z | xargs -0 sha256sum)
  [ "$original_hash" = "$rerun_hash" ] || fail "same pinned sync changed generated bytes"

  printf '%s\n' 'local divergent adaptation' >> "$DEST/.agents/skills/fixture/SKILL.md"
  out=$(run_sync 2>&1); rc=$?
  expect_code 2 "$rc" "divergent generated output must stop: $out"
  assert_contains "$out" "review the diff" "conflict report did not request review"
  assert_grep 'local divergent adaptation' "$DEST/.agents/skills/fixture/SKILL.md" \
    "conflict detection overwrote the local adaptation"
  out=$(run_sync --accept-reviewed 2>&1); rc=$?
  expect_code 0 "$rc" "explicit reviewed acceptance should resolve the conflict: $out"
  assert_no_grep 'local divergent adaptation' "$DEST/.agents/skills/fixture/SKILL.md" \
    "reviewed acceptance did not regenerate the output"
  pass "fm-pstack-sync: pin, idempotence, and conflict guards work"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-pstack-sync.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "sync tool must parse: $out"
  [ -z "$out" ] || fail "sync tool parse emitted unexpected output: $out"
  pass "fm-pstack-sync: shell wrapper parses"
}

test_no_dangling_skill_references() {
  local out rc
  out=$(python3 - "$ROOT" 2>&1 <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
skills_root = root / ".agents" / "skills"
skill_names = {path.parent.name for path in skills_root.glob("*/SKILL.md")}
bold_skill = re.compile(r"\*\*(?P<name>[a-z0-9]+(?:-[a-z0-9]+)*)\*\*")
errors = []

files = sorted(
    path
    for path in skills_root.rglob("*.md")
    if path.name == "SKILL.md" or "references" in path.parts
)
for path in files:
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line_has_skill_context = re.search(r"\b(?:principle\s+)?skills?\b", line)
        if not line_has_skill_context:
            continue
        for match in bold_skill.finditer(line):
            name = match.group("name")
            follows_skill = re.match(r"\s+(?:principle\s+)?skills?\b", line[match.end():])
            grouped_principle_reference = "-" in name and "principle skill" in line
            if name not in skill_names and (follows_skill or grouped_principle_reference):
                errors.append(f"{path}:{line_number}: unresolved skill reference: {name}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
  ); rc=$?
  expect_code 0 "$rc" "all skill references must resolve: $out"
  pass "fm-pstack-sync: skill references resolve on disk"
}

test_script_parses
test_import_converts_frontmatter_and_allowlist
test_pin_and_conflict_guards
test_no_dangling_skill_references
