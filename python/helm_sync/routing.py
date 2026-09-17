"""Resolve project identities and group desired cards by complete board route."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping, Sequence

from .model import BoardRef, DesiredCard, parse_owner, parse_project_number


@dataclass(frozen=True)
class BoardWork:
    """Group one board reference with the desired cards routed to it."""

    board: BoardRef
    cards: tuple[DesiredCard, ...]


def project_for_repo(repo: str | None, registered: Sequence[str]) -> str | None:
    """Resolve a backlog repository value to its registered project identity.

    Args:
        repo: Repository name or owner/repository value from the backlog.
        registered: Project names read from local homes' project registries.

    Returns:
        The matching registered name, ``other`` for that explicit fallback, or None.
    """
    value = repo or ""
    base = value.rsplit("/", 1)[-1]
    if value in registered:
        return value
    if base in registered:
        return base
    if value == "other":
        return "other"
    return None


def board_for_project(
    project: str | None,
    route_map: Mapping[str, object],
    default_board: BoardRef,
) -> BoardRef:
    """Resolve an active or migrating project mapping, else use the default.

    Args:
        project: Registered project identity resolved from the backlog.
        route_map: Decoded ``data/helm-project-map.json`` object.
        default_board: Validated default destination.

    Returns:
        The mapped board when its entry is valid and current, otherwise default.
    """
    projects = route_map.get("projects", {})
    if project is None or not isinstance(projects, Mapping):
        return default_board
    entry = projects.get(project)
    if not isinstance(entry, Mapping):
        return default_board
    state = entry.get("state", "active")
    if state not in ("active", "migrating"):
        return default_board
    owner = entry.get("owner")
    number = entry.get("number")
    try:
        return BoardRef(parse_owner(owner), parse_project_number(number))
    except ValueError:
        return default_board


def route_cards(
    cards: Sequence[DesiredCard],
    default_board: BoardRef,
    *,
    retention_board: BoardRef | None = None,
) -> tuple[BoardWork, ...]:
    """Group desired cards and return retention/default-first board order.

    Args:
        cards: Rendered desired cards from all local homes.
        default_board: Board included even when it has no desired cards.
        retention_board: Optional board that must be processed before default.

    Returns:
        Board groups ordered retention, default, then owner and number.
    """
    grouped: dict[BoardRef, list[DesiredCard]] = {default_board: []}
    if retention_board is not None:
        grouped.setdefault(retention_board, [])
    for card in cards:
        grouped.setdefault(card.board, []).append(card)
    pinned = tuple(dict.fromkeys(board for board in (retention_board, default_board) if board in grouped))
    remainder = sorted((board for board in grouped if board not in pinned), key=lambda b: (b.owner, b.number))
    return tuple(BoardWork(board, tuple(grouped[board])) for board in pinned + tuple(remainder))
