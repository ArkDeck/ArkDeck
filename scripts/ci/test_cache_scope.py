#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

from cache_scope import scope


class CacheScopeTests(unittest.TestCase):
    def test_main_retains_existing_trusted_cache_keys(self):
        for kind in ("swiftpm", "xcode"):
            self.assertEqual(scope(kind, "push", "refs/heads/main"),
                             {"prefix": f"arkdeck-{kind}-v2", "can-save": "true"})

    def test_agent_push_reuses_only_its_own_separate_namespace(self):
        for kind in ("swiftpm", "xcode"):
            first = scope(kind, "push", "refs/heads/agent/first")
            self.assertEqual(first, scope(kind, "push", "refs/heads/agent/first"))
            self.assertNotEqual(first["prefix"], scope(kind, "push", "refs/heads/agent/second")["prefix"])
            self.assertTrue(first["prefix"].startswith(f"arkdeck-{kind}-candidate-v1-"))
            self.assertEqual(first["can-save"], "true")

    def test_queue_and_other_events_only_restore_trusted_caches(self):
        for event, ref in (("merge_group", "refs/heads/gh-readonly-queue/main/pr-12"),
                           ("pull_request", "refs/pull/12/merge"),
                           ("workflow_dispatch", "refs/heads/main"),
                           ("pull_request", "refs/heads/agent/first"),
                           ("push", "refs/heads/unrelated"), ("", "")):
            with self.subTest(event=event, ref=ref):
                self.assertEqual(scope("swiftpm", event, ref),
                                 {"prefix": "arkdeck-swiftpm-v2", "can-save": "false"})


spec = importlib.util.spec_from_file_location("retention", Path(__file__).with_name("retain-rust-caches.py"))
retention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retention)


class CandidateRetentionTests(unittest.TestCase):
    def entry(self, number, branch="agent/a", kind="swiftpm", size=700_000_000):
        ref = f"refs/heads/{branch}"
        prefix = scope(kind, "push", ref)["prefix"]
        return {"id": number, "ref": ref, "key": f"{prefix}-macOS-ARM64-xcode-27.0-{'a' * 64}-{'b' * 40}",
                "version": kind, "size_in_bytes": size, "created_at": f"2026-10-{number:02d}"}

    def test_retains_latest_per_branch_format_with_a_total_budget(self):
        entries = [self.entry(1), self.entry(2), self.entry(3, kind="xcode"), self.entry(4, branch="agent/b")]
        removed = retention.candidate_removals(entries)
        self.assertEqual([e["id"] for e in removed], [2, 1])
        kept = [e for e in entries if e not in removed]
        self.assertLessEqual(sum(e["size_in_bytes"] for e in kept), retention.CANDIDATE_BUDGET_BYTES)

    def test_never_deletes_main_or_other_branches_or_unknown_cache_formats(self):
        entries = [self.entry(1, branch="main"), self.entry(2, branch="other")]
        forged = self.entry(3)
        forged["ref"] = "refs/heads/agent/other"
        entries += [forged, self.entry(4) | {"key": "unrelated-cache"},
                    self.entry(5) | {"version": None}]
        self.assertEqual(retention.candidate_removals(entries), [])

    def test_one_oversized_candidate_cannot_evict_all_main_caches(self):
        entry = self.entry(1, size=retention.CANDIDATE_BUDGET_BYTES + 1)
        self.assertEqual(retention.candidate_removals([entry]), [entry])

    def test_agent_event_only_explicitly_allows_candidate_maintenance(self):
        event = {"repository": {"full_name": "o/r"}, "workflow_run": {
            "head_repository": {"full_name": "o/r"}, "head_branch": "agent/a", "event": "push",
            "path": ".github/workflows/swift-ci.yml", "conclusion": "success"}}
        self.assertFalse(retention.trusted_event(event, "o/r"))
        self.assertTrue(retention.trusted_event(event, "o/r", allow_agent=True))
        for field, value in (("head_repository", {"full_name": "fork/r"}), ("head_branch", "other"),
                             ("event", "pull_request"), ("conclusion", "failure"), ("path", "other.yml")):
            changed = event | {"workflow_run": event["workflow_run"] | {field: value}}
            self.assertFalse(retention.trusted_event(changed, "o/r", allow_agent=True))


if __name__ == "__main__":
    unittest.main()
