"""The published Catalog a record is judged against.

The digest and the canonical operation set come from the generated Rust
constants (`scripts/catalog_gen/generate.py` writes them and CI holds them in
lockstep with `Catalog/`), read from a git revision rather than the working
tree, so an uncommitted Catalog edit can never become the expected digest.
The digest is recomputed from the canonical JSON as the generator computes it.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

GENERATED_RUST = "rust/crates/arkdeck-contract/src/catalog_generated.rs"
_DIGEST = re.compile(r'^pub const CATALOG_DIGEST: &str = "([0-9a-f]{64})";$', re.M)
_CANONICAL = re.compile(r'^pub const CATALOG_CANONICAL_JSON: &str = r#"(.*)"#;$', re.M | re.S)
_REVISION = re.compile(r"^[0-9a-f]{40}$")


class CatalogError(Exception):
    pass


@dataclass(frozen=True)
class Catalog:
    revision: str
    digest: str
    operations: tuple[str, ...]


def parse_generated(text: str) -> tuple[str, tuple[str, ...]]:
    digest = _DIGEST.search(text)
    canonical = _CANONICAL.search(text)
    if not digest or not canonical:
        raise CatalogError(f"{GENERATED_RUST} has no Catalog digest or canonical JSON")
    body = canonical.group(1)
    if hashlib.sha256(body.encode("utf-8")).hexdigest() != digest.group(1):
        raise CatalogError(f"{GENERATED_RUST}: the canonical JSON does not hash to its digest")
    operations = []
    for document in json.loads(body):
        reference = document["id"]
        if "version" in document:
            reference = f"{reference}@{document['version']}"
        operations.append(reference)
    return digest.group(1), tuple(sorted(operations))


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if completed.returncode != 0:
        raise CatalogError(f"git {' '.join(args)} failed: {completed.stderr.strip()}")
    return completed.stdout


def at_revision(repo: Path, revision: str) -> Catalog:
    full = _git(repo, "rev-parse", "--verify", f"{revision}^{{commit}}").strip()
    if not _REVISION.match(full):
        raise CatalogError(f"{revision} does not name a commit")
    digest, operations = parse_generated(_git(repo, "show", f"{full}:{GENERATED_RUST}"))
    return Catalog(full, digest, operations)


def on_protected_main(repo: Path, revision: str, main: str) -> bool:
    completed = subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", revision, main],
        capture_output=True,
        check=False,
    )
    if completed.returncode not in (0, 1):
        raise CatalogError(f"cannot tell whether {revision} is on {main}")
    return completed.returncode == 0
