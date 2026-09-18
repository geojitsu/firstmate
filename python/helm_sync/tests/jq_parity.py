"""Parity fixtures that compare Python Helm behavior with the live jq programs."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Mapping

ROOT = Path(__file__).resolve().parents[3]
os.sys.path.insert(0, str(ROOT / "python"))

from helm_sync.backlog import parse_backlog, record_to_dict
from helm_sync.desired import render_cards
from helm_sync.fleet import FleetInputError, discover_local_homes, load_fleet, registered_projects
from helm_sync.model import (
    BoardField,
    BoardRef,
    BoardSnapshot,
    CardBaseline,
    CardSnapshot,
    DeletedCardTombstone,
    DesiredCard,
    DivergenceKey,
    DraftContent,
    FieldValue,
    Fingerprint,
    HomeId,
    IssueContent,
    ItemId,
    KindName,
    OptionId,
    Owner,
    PriorityName,
    ProjectName,
    ProjectNumber,
    StatusName,
    SyncState,
    TaskId,
)
from helm_sync.planner import _serialize_plan_for_jq_parity, plan_board
from helm_sync.routing import board_for_project, route_cards
from helm_sync.settings import Disabled, SettingsError, load_settings

TICK = chr(96)


def _production_program(function: str) -> str:
    """Read a jq program by sourcing the production Helm library function."""
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; "$2"',
            "jq-parity",
            str(ROOT / "bin" / "fm-helm-lib.sh"),
            function,
        ],
        check=True,
        capture_output=True,
    )
    return result.stdout.decode("utf-8")


def _compact_json(value: object) -> bytes:
    """Encode compact UTF-8 JSON with jq-compatible separators."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"


PARSER_FIXTURES = (
    """## Queued
- [ ] fixture-meta - Trim metadata (repo: sample, kind: task, priority: 1, since: 2026-08-01)
""",
    """## In flight
- [x] fixture-hold - Captain decision (hold: choose a route, hold-kind: captain, reported 2026-08-02)
""",
    """## Queued
- [ ] fixture-blocked - Unblock work blocked-by: fixture-parent blocked-by: fixture-parent blocked-by: fixture-other
""",
    """## Done
- [x] fixture-links - Shipped https://example.test/pull/31 and https://example.test/group/-/merge_requests/7 data/fixture-links/report.md
  first note
  second note
""",
    """## Unknown section
- [ ] ignored - this row is ignored
## Queued
- unstructured row
- [ ] fixture-artifact - Clean this title - data/fixture-artifact/report.md (repo: sample) (done 2026-08-03)
""",
)


DESIRED_FIXTURE = """## Queued
- [ ] fixture-ship - Ship a setting (repo: sample, priority: 2, since: 2026-09-01)
- [ ] fixture-decision - Choose a direction (repo: sample, hold: choose now, hold-kind: captain)
- [ ] fixture-scout - Inspect behavior (repo: sample, kind: scout, priority: 1)
- [ ] fixture-blocked - Wait for prerequisite (repo: sample, blocked-by: fixture-ship)
- [ ] fixture-unsupported - Inspect a repo (repo: mystery/repo)
- [ ] fixture-pr - Repair the bug https://example.test/pull/43 (repo: sample)
  Reproduce before changing anything.
## In flight
- [ ] fixture-active - Continue work (repo: sample, priority: 0)
## Done
- [x] fixture-done - Close the loop (repo: sample, done 2026-09-02)
"""


def _tag_home(record: Mapping[str, object]) -> dict[str, object]:
    """Add only the fixture home fields consumed by desired rendering."""
    return {
        **record,
        "home_id": "main",
        "home_backlog": "/fixture/main/data/backlog.md",
    }


def _desired_dict(card: DesiredCard) -> dict[str, object]:
    """Build the jq desired object shape from a typed desired card."""
    return {
        "title": card.title,
        "body": card.body,
        "status": str(card.status),
        "kind": str(card.kind),
        "project": str(card.project),
        "priority_n": card.priority_n,
        "priority": str(card.priority),
        "board": {"owner": str(card.board.owner), "number": int(card.board.number)},
        "note": card.note,
    }


def _jq_desired_output(records: list[dict[str, object]], report_ids: list[str]) -> bytes:
    """Run the production desired renderer and select each exact desired object."""
    with tempfile.TemporaryDirectory(prefix="helm-jq-desired-") as temp:
        root = Path(temp)
        routing_path = root / "routing.json"
        records_path = root / "records.json"
        routing_path.write_bytes(
            _compact_json(
                {
                    "version": 1,
                    "projects": {
                        "sample": {"owner": "fixture-owner", "number": 1000, "state": "active"}
                    },
                }
            )
        )
        records_path.write_bytes(_compact_json(records))
        rendered = subprocess.run(
            [
                "jq",
                "-c",
                "--slurpfile",
                "routing",
                str(routing_path),
                "--argjson",
                "registered",
                '["sample"]',
                "--arg",
                "default_owner",
                "fixture-owner",
                "--argjson",
                "default_number",
                "999",
                "--argjson",
                "report_ids",
                json.dumps(report_ids),
                _production_program("fm_helm_desired_program"),
                str(records_path),
            ],
            check=True,
            capture_output=True,
        )
        selected = subprocess.run(
            ["jq", "-c", ".[] | .desired"],
            input=rendered.stdout,
            check=True,
            capture_output=True,
        )
        return selected.stdout


def _all_fields() -> dict[str, BoardField]:
    """Build a complete fixture board schema with fake option IDs."""
    return {
        "Status": BoardField(
            "field_status",
            "Status",
            {
                "Queued": OptionId("option_status_queued"),
                "In flight": OptionId("option_status_flight"),
                "Waiting on you": OptionId("option_status_waiting"),
                "Done": OptionId("option_status_done"),
            },
        ),
        "Project": BoardField(
            "field_project",
            "Project",
            {"sample": OptionId("option_project_sample"), "other": OptionId("option_project_other")},
        ),
        "Kind": BoardField(
            "field_kind",
            "Kind",
            {
                "ship": OptionId("option_kind_ship"),
                "investigation": OptionId("option_kind_investigation"),
                "decision": OptionId("option_kind_decision"),
            },
        ),
        "Priority": BoardField(
            "field_priority",
            "Priority",
            {f"P{index}": OptionId(f"option_priority_{index}") for index in range(5)},
        ),
    }


def _status_id(value: str) -> str:
    """Return the fixture option ID for a Status name."""
    return {
        "Queued": "option_status_queued",
        "In flight": "option_status_flight",
        "Waiting on you": "option_status_waiting",
        "Done": "option_status_done",
    }[value]


def _priority_id(value: str) -> str:
    """Return the fixture option ID for a Priority name."""
    return f"option_priority_{value[1:]}"


def _b64(value: str) -> str:
    """Return the base64 encoding used by the production card cache."""
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def _conflict_fp(kind: str, current: str, desired: str) -> str:
    """Return the production divergence fingerprint for a conflict field."""
    current_value = _b64(current) if kind in {"title", "body"} else current
    desired_value = _b64(desired) if kind in {"title", "body"} else desired
    raw = json.dumps([kind, current_value, desired_value], separators=(",", ":")).encode("utf-8")
    return base64.b64encode(raw).decode("ascii")


def _body(value: str) -> str:
    """Give one body fixture a valid task identity line."""
    return f"{TICK}fixture-task{TICK}\n\n{value}"


def _planner_fixture(
    *,
    title_base: str = "Title baseline",
    title_current: str | None = None,
    title_desired: str | None = None,
    body_base: str = "Body baseline",
    body_current: str | None = None,
    body_desired: str | None = None,
    status_base: str = "Queued",
    status_current: str | None = None,
    status_desired: str = "Queued",
    priority_base: str = "P3",
    priority_current: str | None = None,
    priority_desired: str = "P3",
    note: str = "",
    repository: str | None = None,
    board_card: bool = True,
    cached_card: bool = True,
    divergences: tuple[tuple[str, str], ...] = (),
    is_issue: bool = False,
) -> tuple[BoardSnapshot, DesiredCard, SyncState, dict[str, object], str, str]:
    """Create matching Python and jq planner inputs using fixture identities."""
    task = TaskId("fixture-task")
    item = ItemId("PVTI_fixture_card")
    node = "ISSUE_fixture_card" if is_issue else "DRAFT_fixture_card"
    board_ref = BoardRef(Owner("fixture-owner"), ProjectNumber(999))
    title_current = title_base if title_current is None else title_current
    title_desired = title_base if title_desired is None else title_desired
    body_current = body_base if body_current is None else body_current
    body_desired = body_base if body_desired is None else body_desired
    status_current = status_base if status_current is None else status_current
    priority_current = priority_base if priority_current is None else priority_current
    current_body = _body(body_current)
    baseline_body = _body(body_base)
    desired_body = _body(body_desired)
    schema = _all_fields()
    current_fields = {
        "Status": FieldValue("Status", status_current, OptionId(_status_id(status_current))),
        "Project": FieldValue("Project", "sample", OptionId("option_project_sample")),
        "Kind": FieldValue("Kind", "ship", OptionId("option_kind_ship")),
        "Priority": FieldValue("Priority", priority_current, OptionId(_priority_id(priority_current))),
    }
    content = (
        IssueContent(node, title_current, current_body)
        if is_issue
        else DraftContent(node, title_current, current_body)
    )
    current_card = CardSnapshot(
        item,
        content,
        current_fields,
        task,
    )
    snapshot = BoardSnapshot(board_ref, (current_card,) if board_card else (), schema)
    desired = DesiredCard(
        task,
        HomeId("main"),
        board_ref,
        title_desired,
        desired_body,
        StatusName(status_desired),
        KindName("ship"),
        ProjectName("sample"),
        PriorityName(priority_desired),
        priority_desired[1:],
        home_path=Path("/fixture/main"),
        note=note,
        repository=repository,
    )
    baseline = CardBaseline(
        task,
        item,
        board_ref,
        node,
        is_issue,
        _status_id(status_base),
        _priority_id(priority_base),
        title_base,
        baseline_body,
        "1700000000",
        True,
    )
    divergence_set = frozenset(
        DivergenceKey(
            kind,
            task,
            ItemId("") if kind == "unsupported-repo" else item,
            Fingerprint(fingerprint),
        )
        for kind, fingerprint in divergences
    )
    state = SyncState(cards={task: baseline} if cached_card else {}, divergences=divergence_set)
    raw_card = {
        "id": str(item),
        "content": {
            "__typename": "Issue" if is_issue else "DraftIssue",
            "id": node,
            "title": title_current,
            "body": current_body,
        },
        "fieldValues": {
            "nodes": [
                {
                    "field": {"name": field_name},
                    "name": field_value.value,
                    "optionId": str(field_value.option_id or ""),
                }
                for field_name, field_value in current_fields.items()
            ]
        },
    }
    board_json = {
        "data": {
            "user": {
                "projectV2": {
                    "fields": {
                        "nodes": [
                            {
                                "__typename": "ProjectV2SingleSelectField",
                                "id": field.id,
                                "name": field.name,
                                "options": [
                                    {"id": option_id, "name": option_name}
                                    for option_name, option_id in field.options.items()
                                ],
                            }
                            for field in schema.values()
                        ]
                    },
                    "items": {"nodes": [raw_card] if board_card else []},
                }
            }
        }
    }
    cache_row = "\t".join(
        (
            str(task),
            str(item),
            node,
            "issue" if is_issue else "draft",
            _status_id(status_base),
            _priority_id(priority_base),
            _b64(title_base),
            _b64(baseline_body),
            "1700000000",
            "fixture-owner",
            "999",
        )
    )
    cards_tsv = cache_row if cached_card else ""
    divergence_text = "".join(
        f"{kind}\t{task}\t\t{fingerprint}\n"
        if kind == "unsupported-repo"
        else f"{kind}\t{task}\t{item}\t{fingerprint}\n"
        for kind, fingerprint in divergences
    )
    return snapshot, desired, state, board_json, cards_tsv, divergence_text


def _jq_plan_output(
    board: dict[str, object],
    desired: DesiredCard | None,
    cards_tsv: str,
    divergences_text: str,
    *,
    state: str = "queued",
    deleted_tsv: str = "",
    hold_kind: str = "",
    tsv_existed: str = "true",
) -> bytes:
    """Run the production planner with one synthetic board item, or none when `desired` is `None`."""
    with tempfile.TemporaryDirectory(prefix="helm-jq-plan-") as temp:
        root = Path(temp)
        board_path = root / "board.json"
        desired_path = root / "desired.json"
        cards_path = root / "cards.tsv"
        deleted_path = root / "deleted.tsv"
        markers_path = root / "markers.tsv"
        divergences_path = root / "divergences.tsv"
        fps_path = root / "fps.tsv"
        board_path.write_bytes(_compact_json(board))
        if desired is None:
            desired_path.write_bytes(_compact_json([]))
            fps_path.write_text("", encoding="utf-8")
        else:
            desired_record = {
                "id": str(desired.task),
                "state": state,
                "home_path": "/fixture/main",
                "repo": desired.repository or "",
                "hold_kind": hold_kind,
                "desired": {
                    "title": desired.title,
                    "body": desired.body,
                    "status": str(desired.status),
                    "kind": str(desired.kind),
                    "project": str(desired.project),
                    "priority_n": desired.priority_n,
                    "priority": str(desired.priority),
                    "board": {"owner": "fixture-owner", "number": 999},
                    "note": desired.note,
                },
            }
            desired_path.write_bytes(_compact_json([desired_record]))
            body_hash = hashlib.sha256(desired.body.encode("utf-8")).hexdigest()
            fingerprint = hashlib.sha256(
                "\0".join(
                    (
                        str(desired.status),
                        str(desired.priority),
                        str(desired.project),
                        str(desired.kind),
                        desired.title,
                        body_hash,
                    )
                ).encode("utf-8")
            ).hexdigest()
            fps_path.write_text(f"{desired.task}\t{fingerprint}\n", encoding="utf-8")
        cards_path.write_text(cards_tsv + "\n", encoding="utf-8")
        deleted_path.write_text(deleted_tsv, encoding="utf-8")
        markers_path.write_text("", encoding="utf-8")
        divergences_path.write_text(divergences_text, encoding="utf-8")
        result = subprocess.run(
            [
                "jq",
                "-j",
                "--slurpfile",
                "desired",
                str(desired_path),
                "--rawfile",
                "cards",
                str(cards_path),
                "--rawfile",
                "deleted",
                str(deleted_path),
                "--rawfile",
                "markers",
                str(markers_path),
                "--rawfile",
                "divergences",
                str(divergences_path),
                "--rawfile",
                "fps",
                str(fps_path),
                "--arg",
                "force",
                "1",
                "--arg",
                "dispatch_status",
                "In flight",
                "--arg",
                "now",
                "1700000001",
                "--arg",
                "tsv_existed",
                tsv_existed,
                "--arg",
                "retain_source",
                "0",
                "--arg",
                "retain_project",
                "",
                "--arg",
                "board_owner",
                "fixture-owner",
                "--argjson",
                "board_number",
                "999",
                "--arg",
                "default_owner",
                "fixture-owner",
                "--argjson",
                "default_number",
                "999",
                _production_program("fm_helm_plan_program"),
                str(board_path),
            ],
            check=True,
            capture_output=True,
        )
        return result.stdout


def _raw_field_nodes() -> list[dict[str, object]]:
    """Build the raw board schema nodes matching the `_all_fields()` fixture schema."""
    return [
        {
            "__typename": "ProjectV2SingleSelectField",
            "id": field.id,
            "name": field.name,
            "options": [{"id": option_id, "name": option_name} for option_name, option_id in field.options.items()],
        }
        for field in _all_fields().values()
    ]


def _raw_draft_card(item: str, task: str, status: str, node: str) -> dict[str, object]:
    """Build one raw board draft card claiming the given task in its body line 1."""
    body = f"{TICK}{task}{TICK}\n\nbody"
    return {
        "id": item,
        "content": {"__typename": "DraftIssue", "id": node, "title": "T", "body": body},
        "fieldValues": {
            "nodes": [
                {"field": {"name": "Status"}, "name": status, "optionId": _status_id(status)},
                {"field": {"name": "Project"}, "name": "sample", "optionId": "option_project_sample"},
                {"field": {"name": "Kind"}, "name": "ship", "optionId": "option_kind_ship"},
                {"field": {"name": "Priority"}, "name": "P3", "optionId": "option_priority_3"},
            ]
        },
    }


def _draft_card_snapshot(item: str, task: str, status: str, node: str) -> CardSnapshot:
    """Build the Python-side counterpart of `_raw_draft_card`."""
    body = f"{TICK}{task}{TICK}\n\nbody"
    return CardSnapshot(
        ItemId(item),
        DraftContent(node, "T", body),
        {
            "Status": FieldValue("Status", status, OptionId(_status_id(status))),
            "Project": FieldValue("Project", "sample", OptionId("option_project_sample")),
            "Kind": FieldValue("Kind", "ship", OptionId("option_kind_ship")),
            "Priority": FieldValue("Priority", "P3", OptionId("option_priority_3")),
        },
        TaskId(task),
    )


def _deleted_task_fixture(
    task_name: str, item_name: str, status: str, *, state: str, hold_kind: str = ""
) -> tuple[DesiredCard, CardBaseline, BoardSnapshot, str]:
    """Build a live task whose card was previously cached but is now gone from the board."""
    task = TaskId(task_name)
    item = ItemId(item_name)
    board_ref = BoardRef(Owner("fixture-owner"), ProjectNumber(999))
    body = f"{TICK}{task}{TICK}\n\nbody"
    wanted = DesiredCard(
        task,
        HomeId("main"),
        board_ref,
        "T",
        body,
        StatusName(status),
        KindName("ship"),
        ProjectName("sample"),
        PriorityName("P3"),
        "3",
        home_path=Path("/fixture/main"),
        hold_kind=hold_kind or None,
    )
    status_option = _status_id(status)
    baseline = CardBaseline(task, item, board_ref, f"DRAFT_{item_name}", False, status_option, "option_priority_3", "T", body, "1699999999", True)
    snapshot = BoardSnapshot(board_ref, (), _all_fields())
    cards_tsv = "\t".join(
        (str(task), str(item), f"DRAFT_{item_name}", "draft", status_option, "option_priority_3", _b64("T"), _b64(body), "1699999999", "fixture-owner", "999")
    )
    return wanted, baseline, snapshot, cards_tsv


class HelmSyncPythonParityTests(unittest.TestCase):
    """Compare pure Python Helm modules with production jq behavior."""

    def test_backlog_parser_matches_production_jq_fixtures(self) -> None:
        """Match the production parser across the prototype edge-case fixture set."""
        program = _production_program("fm_helm_backlog_parse_program")
        for index, fixture in enumerate(PARSER_FIXTURES, start=1):
            with self.subTest(fixture=index):
                actual = subprocess.run(
                    ["jq", "-c", "-R", "-n", program],
                    input=fixture.encode("utf-8"),
                    check=True,
                    capture_output=True,
                ).stdout
                python_records = [record_to_dict(record) for record in parse_backlog(fixture)]
                self.assertEqual(_compact_json(python_records), actual)

    def test_desired_renderer_matches_production_jq_fixtures(self) -> None:
        """Match card content, option names, report links, and board routes."""
        parsed = parse_backlog(DESIRED_FIXTURE)
        records = [_tag_home(record_to_dict(record)) for record in parsed]
        route_map = {
            "version": 1,
            "projects": {
                "sample": {"owner": "fixture-owner", "number": 1000, "state": "active"}
            },
        }
        default = BoardRef(Owner("fixture-owner"), ProjectNumber(999))
        report_ids = frozenset({"fixture-scout"})
        expected = _jq_desired_output(records, ["fixture-scout"])
        rendered = render_cards(records, ["sample"], route_map, default, report_ids)
        actual = b"".join(_compact_json(_desired_dict(card)) for card in rendered)
        self.assertEqual(expected, actual)

    def test_all_sixteen_conflict_and_edit_plans_match_production_jq(self) -> None:
        """Match five title and body cases plus the six focused planner scenarios."""
        title_base = "Title baseline"
        body_base = "Body baseline"
        cases: list[tuple[str, dict[str, object]]] = []
        for name, current, wanted in (
            ("board-only", "Title captain", title_base),
            ("backlog-only", title_base, "Title backlog"),
            ("converged", "Title converged", "Title converged"),
            ("conflict", "Title captain", "Title backlog"),
            ("unchanged", title_base, title_base),
        ):
            cases.append((f"title-{name}", {"title_current": current, "title_desired": wanted}))
        for name, current, wanted in (
            ("board-only", "Body captain", body_base),
            ("backlog-only", body_base, "Body backlog"),
            ("converged", "Body converged", "Body converged"),
            ("conflict", "Body captain", "Body backlog"),
            ("unchanged", body_base, body_base),
        ):
            cases.append((f"body-{name}", {"body_current": current, "body_desired": wanted}))
        cases.extend(
            (
                ("status-conflict", {"status_current": "In flight", "status_desired": "Done"}),
                ("priority-conflict", {"priority_current": "P1", "priority_desired": "P4"}),
                ("captain-priority-writeback", {"priority_current": "P1", "priority_desired": "P3"}),
                (
                    "repeated-conflict-no-second-wake",
                    {"title_current": "Title captain", "title_desired": "Title backlog"},
                ),
                (
                    "mixed-title-and-body-edit",
                    {
                        "title_current": "Title captain",
                        "title_desired": title_base,
                        "body_current": body_base,
                        "body_desired": "Body backlog",
                    },
                ),
                (
                    "utf8-title-conflict",
                    {
                        "title_base": "Café baseline 🛟",
                        "title_current": "Café captain 🛟",
                        "title_desired": "Café backlog 🛟",
                    },
                ),
            )
        )
        self.assertEqual(16, len(cases))
        for name, overrides in cases:
            with self.subTest(scenario=name):
                divergences: tuple[tuple[str, str], ...] = ()
                if name == "repeated-conflict-no-second-wake":
                    fingerprint = _conflict_fp("title", "Title captain", "Title backlog")
                    divergences = (
                        ("card-edit-title", fingerprint),
                        ("conflict-title", fingerprint),
                    )
                snapshot, wanted, state, raw_board, cards_tsv, divergence_text = _planner_fixture(
                    **overrides,
                    divergences=divergences,
                )
                plan = plan_board(snapshot, (wanted,), state, force=True, epoch="1700000001")
                python_output = _serialize_plan_for_jq_parity(plan)
                jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, divergence_text)
                self.assertEqual(jq_output, python_output)

    def test_issue_title_and_body_writes_match_production_jq(self) -> None:
        """Match Issue title/body write decisions and acknowledgement for six focused cases."""
        title_base = "Title baseline"
        body_base = "Body baseline"
        cases: tuple[tuple[str, dict[str, object]], ...] = (
            ("title-board-only", {"title_current": "Title captain", "title_desired": title_base}),
            ("title-backlog-only", {"title_current": title_base, "title_desired": "Title backlog"}),
            ("title-conflict", {"title_current": "Title captain", "title_desired": "Title backlog"}),
            ("body-board-only", {"body_current": "Body captain", "body_desired": body_base}),
            ("body-backlog-only", {"body_current": body_base, "body_desired": "Body backlog"}),
            ("body-conflict", {"body_current": "Body captain", "body_desired": "Body backlog"}),
        )
        for name, overrides in cases:
            with self.subTest(scenario=name):
                snapshot, wanted, state, raw_board, cards_tsv, divergence_text = _planner_fixture(
                    is_issue=True,
                    **overrides,
                )
                plan = plan_board(snapshot, (wanted,), state, force=True, epoch="1700000001")
                python_output = _serialize_plan_for_jq_parity(plan)
                jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, divergence_text)
                self.assertEqual(jq_output, python_output)

    def test_unsupported_repository_notice_is_debounced_and_cleared(self) -> None:
        """Match the standing note marker lifecycle for one unsupported repo."""
        repo = "fixture-unsupported/repo"
        fingerprint = base64.b64encode(_compact_json(repo).rstrip(b"\n")).decode("ascii")
        cases = (
            ("first-notice", "Repository is unsupported", repo, ()),
            ("repeat-silenced", "Repository is unsupported", repo, (("unsupported-repo", fingerprint),)),
            ("cleared", "", None, (("unsupported-repo", fingerprint),)),
        )
        for name, note, repository, divergences in cases:
            with self.subTest(scenario=name):
                snapshot, wanted, state, raw_board, cards_tsv, divergence_text = _planner_fixture(
                    note=note,
                    repository=repository,
                    divergences=divergences,
                )
                plan = plan_board(snapshot, (wanted,), state, force=True, epoch="1700000001")
                python_output = _serialize_plan_for_jq_parity(plan)
                jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, divergence_text)
                self.assertEqual(jq_output, python_output)

    def test_unsupported_repository_notice_on_new_card_matches_production_jq(self) -> None:
        """Carry the unsupported-repository note through the draft-create plan."""
        snapshot, wanted, state, raw_board, cards_tsv, divergence_text = _planner_fixture(
            note="Repository is unsupported",
            repository="fixture-unsupported/repo",
            board_card=False,
            cached_card=False,
        )
        plan = plan_board(snapshot, (wanted,), state, force=True, epoch="1700000001")
        python_output = _serialize_plan_for_jq_parity(plan)
        jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, divergence_text)
        self.assertEqual(jq_output, python_output)

    def test_missing_card_with_no_backlog_record_closes_to_done(self) -> None:
        """Close a previously synced card whose task left every backlog, matching missing_entries."""
        snapshot, wanted, state, raw_board, cards_tsv, divergence_text = _planner_fixture()
        missing_task, missing_item, missing_node = "fixture-missing-task", "PVTI_missing", "DRAFT_missing"
        missing_card = _draft_card_snapshot(missing_item, missing_task, "Queued", missing_node)
        extended_snapshot = BoardSnapshot(snapshot.board, snapshot.cards + (missing_card,), snapshot.fields)
        raw_board["data"]["user"]["projectV2"]["items"]["nodes"].append(
            _raw_draft_card(missing_item, missing_task, "Queued", missing_node)
        )
        missing_body = f"{TICK}{missing_task}{TICK}\n\nbody"
        missing_cache_row = "\t".join(
            (missing_task, missing_item, missing_node, "draft", "option_status_queued", "option_priority_3",
             _b64("T"), _b64(missing_body), "1699999999", "fixture-owner", "999")
        )
        merged_cards_tsv = cards_tsv + "\n" + missing_cache_row
        missing_baseline = CardBaseline(
            TaskId(missing_task), ItemId(missing_item), snapshot.board, missing_node, False,
            "option_status_queued", "option_priority_3", "T", missing_body, "1699999999", True,
        )
        state = SyncState(cards={**state.cards, TaskId(missing_task): missing_baseline})
        plan = plan_board(extended_snapshot, (wanted,), state, force=True, epoch="1700000001")
        python_output = _serialize_plan_for_jq_parity(plan)
        jq_output = _jq_plan_output(raw_board, wanted, merged_cards_tsv, divergence_text)
        self.assertEqual(jq_output, python_output)

    def test_missing_card_never_before_seen_wakes_intake_without_closing(self) -> None:
        """Wake intake instead of closing an orphan card jq's old cache never saw."""
        snapshot, wanted, state, raw_board, cards_tsv, divergence_text = _planner_fixture()
        missing_task, missing_item, missing_node = "fixture-new-orphan-task", "PVTI_new_orphan", "DRAFT_new_orphan"
        missing_card = _draft_card_snapshot(missing_item, missing_task, "Queued", missing_node)
        extended_snapshot = BoardSnapshot(snapshot.board, snapshot.cards + (missing_card,), snapshot.fields)
        raw_board["data"]["user"]["projectV2"]["items"]["nodes"].append(
            _raw_draft_card(missing_item, missing_task, "Queued", missing_node)
        )
        plan = plan_board(extended_snapshot, (wanted,), state, force=True, epoch="1700000001")
        python_output = _serialize_plan_for_jq_parity(plan)
        jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, divergence_text)
        self.assertEqual(jq_output, python_output)

    def test_missing_card_on_first_ever_sync_closes_instead_of_waking(self) -> None:
        """Close an orphan card on a board's first-ever sync, when no identity cache existed yet."""
        snapshot, wanted, state, raw_board, cards_tsv, divergence_text = _planner_fixture()
        missing_task, missing_item, missing_node = "fixture-bootstrap-orphan-task", "PVTI_bootstrap_orphan", "DRAFT_bootstrap_orphan"
        missing_card = _draft_card_snapshot(missing_item, missing_task, "Queued", missing_node)
        extended_snapshot = BoardSnapshot(snapshot.board, snapshot.cards + (missing_card,), snapshot.fields)
        raw_board["data"]["user"]["projectV2"]["items"]["nodes"].append(
            _raw_draft_card(missing_item, missing_task, "Queued", missing_node)
        )
        state = SyncState(cards=state.cards, cache_existed=False)
        plan = plan_board(extended_snapshot, (wanted,), state, force=True, epoch="1700000001")
        python_output = _serialize_plan_for_jq_parity(plan)
        jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, divergence_text, tsv_existed="false")
        self.assertEqual(jq_output, python_output)

    def test_missing_card_already_done_is_left_alone(self) -> None:
        """Leave an already-Done orphaned card untouched, matching missing_entries' skip."""
        snapshot, wanted, state, raw_board, cards_tsv, divergence_text = _planner_fixture()
        missing_task, missing_item, missing_node = "fixture-missing-done-task", "PVTI_missing_done", "DRAFT_missing_done"
        missing_card = _draft_card_snapshot(missing_item, missing_task, "Done", missing_node)
        extended_snapshot = BoardSnapshot(snapshot.board, snapshot.cards + (missing_card,), snapshot.fields)
        raw_board["data"]["user"]["projectV2"]["items"]["nodes"].append(
            _raw_draft_card(missing_item, missing_task, "Done", missing_node)
        )
        plan = plan_board(extended_snapshot, (wanted,), state, force=True, epoch="1700000001")
        python_output = _serialize_plan_for_jq_parity(plan)
        jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, divergence_text)
        self.assertEqual(jq_output, python_output)

    def test_missing_phase_with_no_desired_records_touches_no_orphan_card(self) -> None:
        """Guard missing_entries: leave every board card alone when this board's desired set is empty."""
        board_ref = BoardRef(Owner("fixture-owner"), ProjectNumber(999))
        schema = _all_fields()
        orphan_task, orphan_item, orphan_node = "fixture-empty-backlog-orphan", "PVTI_empty_orphan", "DRAFT_empty_orphan"
        orphan_card = _draft_card_snapshot(orphan_item, orphan_task, "Queued", orphan_node)
        snapshot = BoardSnapshot(board_ref, (orphan_card,), schema)
        state = SyncState()
        raw_board = {
            "data": {
                "user": {
                    "projectV2": {
                        "fields": {"nodes": _raw_field_nodes()},
                        "items": {"nodes": [_raw_draft_card(orphan_item, orphan_task, "Queued", orphan_node)]},
                    }
                }
            }
        }
        plan = plan_board(snapshot, {}, state, force=True, epoch="1700000001")
        python_output = _serialize_plan_for_jq_parity(plan)
        jq_output = _jq_plan_output(raw_board, None, "", "")
        self.assertEqual(jq_output, python_output)

    def test_deleted_card_for_a_live_task_raises_a_captain_hold(self) -> None:
        """Preserve a captain's card deletion and raise one hold instead of recreating it."""
        wanted, baseline, snapshot, cards_tsv = _deleted_task_fixture(
            "fixture-deleted-task", "PVTI_deleted_old", "Queued", state="queued"
        )
        state = SyncState(cards={wanted.task: baseline})
        plan = plan_board(snapshot, (wanted,), state, force=True, epoch="1700000001")
        python_output = _serialize_plan_for_jq_parity(plan)
        raw_board = {"data": {"user": {"projectV2": {"fields": {"nodes": _raw_field_nodes()}, "items": {"nodes": []}}}}}
        jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, "", state="queued")
        self.assertEqual(jq_output, python_output)

    def test_deleted_card_for_an_already_done_task_is_retained_silently(self) -> None:
        """Retain a tombstoned deletion for a Done task without recreating the card or waking."""
        wanted, baseline, snapshot, cards_tsv = _deleted_task_fixture(
            "fixture-deleted-done-task", "PVTI_deleted_done", "Done", state="done"
        )
        state = SyncState(
            cards={wanted.task: baseline},
            tombstones={wanted.task: DeletedCardTombstone(wanted.task, baseline.item)},
        )
        plan = plan_board(snapshot, (wanted,), state, force=True, epoch="1700000001")
        python_output = _serialize_plan_for_jq_parity(plan)
        raw_board = {"data": {"user": {"projectV2": {"fields": {"nodes": _raw_field_nodes()}, "items": {"nodes": []}}}}}
        deleted_tsv = f"{wanted.task}\t{baseline.item}\n"
        jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, "", state="done", deleted_tsv=deleted_tsv)
        self.assertEqual(jq_output, python_output)

    def test_deleted_card_under_existing_captain_hold_is_retained_silently(self) -> None:
        """Retain a deletion silently under a live captain hold, even though the task isn't Done."""
        wanted, baseline, snapshot, cards_tsv = _deleted_task_fixture(
            "fixture-deleted-hold-task", "PVTI_deleted_hold", "Waiting on you", state="queued", hold_kind="captain"
        )
        state = SyncState(cards={wanted.task: baseline})
        plan = plan_board(snapshot, (wanted,), state, force=True, epoch="1700000001")
        python_output = _serialize_plan_for_jq_parity(plan)
        raw_board = {"data": {"user": {"projectV2": {"fields": {"nodes": _raw_field_nodes()}, "items": {"nodes": []}}}}}
        jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, "", state="queued", hold_kind="captain")
        self.assertEqual(jq_output, python_output)

    def test_deleted_card_for_a_done_task_without_a_tombstone_still_recreates(self) -> None:
        """Match jq's existing recreate behavior for a Done task never previously tombstoned."""
        wanted, baseline, snapshot, cards_tsv = _deleted_task_fixture(
            "fixture-deleted-done-notomb-task", "PVTI_deleted_done_notomb", "Done", state="done"
        )
        state = SyncState(cards={wanted.task: baseline})
        plan = plan_board(snapshot, (wanted,), state, force=True, epoch="1700000001")
        python_output = _serialize_plan_for_jq_parity(plan)
        raw_board = {"data": {"user": {"projectV2": {"fields": {"nodes": _raw_field_nodes()}, "items": {"nodes": []}}}}}
        jq_output = _jq_plan_output(raw_board, wanted, cards_tsv, "", state="done")
        self.assertEqual(jq_output, python_output)

    def test_config_boundary_is_opt_in_and_validates_board_identity(self) -> None:
        """Return Disabled without inputs when absent and reject invalid config values."""
        with tempfile.TemporaryDirectory(prefix="helm-settings-") as temp:
            home = Path(temp)
            self.assertIsInstance(load_settings(home), Disabled)
            config = home / "config" / "helm.json"
            config.parent.mkdir()
            config.write_text('{"owner":"fixture-owner","number":999}\n', encoding="utf-8")
            settings = load_settings(home)
            self.assertEqual(("fixture-owner", 999), (settings.default_board.owner, settings.default_board.number))
            config.write_text('{"owner":"","number":0}\n', encoding="utf-8")
            with self.assertRaises(SettingsError):
                load_settings(home)
            config.unlink()
            config.symlink_to("missing-helm-config.json")
            with self.assertRaises(SettingsError):
                load_settings(home)

    def test_routing_groups_complete_board_refs_in_stable_order(self) -> None:
        """Route by project identity and include empty default and retention boards."""
        default = BoardRef(Owner("fixture-owner"), ProjectNumber(999))
        mapped = BoardRef(Owner("fixture-owner"), ProjectNumber(1000))
        route = board_for_project(
            "sample",
            {"projects": {"sample": {"owner": "fixture-owner", "number": 1000, "state": "migrating"}}},
            default,
        )
        self.assertEqual(mapped, route)
        card = DesiredCard(
            TaskId("fixture-task"),
            HomeId("main"),
            mapped,
            "Title",
            "Body",
            StatusName("Queued"),
            KindName("ship"),
            ProjectName("sample"),
            PriorityName("P3"),
            "3",
            home_path=Path("/fixture/main"),
        )
        order = route_cards((card,), default, retention_board=mapped)
        self.assertEqual((mapped, default), tuple(group.board for group in order))
        self.assertEqual((card,), order[0].cards)

    def test_fleet_discovers_local_homes_and_rejects_duplicate_tasks(self) -> None:
        """Union local backlogs once, skip remote homes, and reject ambiguous IDs."""
        with tempfile.TemporaryDirectory(prefix="helm-fleet-") as temp:
            root = Path(temp)
            main = root / "main"
            mate = root / "mate"
            remote = root / "remote"
            for home in (main, mate):
                (home / "data").mkdir(parents=True)
            (main / "data" / "backlog.md").write_text(
                "## Queued\n- [ ] fixture-main-task - Main work (repo: sample)\n", encoding="utf-8"
            )
            (mate / "data" / "backlog.md").write_text(
                "## Queued\n- [ ] fixture-mate-task - Mate work (repo: beta)\n", encoding="utf-8"
            )
            (main / "data" / "projects.md").write_text("- sample - Main project\n", encoding="utf-8")
            (mate / "data" / "projects.md").write_text("- beta - Mate project\n", encoding="utf-8")
            registry = main / "data" / "secondmates.md"
            registry.write_text(
                f"- fixture-mate - Local fixture (home: {mate}; scope: fixture; projects: beta; added 2026-09-01)\n"
                "- fixture-remote - Remote fixture (host: fixture-host; root: /fixture/root; home: /fixture/remote; scope: fixture; projects: gamma; added 2026-09-01)\n",
                encoding="utf-8",
            )
            homes = discover_local_homes(main, registry)
            self.assertEqual(("main", "fixture-mate"), tuple(str(home.id) for home in homes))
            self.assertEqual(("sample", "beta"), registered_projects(homes))
            records = load_fleet(homes)
            self.assertEqual(("fixture-main-task", "fixture-mate-task"), tuple(str(row.id) for row in records))
            self.assertFalse(remote.exists())
            (mate / "data" / "backlog.md").write_text(
                "## Queued\n- [ ] fixture-main-task - Duplicate work (repo: beta)\n", encoding="utf-8"
            )
            with self.assertRaises(FleetInputError):
                load_fleet(homes)


if __name__ == "__main__":
    unittest.main(verbosity=2)
