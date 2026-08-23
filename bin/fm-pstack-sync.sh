#!/usr/bin/env bash
# Import the pinned pstack skills and regenerate the compact engineering-craft
# catalog used by bin/fm-brief.sh.
#
# Usage:
#   fm-pstack-sync.sh                  fetch the locked source and synchronize
#   fm-pstack-sync.sh --source <dir>   synchronize from a verified local source
#   fm-pstack-sync.sh --check          verify generated outputs without writing
#   fm-pstack-sync.sh --accept-reviewed accept reviewed generated-file changes
#   fm-pstack-sync.sh --config <path>  use an explicit lock file
#   fm-pstack-sync.sh --root <path>    write into an explicit repository root
#   fm-pstack-sync.sh --help           print this usage
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(printenv FM_ROOT_OVERRIDE 2>/dev/null || true)
[ -n "$ROOT" ] || ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
CONFIG=$(printenv FM_PSTACK_SYNC_CONFIG 2>/dev/null || true)
[ -n "$CONFIG" ] || CONFIG=$SCRIPT_DIR/fm-pstack-sync.lock.json
SOURCE=
CHECK=0
ACCEPT=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --source) [ "$#" -ge 2 ] || { echo "error: --source requires a directory" >&2; exit 2; }; SOURCE=$2; shift 2 ;;
    --config) [ "$#" -ge 2 ] || { echo "error: --config requires a path" >&2; exit 2; }; CONFIG=$2; shift 2 ;;
    --root) [ "$#" -ge 2 ] || { echo "error: --root requires a directory" >&2; exit 2; }; ROOT=$2; shift 2 ;;
    --check) CHECK=1; shift ;;
    --accept-reviewed) ACCEPT=1; shift ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$CHECK" -eq 0 ] || [ "$ACCEPT" -eq 0 ] || {
  echo "error: --check and --accept-reviewed cannot be combined" >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || {
  echo "error: fm-pstack-sync.sh requires python3" >&2
  exit 1
}

exec python3 - "$ROOT" "$CONFIG" "$SOURCE" "$CHECK" "$ACCEPT" <<'PY'
from __future__ import annotations

import ast
from contextlib import contextmanager
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(sys.argv[1]).resolve()
CONFIG_ARG = Path(sys.argv[2])
CONFIG = CONFIG_ARG if CONFIG_ARG.is_absolute() else (ROOT / CONFIG_ARG).resolve()
SOURCE_ARG = sys.argv[3]
CHECK = sys.argv[4] == "1"
ACCEPT = sys.argv[5] == "1"


def fail(message: str) -> None:
    print(f"fm-pstack-sync: error: {message}", file=sys.stderr)
    raise SystemExit(1)


def git_output(source: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(source), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        fail(f"git source verification failed: {detail.strip()}")
    return result.stdout.strip()


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read JSON config {path}: {exc}")


def validate_config(config: dict) -> None:
    if config.get("schema") != 1:
        fail("unsupported lock schema")
    upstream = config.get("upstream")
    if not isinstance(upstream, dict):
        fail("lock is missing upstream configuration")
    commit = upstream.get("commit", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail("upstream.commit must be a 40-character lowercase commit pin")
    if not upstream.get("repository") or not upstream.get("source_root"):
        fail("upstream.repository and upstream.source_root are required")
    allowlist = config.get("allowlist")
    if not isinstance(allowlist, list) or not allowlist:
        fail("allowlist must contain at least one skill")
    names = set()
    for entry in allowlist:
        if not isinstance(entry, dict) or not entry.get("name") or not entry.get("source"):
            fail("every allowlist entry needs name and source")
        name = entry["name"]
        if name in names:
            fail(f"duplicate allowlist skill: {name}")
        names.add(name)
        if Path(entry["source"]).is_absolute() or ".." in Path(entry["source"]).parts:
            fail(f"allowlist source escapes upstream root: {name}")
        include = entry.get("include")
        if not isinstance(include, list) or not include:
            fail(f"allowlist entry has no include patterns: {name}")
    frontmatter = config.get("frontmatter", {})
    if not isinstance(frontmatter.get("remove_keys"), list) or not isinstance(frontmatter.get("set"), dict):
        fail("frontmatter policy must define remove_keys and set")
    index = config.get("index", {})
    if not index.get("path") or not isinstance(index.get("groups"), list):
        fail("compatibility.index must define path and groups")
    listed = {skill for group in index["groups"] for skill in group.get("skills", [])}
    missing = names - listed
    if missing:
        fail(f"allowlisted skills missing from generated index: {', '.join(sorted(missing))}")
    budget = index.get("brief_budget", {})
    if not all(isinstance(budget.get(key), int) for key in ("baseline_words", "max_words", "catalog_max_words")):
        fail("compatibility.index.brief_budget must contain integer limits")


@contextmanager
def source_context(config: dict):
    upstream = config["upstream"]
    if SOURCE_ARG:
        source = Path(SOURCE_ARG).expanduser()
        if not source.is_absolute():
            source = (ROOT / source).resolve()
        else:
            source = source.resolve()
        if not source.is_dir():
            fail(f"source directory does not exist: {source}")
        if source == ROOT:
            fail("source directory cannot be the destination repository root")
        if (source / ".git").exists():
            actual = git_output(source, "rev-parse", "HEAD")
        else:
            marker = source / ".pstack-source-commit"
            if not marker.is_file():
                fail("--source requires a git checkout or .pstack-source-commit marker")
            actual = marker.read_text(encoding="utf-8").strip()
        if actual != upstream["commit"]:
            fail(f"source commit {actual or '<empty>'} is not locked commit {upstream['commit']}")
        yield source
        return

    temp = Path(tempfile.mkdtemp(prefix=".fm-pstack-sync.", dir=ROOT))
    source = temp / "source"
    try:
        subprocess.run(["git", "init", "--quiet", str(source)], check=True)
        subprocess.run(
            ["git", "-C", str(source), "fetch", "--quiet", "--depth", "1", upstream["repository"], upstream["commit"]],
            check=True,
        )
        subprocess.run(["git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD"], check=True)
        actual = git_output(source, "rev-parse", "HEAD")
        if actual != upstream["commit"]:
            fail(f"fetched commit {actual} is not locked commit {upstream['commit']}")
        yield source
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        fail(f"could not fetch locked source: {detail.strip()}")
    finally:
        shutil.rmtree(temp, ignore_errors=True)


def yaml_scalar(value: str) -> str:
    value = value.strip()
    if value.startswith(('"', "'")):
        try:
            return str(ast.literal_eval(value))
        except (SyntaxError, ValueError):
            return value[1:-1]
    return value


def frontmatter(text: str) -> tuple[dict, str]:
    if not text.startswith("---\n"):
        fail("allowlisted SKILL.md is missing YAML frontmatter")
    end = text.find("\n---\n", 4)
    if end == -1:
        fail("allowlisted SKILL.md has unterminated YAML frontmatter")
    raw = text[4:end]
    body = text[end + len("\n---\n"):]
    values: dict[str, str] = {}
    lines = raw.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        match = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if not match:
            index += 1
            continue
        key, value = match.groups()
        if value in {">", ">-", "|", "|-"}:
            chunks = []
            index += 1
            while index < len(lines) and (lines[index].startswith(" ") or not lines[index]):
                chunks.append(lines[index].strip())
                index += 1
            values[key] = " ".join(chunk for chunk in chunks if chunk)
            continue
        values[key] = yaml_scalar(value)
        index += 1
    if not values.get("name") or not values.get("description"):
        fail("allowlisted SKILL.md frontmatter needs name and description")
    return values, body


def matches(path: str, pattern: str) -> bool:
    if pattern.endswith("/**"):
        return path.startswith(pattern[:-3].rstrip("/") + "/")
    return fnmatch.fnmatchcase(path, pattern)


SKILL_TOKEN = r"[a-z0-9]+(?:-[a-z0-9]+)*"
SKILL_REFERENCE = re.compile(
    rf"\*\*(?P<bold>{SKILL_TOKEN})\*\*"
    rf"|(?P<per>\bper\s+)(?P<plain>{SKILL_TOKEN})(?=\b)"
)


def principle_aliases(config: dict) -> dict[str, str]:
    imported = {entry["name"] for entry in config["allowlist"]}
    skills_root = ROOT / ".agents" / "skills"
    local = {
        path.name
        for path in (skills_root.iterdir() if skills_root.is_dir() else ())
        if path.is_dir() and (path / "SKILL.md").is_file()
    }
    aliases = {}
    for skill in sorted(local):
        if not skill.startswith("principle-"):
            continue
        original = skill.removeprefix("principle-")
        if original not in imported and original not in local:
            aliases[original] = skill
    return aliases


def rewrite_skill_references(text: str, aliases: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group("bold") or match.group("plain")
        replacement = aliases.get(name)
        if replacement is None:
            return match.group(0)
        if match.group("bold") is not None:
            return f"**{replacement}**"
        return f"{match.group('per')}{replacement}"

    return SKILL_REFERENCE.sub(replace, text)


def replacement_text(text: str, config: dict, aliases: dict[str, str]) -> str:
    replacements = sorted(config.get("replacements", []), key=lambda item: len(item.get("pattern", "")), reverse=True)
    for item in replacements:
        pattern = item.get("pattern")
        if not isinstance(pattern, str) or not isinstance(item.get("replacement"), str):
            fail("each compatibility replacement needs string pattern and replacement")
        text = text.replace(pattern, item["replacement"])
    for item in config.get("post_replacements", []):
        text = text.replace(item["pattern"], item["replacement"])
    return rewrite_skill_references(text, aliases)


def insert_boundary(body: str, skill: str, config: dict) -> str:
    compatibility = config["compatibility"]
    block = ["## Firstmate compatibility", "", compatibility["boundary"]]
    note = compatibility.get("skill_notes", {}).get(skill)
    if note:
        block.extend(["", note])
    block.extend(["", ""])
    lines = body.splitlines()
    heading = next((index for index, line in enumerate(lines) if line.startswith("# ")), None)
    if heading is None:
        return "\n".join(block + lines).rstrip() + "\n"
    insert_at = heading + 1
    while insert_at < len(lines) and not lines[insert_at].strip():
        insert_at += 1
    result = lines[:insert_at] + [""] + block + lines[insert_at:]
    return "\n".join(result).rstrip() + "\n"
def transformed(
    path: Path,
    relative: str,
    skill: str,
    config: dict,
    aliases: dict[str, str],
) -> tuple[bytes, str | None]:
    text = path.read_text(encoding="utf-8")
    metadata = None
    if relative == "SKILL.md":
        metadata, body = frontmatter(text)
        body = replacement_text(body, config, aliases)
        body = insert_boundary(body, skill, config)
        policy = config["frontmatter"]
        removed = set(policy["remove_keys"])
        cleaned = {key: value for key, value in metadata.items() if key not in removed}
        cleaned["name"] = replacement_text(cleaned["name"], config, aliases)
        cleaned["description"] = replacement_text(cleaned["description"], config, aliases)
        description = cleaned["description"]
        frontmatter_lines = [
            "---",
            f"name: {json.dumps(cleaned['name'], ensure_ascii=False)}",
            f"description: {json.dumps(cleaned['description'], ensure_ascii=False)}",
        ]
        for key, value in cleaned.items():
            if key in {"name", "description"} or key in policy["set"]:
                continue
            frontmatter_lines.append(f"{key}: {json.dumps(value, ensure_ascii=False)}")
        for key, value in policy["set"].items():
            parts = key.split(".")
            if len(parts) == 1:
                frontmatter_lines.append(f"{key}: {json.dumps(value, ensure_ascii=False)}")
            elif len(parts) == 2:
                frontmatter_lines.append(f"{parts[0]}:")
                frontmatter_lines.append(f"  {parts[1]}: {json.dumps(value, ensure_ascii=False)}")
            else:
                fail(f"frontmatter set key must be one or two levels: {key}")
        frontmatter_lines.extend([
            "---",
            "",
        ])
        output = "\n".join(frontmatter_lines) + body
    else:
        output = replacement_text(text, config, aliases)
    forbidden = (
        "Cursor Task",
        "subagent_type",
        "generalPurpose",
        "~/.cursor",
        "control-notes",
        "poteto-mode",
        "Graphite",
    )
    found = [term for term in forbidden if term in output]
    if found:
        fail(f"compatibility adaptation leaked {', '.join(found)} into {skill}/{relative}")
    return output.encode("utf-8"), description if metadata else None


def expected_outputs(source: Path, config: dict) -> tuple[dict[Path, bytes], dict[str, str]]:
    source_root = source / config["upstream"]["source_root"]
    if not source_root.is_dir():
        fail(f"source root is missing: {source_root}")
    outputs: dict[Path, bytes] = {}
    descriptions: dict[str, str] = {}
    aliases = principle_aliases(config)
    for entry in config["allowlist"]:
        skill = entry["name"]
        origin = source_root / entry["source"]
        if not origin.is_dir():
            fail(f"allowlisted skill is missing from source: {skill}")
        destination = ROOT / entry.get("destination", f".agents/skills/{skill}")
        files = []
        for path in origin.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(origin).as_posix()
            if any(matches(relative, pattern) for pattern in entry["include"]):
                files.append((relative, path))
        if not any(relative == "SKILL.md" for relative, _ in files):
            fail(f"allowlisted skill has no SKILL.md: {skill}")
        for relative, path in sorted(files):
            content, description = transformed(path, relative, skill, config, aliases)
            target = destination / relative
            outputs[target] = content
            if relative == "SKILL.md":
                descriptions[skill] = description or ""

    for group in config["index"]["groups"]:
        for skill in group.get("skills", []):
            if skill in descriptions:
                continue
            local = ROOT / ".agents" / "skills" / skill / "SKILL.md"
            if not local.is_file():
                fail(f"generated index skill is missing locally: {skill}")
            metadata, _ = frontmatter(local.read_text(encoding="utf-8"))
            descriptions[skill] = metadata["description"]
    index = build_index(config, descriptions)
    outputs[ROOT / config["index"]["path"]] = index.encode("utf-8")
    return outputs, descriptions


def display_name(skill: str) -> str:
    return skill.removeprefix("principle-").replace("-", " ").title()


def build_index(config: dict, descriptions: dict[str, str]) -> str:
    index = config["index"]
    lines = ["# Engineering craft", "<!-- Generated by bin/fm-pstack-sync.sh. Do not edit by hand. -->", ""]
    lines.extend(index.get("preamble", []))
    lines.append("")
    for group in index["groups"]:
        lines.append(f"**{group['title']}**")
        for skill in group.get("skills", []):
            if skill not in descriptions:
                fail(f"generated index has no description for {skill}")
            description = " ".join(descriptions[skill].split())
            lines.append(f"- **{display_name(skill)}** (`{skill}`) - {description}")
        lines.append("")
    lines.extend(index.get("footer", []))
    lines.append("")
    return "\n".join(lines)


def write_outputs(outputs: dict[Path, bytes], conflicts: list[Path]) -> None:
    if conflicts and not ACCEPT:
        print("fm-pstack-sync: conflict: generated outputs differ from the reviewed local result:", file=sys.stderr)
        for path in conflicts:
            print(f"  {path.relative_to(ROOT)}", file=sys.stderr)
        print("fm-pstack-sync: review the diff, then rerun with --accept-reviewed", file=sys.stderr)
        raise SystemExit(2)
    for path, content in sorted(outputs.items(), key=lambda item: str(item[0])):
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.read_bytes() == content:
            continue
        if CHECK:
            print(f"fm-pstack-sync: out of date: {path.relative_to(ROOT)}")
            continue
        temporary = tempfile.NamedTemporaryFile("wb", dir=path.parent, prefix=f".{path.name}.", delete=False)
        try:
            with temporary:
                temporary.write(content)
                temporary.flush()
                os.fsync(temporary.fileno())
            os.replace(temporary.name, path)
        finally:
            if os.path.exists(temporary.name):
                os.unlink(temporary.name)
        print(f"fm-pstack-sync: wrote {path.relative_to(ROOT)}")


def main() -> None:
    if not ROOT.is_dir():
        fail(f"repository root does not exist: {ROOT}")
    config = read_json(CONFIG)
    validate_config(config)
    with source_context(config) as source:
        outputs, _ = expected_outputs(source, config)
    conflicts = [path for path, content in outputs.items() if path.exists() and path.read_bytes() != content]
    write_outputs(outputs, conflicts)
    if CHECK:
        if conflicts:
            raise SystemExit(2)
        print("fm-pstack-sync: generated outputs are current")
    elif not conflicts:
        print(f"fm-pstack-sync: synchronized {len(outputs)} generated files at {config['upstream']['commit']}")


if __name__ == "__main__":
    main()
PY
