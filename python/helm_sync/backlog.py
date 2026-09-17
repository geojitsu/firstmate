"""Parse backlog Markdown into records matching the production jq program."""

from __future__ import annotations

import re
from dataclasses import replace

from .model import BacklogRecord, TaskId

_WS = r"[ \t\r\n\v\f]"
_WS_PLUS = _WS + "+"
_URL = re.compile(r'https?://[^ \t\r\n\v\f)"<>]+')
_ROW = re.compile(r"^-[ \t\r\n\v\f]+\[(?P<check>[ xX])\][ \t\r\n\v\f]+(?P<id>[^ \t\r\n\v\f]+)[ \t\r\n\v\f]+-[ \t\r\n\v\f]+(?P<rest>.*)$")
_TRAILING_METADATA = re.compile(
    r"[ \t\r\n\v\f]*\([ \t\r\n\v\f]*(?:(?:repo|kind|priority|hold|hold-kind|hold-until):[ \t\r\n\v\f]*[^)]*|(?:since|merged|reported|done):?[ \t\r\n\v\f]+[^)]*)[ \t\r\n\v\f]*\)[ \t\r\n\v\f]*$"
)
_TITLE_ARTIFACTS = (
    re.compile(r"[ \t\r\n\v\f]+-[ \t\r\n\v\f]+data/[^ \t\r\n\v\f)]+/report\.md$"),
    re.compile(r"[ \t\r\n\v\f]+data/[^ \t\r\n\v\f)]+/report\.md$"),
    re.compile(r"[ \t\r\n\v\f]+-[ \t\r\n\v\f]+local main$"),
    re.compile(r"[ \t\r\n\v\f]+local main$"),
    re.compile(r"[ \t\r\n\v\f]+-[ \t\r\n\v\f]*$"),
)
_SPACE_RUN = re.compile(_WS + "+")


def _trim(value: str) -> str:
    return value.strip(" \t\r\n\v\f")


def _capture(rest: str, pattern: str) -> str | None:
    match = re.search(pattern, rest)
    return _trim(match.group("v")) if match else None


def _metadata(rest: str, key: str) -> str | None:
    return _capture(
        rest,
        r".*(?:\(|," + _WS + r"*)" + re.escape(key) + r":" + _WS + r"*(?P<v>[^,)]*)",
    )


def _metadata_word(rest: str, key: str) -> str | None:
    return _capture(
        rest,
        r".*(?:\(|," + _WS + r"*)" + re.escape(key) + r":?" + _WS_PLUS + r"(?P<v>[^,)]*)",
    )


def _clean_title(value: str) -> str:
    cleaned = value
    for _ in range(20):
        updated = _TRAILING_METADATA.sub("", cleaned, count=1)
        if updated == cleaned:
            break
        cleaned = updated
    for pattern in _TITLE_ARTIFACTS:
        cleaned = pattern.sub("", cleaned, count=1)
    return _trim(_SPACE_RUN.sub(" ", cleaned))


def _title_of(rest: str) -> str:
    title = _URL.sub("", rest)
    title = re.sub(
        r"[ \t\r\n\v\f]*blocked-by:[ \t\r\n\v\f]+[^ \t\r\n\v\f)]+[ \t\r\n\v\f]+-[ \t\r\n\v\f]+.*$",
        "",
        title,
        count=1,
    )
    title = re.sub(r"[ \t\r\n\v\f]*blocked-by:[ \t\r\n\v\f]+[^ \t\r\n\v\f]+", "", title)
    return _clean_title(title)


def _blocked_by_ids(rest: str) -> tuple[str, ...]:
    found = re.findall(r"blocked-by:[ \t\r\n\v\f]+([^ \t\r\n\v\f)]+)", rest)
    return tuple(dict.fromkeys(found))


def _section_state(heading: str) -> str | None:
    value = _trim(heading)
    return {"In flight": "in_flight", "Queued": "queued", "Done": "done"}.get(value)


def parse_backlog(text: str) -> tuple[BacklogRecord, ...]:
    """Parse backlog text using the production jq program's record rules.

    Args:
        text: Complete UTF-8 decoded contents of one backlog file.

    Returns:
        Records in source order, including unstructured rows.
    """
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    section: str | None = None
    records: list[BacklogRecord] = []
    order = 0

    for line in lines:
        if re.match(r"^##[ \t\r\n\v\f]+", line):
            section = _section_state(re.sub(r"^##[ \t\r\n\v\f]+", "", line, count=1))
            continue
        if section is None or _trim(line) == "":
            continue

        row = _ROW.match(line)
        if row:
            order += 1
            rest = row.group("rest")
            report_match = re.search(r".*(?P<v>data/[^ \t\r\n\v\f)]+/report\.md).*", rest)
            records.append(
                BacklogRecord(
                    order=order,
                    state=section,
                    structured=True,
                    id=TaskId(_trim(row.group("id"))),
                    checked=bool(re.search(r"[xX]", row.group("check"))),
                    title=_title_of(rest),
                    repo=_metadata(rest, "repo"),
                    kind=_metadata(rest, "kind"),
                    priority=_metadata(rest, "priority"),
                    hold_reason=_metadata(rest, "hold"),
                    hold_kind=_metadata(rest, "hold-kind"),
                    since=_metadata_word(rest, "since"),
                    merged=_metadata_word(rest, "merged"),
                    reported=_metadata_word(rest, "reported"),
                    done=_metadata_word(rest, "done"),
                    blocked_by_ids=_blocked_by_ids(rest),
                    pr_url=next(
                        (
                            url
                            for url in _URL.findall(rest)
                            if re.search(r"/pull/[1-9][0-9]*$", url)
                            or re.search(r"/-/merge_requests/[1-9][0-9]*$", url)
                        ),
                        None,
                    ),
                    report_path=_trim(report_match.group("v")) if report_match else None,
                )
            )
        elif line[:1] in " \t\r\n\v\f" and records and records[-1].structured:
            body = _trim(line)
            if body:
                records[-1] = replace(records[-1], body_lines=records[-1].body_lines + (body,))
        else:
            order += 1
            records.append(BacklogRecord(order=order, state=section, structured=False, raw=line))

    return tuple(records)


def record_to_dict(record: BacklogRecord) -> dict[str, object]:
    """Convert one parsed record to jq-compatible JSON data.

    Args:
        record: One structured or unstructured parsed backlog record.

    Returns:
        A JSON-compatible object with the same fields and ordering as jq output.
    """
    if not record.structured:
        return {"order": record.order, "state": record.state, "structured": False, "raw": record.raw}
    return {
        "order": record.order,
        "state": record.state,
        "structured": True,
        "id": record.id,
        "checked": record.checked,
        "title": record.title,
        "repo": record.repo,
        "kind": record.kind,
        "priority": record.priority,
        "hold_reason": record.hold_reason,
        "hold_kind": record.hold_kind,
        "since": record.since,
        "merged": record.merged,
        "reported": record.reported,
        "done": record.done,
        "blocked_by_ids": list(record.blocked_by_ids),
        "pr_url": record.pr_url,
        "report_path": record.report_path,
        "body_lines": list(record.body_lines),
    }
