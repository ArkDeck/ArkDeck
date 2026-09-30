#!/usr/bin/env python3
"""Exercise source/cache isolation and complete native Cargo test scheduling."""
from __future__ import annotations

import contextlib
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile
import unittest
import zipfile
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cache = load("ci-workspace")
tests = load("run-workspace-tests")
policy = load("ci-policy-tools")
retention_spec = importlib.util.spec_from_file_location("retention", Path(__file__).resolve().parents[2] / "scripts/ci/retain-rust-caches.py")
retention = importlib.util.module_from_spec(retention_spec)
retention_spec.loader.exec_module(retention)


class WorkspaceCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="arkdeck-ci-cache-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.source = self.directory / "checkout"
        self.source.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "CI fixture")
        self.git("config", "user.email", "ci@example.invalid")
        self.write("rust/src/lib.rs", "// first\n")
        self.write("rust/Cargo.toml", '[workspace]\n')
        self.write("rust/Cargo.lock", "# lock\n")
        self.write("rust/rust-toolchain.toml", '[toolchain]\nchannel = "stable"\n')
        self.write(".gitignore", "rust/target/\nignored\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.root = cache.cache_root(str(self.directory / "cache"), self.source)

    def git(self, *args):
        return cache.git(self.source, *args)

    def write(self, path, text):
        file = self.source / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        return file

    def test_restore_preserves_identical_mtimes_and_updates_changed_deleted_and_untracked_sources(self):
        mirror = cache.prepare(self.source, self.root)
        file = mirror / "rust/src/lib.rs"
        os.utime(file, ns=(1_000_000_000, 1_000_000_000))
        (mirror / "stray").write_text("cached source must not survive")
        (mirror / "rust/target").mkdir()
        (mirror / "rust/target/product").write_text("retained build")
        self.write("ignored", "must not be copied")
        self.write("new-input", "current untracked source")
        cache.prepare(self.source, self.root)
        self.assertEqual(file.stat().st_mtime_ns, 1_000_000_000)
        self.assertFalse((mirror / "stray").exists())
        self.assertFalse((mirror / "ignored").exists())
        self.assertEqual((mirror / "new-input").read_text(), "current untracked source")
        self.assertEqual((mirror / "rust/target/product").read_text(), "retained build")
        self.write("rust/src/lib.rs", "// changed\n")
        (self.source / "new-input").unlink()
        cache.prepare(self.source, self.root)
        self.assertEqual(file.read_text(), "// changed\n")
        self.assertGreater(file.stat().st_mtime_ns, 1_000_000_000)
        self.assertFalse((mirror / "new-input").exists())

    def test_restored_git_authority_is_replaced_without_inheriting_credentials_or_environment(self):
        mirror = cache.prepare(self.source, self.root)
        cache.git(mirror, "config", "http.extraheader", "fixture-secret")
        old = self.git("rev-parse", "HEAD")
        self.write("next", "next revision")
        self.git("add", ".")
        self.git("commit", "-qm", "next")
        current = self.git("rev-parse", "HEAD")
        cache.prepare(self.source, self.root)
        self.assertEqual(cache.git(mirror, "rev-parse", "HEAD"), current)
        self.assertEqual(cache.git(mirror, "rev-parse", "origin/main"), old)
        self.assertNotIn("fixture-secret", (mirror / ".git/config").read_text())
        self.assertEqual(cache.git(mirror, "show", "origin/main:rust/src/lib.rs"), "// first")
        expected_objects = self.git("rev-parse", "--path-format=absolute", "--git-path", "objects")
        self.assertEqual((mirror / ".git/objects/info/alternates").read_bytes(),
                         expected_objects.encode("utf-8") + b"\n")
        self.assertEqual(cache.git(mirror, "diff", "--name-only"), "")
        child = mirror / "fixture-git"
        child.mkdir()
        cache.git(child, "init", "-q")
        self.assertTrue((child / ".git").is_dir())
        self.assertEqual(self.git("rev-parse", "HEAD"), current)

    def test_rejects_shared_or_unowned_roots_and_simultaneous_use(self):
        for root in (self.source, self.source / "target", self.directory):
            with self.subTest(root=root), self.assertRaises(ValueError):
                cache.cache_root(str(root), self.source)
        unowned = self.directory / "unowned"
        unowned.mkdir()
        (unowned / "file").write_text("keep")
        with self.assertRaises(ValueError):
            cache.cache_root(str(unowned), self.source)
        with cache.locked(self.root):
            with self.assertRaises(ValueError):
                with cache.locked(self.root):
                    self.fail("two writers")
        self.assertFalse((self.root / "in-use").exists())

    @unittest.skipIf(sys.platform == "win32", "creating symlinks requires a Windows privilege")
    def test_restored_parent_symlink_never_writes_outside_owned_workspace(self):
        mirror = cache.prepare(self.source, self.root)
        outside = self.directory / "outside"
        outside.mkdir()
        sentinel = outside / "lib.rs"
        sentinel.write_text("untouched")
        shutil.rmtree(mirror / "rust/src")
        (mirror / "rust/src").symlink_to(outside, target_is_directory=True)
        cache.prepare(self.source, self.root)
        self.assertEqual(sentinel.read_text(), "untouched")
        self.assertFalse((mirror / "rust/src").is_symlink())

    def test_view_sync_retains_only_its_own_target_and_identical_source_mtimes(self):
        stage = self.directory / "stage"
        (stage / "rust/src").mkdir(parents=True)
        (stage / "rust/src/lib.rs").write_text("source")
        for name in ("published", "candidate"):
            destination = self.root / name
            cache.sync_tree(stage, destination, preserve=(("rust", "target"),))
            (destination / "rust/target").mkdir()
            (destination / "rust/target/product").write_text(name)
            file = destination / "rust/src/lib.rs"
            os.utime(file, ns=(1_000_000_000, 1_000_000_000))
            (destination / "stale-input").write_text("obsolete")
            cache.sync_tree(stage, destination, preserve=(("rust", "target"),))
            self.assertEqual(file.stat().st_mtime_ns, 1_000_000_000)
            self.assertEqual((destination / "rust/target/product").read_text(), name)
            self.assertFalse((destination / "stale-input").exists())

    def test_cache_key_separates_compiler_image_flags_manifests_and_stable_path(self):
        with patch.object(cache.subprocess, "check_output", return_value="compiler-v1"), patch.dict(os.environ, {"ImageVersion": "image-v1"}):
            original = cache.key(self.source, str(self.root))
            self.write("rust/src/lib.rs", "// source-only edit\n")
            self.assertEqual(cache.key(self.source, str(self.root)), original)
            self.assertNotEqual(cache.key(self.source, str(self.root / "other")), original)
            for variable, value in (("ImageVersion", "image-v2"), ("RUSTFLAGS", "-C debuginfo=0"),
                                    ("CARGO_INCREMENTAL", "0")):
                with patch.dict(os.environ, {variable: value}):
                    self.assertNotEqual(cache.key(self.source, str(self.root)), original)
            with patch.object(cache.subprocess, "check_output", return_value="compiler-v2"):
                self.assertNotEqual(cache.key(self.source, str(self.root)), original)
            self.write("rust/Cargo.lock", "# different dependency\n")
            self.assertNotEqual(cache.key(self.source, str(self.root)), original)

    def test_daily_entries_preserve_compatibility_without_one_archive_per_commit(self):
        with patch.object(cache.subprocess, "check_output", return_value="compiler-v1"):
            first = cache.cache_outputs(self.source, str(self.root), "2026-09-28")
            self.write("rust/src/lib.rs", "// source edit\n")
            with patch.dict(os.environ, {"GITHUB_SHA": "different-commit"}):
                self.assertEqual(cache.cache_outputs(self.source, str(self.root), "2026-09-28"), first)
            next_day = cache.cache_outputs(self.source, str(self.root), "2026-09-29")
            self.assertEqual(first["prefix"], next_day["prefix"])
            self.assertNotEqual(first["key"], next_day["key"])
            self.write("rust/Cargo.lock", "new dependencies")
            self.assertNotEqual(cache.cache_outputs(self.source, str(self.root), "2026-09-28")["prefix"], first["prefix"])

    def test_fallback_keeps_host_toolchain_image_flags_and_root_but_not_manifests(self):
        environment = {"RUNNER_OS": "Windows", "RUNNER_ARCH": "X64", "ImageVersion": "20260922.246.2"}
        with patch.object(cache.subprocess, "check_output", return_value="compiler-v1"), patch.dict(os.environ, environment):
            first = cache.cache_outputs(self.source, str(self.root), "2026-09-28")
            self.assertTrue(first["prefix"].startswith(first["fallback"]))
            self.assertTrue(first["key"].startswith(first["prefix"]))
            # The image is in clear, so retention can keep one entry per image.
            self.assertTrue(first["fallback"].startswith("arkdeck-rust-build-v3-Windows-X64-image-20260922.246.2-"))
            self.assertEqual(retention.RUST_KEY.fullmatch(first["key"])["image"], "20260922.246.2")
            # Manifest churn: a new exact prefix, the same fallback.
            for path, text in (("rust/Cargo.lock", "# new dependency\n"),
                               ("rust/crates/new/Cargo.toml", '[package]\nname = "new"\n')):
                self.write(path, text)
                changed = cache.cache_outputs(self.source, str(self.root), "2026-09-28")
                self.assertNotEqual(changed["prefix"], first["prefix"])
                self.assertEqual(changed["fallback"], first["fallback"])
            # Every other compatibility dimension still separates the fallback.
            for variable, value in (("ImageVersion", "20260925.250.1"), ("RUNNER_OS", "Linux"),
                                    ("RUSTFLAGS", "-C debuginfo=0"), ("CARGO_INCREMENTAL", "1")):
                with patch.dict(os.environ, {variable: value}):
                    self.assertNotEqual(cache.cache_outputs(self.source, str(self.root))["fallback"], first["fallback"])
            self.assertNotEqual(cache.cache_outputs(self.source, str(self.root / "other"))["fallback"], first["fallback"])
            with patch.object(cache.subprocess, "check_output", return_value="compiler-v2"):
                self.assertNotEqual(cache.cache_outputs(self.source, str(self.root))["fallback"], first["fallback"])
            self.write("rust/rust-toolchain.toml", '[toolchain]\nchannel = "beta"\n')
            self.assertNotEqual(cache.cache_outputs(self.source, str(self.root))["fallback"], first["fallback"])
            # An image string cannot forge the key's separators.
            with patch.dict(os.environ, {"ImageVersion": "a-b/c d"}):
                self.assertIn("-image-a_b_c_d-", cache.cache_outputs(self.source, str(self.root))["fallback"])

    def test_compaction_preserves_each_views_linked_products_and_debug_info(self):
        mirror = cache.prepare(self.source, self.root)
        targets = [mirror / "rust/target"]
        targets += [targets[0] / "contract-check" / view / "rust/target" for view in ("published", "candidate")]
        for target in targets:
            for name in ("debug/incremental/chunk", "debug/deps/library.rlib", "debug/agent.dSYM/symbols", "debug/.fingerprint/input", "readonly-check/report.json"):
                path = target / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name)
        with contextlib.redirect_stdout(io.StringIO()):
            result = cache.compact(self.root)
        self.assertLess(result["afterBytes"], result["beforeBytes"])
        for target in targets:
            self.assertFalse((target / "debug/incremental").exists())
            for name in ("debug/deps/library.rlib", "debug/agent.dSYM/symbols", "debug/.fingerprint/input", "readonly-check/report.json"):
                self.assertEqual((target / name).read_text(), name)
        self.assertEqual(result["afterBytes"], cache.directory_sizes(self.root)[self.root])

    @unittest.skipIf(sys.platform == "win32", "creating symlinks requires a Windows privilege")
    def test_compaction_rejects_symlinked_target_parents(self):
        mirror = cache.prepare(self.source, self.root)
        outside = self.directory / "outside"
        (outside / "incremental").mkdir(parents=True)
        (outside / "incremental/keep").write_text("untouched")
        (mirror / "rust/target").mkdir()
        (mirror / "rust/target/debug").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            cache.compact(self.root)
        self.assertEqual((outside / "incremental/keep").read_text(), "untouched")


class PolicyDistributionTests(unittest.TestCase):
    def test_unseeded_vet_keeps_locked_pinned_source_fallback_and_pr_cannot_publish(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binaries = home / ".cargo/bin"
            binaries.mkdir(parents=True)
            (binaries / "cargo-deny").write_text("restored trusted tool")
            def install(argv, **kwargs):
                self.assertEqual(argv, ["cargo", "install", "--locked", "--version", "0.10.2", "cargo-vet"])
                self.assertTrue(kwargs["check"])
                (binaries / "cargo-vet").write_text("compiled pinned tool")
            def version(argv, **kwargs):
                return "cargo-deny 0.20.2\n" if Path(argv[0]).name == "cargo-deny" else "cargo-vet 0.10.2\n"
            env = {"GH_TOKEN": "", "GITHUB_REF": "refs/heads/agent/pr", "GITHUB_EVENT_NAME": "push",
                   "GITHUB_OUTPUT": str(home / "output")}
            with patch.dict(os.environ, env), patch.object(policy.Path, "home", return_value=home), \
                    patch.object(policy.platform, "system", return_value="Linux"), \
                    patch.object(policy.platform, "machine", return_value="x86_64"), \
                    patch.object(policy.subprocess, "run", side_effect=install) as source_install, \
                    patch.object(policy.subprocess, "check_output", side_effect=version):
                policy.main()
                self.assertEqual(source_install.call_count, 1)
                policy.main()
                self.assertEqual(source_install.call_count, 1)
            self.assertEqual((home / "output").read_text(), "publish-vet=false\npublish-vet=false\n")
            with patch.object(policy.subprocess, "check_output", return_value="cargo-vet 0.10.0\n"):
                with self.assertRaises(ValueError):
                    policy.require_version(binaries / "cargo-vet", policy.VET_VERSION)

    def test_upstream_archive_requires_pinned_digest_and_regular_exact_member(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "cargo-deny"
            for symlink in (False, True):
                buffer = io.BytesIO()
                with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
                    member = tarfile.TarInfo(f"{policy.DENY_ASSET}/cargo-deny")
                    member.size = 4 if not symlink else 0
                    if symlink:
                        member.type = tarfile.SYMTYPE
                        member.linkname = "/outside"
                    archive.addfile(member, None if symlink else io.BytesIO(b"tool"))
                data = buffer.getvalue()
                with self.assertRaisesRegex(ValueError, "checksum"):
                    policy.install_deny(data, destination)
                with patch.object(policy, "DENY_SHA256", policy.sha(data)):
                    if symlink:
                        with self.assertRaises(ValueError):
                            policy.install_deny(data, destination)
                    else:
                        policy.install_deny(data, destination)
                        self.assertEqual(destination.read_bytes(), b"tool")

    def test_vet_bundle_checks_zip_digest_manifest_version_and_binary_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "cargo-vet"
            binary.write_bytes(b"compiled pinned tool")
            bundle = Path(directory) / "bundle"
            policy.prepare_vet_artifact(binary, bundle)
            manifest = json.loads((bundle / "manifest.json").read_text())
            for mutation in (None, "version", "sha256", "path"):
                doc = manifest.copy()
                if mutation in ("version", "sha256"):
                    doc[mutation] = "wrong"
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, "w") as archive:
                    archive.writestr("cargo-vet" if mutation != "path" else "../cargo-vet", binary.read_bytes())
                    archive.writestr("manifest.json", json.dumps(doc))
                data = buffer.getvalue()
                artifact = {"digest": "sha256:" + policy.sha(data)}
                output = Path(directory) / "restored"
                if mutation:
                    with self.assertRaises(ValueError):
                        policy.restore_vet(data, artifact, output)
                else:
                    policy.restore_vet(data, artifact, output)
                    self.assertEqual(output.read_bytes(), binary.read_bytes())
                    with self.assertRaisesRegex(ValueError, "checksum"):
                        policy.restore_vet(data + b"tampered", artifact, output)

    def test_only_recent_successful_main_push_producers_supply_vet(self):
        now = datetime(2026, 9, 28, tzinfo=timezone.utc)
        artifact = {"name": policy.VET_ARTIFACT, "expired": False, "size_in_bytes": 100,
                    "created_at": "2026-09-27T00:00:00Z", "workflow_run": {
                        "id": 5, "repository_id": 7, "head_repository_id": 7, "head_branch": "main", "head_sha": "a"}}
        producer = {"event": "push", "head_branch": "main", "path": ".github/workflows/swift-ci.yml",
                    "conclusion": "success", "head_sha": "a", "repository": {"id": 7}, "head_repository": {"id": 7}}
        for field, value in ((None, None), ("event", "pull_request"), ("head_branch", "agent/untrusted"),
                             ("conclusion", "failure"), ("head_sha", "other"), ("path", ".github/workflows/other.yml"),
                             ("head_repository", {"id": 8})):
            run = producer | ({field: value} if field else {})
            with patch.object(policy, "api", side_effect=[{"artifacts": [artifact]}, run]):
                found = policy.trusted_vet_artifact("owner/repo", 7, now)
                self.assertEqual(found, None if field else artifact)
        for changed in (artifact | {"expired": True}, artifact | {"created_at": "2026-01-01T00:00:00Z"},
                        artifact | {"workflow_run": artifact["workflow_run"] | {"head_repository_id": 8}}):
            with patch.object(policy, "api", return_value={"artifacts": [changed]}) as api:
                self.assertIsNone(policy.trusted_vet_artifact("owner/repo", 7, now))
                self.assertEqual(api.call_count, 1)


class CacheRetentionTests(unittest.TestCase):
    def test_keeps_latest_per_format_and_never_deletes_other_families_or_branches(self):
        def entry(n, version="mac", key=None, ref="refs/heads/main"):
            return {"id": n, "created_at": f"2026-09-{n:02d}", "version": version, "ref": ref,
                    "key": key or f"arkdeck-rust-build-v2-macOS-ARM64-{'a' * 64}-2026-09-{n:02d}"}
        rows = [entry(1, key=f"arkdeck-rust-build-v1-{'a' * 64}-{'b' * 40}"), entry(2), entry(3),
                entry(4, "linux"), entry(5, key="arkdeck-cargo-policy-tools-v1"),
                entry(6, key="arkdeck-swiftpm-v2"), entry(7, key="arkdeck-xcode-v2"),
                entry(8, ref="refs/heads/agent/pr"), entry(9, key="arkdeck-rust-build-unrecognized")]
        self.assertEqual([e["id"] for e in retention.removals(rows)], [2, 1])
        same_path_other_host = entry(10)
        same_path_other_host["key"] = same_path_other_host["key"].replace("macOS-ARM64", "Linux-X64")
        self.assertEqual(retention.removals([entry(3), same_path_other_host]), [])

    @staticmethod
    def v3(n, image, size=700_000_000, version="win", host="Windows-X64", manifests="c"):
        return {"id": n, "created_at": f"2026-09-{n:02d}", "version": version, "ref": "refs/heads/main",
                "size_in_bytes": size,
                "key": f"arkdeck-rust-build-v3-{host}-image-{image}-{'a' * 64}-{manifests * 64}-2026-09-{n:02d}"}

    def test_keeps_the_newest_entry_of_a_second_image_but_never_a_third(self):
        rows = [self.v3(1, "old"), self.v3(2, "img.1"), self.v3(3, "img.2"), self.v3(4, "img.1", manifests="d"),
                self.v3(5, "img.2", manifests="d"), self.v3(6, "img.1", version="lin", host="Linux-X64")]
        # 5 (img.2) is the newest Windows entry and 4 the newest of img.1; the
        # older entries of either image and a third image go. Linux is its
        # own format.
        self.assertEqual(sorted(e["id"] for e in retention.removals(rows)), [1, 2, 3])
        # One entry per image: the same image never takes the second slot.
        self.assertEqual([e["id"] for e in retention.removals([self.v3(1, "img.1"), self.v3(2, "img.1")])], [1])
        # A v2 key names no image, so it never takes the second slot.
        v2 = {"id": 1, "created_at": "2026-09-01", "version": "win", "ref": "refs/heads/main", "size_in_bytes": 1,
              "key": f"arkdeck-rust-build-v2-Windows-X64-{'a' * 64}-2026-09-01"}
        self.assertEqual([e["id"] for e in retention.removals([v2, self.v3(2, "img.1")])], [1])

    def test_other_image_entries_fit_the_rust_budget_and_never_displace_the_newest(self):
        budget = retention.RUST_BUDGET_BYTES
        rows = [self.v3(1, "a", size=budget // 4, version="w1"), self.v3(2, "b", size=budget // 4, version="w1"),
                self.v3(3, "a", size=budget // 4, version="w2"), self.v3(4, "b", size=budget // 4, version="w2"),
                self.v3(5, "a", size=budget // 4, version="w3"), self.v3(6, "b", size=budget // 4, version="w3")]
        # Primaries 2, 4 and 6 take three quarters; only the newest other-image
        # entry (5) fits, the older ones (3, 1) are deleted.
        self.assertEqual(sorted(e["id"] for e in retention.removals(rows)), [1, 3])
        # Primaries alone over the budget are all kept, as before this rule.
        huge = [self.v3(1, "a", size=budget, version="w1"), self.v3(2, "b", size=budget, version="w1"),
                self.v3(3, "a", size=budget, version="w2")]
        self.assertEqual([e["id"] for e in retention.removals(huge)], [1])
        # Other families are neither counted nor deleted.
        other = {"id": 9, "created_at": "2026-09-09", "version": "w1", "ref": "refs/heads/main",
                 "size_in_bytes": 10 * budget, "key": "arkdeck-swiftpm-v2-macOS-ARM64-xcode-27.0-image-x-y"}
        self.assertEqual(retention.removals(rows[:2] + [other]), [])

    def test_write_authority_requires_successful_same_repository_main_ci(self):
        event = {"repository": {"full_name": "o/r"}, "workflow_run": {
            "head_repository": {"full_name": "o/r"}, "head_branch": "main", "event": "push",
            "path": ".github/workflows/swift-ci.yml", "conclusion": "success"}}
        self.assertTrue(retention.trusted_event(event, "o/r"))
        for field, value in (("head_repository", {"full_name": "fork/r"}), ("head_branch", "agent/pr"),
                             ("event", "pull_request"), ("conclusion", "failure"), ("path", "other.yml")):
            self.assertFalse(retention.trusted_event(event | {"workflow_run": event["workflow_run"] | {field: value}}, "o/r"))


class CargoSchedulingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="arkdeck-ci-cargo-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest = self.root / "Cargo.toml"
        self.manifest.write_text('[package]\nname="arkdeck-agentd"\nversion="0.1.0"\nedition="2021"\n')
        self.metadata = {"workspace_members": ["agent"], "packages": [
            {"id": "agent", "name": "arkdeck-agentd", "manifest_path": str(self.manifest), "targets": []}]}

    def artifact(self, name, kind="test", package="agent", harness=True):
        return {"reason": "compiler-artifact", "package_id": package, "target": {"name": name, "kind": [kind]},
                "profile": {"test": harness}, "executable": "/never-executed-directly"}

    def messages(self, *artifacts):
        return [*artifacts, {"reason": "build-finished", "success": True}]

    def test_new_and_sensitive_targets_are_exhaustive_and_conservative(self):
        planned = dict(tests.queues(self.messages(
            self.artifact("workspace_tests_process"), self.artifact("spawning"),
            self.artifact("capture_diagnostics"), self.artifact("brand_new"),
            self.artifact("arkforged_owner_stop", harness=False), self.artifact("agent", "lib"),
            self.artifact("agent", "bin"), self.artifact("checked_example", "example"),
        ), self.metadata))
        self.assertEqual(planned["isolated"], tests.BASE + ["--test", "workspace_tests_process"])
        conservative = planned["shared-resources"]
        for target in ("spawning", "capture_diagnostics", "brand_new", "arkforged_owner_stop", "checked_example"):
            self.assertIn(target, conservative)
        self.assertIn("--lib", conservative)
        self.assertIn("--bin", conservative)
        self.assertNotIn("workspace_tests_process", conservative)
        self.assertEqual(conservative[:len(tests.BASE)], tests.BASE)

    def test_duplicate_names_do_not_inherit_another_packages_overlap_permission(self):
        self.metadata["workspace_members"].append("other")
        self.metadata["packages"].append(dict(self.metadata["packages"][0], id="other", name="other"))
        planned = dict(tests.queues(self.messages(self.artifact("workspace_tests_process"),
            self.artifact("workspace_tests_process", package="other")), self.metadata))
        self.assertNotIn("isolated", planned)
        self.assertIn("workspace_tests_process", planned["shared-resources"])

    def test_audited_cli_targets_overlap_but_other_package_names_stay_conservative(self):
        cli = dict(self.metadata["packages"][0], id="cli", name="arkdeck-cli")
        self.metadata["workspace_members"].append("cli")
        self.metadata["packages"].append(cli)
        planned = dict(tests.queues(self.messages(
            self.artifact("domain_leaves", package="cli"), self.artifact("runtime_service", package="cli"),
            self.artifact("spawning"), self.artifact("control_action_host_process"),
        ), self.metadata))
        self.assertIn("domain_leaves", planned["isolated"])
        self.assertIn("runtime_service", planned["isolated"])
        self.assertNotIn("spawning", planned["isolated"])
        self.assertNotIn("control_action_host_process", planned["isolated"])
        planned = dict(tests.queues(self.messages(self.artifact("runtime_service")), self.metadata))
        self.assertNotIn("isolated", planned)

    def test_ambiguous_shapes_fall_back_to_all_tests_and_incomplete_inventory_fails(self):
        with self.assertRaisesRegex(ValueError, "complete test build"):
            tests.queues([self.artifact("test")], self.metadata)
        self.manifest.write_text(self.manifest.read_text() + '\n[[example]]\nname="custom"\nharness=false\n')
        self.assertEqual(tests.queues(self.messages(self.artifact("test")), self.metadata), [("workspace", tests.BASE)])
        self.assertEqual(tests.queues(self.messages(), self.metadata), [("workspace", tests.BASE)])

    @unittest.skipUnless(shutil.which("cargo"), "native fixture needs Cargo")
    def test_native_cargo_keeps_harnesses_docs_environment_overlap_and_failures(self):
        # A tiny dependency-free workspace, not the product's full CI gate.
        # The two tests handshake: serialized Cargo executions cannot pass.
        self.manifest.write_text(self.manifest.read_text() + '\n[[test]]\nname="custom"\nharness=false\n')
        (self.root / "src").mkdir()
        (self.root / "tests").mkdir()
        (self.root / "receipts").mkdir()
        helper = '''fn mark(name: &str) {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    assert_eq!(std::env::current_dir().unwrap(), root);
    std::fs::write(root.join("receipts").join(name), "ran").unwrap();
}
fn overlap(mine: &str, peer: &str) {
    mark(mine);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("receipts").join(peer).exists() {
        assert!(std::time::Instant::now() < deadline, "Cargo queues did not overlap");
        std::thread::yield_now();
    }
}
'''
        (self.root / "src/lib.rs").write_text('''/// ```
/// std::fs::write("receipts/doc", "ran").unwrap();
/// assert!(std::env::var("ARKDECK_CI_FIXTURE_FAIL_DOC").is_err());
/// ```
pub fn documented() {}
#[test] fn unit() { std::fs::write("receipts/unit", "ran").unwrap(); }
''')
        (self.root / "tests/shared.rs").write_text(helper + '#[test] fn shared() { overlap("shared", "isolated"); }\n')
        (self.root / "tests/workspace_tests_process.rs").write_text(helper + '#[test] fn isolated() { overlap("isolated", "shared"); }\n')
        (self.root / "tests/custom.rs").write_text('fn main() { std::fs::write("receipts/custom", "ran").unwrap(); }\n')
        environment = {"CARGO_TARGET_DIR": str(self.root / "target"), "CARGO_BUILD_JOBS": "2"}
        with patch.dict(os.environ, environment), contextlib.redirect_stdout(io.StringIO()):
            subprocess.run(["cargo", "generate-lockfile", "--offline"], cwd=self.root, check=True, capture_output=True)
            directory = self.root / "reports"
            code = tests.execute(self.root, workers=2, directory=directory)
            if code:
                self.fail("native fixture failed: " + "\n".join(p.read_text() for p in directory.glob("*.log")))
            self.assertEqual({p.name for p in (self.root / "receipts").iterdir()}, {"unit", "doc", "shared", "isolated", "custom"})
            # Compaction does not invalidate linked outputs/fingerprints. Cargo
            # can reuse them even though compiler incremental scratch is gone.
            shutil.rmtree(self.root / "target/debug/incremental", ignore_errors=True)
            warm = subprocess.run(tests.BASE + ["--no-run", "--message-format=json"],
                                  cwd=self.root, check=True, capture_output=True, text=True)
            artifacts = [json.loads(line) for line in warm.stdout.splitlines() if line.startswith('{')]
            self.assertTrue(all(m["fresh"] for m in artifacts if m.get("reason") == "compiler-artifact"))
            # A failing queue must not suppress the other queue or doctests.
            (self.root / "tests/shared.rs").write_text(helper + '#[test] fn shared() { mark("shared"); panic!("fixture failure"); }\n')
            with patch.dict(os.environ, {"ARKDECK_CI_FIXTURE_FAIL_DOC": "1"}):
                self.assertNotEqual(tests.execute(self.root, workers=2, directory=directory), 0)
            report = json.loads((directory / "timings.json").read_text())
            stages = {stage["name"]: stage for stage in report["stages"]}
            self.assertTrue(report["completed"])
            self.assertNotEqual(stages["shared-resources"]["exitCode"], 0)
            self.assertNotEqual(stages["doctests"]["exitCode"], 0)
            self.assertEqual(stages["isolated"]["exitCode"], 0)


if __name__ == "__main__":
    unittest.main()
