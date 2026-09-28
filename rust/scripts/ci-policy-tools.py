#!/usr/bin/env python3
"""Pinned Linux policy tools, with a protected-main artifact for cargo-vet.

cargo-vet 0.10.2 has no upstream binary release. Only successful main push
runs of Swift CI may supply it; otherwise retain the locked source install.
The artifact is independent of the build-cache eviction budget.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import urllib.request
import zipfile

DENY_VERSION = "0.20.2"
VET_VERSION = "0.10.2"
DENY_ASSET = f"cargo-deny-{DENY_VERSION}-x86_64-unknown-linux-musl"
DENY_URL = f"https://github.com/EmbarkStudios/cargo-deny/releases/download/{DENY_VERSION}/{DENY_ASSET}.tar.gz"
# Checked against the release asset digest and the downloaded archive.
DENY_SHA256 = "9f12ed4c49936e09b48bf862b595cde2fe64fcbd9d74dfacac6131ca824c8d5f"
VET_ARTIFACT = f"cargo-vet-linux-x64-{VET_VERSION}-v1"
MAX_BINARY_BYTES = 64 * 1024 * 1024


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def api(path: str, *, binary: bool = False):
    data = subprocess.check_output(["gh", "api", path])
    return data if binary else json.loads(data)


def trusted_vet_artifact(repository: str, repository_id: int, now: datetime) -> dict | None:
    # Limit work even if an untrusted branch publishes many same-name artifacts.
    # Metadata filters are only a first pass; the producer run is checked too.
    for page in range(1, 4):
        data = api(f"repos/{repository}/actions/artifacts?name={VET_ARTIFACT}&per_page=100&page={page}")
        for artifact in data["artifacts"]:
            run = artifact.get("workflow_run", {})
            if (artifact["name"] != VET_ARTIFACT or artifact["expired"]
                    or artifact["size_in_bytes"] > MAX_BINARY_BYTES
                    or run.get("head_branch") != "main"
                    or run.get("repository_id") != repository_id
                    or run.get("head_repository_id") != repository_id):
                continue
            # Renew before the 30-day retention expires, even on a cache hit.
            created = datetime.fromisoformat(artifact["created_at"].replace("Z", "+00:00"))
            if not 0 <= (now - created).total_seconds() < 21 * 86400:
                continue
            producer = api(f"repos/{repository}/actions/runs/{run['id']}")
            if (producer.get("event") == "push" and producer.get("head_branch") == "main"
                    and producer.get("path") == ".github/workflows/swift-ci.yml"
                    and producer.get("conclusion") == "success"
                    and producer.get("head_sha") == run.get("head_sha")
                    and producer.get("repository", {}).get("id") == repository_id
                    and producer.get("head_repository", {}).get("id") == repository_id):
                return artifact
        if len(data["artifacts"]) < 100:
            break
    return None


def install_deny(archive: bytes, destination: Path) -> None:
    if sha(archive) != DENY_SHA256:
        raise ValueError("cargo-deny release archive checksum mismatch")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as source:
        member = source.getmember(f"{DENY_ASSET}/cargo-deny")
        if not member.isfile() or member.size > MAX_BINARY_BYTES:
            raise ValueError("cargo-deny archive has no bounded regular executable")
        # Never extract archive-supplied paths, links, modes or other files.
        destination.write_bytes(source.extractfile(member).read())
    destination.chmod(0o755)


def restore_vet(archive: bytes, artifact: dict, destination: Path) -> None:
    if artifact.get("digest") != "sha256:" + sha(archive):
        raise ValueError("cargo-vet artifact archive checksum mismatch")
    with zipfile.ZipFile(io.BytesIO(archive)) as source:
        if sorted(source.namelist()) != ["cargo-vet", "manifest.json"]:
            raise ValueError("unexpected cargo-vet artifact contents")
        if source.getinfo("cargo-vet").file_size > MAX_BINARY_BYTES or source.getinfo("manifest.json").file_size > 4096:
            raise ValueError("oversized cargo-vet artifact")
        manifest = json.loads(source.read("manifest.json"))
        binary = source.read("cargo-vet")
    if (manifest.get("schemaVersion") != "arkdeck.cargo-vet/1"
            or manifest.get("version") != VET_VERSION
            or manifest.get("sha256") != sha(binary)):
        raise ValueError("cargo-vet artifact manifest mismatch")
    destination.write_bytes(binary)
    destination.chmod(0o755)


def require_version(binary: Path, version: str) -> None:
    actual = subprocess.check_output([str(binary), "--version"], text=True).strip()
    if actual != f"{binary.name} {version}":
        raise ValueError(f"unexpected {binary.name} version: {actual}")


def prepare_vet_artifact(binary: Path, directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    data = binary.read_bytes()
    (directory / "cargo-vet").write_bytes(data)
    (directory / "manifest.json").write_text(json.dumps({
        "schemaVersion": "arkdeck.cargo-vet/1", "version": VET_VERSION, "sha256": sha(data),
    }) + "\n")


def main() -> None:
    if platform.system() != "Linux" or platform.machine() not in ("x86_64", "AMD64"):
        raise ValueError("policy binary distribution is pinned to Linux x64")
    directory = Path.home() / ".cargo/bin"
    directory.mkdir(parents=True, exist_ok=True)
    deny, vet = directory / "cargo-deny", directory / "cargo-vet"
    main_push = os.environ.get("GITHUB_REF") == "refs/heads/main" and os.environ.get("GITHUB_EVENT_NAME") == "push"
    artifact = None
    if os.environ.get("GH_TOKEN") and (main_push or not vet.exists()):
        # A transport outage is a cache miss. A downloaded artifact failing
        # provenance, checksum or version verification is never executed.
        try:
            artifact = trusted_vet_artifact(os.environ["GITHUB_REPOSITORY"],
                                            int(os.environ["GITHUB_REPOSITORY_ID"]), datetime.now(timezone.utc))
        except subprocess.CalledProcessError:
            print("Trusted policy artifact unavailable; retaining locked source fallback", flush=True)
    if not deny.exists():
        with urllib.request.urlopen(DENY_URL, timeout=60) as response:
            data = response.read(MAX_BINARY_BYTES + 1)
        install_deny(data, deny)
    if not vet.exists():
        if artifact:
            data = api(f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/artifacts/{artifact['id']}/zip", binary=True)
            restore_vet(data, artifact, vet)
            print(f"Restored cargo-vet from successful main run {artifact['workflow_run']['id']}", flush=True)
        else:
            subprocess.run(["cargo", "install", "--locked", "--version", VET_VERSION, "cargo-vet"], check=True)
    require_version(deny, DENY_VERSION)
    require_version(vet, VET_VERSION)
    publish = main_push and artifact is None
    if publish:
        prepare_vet_artifact(vet, Path(os.environ["ARKDECK_POLICY_ARTIFACT_DIR"]))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"publish-vet={'true' if publish else 'false'}\n")


if __name__ == "__main__":
    main()
