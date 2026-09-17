"""Discover local homes and build a validated union of their backlogs."""

from __future__ import annotations

import re
from pathlib import Path

from .backlog import parse_backlog
from .model import BacklogRecord, HomeId, HomeRef, TaskId, parse_home_id, parse_task_id

_LOCAL_HOME = re.compile(
    r"^- (?P<id>[A-Za-z0-9._-]+) - .+ \(home:[ \t]*(?P<home>[^;)]*);[ \t]*scope:[ \t]*(.*);[ \t]*projects:[ \t]*[^;)]*;[ \t]*added[ \t]+[0-9]{4}-[0-9]{2}-[0-9]{2}\)[ \t]*$"
)
_REMOTE_HOME = re.compile(
    r"^- [A-Za-z0-9._-]+ - .+ \(host:[^;)]*;[ \t]*root:[^;)]*;[ \t]*home:[^;)]*;[ \t]*scope:.*;[ \t]*projects:[^;)]*;[ \t]*added[ \t]+[0-9]{4}-[0-9]{2}-[0-9]{2}\)[ \t]*$"
)


class FleetInputError(ValueError):
    """Report malformed or duplicate local fleet input."""


def discover_local_homes(main_home: Path, registry_path: Path) -> tuple[HomeRef, ...]:
    """Return the main home followed by registered local secondmate homes.

    Args:
        main_home: Root of the primary local home.
        registry_path: Main home's secondmate registry path.

    Returns:
        The main home and valid absolute-path local homes in registry order.
        Remote, malformed, and relative-path entries are skipped.
    """
    homes = [HomeRef(HomeId("main"), main_home, main=True)]
    if registry_path.is_symlink() or not registry_path.is_file():
        return tuple(homes)
    try:
        lines = registry_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return tuple(homes)
    seen_ids = {HomeId("main")}
    for line in lines:
        if _REMOTE_HOME.fullmatch(line):
            continue
        match = _LOCAL_HOME.fullmatch(line)
        if match is None:
            continue
        home_id = parse_home_id(match.group("id"))
        raw_home = match.group("home").strip()
        path = Path(raw_home)
        if not raw_home or not path.is_absolute() or home_id in seen_ids:
            continue
        homes.append(HomeRef(home_id, path))
        seen_ids.add(home_id)
    return tuple(homes)


def parse_home_backlog(home: HomeRef) -> tuple[BacklogRecord, ...]:
    """Parse and validate one home's backlog records.

    Args:
        home: Local home whose ``data/backlog.md`` is read.

    Returns:
        Structured backlog records tagged with their owning home paths.

    Raises:
        FleetInputError: If a backlog is absent, malformed, or has invalid rows.
    """
    backlog_path = home.path / "data" / "backlog.md"
    if backlog_path.is_symlink() or not backlog_path.is_file():
        raise FleetInputError(f"{backlog_path} is absent or not a regular file")
    try:
        parsed = parse_backlog(backlog_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as exc:
        raise FleetInputError(f"{backlog_path} could not be read") from exc
    records: list[BacklogRecord] = []
    seen: set[TaskId] = set()
    for record in parsed:
        if not record.structured or record.id is None or not record.title:
            raise FleetInputError(f"{backlog_path} contains an unstructured or empty task row")
        try:
            task = parse_task_id(record.id)
        except ValueError as exc:
            raise FleetInputError(f"{backlog_path} contains an invalid task id") from exc
        if task in seen:
            raise FleetInputError(f"{backlog_path} contains duplicate task id {task}")
        seen.add(task)
        records.append(
            BacklogRecord(
                **{
                    **record.__dict__,
                    "id": task,
                    "home_id": home.id,
                    "home_backlog": backlog_path,
                    "home_path": home.path,
                }
            )
        )
    return tuple(records)


def load_fleet(homes: tuple[HomeRef, ...]) -> tuple[BacklogRecord, ...]:
    """Parse each local home once and reject duplicate IDs across the union.

    Args:
        homes: Ordered primary and local secondmate homes.

    Returns:
        The ordered union of each home's validated backlog records.

    Raises:
        FleetInputError: If one task id appears in more than one home.
    """
    all_records: list[BacklogRecord] = []
    owners: dict[TaskId, HomeId] = {}
    for home in homes:
        for record in parse_home_backlog(home):
            assert record.id is not None and record.home_id is not None
            prior_home = owners.get(record.id)
            if prior_home is not None:
                raise FleetInputError(
                    f"task id {record.id} appears in both homes {prior_home} and {record.home_id}"
                )
            owners[record.id] = record.home_id
            all_records.append(record)
    return tuple(all_records)


def registered_projects(homes: tuple[HomeRef, ...]) -> tuple[str, ...]:
    """Return project names from local home registries in first-seen order.

    Args:
        homes: Ordered primary and local secondmate homes.

    Returns:
        Unique project names in their first-seen home and file order.
    """
    projects: list[str] = []
    seen: set[str] = set()
    for home in homes:
        registry = home.path / "data" / "projects.md"
        if registry.is_symlink() or not registry.is_file():
            continue
        try:
            lines = registry.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            continue
        for line in lines:
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "-" and parts[1] not in seen:
                seen.add(parts[1])
                projects.append(parts[1])
    return tuple(projects)
