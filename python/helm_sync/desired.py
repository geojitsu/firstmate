"""Render backlog records into canonical Helm cards without side effects."""

from __future__ import annotations

from pathlib import Path
from typing import Mapping, Sequence

from .model import (
    BoardRef,
    BacklogRecord,
    DesiredCard,
    HomeId,
    KindName,
    PriorityName,
    ProjectName,
    ReportPath,
    StatusName,
    TaskId,
    parse_task_id,
)
from .routing import board_for_project, project_for_repo


def _value(record: BacklogRecord | Mapping[str, object], key: str, default: object = None) -> object:
    if isinstance(record, BacklogRecord):
        return getattr(record, key, default)
    return record.get(key, default)


def _kind(record: BacklogRecord | Mapping[str, object]) -> str:
    hold_kind = _value(record, "hold_kind")
    hold_reason = _value(record, "hold_reason") or ""
    raw_kind = _value(record, "kind") or "ship"
    if hold_kind == "captain" and hold_reason != "":
        return "decision"
    if raw_kind in ("task", "scout"):
        return "investigation"
    return "ship"


def _priority(value: object) -> str:
    raw = str(value)
    return f"P{raw}" if raw in {"0", "1", "2", "3", "4"} else "P3"


def _status(state: object, kind: str) -> str:
    if state == "done":
        return "Done"
    if kind == "decision":
        return "Waiting on you"
    if state == "in_flight":
        return "In flight"
    return "Queued"


def _type_line(kind: str) -> str:
    return {
        "ship": "ship - produces a change and a PR",
        "investigation": "investigation - produces knowledge, not code",
        "decision": "decision - needs your call before anything moves",
    }[kind]


def _body(
    record: BacklogRecord | Mapping[str, object],
    kind: str,
    priority: str,
    report_path: str,
) -> str:
    repo = _value(record, "repo") or "-"
    if repo == "":
        repo = "-"
    filed = "unknown"
    for key in ("since", "reported", "done", "merged"):
        candidate = _value(record, key)
        if candidate is not None:
            filed = str(candidate)
            break
    hold = str(_value(record, "hold_reason") or "")
    blocked = ", ".join(_value(record, "blocked_by_ids", ()) or ())
    pr_url = str(_value(record, "pr_url") or "")
    task = str(_value(record, "id") or "")
    lines = _value(record, "body_lines", ()) or ()
    body = f"`{task}`\n\n"
    if kind == "decision" and hold:
        body += f"## What you need to decide\n\n{hold}\n\n"
    body += "## Facts\n\n"
    body += f"- **Repo:** {repo}\n"
    body += f"- **Type:** {_type_line(kind)}\n"
    body += f"- **Priority:** {priority}\n"
    body += f"- **Filed:** {filed}\n"
    if blocked:
        body += f"- **Blocked by:** {blocked}\n"
    if report_path:
        body += f"- **Report:** `{report_path}`\n"
    if pr_url:
        body += f"- **PR:** {pr_url}\n"
    body += "\n## Notes\n\n"
    body += "".join(f"{line}\n" for line in lines)
    body += "\n---\n_Source of truth: `data/backlog.md` in the owning local home._"
    return body


def render_card(
    record: BacklogRecord | Mapping[str, object],
    registered_projects: Sequence[str],
    route_map: Mapping[str, object],
    default_board: BoardRef,
    report_ids: frozenset[str] = frozenset(),
) -> DesiredCard:
    """Render one backlog record into its immutable desired-card record.

    Args:
        record: Parsed structured backlog record, optionally tagged with home data.
        registered_projects: Project identities across the local fleet.
        route_map: Decoded Helm project routing map.
        default_board: Validated default board destination.
        report_ids: Task identifiers with a main-home report file.

    Returns:
        The canonical desired card with the same field values as the jq renderer.

    Raises:
        ValueError: If the record does not have a valid task identifier.
    """
    raw_id = _value(record, "id")
    task = parse_task_id(raw_id)
    repo_value = _value(record, "repo")
    repo = str(repo_value) if repo_value is not None else None
    project_name = project_for_repo(repo, registered_projects)
    project = project_name or "other"
    kind = _kind(record)
    raw_priority = _value(record, "priority")
    priority_n = "3" if raw_priority is None else str(raw_priority)
    priority = _priority(priority_n)
    explicit_report = _value(record, "report_path") or ""
    report = str(explicit_report) if explicit_report else (f"data/{task}/report.md" if str(task) in report_ids else "")
    state = _value(record, "state")
    status = _status(state, kind)
    home_id = _value(record, "home_id") or "main"
    home_backlog = _value(record, "home_backlog")
    if home_backlog:
        home_backlog = Path(str(home_backlog))
    home_path_value = _value(record, "home_path")
    if home_path_value:
        home_path = Path(str(home_path_value))
    elif home_backlog:
        home_path = Path(str(home_backlog)).parent.parent
    else:
        home_path = None
    board = board_for_project(project_name, route_map, default_board)
    note = "" if project_name is not None else f"fm-helm-sync: unsupported repository {repo or ''} for {task}; using other"
    return DesiredCard(
        task=task,
        home=HomeId(str(home_id)),
        board=board,
        title=str(_value(record, "title") or ""),
        body=_body(record, kind, priority, report),
        status=StatusName(status),
        kind=KindName(kind),
        project=ProjectName(project),
        priority=PriorityName(priority),
        priority_n=priority_n,
        report_path=ReportPath(report) if report else None,
        home_path=home_path,
        note=note,
        repository=repo,
    )


def render_cards(
    records: Sequence[BacklogRecord | Mapping[str, object]],
    registered_projects: Sequence[str],
    route_map: Mapping[str, object],
    default_board: BoardRef,
    report_ids: frozenset[str] = frozenset(),
) -> tuple[DesiredCard, ...]:
    """Render a backlog union once into its ordered desired-card sequence.

    Args:
        records: Structured records collected from local homes.
        registered_projects: Project identities in the local-home union.
        route_map: Decoded Helm project routing map.
        default_board: Validated default board destination.
        report_ids: Task identifiers with a main-home report file.

    Returns:
        Immutable desired cards in the same order as their backlog records.
    """
    return tuple(
        render_card(record, registered_projects, route_map, default_board, report_ids)
        for record in records
        if bool(_value(record, "structured", True))
    )
