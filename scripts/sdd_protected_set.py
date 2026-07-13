#!/usr/bin/env python3
"""Single source of truth for the Core-baseline protected file set."""

from __future__ import annotations

import glob
import sys
from importlib import metadata
from pathlib import Path


# The runtime pins are declared in two protected files — `.python-version`
# (exact CPython version) and `scripts/requirements-sdd.txt` (exact PyYAML
# version) — and are parsed here so there is exactly one source of truth per
# pin. Unreadable or malformed pin files fail closed.
_PIN_ROOT = Path(__file__).resolve().parent.parent


def _pinned_python() -> tuple[int, int, int] | None:
    try:
        raw = (_PIN_ROOT / ".python-version").read_text(encoding="utf-8").strip()
        major, minor, micro = (int(part) for part in raw.split("."))
    except (OSError, ValueError):
        return None
    return (major, minor, micro)


def _pinned_pyyaml() -> str | None:
    try:
        lines = (_PIN_ROOT / "scripts/requirements-sdd.txt").read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("PyYAML=="):
            return stripped.removeprefix("PyYAML==")
    return None


def require_sdd_runtime() -> None:
    """Fail closed unless the SDD tooling runs on the pinned runtime.

    The pinned versions come from `.python-version` and
    `scripts/requirements-sdd.txt`; both files are part of the protected set,
    so drifting them without a candidate relock already fails the guard.
    """

    required_python = _pinned_python()
    if required_python is None:
        print(
            "ERROR: ArkDeck SDD tooling cannot read the pinned CPython version "
            "from .python-version.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    python_label = ".".join(str(part) for part in required_python)
    supported = (
        sys.implementation.name == "cpython"
        and tuple(sys.version_info[:3]) == required_python
        and sys.version_info.releaselevel == "final"
        and sys.version_info.serial == 0
    )
    if not supported:
        print(f"ERROR: ArkDeck SDD tooling requires CPython {python_label}.", file=sys.stderr)
        raise SystemExit(1)

    required_pyyaml = _pinned_pyyaml()
    if required_pyyaml is None:
        print(
            "ERROR: ArkDeck SDD tooling cannot read the pinned PyYAML version "
            "from scripts/requirements-sdd.txt.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    try:
        pyyaml_version = metadata.version("PyYAML")
    except metadata.PackageNotFoundError:
        pyyaml_version = None
    if pyyaml_version != required_pyyaml:
        print(
            f"ERROR: ArkDeck SDD tooling requires PyYAML {required_pyyaml}; install "
            f"scripts/requirements-sdd.txt with CPython {python_label}.",
            file=sys.stderr,
        )
        raise SystemExit(1)


# Both the guard (check_sdd.py) and the candidate relock tool
# (relock_baseline.py) MUST consume this constant. Editing this list is a
# governance change: the file itself is part of the protected set, so any
# modification requires a candidate relock before ratification and an approved
# Core change afterwards.
SDD_PROTECTED_PATTERNS: tuple[str, ...] = (
    ".github/CODEOWNERS",
    ".github/workflows/agent-pr.yml",
    ".github/workflows/sdd-guard.yml",
    ".python-version",
    "AGENTS.md",
    "openspec/README.md",
    "openspec/constitution.md",
    "openspec/project.md",
    "openspec/config.yaml",
    "openspec/governance/**/*",
    "openspec/architecture/**/*",
    "openspec/schemas/**/*",
    "openspec/templates/change/**/*",
    "openspec/changes/README.md",
    "openspec/specs/**/*",
    "openspec/contracts/*.schema.json",
    "openspec/contracts/provider-contracts.md",
    "openspec/contracts/workflow-step-registry.yaml",
    "openspec/contracts/capability-registry.yaml",
    "openspec/contracts/catalogs/remote-operations.yaml",
    "openspec/verification/policy.md",
    "openspec/verification/acceptance-index.txt",
    "openspec/verification/acceptance-cases.yaml",
    "scripts/check_sdd.py",
    "scripts/sdd_guard_core.py",
    "scripts/sdd_guard_lifecycle.py",
    "scripts/sdd_guard_release.py",
    "scripts/check-sdd.sh",
    "scripts/check-json.py",
    "scripts/sdd_guard_support.py",
    "scripts/sdd_protected_set.py",
    "scripts/relock_baseline.py",
    "scripts/guard_selftest.py",
    "scripts/requirements-sdd.txt",
)


def sdd_protected_files(root: str | Path) -> list[str]:
    """Expand the protected patterns into sorted repo-relative file paths."""

    root_path = Path(root).resolve()
    protected: set[str] = set()
    for pattern in SDD_PROTECTED_PATTERNS:
        for raw_path in glob.glob(str(root_path / pattern), recursive=True):
            path = Path(raw_path)
            if path.is_file():
                protected.add(path.relative_to(root_path).as_posix())
    return sorted(protected)
