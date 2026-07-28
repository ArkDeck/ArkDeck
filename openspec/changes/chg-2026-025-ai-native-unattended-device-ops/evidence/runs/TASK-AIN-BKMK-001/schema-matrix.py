#!/usr/bin/env python3
"""Offline Manifest 2.1 path-source shape checks for TASK-AIN-BKMK-001."""

from __future__ import annotations

import json
from pathlib import Path


CHANGE_ROOT = Path(__file__).resolve().parents[3]
manifest_schema = json.loads(
    (CHANGE_ROOT / "contracts" / "manifest.schema.v2.1-draft.json").read_text(
        encoding="utf-8"
    )
)
assert manifest_schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"

toolchain_schema = manifest_schema["$defs"]["rockchipToolchain"]
path_source_schema = toolchain_schema["properties"]["pathSource"]
assert path_source_schema == {
    "enum": [
        "userSelectedSecurityScopedBookmark",
        "installedOrdinaryBookmark",
    ]
}
assert toolchain_schema["additionalProperties"] is False
assert "pathSource" in toolchain_schema["required"]

allowed_sources = path_source_schema["enum"]
assert "userSelectedSecurityScopedBookmark" in allowed_sources
assert "installedOrdinaryBookmark" in allowed_sources
assert "callerSelectedPath" not in allowed_sources
assert "path" not in toolchain_schema["properties"]
assert "bookmarkData" not in toolchain_schema["properties"]

print(
    "SCHEMA-AIN-BKMK-001 PASS draft-shape=2020-12 "
    "historical-scoped=accepted new-ordinary=accepted "
    "unknown=rejected path=forbidden bookmarkData=forbidden network=0"
)
