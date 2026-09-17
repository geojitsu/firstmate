"""Immutable domain records shared by the Helm sync planning modules."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from types import MappingProxyType
from typing import Literal, Mapping, NewType, TypeAlias

Owner = NewType("Owner", str)
ProjectNumber = NewType("ProjectNumber", int)
TaskId = NewType("TaskId", str)
HomeId = NewType("HomeId", str)
ItemId = NewType("ItemId", str)
OptionId = NewType("OptionId", str)
ProjectName = NewType("ProjectName", str)
StatusName = NewType("StatusName", str)
KindName = NewType("KindName", str)
PriorityName = NewType("PriorityName", str)
ReportPath = NewType("ReportPath", str)
Signature = NewType("Signature", str)
InputHash = NewType("InputHash", str)
Fingerprint = NewType("Fingerprint", str)
FieldName = Literal["Status", "Priority", "Project", "Kind"]

_OWNER_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def parse_owner(value: object) -> Owner:
    """Validate and brand a GitHub owner login.

    Args:
        value: Untrusted owner value from configuration or routing data.

    Returns:
        A validated Owner string.

    Raises:
        ValueError: If the value is not a valid owner login.
    """
    if not isinstance(value, str) or not _OWNER_RE.fullmatch(value):
        raise ValueError("board owner must be a valid non-empty login")
    return Owner(value)


def parse_project_number(value: object) -> ProjectNumber:
    """Validate and brand a positive GitHub Project number.

    Args:
        value: Untrusted number value from configuration or routing data.

    Returns:
        A validated positive ProjectNumber.

    Raises:
        ValueError: If the value is not a positive integer.
    """
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValueError("board number must be a positive integer")
    return ProjectNumber(value)


def parse_task_id(value: object) -> TaskId:
    """Validate and brand a backlog task identifier.

    Args:
        value: Untrusted task ID from a parsed backlog or board card.

    Returns:
        A validated TaskId.

    Raises:
        ValueError: If the value contains characters outside the task ID grammar.
    """
    if not isinstance(value, str) or not _ID_RE.fullmatch(value):
        raise ValueError("task id must contain only letters, digits, dot, underscore, or hyphen")
    return TaskId(value)


def parse_home_id(value: object) -> HomeId:
    """Validate and brand a registered local-home identifier.

    Args:
        value: Untrusted home ID from the secondmate registry.

    Returns:
        A validated HomeId.

    Raises:
        ValueError: If the value contains characters outside the home ID grammar.
    """
    if not isinstance(value, str) or not _ID_RE.fullmatch(value):
        raise ValueError("home id must contain only letters, digits, dot, underscore, or hyphen")
    return HomeId(value)


def parse_item_id(value: object) -> ItemId:
    """Validate and brand a synthetic or GitHub board item identifier.

    Args:
        value: Untrusted item ID read from a board snapshot.

    Returns:
        A validated ItemId.

    Raises:
        ValueError: If the value is empty or contains a line or field separator.
    """
    if not isinstance(value, str) or not value or any(ch in value for ch in "\t\r\n\0"):
        raise ValueError("item id must be a non-empty single-line string")
    return ItemId(value)


@dataclass(frozen=True, order=True)
class BoardRef:
    """Identify a GitHub Project by owner and board number."""

    owner: Owner
    number: ProjectNumber

    def __post_init__(self) -> None:
        object.__setattr__(self, "owner", parse_owner(self.owner))
        object.__setattr__(self, "number", parse_project_number(self.number))


@dataclass(frozen=True)
class HomeRef:
    """Identify a local Helm home and its filesystem root."""

    id: HomeId
    path: Path
    main: bool = False


@dataclass(frozen=True)
class BacklogRecord:
    """Represent one structured or unstructured backlog line group."""

    order: int
    state: str | None
    structured: bool
    id: TaskId | None = None
    checked: bool | None = None
    title: str | None = None
    repo: str | None = None
    kind: str | None = None
    priority: str | None = None
    hold_reason: str | None = None
    hold_kind: str | None = None
    since: str | None = None
    merged: str | None = None
    reported: str | None = None
    done: str | None = None
    blocked_by_ids: tuple[str, ...] = ()
    pr_url: str | None = None
    report_path: str | None = None
    body_lines: tuple[str, ...] = ()
    raw: str | None = None
    home_id: HomeId | None = None
    home_backlog: Path | None = None
    home_path: Path | None = None


@dataclass(frozen=True)
class DesiredCard:
    """Hold the canonical backlog-owned fields rendered for one card."""

    task: TaskId
    home: HomeId
    board: BoardRef
    title: str
    body: str
    status: StatusName
    kind: KindName
    project: ProjectName
    priority: PriorityName
    priority_n: str
    report_path: ReportPath | None = None
    home_path: Path | None = None
    note: str = ""
    repository: str | None = None


@dataclass(frozen=True)
class DraftContent:
    """Represent editable title and body content for a draft card."""

    node_id: str
    title: str
    body: str


@dataclass(frozen=True)
class IssueContent:
    """Represent Issue content whose title and body Helm must preserve."""

    node_id: str
    title: str
    body: str


CardContent: TypeAlias = DraftContent | IssueContent


@dataclass(frozen=True)
class FieldValue:
    """Represent one board field's display value and selected option id."""

    name: FieldName
    value: str
    option_id: OptionId | None = None


@dataclass(frozen=True)
class BoardField:
    """Describe one single-select field and its available named options."""

    id: str
    name: FieldName
    options: Mapping[str, OptionId]

    def __post_init__(self) -> None:
        object.__setattr__(self, "options", MappingProxyType(dict(self.options)))


@dataclass(frozen=True)
class CardSnapshot:
    """Capture one current board item for a pure reconciliation pass."""

    item: ItemId
    content: CardContent
    fields: Mapping[FieldName, FieldValue]
    task: TaskId | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "fields", MappingProxyType(dict(self.fields)))


@dataclass(frozen=True)
class BoardSnapshot:
    """Capture the current cards and schema for one board."""

    board: BoardRef
    cards: tuple[CardSnapshot, ...]
    fields: Mapping[FieldName, BoardField]

    def __post_init__(self) -> None:
        object.__setattr__(self, "cards", tuple(self.cards))
        object.__setattr__(self, "fields", MappingProxyType(dict(self.fields)))


@dataclass(frozen=True)
class CardBaseline:
    """Remember the last acknowledged values for one synchronized card."""

    task: TaskId
    item: ItemId
    board: BoardRef
    node_id: str
    is_issue: bool
    status_option: str
    priority_option: str
    title: str
    body: str
    epoch: str = ""
    version_two: bool = True


@dataclass(frozen=True)
class DispatchMarker:
    """Remember one captain dispatch request already queued for a card."""

    task: TaskId
    item: ItemId
    option: OptionId
    fingerprint: Fingerprint


@dataclass(frozen=True)
class DeletedCardTombstone:
    """Keep a deleted board-card identity from being recreated automatically."""

    task: TaskId
    item: ItemId


@dataclass(frozen=True)
class DivergenceKey:
    """Identify one field divergence and its current fingerprint."""

    kind: str
    task: TaskId
    item: ItemId
    fingerprint: Fingerprint


@dataclass(frozen=True)
class SyncState:
    """Provide the immutable state snapshot consumed by a board planner."""

    cards: Mapping[TaskId, CardBaseline] = field(default_factory=dict)
    dispatches: Mapping[TaskId, DispatchMarker] = field(default_factory=dict)
    tombstones: Mapping[TaskId, DeletedCardTombstone] = field(default_factory=dict)
    divergences: frozenset[DivergenceKey] = frozenset()
    poll_signatures: Mapping[BoardRef, Signature] = field(default_factory=dict)
    completed_input_hash: InputHash | None = None
    forced_resume: bool = False

    def __post_init__(self) -> None:
        object.__setattr__(self, "cards", MappingProxyType(dict(self.cards)))
        object.__setattr__(self, "dispatches", MappingProxyType(dict(self.dispatches)))
        object.__setattr__(self, "tombstones", MappingProxyType(dict(self.tombstones)))
        object.__setattr__(self, "divergences", frozenset(self.divergences))
        object.__setattr__(self, "poll_signatures", MappingProxyType(dict(self.poll_signatures)))


@dataclass(frozen=True)
class FieldWrite:
    """Describe one single-select field update proposed by the planner."""

    field_id: str
    name: FieldName
    value: str
    option_id: OptionId


@dataclass(frozen=True)
class WakeRequest:
    """Describe a keyed wake requested by a reconciliation decision."""

    key: str
    payload: str


@dataclass(frozen=True)
class DivergenceChange:
    """Describe a divergence fingerprint to remember or forget."""

    kind: str
    action: Literal["keep", "remove"]
    item: str
    fingerprint: str


@dataclass(frozen=True)
class NoChange:
    """Carry the baseline advancement authorized by a no-write decision."""

    task: TaskId
    item: ItemId
    baseline: CardBaseline
    expected: CardSnapshot
    title: str = ""
    body: str = ""
    field_writes: tuple[FieldWrite, ...] = ()
    wakes: tuple[WakeRequest, ...] = ()
    divergence_changes: tuple[DivergenceChange, ...] = ()
    marker_action: str = ""
    marker_fingerprint: str = ""
    writeback_priority: str = ""
    home_path: Path | None = None
    acknowledge: Mapping[str, object] = field(default_factory=dict)
    fingerprint: Fingerprint = Fingerprint("")
    note: str = ""
    compatibility_only: bool = False

    def __post_init__(self) -> None:
        object.__setattr__(self, "acknowledge", MappingProxyType(dict(self.acknowledge)))


@dataclass(frozen=True)
class CreateDraft:
    """Describe a new draft card and its initial field values."""

    task: TaskId
    desired: DesiredCard
    field_writes: tuple[FieldWrite, ...]
    baseline: CardBaseline
    acknowledge: Mapping[str, object]
    fingerprint: Fingerprint = Fingerprint("")
    divergence_changes: tuple[DivergenceChange, ...] = ()
    note: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "acknowledge", MappingProxyType(dict(self.acknowledge)))


@dataclass(frozen=True)
class UpdateDraft:
    """Describe a guarded draft text and field update with its acknowledgement."""

    task: TaskId
    item: ItemId
    draft_issue_id: str | None
    title: str
    body: str
    text_changed: bool
    field_writes: tuple[FieldWrite, ...]
    expected: CardSnapshot
    baseline: CardBaseline
    acknowledge: Mapping[str, object]
    wakes: tuple[WakeRequest, ...] = ()
    divergence_changes: tuple[DivergenceChange, ...] = ()
    marker_action: str = ""
    marker_fingerprint: str = ""
    writeback_priority: str = ""
    home_path: Path | None = None
    fingerprint: Fingerprint = Fingerprint("")
    note: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "acknowledge", MappingProxyType(dict(self.acknowledge)))


@dataclass(frozen=True)
class UpdateIssueFields:
    """Describe field updates for a real Issue without changing its text."""

    task: TaskId
    item: ItemId
    field_writes: tuple[FieldWrite, ...]
    expected: CardSnapshot
    baseline: CardBaseline
    acknowledge: Mapping[str, object]
    wakes: tuple[WakeRequest, ...] = ()
    divergence_changes: tuple[DivergenceChange, ...] = ()
    marker_action: str = ""
    marker_fingerprint: str = ""
    writeback_priority: str = ""
    home_path: Path | None = None
    fingerprint: Fingerprint = Fingerprint("")
    note: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "acknowledge", MappingProxyType(dict(self.acknowledge)))


@dataclass(frozen=True)
class CloseMissingCard:
    """Describe closing a previously synchronized card absent from backlog."""

    task: TaskId
    item: ItemId
    field_write: FieldWrite
    expected: CardSnapshot
    acknowledge: Mapping[str, object]

    def __post_init__(self) -> None:
        object.__setattr__(self, "acknowledge", MappingProxyType(dict(self.acknowledge)))


@dataclass(frozen=True)
class RecordDispatchRequest:
    """Describe persisting a new captain dispatch request."""

    task: TaskId
    item: ItemId
    option: OptionId
    fingerprint: Fingerprint


@dataclass(frozen=True)
class ClearDispatchRequest:
    """Describe clearing an obsolete captain dispatch request."""

    task: TaskId


@dataclass(frozen=True)
class WritePriorityToBacklog:
    """Describe writing a valid captain Priority edit into the backlog."""

    task: TaskId
    home_path: Path
    priority: str


@dataclass(frozen=True)
class HoldDeletedTask:
    """Describe placing a captain hold after deletion of a live card."""

    task: TaskId
    home_path: Path
    reason: str


@dataclass(frozen=True)
class KeepDeletedTombstone:
    """Describe retaining a deleted-card tombstone."""

    task: TaskId
    item: ItemId


@dataclass(frozen=True)
class RaiseWake:
    """Describe one keyed wake emitted by the board planner."""

    task: TaskId
    wake: WakeRequest


@dataclass(frozen=True)
class RememberDivergence:
    """Describe recording a divergence fingerprint."""

    key: DivergenceKey


@dataclass(frozen=True)
class ForgetDivergence:
    """Describe removing obsolete divergence memory for a task field."""

    kind: str
    task: TaskId
    item: ItemId


PlanAction: TypeAlias = (
    CreateDraft
    | UpdateDraft
    | UpdateIssueFields
    | CloseMissingCard
    | RecordDispatchRequest
    | ClearDispatchRequest
    | WritePriorityToBacklog
    | HoldDeletedTask
    | KeepDeletedTombstone
    | RaiseWake
    | RememberDivergence
    | ForgetDivergence
    | NoChange
)


@dataclass(frozen=True)
class BoardPlan:
    """Group typed reconciliation actions and a signature for one board read."""

    board: BoardRef
    actions: tuple[PlanAction, ...]
    snapshot_signature: Signature
