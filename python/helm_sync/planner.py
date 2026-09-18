"""Build pure, fieldwise Helm reconciliation plans from fresh snapshots."""

from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
from typing import Iterable, Mapping, Sequence

from .model import (
    BoardField,
    BoardPlan,
    BoardSnapshot,
    CardBaseline,
    CardSnapshot,
    CloseMissingCard,
    CreateDraft,
    DesiredCard,
    DivergenceChange,
    DivergenceKey,
    DraftContent,
    FieldWrite,
    FieldName,
    Fingerprint,
    HoldDeletedTask,
    ItemId,
    KeepDeletedTombstone,
    NoChange,
    OptionId,
    PlanAction,
    Signature,
    SkipRecreatingDeletedCard,
    SyncState,
    TaskId,
    UpdateDraft,
    UpdateIssueFields,
    WakeMissingCard,
    WakeRequest,
    parse_item_id,
    parse_task_id,
)

_US = "\x1f"
_RS = "\x1e"


class PlanError(ValueError):
    """Report a board snapshot that cannot be safely reconciled."""


def _json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _b64(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def _item_task(card: CardSnapshot) -> TaskId | None:
    if card.task is not None:
        return parse_task_id(card.task)
    first = card.content.body.split("\n", 1)[0]
    if len(first) < 3 or first[0] != "`" or first[-1] != "`":
        return None
    try:
        return parse_task_id(first[1:-1])
    except ValueError:
        return None


def _field(snapshot: CardSnapshot, name: FieldName):
    return snapshot.fields.get(name)


def _option(fields: Mapping[FieldName, BoardField], field_name: FieldName, value: str) -> str:
    field = fields.get(field_name)
    if field is None:
        raise PlanError(f"required Helm field is unavailable: {field_name}")
    option = field.options.get(value)
    if option is None:
        raise PlanError(f"required Helm option is unavailable: {field_name}={value}")
    return str(option)


def _field_id(fields: Mapping[FieldName, BoardField], field_name: FieldName) -> str:
    field = fields.get(field_name)
    if field is None:
        raise PlanError(f"required Helm field is unavailable: {field_name}")
    return field.id


def _current_option(card: CardSnapshot, name: FieldName) -> str:
    field = _field(card, name)
    return str(field.option_id) if field is not None and field.option_id is not None else ""


def _current_value(card: CardSnapshot, name: FieldName) -> str:
    field = _field(card, name)
    return field.value if field is not None else ""


def _snapshot_json(card: CardSnapshot) -> str:
    content = card.content
    fields = [
        {"field": value.name, "name": value.value, "optionId": str(value.option_id or "")}
        for value in card.fields.values()
        if value.name
    ]
    fields.sort(key=lambda value: (value["field"], value["optionId"], value["name"]))
    return _json({"title": content.title, "body": content.body, "fields": fields})


def _fingerprint(kind: str, current: str, desired: str) -> Fingerprint:
    encoded = _json([kind, current, desired]).encode("utf-8")
    return Fingerprint(base64.b64encode(encoded).decode("ascii"))


def _divergence_exists(
    divergences: Iterable[DivergenceKey], kind: str, task: TaskId, item: ItemId, fp: str
) -> bool:
    return any(d.kind == kind and d.task == task and d.item == item and d.fingerprint == fp for d in divergences)


def _divergence_for(divergences: Iterable[DivergenceKey], kind: str, task: TaskId) -> DivergenceKey | None:
    return next((d for d in divergences if d.kind == kind and d.task == task), None)


def _priority_digit(value: str) -> str:
    return value[1:] if value in {"P0", "P1", "P2", "P3", "P4"} else ""


def _desired_fingerprint(desired: DesiredCard) -> Fingerprint:
    body_hash = hashlib.sha256(desired.body.encode("utf-8")).hexdigest()
    parts = (
        str(desired.status),
        str(desired.priority),
        str(desired.project),
        str(desired.kind),
        desired.title,
        body_hash,
    )
    return Fingerprint(hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest())


def _cache_row(baseline: CardBaseline) -> str:
    return "\t".join(
        (
            str(baseline.task),
            str(baseline.item),
            baseline.node_id,
            "issue" if baseline.is_issue else "draft",
            baseline.status_option,
            baseline.priority_option,
            _b64(baseline.title),
            _b64(baseline.body),
            baseline.epoch,
            str(baseline.board.owner),
            str(baseline.board.number),
        )
    )


def _writes(
    fields: Mapping[FieldName, BoardField], names: Sequence[tuple[FieldName, str]]
) -> tuple[FieldWrite, ...]:
    return tuple(
        FieldWrite(_field_id(fields, name), name, value, OptionId(option))
        for name, value, option in ((name, value, _option(fields, name, value)) for name, value in names)
    )


def _make_baseline(
    task: TaskId,
    card: CardSnapshot,
    board: BoardSnapshot,
    status_option: str,
    priority_option: str,
    title: str,
    body: str,
    epoch: str,
) -> CardBaseline:
    return CardBaseline(
        task=task,
        item=card.item,
        board=board.board,
        node_id=card.content.node_id,
        is_issue=not isinstance(card.content, DraftContent),
        status_option=status_option,
        priority_option=priority_option,
        title=title,
        body=body,
        epoch=epoch,
    )


def _plan_existing(
    board: BoardSnapshot,
    card: CardSnapshot,
    desired: DesiredCard,
    old: CardBaseline | None,
    state: SyncState,
    *,
    force: bool,
    dispatch_status: str,
    epoch: str,
) -> PlanAction:
    task = desired.task
    item = parse_item_id(card.item)
    fields = board.fields
    card_title = card.content.title
    card_body = card.content.body
    is_issue = not isinstance(card.content, DraftContent)
    node_id = card.content.node_id
    status_field = _field_id(fields, "Status")
    project_field = _field_id(fields, "Project")
    kind_field = _field_id(fields, "Kind")
    priority_field = _field_id(fields, "Priority")
    status_option = _option(fields, "Status", str(desired.status))
    project_option = _option(fields, "Project", str(desired.project))
    kind_option = _option(fields, "Kind", str(desired.kind))
    priority_option = _option(fields, "Priority", str(desired.priority))

    current_status = _current_option(card, "Status")
    current_priority = _current_option(card, "Priority")
    rebuilt = old is None or not old.version_two
    base_status = current_status if rebuilt else old.status_option
    base_priority = current_priority if rebuilt else old.priority_option
    base_title = card_title if rebuilt else old.title
    base_body = card_body if rebuilt else old.body

    current_title_b64 = _b64(card_title)
    current_body_b64 = _b64(card_body)
    desired_title_b64 = _b64(desired.title)
    desired_body_b64 = _b64(desired.body)
    base_title_b64 = _b64(base_title)
    base_body_b64 = _b64(base_body)

    status_normal = rebuilt or current_status == base_status
    status_board_changed = current_status != base_status
    waiting_option = _option(fields, "Status", "Waiting on you")
    dispatch_option = _option(fields, "Status", dispatch_status)
    done_option = _option(fields, "Status", "Done")
    waiting_status_changed = current_status == waiting_option and status_board_changed
    priority_board_changed = current_priority != base_priority and priority_option == base_priority
    title_board_changed = current_title_b64 != base_title_b64 and desired_title_b64 == base_title_b64
    body_board_changed = current_body_b64 != base_body_b64 and desired_body_b64 == base_body_b64
    status_conflict = current_status != base_status and status_option != base_status and current_status != status_option
    priority_conflict = current_priority != base_priority and priority_option != base_priority and current_priority != priority_option
    title_conflict = current_title_b64 != base_title_b64 and desired_title_b64 != base_title_b64 and current_title_b64 != desired_title_b64
    body_conflict = current_body_b64 != base_body_b64 and desired_body_b64 != base_body_b64 and current_body_b64 != desired_body_b64
    any_conflict = status_conflict or priority_conflict or title_conflict or body_conflict

    title_write = not title_conflict and current_title_b64 != desired_title_b64 and not title_board_changed
    body_write = not body_conflict and current_body_b64 != desired_body_b64 and not body_board_changed
    text_write = title_write or body_write

    title_fp = _fingerprint("title", current_title_b64, desired_title_b64)
    body_fp = _fingerprint("body", current_body_b64, desired_body_b64)
    status_fp = _fingerprint("status", current_status, status_option)
    priority_fp = _fingerprint("priority", current_priority, priority_option)
    title_edit = title_board_changed or title_conflict
    body_edit = body_board_changed or body_conflict
    title_edit_wake = title_edit and not _divergence_exists(
        state.divergences, "card-edit-title", task, item, title_fp
    )
    body_edit_wake = body_edit and not _divergence_exists(
        state.divergences, "card-edit-body", task, item, body_fp
    )
    conflict_wake = (
        (status_conflict and not _divergence_exists(state.divergences, "conflict-status", task, item, status_fp))
        or (priority_conflict and not _divergence_exists(state.divergences, "conflict-priority", task, item, priority_fp))
        or (title_conflict and not _divergence_exists(state.divergences, "conflict-title", task, item, title_fp))
        or (body_conflict and not _divergence_exists(state.divergences, "conflict-body", task, item, body_fp))
    )

    current_status_value = _current_value(card, "Status")
    current_priority_value = _current_value(card, "Priority")
    priority_digit = _priority_digit(current_priority_value)
    writeback = priority_digit if priority_board_changed and priority_digit else ""
    dispatch = (
        current_status == dispatch_option
        and status_board_changed
        and str(desired.status) != dispatch_status
        and str(desired.status) != "Done"
    )
    dispatch_fp = f"{item}:{dispatch_option}"
    marker_action = ""
    wakes: list[WakeRequest] = []
    if not is_issue and (title_edit_wake or body_edit_wake):
        wakes.append(
            WakeRequest(
                f"helm-card-edit:{task}",
                f"check: captain edited Helm card {task} text; reconcile it into the backlog",
            )
        )
    if dispatch:
        marker = state.dispatches.get(task)
        if marker is not None and str(marker.fingerprint) == dispatch_fp:
            marker_action = ""
        else:
            marker_action = "request"
            wakes.append(
                WakeRequest(
                    f"helm-dispatch:{task}",
                    f"check: Helm dispatch request for {task} (board item {item})",
                )
            )
    elif task in state.dispatches:
        marker_action = "remove"

    deferred = False
    status_deferred_kind = ""
    status_deferred_fp = ""
    if not dispatch and current_status_value != str(desired.status) and current_status == waiting_option:
        waiting_fp = f"{current_status}:{status_option}"
        marker = _divergence_for(state.divergences, "status-waiting", task)
        if status_board_changed or (marker is not None and marker.fingerprint == waiting_fp):
            deferred = True
            status_deferred_kind = "status-waiting"
            status_deferred_fp = waiting_fp
            if marker is None or marker.fingerprint != waiting_fp:
                wakes.append(
                    WakeRequest(
                        f"helm-status-waiting:{task}",
                        f"check: captain moved Helm card {task} to Waiting on you; reconcile it into the backlog",
                    )
                )
    elif not dispatch and status_board_changed and current_status_value != str(desired.status):
        if current_status_value == "Done" and str(desired.status) != "Done":
            deferred = True
            status_deferred_kind = "status-done"
            status_deferred_fp = current_status
            marker = _divergence_for(state.divergences, status_deferred_kind, task)
            if marker is None or marker.fingerprint != status_deferred_fp:
                wakes.append(
                    WakeRequest(
                        f"helm-status-done:{task}",
                        f"check: captain moved Helm card {task} to Done while the task is live; confirm and reconcile",
                    )
                )
        elif (current_status_value == "Queued" and str(desired.status) in {"In flight", "Done"}) or (
            current_status_value == "In flight" and str(desired.status) == "Done"
        ):
            deferred = True
            status_deferred_kind = "status-back"
            status_deferred_fp = current_status
            marker = _divergence_for(state.divergences, status_deferred_kind, task)
            if marker is None or marker.fingerprint != status_deferred_fp:
                wakes.append(
                    WakeRequest(
                        f"helm-status-back:{task}",
                        f"check: captain moved Helm card {task} back to {current_status_value}; reconcile it into the backlog",
                    )
                )
    if conflict_wake:
        wakes.append(
            WakeRequest(
                f"helm-card-edit:{task}",
                f"check: Helm card {task} changed on both board and backlog; reconcile the conflict",
            )
        )

    field_writes: list[FieldWrite] = []
    if not status_conflict and not dispatch and not deferred and status_normal and current_status_value != str(desired.status):
        field_writes.append(FieldWrite(status_field, "Status", str(desired.status), OptionId(status_option)))
    if _current_option(card, "Project") != project_option:
        field_writes.append(FieldWrite(project_field, "Project", str(desired.project), OptionId(project_option)))
    if _current_option(card, "Kind") != kind_option:
        field_writes.append(FieldWrite(kind_field, "Kind", str(desired.kind), OptionId(kind_option)))
    if not priority_conflict and not writeback and _current_option(card, "Priority") != priority_option:
        field_writes.append(FieldWrite(priority_field, "Priority", str(desired.priority), OptionId(priority_option)))

    if status_conflict:
        cache_status = base_status
    elif any(write.name == "Status" for write in field_writes):
        cache_status = status_option
    elif waiting_status_changed:
        cache_status = current_status
    elif rebuilt or status_normal or current_status == status_option:
        cache_status = status_option
    else:
        cache_status = base_status

    if priority_conflict:
        cache_priority = base_priority
    elif any(write.name == "Priority" for write in field_writes):
        cache_priority = priority_option
    elif rebuilt:
        cache_priority = priority_option
    elif priority_board_changed:
        cache_priority = current_priority
    else:
        cache_priority = priority_option

    text_board_changed = title_board_changed or body_board_changed
    cache_title = (
        desired_title_b64
        if title_write or rebuilt or current_title_b64 == desired_title_b64 or not title_board_changed
        else base_title_b64
    )
    if title_conflict:
        cache_title = base_title_b64
    cache_body = (
        desired_body_b64
        if body_write or rebuilt or current_body_b64 == desired_body_b64 or not body_board_changed
        else base_body_b64
    )
    if body_conflict:
        cache_body = base_body_b64
    baseline = _make_baseline(
        task,
        card,
        board,
        cache_status,
        cache_priority,
        _decode_b64(cache_title),
        _decode_b64(cache_body),
        epoch,
    )

    note, note_changes = _unsupported_repo_note(desired, state)
    unsupported_marker = _divergence_for(state.divergences, "unsupported-repo", task)

    # A normal sync can avoid reprocessing an unchanged desired baseline. Poll
    # requests set force so captain edits reach this three-way comparison.
    if (
        not force
        and old is not None
        and old.version_two
        and old.status_option == status_option
        and old.priority_option == priority_option
        and old.title == desired.title
        and old.body == desired.body
        and not desired.note
        and unsupported_marker is None
    ):
        if any_conflict:
            early_baseline = _make_baseline(
                task,
                card,
                board,
                base_status,
                base_priority,
                base_title,
                base_body,
                epoch,
            )
        else:
            early_title = (
                desired_title_b64
                if rebuilt or (current_title_b64 == desired_title_b64 and current_body_b64 == desired_body_b64) or not text_board_changed
                else base_title_b64
            )
            early_body = (
                desired_body_b64
                if rebuilt or (current_title_b64 == desired_title_b64 and current_body_b64 == desired_body_b64) or not text_board_changed
                else base_body_b64
            )
            early_baseline = _make_baseline(
                task,
                card,
                board,
                cache_status,
                cache_priority,
                _decode_b64(early_title),
                _decode_b64(early_body),
                epoch,
            )
        return NoChange(
            task,
            item,
            early_baseline,
            card,
            fingerprint=Fingerprint(""),
            note=note,
            compatibility_only=True,
        )

    div_changes: list[DivergenceChange] = list(note_changes)
    _change(div_changes, state, "card-edit-title", task, item, title_fp, title_edit)
    _change(div_changes, state, "card-edit-body", task, item, body_fp, body_edit)
    _change(div_changes, state, "conflict-status", task, item, status_fp, status_conflict)
    _change(div_changes, state, "conflict-priority", task, item, priority_fp, priority_conflict)
    _change(div_changes, state, "conflict-title", task, item, title_fp, title_conflict)
    _change(div_changes, state, "conflict-body", task, item, body_fp, body_conflict)
    for kind, fp in (("card-edit", ""), ("conflict", ""), ("new-card", ""), ("card-deleted", "")):
        _change(div_changes, state, kind, task, item, fp, False, remove_existing=True)
    if status_deferred_kind:
        _change(div_changes, state, status_deferred_kind, task, item, status_deferred_fp, True)
    else:
        for kind in ("status-back", "status-done", "status-waiting"):
            _change(div_changes, state, kind, task, item, "", False, remove_existing=True)

    acknowledge: dict[str, object] = {
        "new": False,
        "text": text_write and not is_issue,
        "title": desired.title if title_write else card_title,
        "body": desired.body if body_write else card_body,
        "fields": [
            {"name": write.name, "value": write.value, "option": str(write.option_id)}
            for write in field_writes
        ],
    }
    final_title = desired.title if title_write else card_title
    final_body = desired.body if body_write else card_body
    common = {
        "wakes": tuple(wakes),
        "divergence_changes": tuple(div_changes),
        "marker_action": marker_action,
        "marker_fingerprint": dispatch_fp,
        "writeback_priority": writeback,
        "home_path": desired.home_path,
        "fingerprint": _desired_fingerprint(desired),
        "note": note,
    }
    if is_issue:
        action_type = UpdateIssueFields if field_writes else NoChange
        if action_type is NoChange:
            return NoChange(
                task,
                item,
                baseline,
                card,
                title=final_title,
                body=final_body,
                field_writes=tuple(field_writes),
                acknowledge=acknowledge,
                **common,
            )
        return UpdateIssueFields(
            task,
            item,
            tuple(field_writes),
            card,
            baseline,
            acknowledge,
            **common,
        )
    if text_write or field_writes:
        return UpdateDraft(
            task=task,
            item=item,
            draft_issue_id=node_id if text_write else None,
            title=final_title,
            body=final_body,
            text_changed=text_write,
            field_writes=tuple(field_writes),
            expected=card,
            baseline=baseline,
            acknowledge=acknowledge,
            **common,
        )
    return NoChange(
        task,
        item,
        baseline,
        card,
        title=final_title,
        body=final_body,
        field_writes=tuple(field_writes),
        acknowledge=acknowledge,
        **common,
    )


def _decode_b64(value: str) -> str:
    return base64.b64decode(value.encode("ascii")).decode("utf-8")


def _change(
    changes: list[DivergenceChange],
    state: SyncState,
    kind: str,
    task: TaskId,
    item: ItemId,
    fp: str,
    active: bool,
    *,
    remove_existing: bool = False,
) -> None:
    existing = _divergence_for(state.divergences, kind, task)
    if active:
        changes.append(DivergenceChange(kind, "keep", str(item), fp))
    elif remove_existing and existing is not None:
        changes.append(DivergenceChange(kind, "remove", str(item), ""))


def _record_repo(card: DesiredCard) -> str:
    return card.repository or ""


def _unsupported_repo_note(
    desired: DesiredCard,
    state: SyncState,
) -> tuple[str, tuple[DivergenceChange, ...]]:
    """Return the visible unsupported-repository note and its marker update."""
    task = desired.task
    marker = _divergence_for(state.divergences, "unsupported-repo", task)
    if desired.note:
        fingerprint = Fingerprint(_b64(_json(_record_repo(desired))))
        note = "" if _divergence_exists(
            state.divergences,
            "unsupported-repo",
            task,
            ItemId(""),
            str(fingerprint),
        ) else desired.note
        return note, (DivergenceChange("unsupported-repo", "keep", "", str(fingerprint)),)
    if marker is not None:
        return "", (DivergenceChange("unsupported-repo", "remove", "", ""),)
    return "", ()


def _missing_phase_actions(
    snapshot: BoardSnapshot, desired_by_task: Mapping[TaskId, DesiredCard], state: SyncState
) -> list[PlanAction]:
    """Close or wake on previously seen and never-before-seen orphan cards.

    Mirrors ``bin/fm-helm-lib.sh``'s ``missing_entries``: a card with no valid
    task-id body is left untouched (matching jq's "ignore" branch, which this
    port does not yet raise a note for), a valid but never-before-seen task id
    (a captain-created card with no backlog task) wakes intake instead of
    being closed when the identity cache already existed before this run,
    and every other orphaned task is closed. When this board's desired set is
    empty, no card on the board is touched, matching jq's own guard against a
    failed or empty backlog read mass-closing or mass-waking every card.
    """
    if not desired_by_task:
        return []
    done_option = _option(snapshot.fields, "Status", "Done")
    status_field = _field_id(snapshot.fields, "Status")
    actions: list[PlanAction] = []
    for card in snapshot.cards:
        task = _item_task(card)
        if task is None or task in desired_by_task:
            continue
        if _current_option(card, "Status") == done_option:
            continue
        item = parse_item_id(card.item)
        if state.cache_existed and task not in state.cards:
            fingerprint = str(item)
            wakes: tuple[WakeRequest, ...] = ()
            if not _divergence_exists(state.divergences, "new-card", task, item, fingerprint):
                wakes = (
                    WakeRequest(
                        f"helm-new-card:{task}",
                        f"check: captain added Helm card {task} with no backlog task; run intake",
                    ),
                )
            actions.append(
                WakeMissingCard(
                    task=task,
                    item=item,
                    wakes=wakes,
                    divergence_changes=(DivergenceChange("new-card", "keep", str(item), fingerprint),),
                )
            )
            continue
        actions.append(
            CloseMissingCard(
                task=task,
                item=item,
                field_write=FieldWrite(status_field, "Status", "Done", OptionId(done_option)),
                expected=card,
                acknowledge={
                    "new": False,
                    "text": False,
                    "fields": [{"name": "Status", "value": "Done", "option": done_option}],
                },
            )
        )
    return actions


_DELETED_CARD_CHOICES = "the task is queued: cancel it (Done), mark it done, or was the card deleted by mistake"


def _deleted_phase_actions(
    snapshot: BoardSnapshot,
    desired_by_task: Mapping[TaskId, DesiredCard],
    state: SyncState,
) -> list[PlanAction]:
    """Preserve a captain-deleted card instead of silently recreating it.

    Mirrors ``bin/fm-helm-lib.sh``'s ``deleted_entries``: a cached task whose
    item id is gone from the board and whose task id has no replacement card
    is either retained silently (task already Done, or already under an
    existing captain hold) or raises a captain hold. This port does not
    distinguish in-flight/blocked task states from queued, since
    ``DesiredCard`` carries no such field; every hold uses the same
    queued-style choices text.
    """
    item_set = {card.item for card in snapshot.cards}
    line1_tasks = {task for card in snapshot.cards if (task := _item_task(card)) is not None}
    actions: list[PlanAction] = []
    for task, baseline in state.cards.items():
        if baseline.board != snapshot.board:
            continue
        if baseline.item in item_set or task in line1_tasks:
            continue
        wanted = desired_by_task.get(task)
        if wanted is None:
            continue
        if str(wanted.status) == "Done" or wanted.hold_kind == "captain":
            actions.append(KeepDeletedTombstone(task, baseline.item))
            continue
        fingerprint = str(baseline.item)
        wakes: tuple[WakeRequest, ...] = ()
        if not _divergence_exists(state.divergences, "card-deleted", task, baseline.item, fingerprint):
            wakes = (
                WakeRequest(
                    f"helm-card-deleted:{task}",
                    f"check: captain deleted Helm card {task} ({_DELETED_CARD_CHOICES})",
                ),
            )
        actions.append(
            HoldDeletedTask(
                task=task,
                item=baseline.item,
                home_path=wanted.home_path,
                reason=f"Helm card deleted; {_DELETED_CARD_CHOICES}.",
                wakes=wakes,
                divergence_changes=(DivergenceChange("card-deleted", "keep", str(baseline.item), fingerprint),),
            )
        )
    return actions


def plan_board(
    snapshot: BoardSnapshot,
    desired: Mapping[TaskId, DesiredCard] | Sequence[DesiredCard],
    state: SyncState,
    *,
    force: bool = False,
    dispatch_status: str = "In flight",
    epoch: str = "0",
) -> BoardPlan:
    """Plan fieldwise reconciliation for one fresh board snapshot.

    Args:
        snapshot: Fresh board contents and schema.
        desired: Desired cards keyed by task id or provided in source order.
        state: Previously acknowledged cache and divergence markers.
        force: Whether the caller requires a full reconciliation pass.
        dispatch_status: Status option used to recognize a dispatch request.
        epoch: Run epoch recorded in resulting card baselines.

    Returns:
        An immutable board plan with one primary action per desired card.

    Raises:
        PlanError: If the board contains duplicate card identities or required schema.
    """
    desired_cards = tuple(desired.values()) if isinstance(desired, Mapping) else tuple(desired)
    desired_by_task = {card.task: card for card in desired_cards if card.board == snapshot.board}
    if len(desired_by_task) != len([card for card in desired_cards if card.board == snapshot.board]):
        raise PlanError("desired cards contain duplicate task identifiers")
    cards_by_task: dict[TaskId, CardSnapshot] = {}
    for card in snapshot.cards:
        task = _item_task(card)
        if task is None or task not in desired_by_task:
            continue
        if task in cards_by_task:
            raise PlanError(f"duplicate Helm cards for {task}")
        cards_by_task[task] = card
    item_set = {card.item for card in snapshot.cards}

    actions: list[PlanAction] = []
    for task, wanted in desired_by_task.items():
        current = cards_by_task.get(task)
        old = state.cards.get(task)
        if current is None:
            tombstone = state.tombstones.get(task)
            if tombstone is not None:
                note, _ = _unsupported_repo_note(wanted, state)
                actions.append(SkipRecreatingDeletedCard(task, f"{tombstone.task}\t{tombstone.item}", note))
                continue
            if old is not None and str(wanted.status) != "Done" and old.item and old.item not in item_set:
                note, _ = _unsupported_repo_note(wanted, state)
                actions.append(SkipRecreatingDeletedCard(task, "", note))
                continue
            note, note_changes = _unsupported_repo_note(wanted, state)
            field_writes = _writes(
                snapshot.fields,
                (
                    ("Status", str(wanted.status)),
                    ("Project", str(wanted.project)),
                    ("Kind", str(wanted.kind)),
                    ("Priority", str(wanted.priority)),
                ),
            )
            baseline = CardBaseline(
                task=task,
                item=ItemId(""),
                board=snapshot.board,
                node_id="",
                is_issue=False,
                status_option=str(field_writes[0].option_id),
                priority_option=str(field_writes[-1].option_id),
                title=wanted.title,
                body=wanted.body,
                epoch=epoch,
            )
            actions.append(
                CreateDraft(
                    task,
                    wanted,
                    field_writes,
                    baseline,
                    {"new": True, "title": wanted.title, "body": wanted.body},
                    _desired_fingerprint(wanted),
                    note_changes,
                    note,
                )
            )
            continue
        actions.append(
            _plan_existing(
                snapshot,
                current,
                wanted,
                old,
                state,
                force=force,
                dispatch_status=dispatch_status,
                epoch=epoch,
            )
        )

    actions.extend(_missing_phase_actions(snapshot, desired_by_task, state))
    actions.extend(_deleted_phase_actions(snapshot, desired_by_task, state))

    canonical = [
        {
            "item": str(card.item),
            "task": str(_item_task(card) or ""),
            "title": card.content.title,
            "body": card.content.body,
            "fields": sorted(
                (value.name, value.value, str(value.option_id or "")) for value in card.fields.values()
            ),
        }
        for card in snapshot.cards
    ]
    signature = hashlib.sha256(_json(canonical).encode("utf-8")).hexdigest()
    return BoardPlan(snapshot.board, tuple(actions), Signature(signature))


def _legacy_action_bytes(action: PlanAction) -> bytes:
    """Project a typed card decision to the live jq stream for parity tests."""
    if isinstance(action, CreateDraft):
        return _legacy_create_bytes(action)
    if isinstance(action, CloseMissingCard):
        return _legacy_missing_close_bytes(action)
    if isinstance(action, WakeMissingCard):
        return _legacy_missing_wake_bytes(action)
    if isinstance(action, KeepDeletedTombstone):
        return _legacy_deleted_retain_bytes(action)
    if isinstance(action, HoldDeletedTask):
        return _legacy_deleted_hold_bytes(action)
    if isinstance(action, SkipRecreatingDeletedCard):
        return _legacy_skip_deleted_bytes(action)
    if not isinstance(action, (NoChange, UpdateDraft, UpdateIssueFields)):
        return b""
    baseline = action.baseline
    if isinstance(action, NoChange) and action.compatibility_only:
        values = (
            "record", "none", str(baseline.task), str(baseline.item), _cache_row(baseline),
            "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", action.note,
        )
        return "\0".join(values).encode("utf-8") + b"\0"
    draft_id = action.draft_issue_id or "" if isinstance(action, UpdateDraft) else ""
    title = action.title if isinstance(action, (NoChange, UpdateDraft)) else str(action.acknowledge["title"])
    body = action.body if isinstance(action, (NoChange, UpdateDraft)) else str(action.acknowledge["body"])
    writes = action.field_writes if isinstance(action, (NoChange, UpdateDraft, UpdateIssueFields)) else ()
    wakes = action.wakes
    div_changes = action.divergence_changes
    expected = _snapshot_json(action.expected)
    acknowledge = _json(dict(action.acknowledge))
    home = str(action.home_path) if action.home_path else ""
    marker = action.marker_action
    marker_fp = action.marker_fingerprint
    writeback = action.writeback_priority
    fingerprint = str(action.fingerprint)
    note = action.note
    action_name = "none" if isinstance(action, NoChange) else "update"
    fields_text = _US.join(
        _RS.join((write.field_id, write.name, write.value, str(write.option_id))) for write in writes
    )
    wakes_text = _US.join(_RS.join((wake.key, wake.payload)) for wake in wakes)
    div_text = _US.join(
        _RS.join((change.kind, change.action, change.item, change.fingerprint)) for change in div_changes
    )
    values = (
        "record",
        action_name,
        str(baseline.task),
        str(baseline.item),
        _cache_row(baseline),
        draft_id,
        title,
        body,
        fields_text,
        wakes_text,
        marker,
        marker_fp,
        div_text,
        writeback,
        home,
        "",
        "",
        expected,
        "",
        acknowledge,
        fingerprint,
        note,
    )
    return "\0".join(values).encode("utf-8") + b"\0"


def _legacy_create_bytes(action: CreateDraft) -> bytes:
    writes = action.field_writes
    fields_text = _US.join(
        _RS.join((write.field_id, write.name, write.value, str(write.option_id))) for write in writes
    )
    div_text = _US.join(
        _RS.join((change.kind, change.action, change.item, change.fingerprint))
        for change in action.divergence_changes
    )
    baseline = action.baseline
    cache = "\t".join(
        (
            str(baseline.task),
            "",
            "",
            "draft",
            baseline.status_option,
            baseline.priority_option,
            _b64(baseline.title),
            _b64(baseline.body),
            baseline.epoch,
            str(baseline.board.owner),
            str(baseline.board.number),
        )
    )
    values = (
        "record",
        "create",
        str(action.task),
        "",
        cache,
        "",
        action.desired.title,
        action.desired.body,
        fields_text,
        "",
        "",
        "",
        div_text,
        "",
        str(action.desired.home_path or ""),
        "",
        "",
        _json({"title": action.desired.title, "body": action.desired.body, "fields": []}),
        _json(dict(action.acknowledge)),
        _json({"new": False, "text": False, "fields": [{"name": w.name, "value": w.value, "option": str(w.option_id)} for w in writes]}),
        str(action.fingerprint),
        action.note,
    )
    return "\0".join(values).encode("utf-8") + b"\0"


def _legacy_skip_deleted_bytes(action: SkipRecreatingDeletedCard) -> bytes:
    values = (
        "record", "skip", str(action.task), "", "", "", "", "", "", "", "", "", "", "", "",
        action.tombstone, "", "", "", "", "", action.note,
    )
    return "\0".join(values).encode("utf-8") + b"\0"


def _legacy_missing_close_bytes(action: CloseMissingCard) -> bytes:
    write = action.field_write
    fields_text = _RS.join((write.field_id, write.name, write.value, str(write.option_id)))
    values = (
        "missing", "close", str(action.task), str(action.item), "", "", "", "",
        fields_text, "", "", "", "", "", "", "", "",
        _snapshot_json(action.expected), "", _json(dict(action.acknowledge)), "", "",
    )
    return "\0".join(values).encode("utf-8") + b"\0"


def _legacy_missing_wake_bytes(action: WakeMissingCard) -> bytes:
    wakes_text = _US.join(_RS.join((wake.key, wake.payload)) for wake in action.wakes)
    div_text = _US.join(
        _RS.join((change.kind, change.action, change.item, change.fingerprint))
        for change in action.divergence_changes
    )
    values = (
        "missing", "wake", str(action.task), str(action.item), "", "", "", "",
        "", wakes_text, "", "", div_text, "", "", "", "",
        "", "", "", "", "",
    )
    return "\0".join(values).encode("utf-8") + b"\0"


def _legacy_deleted_retain_bytes(action: KeepDeletedTombstone) -> bytes:
    tombstone = f"{action.task}\t{action.item}"
    values = (
        "deleted", "retain", str(action.task), "", "", "", "", "", "", "", "", "", "", "", "",
        tombstone, "", "", "", "", "", "",
    )
    return "\0".join(values).encode("utf-8") + b"\0"


def _legacy_deleted_hold_bytes(action: HoldDeletedTask) -> bytes:
    tombstone = f"{action.task}\t{action.item}"
    wakes_text = _US.join(_RS.join((wake.key, wake.payload)) for wake in action.wakes)
    div_text = _US.join(
        _RS.join((change.kind, change.action, change.item, change.fingerprint))
        for change in action.divergence_changes
    )
    home = str(action.home_path) if action.home_path else ""
    values = (
        "deleted", "hold", str(action.task), str(action.item), "", "", "", "", "",
        wakes_text, "", "", div_text, "", home, tombstone, action.reason, "", "", "", "", "",
    )
    return "\0".join(values).encode("utf-8") + b"\0"


def _serialize_plan_for_jq_parity(plan: BoardPlan) -> bytes:
    """Encode a typed board plan in the existing jq format for parity tests."""
    return b"".join(_legacy_action_bytes(action) for action in plan.actions)
