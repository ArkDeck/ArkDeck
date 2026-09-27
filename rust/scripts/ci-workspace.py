#!/usr/bin/env python3
"""Task-owned, stable Rust CI sources and build products; never installed state.

Checksum synchronization retains mtimes for identical sources after a cache
restore. A small, fresh Git database borrows only this checkout's object store,
so contract checks still read the exact HEAD and current origin/main. Neither
Git credentials nor a cached ref determines what gets built.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
MARKER = ".arkdeck-rust-ci-v1"


def remove(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def sync_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        value = os.readlink(source)
        if destination.is_symlink() and os.readlink(destination) == value:
            return
        remove(destination)
        destination.symlink_to(value)
        return
    if not source.is_file():
        raise ValueError(f"source is not a regular file: {source}")
    if destination.is_symlink() or (destination.exists() and not destination.is_file()):
        remove(destination)
    if not destination.exists() or source.read_bytes() != destination.read_bytes():
        # Do not copy the checkout's old timestamp over changed contents.
        shutil.copyfile(source, destination)
    shutil.copymode(source, destination)


def sync_tree(source: Path, destination: Path, *, preserve: tuple[tuple[str, ...], ...] = ()) -> None:
    """Make a source view exact, retaining only explicitly owned build directories."""
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        remove(destination)
    destination.mkdir(parents=True, exist_ok=True)
    names = {entry.name for entry in source.iterdir()}
    for entry in destination.iterdir():
        if (entry.name,) in preserve and (entry.is_symlink() or not entry.is_dir()):
            raise ValueError(f"preserved build products must be an owned directory: {entry}")
        if entry.name not in names and (entry.name,) not in preserve:
            remove(entry)
    for entry in source.iterdir():
        if (entry.name,) in preserve:
            raise ValueError(f"source must not supply preserved build directory: {entry}")
        target = destination / entry.name
        if entry.is_dir() and not entry.is_symlink():
            keep = tuple(path[1:] for path in preserve if path[0] == entry.name)
            sync_tree(entry, target, preserve=keep)
        else:
            sync_file(entry, target)


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True).strip()


def cache_root(value: str, source: Path = ROOT) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise ValueError("ARKDECK_RUST_CACHE_ROOT must be absolute")
    root = path.resolve()
    source = source.resolve()
    if root == source or source in root.parents or root in source.parents:
        raise ValueError("Rust CI cache must be separate from the source checkout")
    root.mkdir(parents=True, exist_ok=True)
    marker = root / MARKER
    if not marker.exists():
        if any(root.iterdir()):
            raise ValueError("refusing to adopt a nonempty Rust CI cache without its ownership marker")
        marker.write_text("arkdeck.rust-ci-cache/1\n")
    if marker.is_symlink() or marker.read_text() != "arkdeck.rust-ci-cache/1\n":
        raise ValueError("invalid Rust CI cache ownership marker")
    return root


@contextlib.contextmanager
def locked(root: Path):
    lock = root / "in-use"
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise ValueError("Rust CI cache is already in use; each job must own its cache root") from error
    try:
        yield
    finally:
        lock.rmdir()


def prepare(source: Path, root: Path) -> Path:
    mirror = root / "workspace"
    if mirror.is_symlink():
        raise ValueError("Rust CI workspace must not be a symlink")
    mirror.mkdir(exist_ok=True)
    listed = subprocess.check_output([
        "git", "-C", str(source), "ls-files", "--cached", "--others", "--exclude-standard", "-z",
    ]).decode().split("\0")
    paths = {name for name in listed if name and ((source / name).exists() or (source / name).is_symlink())}
    tree = {}
    for name in paths:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or path.parts[0] == ".git":
            raise ValueError(f"invalid mirrored source path: {name}")
        if path.parts[:2] == ("rust", "target"):
            raise ValueError("source must not supply the preserved Rust target directory")
        node = tree
        for part in path.parts:
            node = node.setdefault(part, {})

    def prune(directory: Path, expected: dict) -> None:
        # Remove arbitrary leftovers too, not just files in the previous
        # manifest. Never traverse restored symlinks or the owned build tree.
        for entry in directory.iterdir():
            if entry == mirror / "rust/target":
                if entry.is_symlink() or not entry.is_dir():
                    raise ValueError("Rust CI target must be an owned directory")
            elif entry.name not in expected:
                remove(entry)
        for name, children in expected.items():
            if children:
                child = directory / name
                if child.is_symlink() or (child.exists() and not child.is_dir()):
                    remove(child)
                child.mkdir(exist_ok=True)
                prune(child, children)

    prune(mirror, tree)
    for name in sorted(paths):
        sync_file(source / name, mirror / name)

    # Never restore authority (refs/index/config) from a previous job. Alternates
    # avoid copying the entire history or putting source-repository credentials
    # in the cache. Test children inherit no GIT_DIR/GIT_WORK_TREE overrides.
    remove(mirror / ".git")
    git(mirror, "init", "--quiet")
    git(mirror, "config", "core.autocrlf", "false")
    objects = git(source, "rev-parse", "--path-format=absolute", "--git-path", "objects")
    (mirror / ".git/objects/info/alternates").write_text(objects + "\n")
    head = git(source, "rev-parse", "HEAD")
    main = git(source, "rev-parse", "refs/remotes/origin/main")
    git(mirror, "update-ref", "--no-deref", "HEAD", head)
    git(mirror, "update-ref", "refs/remotes/origin/main", main)
    git(mirror, "read-tree", "HEAD")
    print(f"Rust CI workspace: {mirror}; HEAD={head}; origin/main={main}", flush=True)
    return mirror


def key(source: Path, root: str) -> str:
    identity = {
        "rustc": subprocess.check_output(["rustc", "-vV"], cwd=source / "rust", text=True),
        "cargo": subprocess.check_output(["cargo", "-V"], cwd=source / "rust", text=True),
        "image": os.environ.get("ImageVersion", "unknown"),
        "root": str(Path(root).resolve()),
        "flags": {k: os.environ.get(k, "") for k in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC_WRAPPER")},
        "inputs": {},
    }
    for directory, children, files in os.walk(source / "rust"):
        children[:] = sorted(name for name in children if name not in ("target", ".git"))
        if "Cargo.toml" in files:
            path = Path(directory) / "Cargo.toml"
            identity["inputs"][path.relative_to(source).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ("rust/Cargo.lock", "rust/rust-toolchain.toml"):
        identity["inputs"][name] = hashlib.sha256((source / name).read_bytes()).hexdigest()
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return "arkdeck-rust-build-v1-" + digest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("key", "prepare", "exec"))
    parser.add_argument("--cwd", choices=(".", "rust"), default=".")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    # Options precede the action; everything after `--` belongs to the child.
    arguments = parser.parse_args()
    value = os.environ.get("ARKDECK_RUST_CACHE_ROOT", "")
    if not value:
        raise ValueError("ARKDECK_RUST_CACHE_ROOT is required; no shared local cache is implicit")
    if arguments.action == "key":
        result = key(ROOT, value)
        print(result)
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write(f"key={result}\n")
        return 0
    root = cache_root(value)
    with locked(root):
        if arguments.action == "prepare":
            prepare(ROOT, root)
            return 0
        mirror = root / "workspace"
        if git(mirror, "rev-parse", "HEAD") != git(ROOT, "rev-parse", "HEAD"):
            raise ValueError("prepare the stable Rust workspace for this exact revision first")
        command = arguments.command
        if command[:1] == ["--"]:
            command = command[1:]
        if not command:
            raise ValueError("exec requires a command after --")
        environment = dict(os.environ, CARGO_TARGET_DIR=str(mirror / "rust/target"),
                           ARKDECK_RUST_STABLE_VIEWS="1")
        return subprocess.run(command, cwd=mirror / arguments.cwd, env=environment, check=False).returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Rust CI workspace: {error}", file=sys.stderr)
        sys.exit(1)
