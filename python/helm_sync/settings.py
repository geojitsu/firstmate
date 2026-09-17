"""Read and validate Helm's opt-in configuration boundary."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

from .model import BoardRef, StatusName, parse_owner, parse_project_number


@dataclass(frozen=True)
class Disabled:
    """Represent an absent Helm configuration without reading other inputs."""


@dataclass(frozen=True)
class HelmSettings:
    """Hold the validated default board and dispatch Status option."""

    default_board: BoardRef
    dispatch_status: StatusName
    config_path: Path


class SettingsError(ValueError):
    """Report an invalid or unsafe Helm configuration file."""


SettingsResult = Disabled | HelmSettings


def load_settings(home: Path) -> SettingsResult:
    """Load Helm configuration, returning Disabled when opt-in is absent.

    Args:
        home: Root of the local Helm home.

    Returns:
        Disabled when ``config/helm.json`` is absent, otherwise validated settings.

    Raises:
        SettingsError: If configuration is linked, unreadable, malformed, or invalid.
    """
    config_path = home / "config" / "helm.json"
    if config_path.is_symlink():
        raise SettingsError("config/helm.json must be a regular non-symlink file")
    if not config_path.exists():
        return Disabled()
    if not config_path.is_file():
        raise SettingsError("config/helm.json must be a regular non-symlink file")
    try:
        content = "\n".join(
            line for line in config_path.read_text(encoding="utf-8").splitlines()
            if not line.lstrip().startswith(("//", "#"))
        )
        raw = json.loads(content)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SettingsError("config/helm.json could not be read as JSON") from exc
    return settings_from_mapping(raw, config_path)


def settings_from_mapping(raw: object, config_path: Path) -> HelmSettings:
    """Validate decoded configuration data at the JSON boundary.

    Args:
        raw: Decoded configuration value.
        config_path: Source path retained for diagnostics and future consumers.

    Returns:
        A validated HelmSettings record.

    Raises:
        SettingsError: If required values have invalid types or values.
    """
    if not isinstance(raw, Mapping):
        raise SettingsError("config/helm.json must contain an object")
    try:
        owner = parse_owner(raw.get("owner"))
        number = parse_project_number(raw.get("number"))
    except ValueError as exc:
        raise SettingsError(f"config/helm.json has invalid default board: {exc}") from exc
    dispatch_status = raw.get("dispatch_status")
    if dispatch_status is None:
        dispatch_status = "In flight"
    if not isinstance(dispatch_status, str) or not dispatch_status:
        raise SettingsError("config/helm.json has an empty or invalid dispatch_status")
    return HelmSettings(BoardRef(owner, number), StatusName(dispatch_status), config_path)
