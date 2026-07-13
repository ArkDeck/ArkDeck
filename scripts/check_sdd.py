#!/usr/bin/env python3.14
"""Fail-closed ArkDeck SDD governance guard.

This is the CPython 3.14 port of the original repository guard.  The product
rules live in ``openspec``; this program only enforces those immutable rules.
It deliberately avoids shell command strings and invokes Git/verifiers with
argument arrays.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from sdd_protected_set import require_sdd_runtime


ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    """Run every SDD validation and preserve the guard's stable CLI contract."""

    require_sdd_runtime()
    errors: list[str] = []

    try:
        from sdd_guard_core import run_core_guard
    except ImportError as exc:
        errors.append(f"Python SDD guard component unavailable: {exc.name}")
        context: dict[str, object] = {}
    else:
        context = run_core_guard(ROOT, errors)

    # Deep lifecycle validation is intentionally a separate phase: it consumes
    # only the already ambiguity-checked documents returned by the Core phase.
    # This prevents a task/archive parser from interpreting bytes differently
    # from the baseline and specification parser.
    try:
        from sdd_guard_lifecycle import run_lifecycle_guard
    except ImportError as exc:
        errors.append(f"Python SDD guard component unavailable: {exc.name}")
        lifecycle_context: dict[str, object] = {}
    else:
        lifecycle_context = run_lifecycle_guard(ROOT, errors, context)

    context.update(lifecycle_context)
    context["_identity_inventory_sink"] = {}
    try:
        from sdd_guard_release import run_release_guard
    except ImportError as exc:
        errors.append(f"Python SDD guard component unavailable: {exc.name}")
    else:
        run_release_guard(ROOT, errors, context)

    # Tooling hook: scripts/ledger_snapshot.py builds the external identity
    # ledger from exactly the guard's inventory (never a second implementation).
    dump_target = os.environ.get("ARKDECK_DUMP_INVENTORY")
    if dump_target:
        entries = sorted(
            (
                {"kind": kind, "id": identity, "revision": revision, "sha256": digest}
                for (kind, identity, revision), digest in context[
                    "_identity_inventory_sink"
                ].items()
            ),
            key=lambda entry: (entry["kind"], entry["id"], entry["revision"]),
        )
        Path(dump_target).write_text(
            json.dumps(entries, indent=1) + "\n", encoding="utf-8"
        )

    if errors:
        print("\n".join(f"ERROR: {error}" for error in errors), file=sys.stderr)
        return 1

    requirements = context.get("requirements", {})
    acceptance = context.get("acceptance", {})
    print(
        f"SDD checks passed: {len(requirements)} requirements, "
        f"{len(acceptance)} acceptance scenarios."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
