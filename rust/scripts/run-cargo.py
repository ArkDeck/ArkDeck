#!/usr/bin/env python3
"""Run local Rust checks in one persistent source mirror and target per chat."""
from __future__ import annotations

import contextlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[2]
OWNER_RECORD = ".arkdeck-cargo-owner.json"
COMMANDS = {"build", "check", "test", "clippy", "fmt", "metadata", "fetch", "run",
            "generate-lockfile", "deny", "vet"}
spec = importlib.util.spec_from_file_location("arkdeck_local_ci_workspace", Path(__file__).with_name("ci-workspace.py"))
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


def owner_id(environment: dict[str, str]) -> str:
    owner = environment.get("ARKDECK_CARGO_OWNER", environment.get("CODEX_THREAD_ID", "local"))
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", owner):
        raise ValueError("Cargo owner must be a stable identifier without path separators")
    return owner


def default_cache(owner: str) -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / (
        "Library/Caches" if sys.platform == "darwin" else ".cache")))
    return base / "com.arkdeck.ArkDeck/Cargo/Owners" / owner


@contextlib.contextmanager
def runner_lock(root: Path):
    """OS releases the lock even if Cargo or the chat is interrupted."""
    path = root / "runner.lock"
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError("Cargo runner lock must be an owned regular file")
    with path.open("a+b") as lock:
        try:
            if os.name == "nt":
                import msvcrt
                if path.stat().st_size == 0:
                    lock.write(b"\0")
                    lock.flush()
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise ValueError("this chat's Cargo cache is already in use; retry after its check finishes") from error
        try:
            yield
        finally:
            if os.name == "nt":
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock, fcntl.LOCK_UN)


def claim_owner(root: Path, owner: str) -> None:
    path = root / OWNER_RECORD
    expected = {"schemaVersion": "arkdeck.local-cargo-owner/1", "owner": owner, "cacheRoot": str(root)}
    if path.is_symlink():
        raise ValueError("Cargo owner record must not be a symlink")
    if path.exists():
        if json.loads(path.read_text()) != expected:
            raise ValueError("Cargo cache belongs to another chat or root")
    else:
        path.write_text(json.dumps(expected, sort_keys=True) + "\n")


def source_root(environment: dict[str, str]) -> Path:
    source = Path(environment.get("ARKDECK_CARGO_SOURCE_ROOT", ROOT))
    if not source.is_absolute() or not source.is_dir():
        raise ValueError("Cargo source root must be an absolute Git checkout")
    source = source.resolve()
    if Path(cache.git(source, "rev-parse", "--show-toplevel")).resolve() != source:
        raise ValueError("Cargo source root must be an independent Git top-level")
    return source


def validate_options(command: str, options: list[str]) -> None:
    # Cargo's trailing program/test arguments do not configure the build.
    cargo_options = options if command == "fmt" else (
        options[:options.index("--")] if "--" in options else options)
    for option in cargo_options:
        if option.split("=", 1)[0] in {"--manifest-path", "--target-dir", "--config", "--lockfile-path"}:
            raise ValueError("manifest, target, config and lockfile paths are managed by this runner")
        if option.split("=", 1)[0] == "--target":
            raise ValueError("local checks build only the native host; --target is not supported")


def native_configuration(cwd: Path, environment: dict[str, str]) -> None:
    if "CARGO_BUILD_TARGET" in environment:
        raise ValueError("local checks build only the native host; CARGO_BUILD_TARGET is not supported")
    cargo_home = Path(environment.get("CARGO_HOME", Path.home() / ".cargo"))
    paths = [cargo_home / "config", cargo_home / "config.toml"]
    for directory in (cwd, *cwd.parents):
        paths.extend((directory / ".cargo/config", directory / ".cargo/config.toml"))
    for path in paths:
        if path.exists() and "target" in tomllib.loads(path.read_text()).get("build", {}):
            raise ValueError("local checks build only the native host; Cargo build.target is not supported")


def return_edits(source: Path, mirror: Path, originals: dict[Path, bytes | None]) -> None:
    changed = {name: (mirror / name).read_bytes() for name, data in originals.items()
               if (mirror / name).read_bytes() != data}
    # A formatter must not overwrite edits made in the checkout during its run.
    for name in changed:
        path = source / name
        current = path.read_bytes() if path.exists() else None
        if path.is_symlink() or current != originals[name]:
            raise ValueError(f"source changed during Cargo invocation; edits retained in mirror: {name}")
    for name, data in changed.items():
        (source / name).write_bytes(data)


def main(arguments: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if arguments is None else arguments
    if not arguments or arguments[0] in {"-h", "--help"}:
        print("usage: python3 rust/scripts/run-cargo.py {build|check|test|clippy|fmt|metadata|fetch|run|generate-lockfile|deny|vet} [cargo options]")
        print("       python3 rust/scripts/run-cargo.py exec -- <host check command>")
        print("ARKDECK_CARGO_OWNER: stable chat owner (default CODEX_THREAD_ID, otherwise local)")
        print("ARKDECK_CARGO_CACHE_ROOT: absolute external cache; keep the same root across tasks")
        print("ARKDECK_CARGO_SOURCE_ROOT: optional source checkout; changing it retains the target")
        return 0
    command, *options = arguments
    if command not in COMMANDS | {"exec"}:
        raise ValueError("unsupported Cargo command")
    if command == "exec":
        if options[:1] == ["--"]:
            options = options[1:]
        if not options:
            raise ValueError("exec requires a host check command")
    else:
        validate_options(command, options)
    environment = cache.git_environment()
    source = source_root(environment)
    owner = owner_id(environment)
    value = environment.get("ARKDECK_CARGO_CACHE_ROOT", str(default_cache(owner)))
    root = cache.cache_root(value, source)
    with runner_lock(root):
        claim_owner(root, owner)
        # Synchronize and run under one lock. Cache identity depends only on
        # the chat, never the task, checkout path, HEAD or source digest.
        mirror = cache.prepare(source, root)
        environment.update(CARGO_TARGET_DIR=str(mirror / "rust/target"), CARGO_BUILD_JOBS="2",
                           ARKDECK_RUST_STABLE_VIEWS="1")
        native_configuration(mirror / "rust", environment)
        print(f"ArkDeck Cargo owner: {owner}; target: {environment['CARGO_TARGET_DIR']}", flush=True)
        if command == "exec":
            return subprocess.run(options, cwd=mirror, env=environment, check=False).returncode
        originals = {}
        if command == "fmt" and "--check" not in options:
            originals = {path.relative_to(mirror): path.read_bytes()
                         for path in (mirror / "rust").rglob("*.rs")
                         if "target" not in path.relative_to(mirror / "rust").parts and not path.is_symlink()}
        elif command == "generate-lockfile":
            path = source / "rust/Cargo.lock"
            originals = {Path("rust/Cargo.lock"): path.read_bytes() if path.exists() else None}
        argv = ["cargo", command]
        if command not in {"fmt", "generate-lockfile"} and "--locked" not in options:
            argv.append("--locked")
        result = subprocess.run([*argv, *options], cwd=mirror / "rust", env=environment, check=False)
        if result.returncode == 0 and originals:
            return_edits(source, mirror, originals)
        return result.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"run-cargo: {error}", file=sys.stderr)
        raise SystemExit(1)
