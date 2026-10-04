#!/usr/bin/env python3
"""Exercise PR dependency discovery on real Git histories and API read-backs."""
import copy
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import agent_pr as subject

REPOSITORY = "example/ArkDeck"


def pull(number, branch, sha, base="main"):
    return {"number": number, "state": "open", "merged": False, "title": "change", "body": "",
            "user": {"login": "github-actions[bot]"},
            "head": {"ref": branch, "sha": sha, "repo": {"full_name": REPOSITORY}},
            "base": {"ref": base, "sha": "a" * 40, "repo": {"full_name": REPOSITORY}}}


class API:
    def __init__(self, pulls=(), stacks=()):
        self.pulls = copy.deepcopy(list(pulls))
        self.stacks = copy.deepcopy(list(stacks))
        self.writes = []
        self.lose_response = False

    def pages(self, path):
        return copy.deepcopy(self.stacks if path == "/stacks" else self.pulls)

    def request(self, path, payload=None):
        if payload is None:
            return copy.deepcopy(next(p for p in self.pulls if path == f"/pulls/{p['number']}"))
        self.writes.append((path, payload))
        if path == "/pulls":
            self.pulls.append(pull(99, payload["head"], self.sha, payload["base"]))
            self.pulls[-1].update({"title": payload["title"], "body": payload["body"]})
        elif path == "/stacks":
            self.stacks.append({"number": 1, "pull_requests": [
                {"number": n, "state": "open"} for n in payload["pull_requests"]]})
        else:
            stack = next(s for s in self.stacks if path == f"/stacks/{s['number']}/add")
            stack["pull_requests"] += [{"number": n, "state": "open"} for n in payload["pull_requests"]]
        if self.lose_response:
            raise subprocess.CalledProcessError(1, "gh", stderr="connection lost")
        return {}


class BranchTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.repo = subject.Repository(Path(temp.name))
        self.repo.git("init", "-q", "--initial-branch=main")
        self.repo.git("config", "user.name", "Fixture")
        self.repo.git("config", "user.email", "fixture@example.invalid")
        self.repo.git("config", "commit.gpgsign", "false")
        self.main = self.commit("main")
        self.repo.git("update-ref", "refs/remotes/origin/main", self.main)
        self.parent = self.commit("parent")
        self.child = self.commit("child")
        self.pulls = [pull(1, "agent/parent", self.parent)]

    def commit(self, message):
        self.repo.git("commit", "--allow-empty", "-qm", message)
        return self.repo.git("rev-parse", "HEAD")

    def choose(self, existing=None):
        return subject.choose_base(self.repo, self.pulls, REPOSITORY, "agent/child", self.child, existing)

    def test_new_child_chooses_nearest_unmerged_ancestor(self):
        self.pulls.append(pull(2, "agent/grandparent", self.main))
        self.assertEqual(self.choose(), "agent/parent")

    def test_existing_base_survives_new_commit_and_main_trailer(self):
        self.child = self.commit("child\n\nStack-Base: main")
        self.assertEqual(self.choose(pull(3, "agent/child", self.child, "agent/parent")), "agent/parent")

    def test_explicit_parent_works_after_parent_advanced(self):
        self.pulls[0]["head"]["sha"] = self.commit("advanced parent")
        self.repo.git("checkout", "--detach", self.child)
        self.child = self.commit("child\n\nStack-Base: agent/parent")
        self.assertEqual(self.choose(), "agent/parent")

    def test_explicit_main_starts_independent_work(self):
        self.child = self.commit("child\n\nStack-Base: main")
        self.assertEqual(self.choose(), "main")

    def test_equally_close_parents_require_explicit_base(self):
        self.pulls.append(pull(2, "agent/alias", self.parent))
        with self.assertRaisesRegex(subject.IdentityError, "ambiguous"):
            self.choose()

    def test_two_incomparable_parents_require_explicit_base(self):
        self.repo.git("checkout", "--detach", self.main)
        other = self.commit("other")
        self.repo.git("checkout", "--detach", self.child)
        self.repo.git("merge", "--no-ff", "-m", "both parents", other)
        self.child = self.repo.git("rev-parse", "HEAD")
        self.pulls.append(pull(2, "agent/other", other))
        with self.assertRaisesRegex(subject.IdentityError, "ambiguous"):
            self.choose()

    def test_merged_parent_is_not_inferred(self):
        self.repo.git("update-ref", "refs/remotes/origin/main", self.parent)
        self.assertEqual(self.choose(), "main")

    def test_missing_cross_repo_and_self_bases_are_rejected(self):
        for base in ("agent/missing", "agent/child", "other/branch"):
            with self.subTest(base=base):
                self.child = self.commit(f"child\n\nStack-Base: {base}")
                with self.assertRaises(subject.IdentityError):
                    self.choose()
        self.child = self.commit("child\n\nStack-Base: agent/parent")
        self.pulls[0]["head"]["repo"]["full_name"] = "fork/ArkDeck"
        with self.assertRaises(subject.IdentityError):
            self.choose()

    def test_create_readback_registers_stack_and_preserves_traceability(self):
        self.child = self.commit("fix(TASK-CI-001): child")
        api = API(self.pulls)
        api.sha = self.child
        number, stack = subject.open_pull(self.repo, api, REPOSITORY, "agent/child", self.child)
        self.assertEqual((number, stack), (99, 1))
        self.assertEqual(api.writes[0][1]["base"], "agent/parent")
        self.assertIn("Task: TASK-CI-001", api.writes[0][1]["body"])
        self.assertIn("Depends on #1", api.writes[0][1]["body"])
        self.assertEqual(api.writes[1][1], {"pull_requests": [1, 99]})
        subject.open_pull(self.repo, api, REPOSITORY, "agent/child", self.child)
        self.assertEqual(len(api.writes), 2)

    def test_existing_wrong_author_or_stale_head_permits_no_mutation(self):
        for field in ("author", "head", "repository"):
            with self.subTest(field=field):
                child = pull(2, "agent/child", self.child, "agent/parent")
                if field == "author":
                    child["user"]["login"] = "someone"
                elif field == "head":
                    child["head"]["sha"] = self.parent
                else:
                    child["base"]["repo"]["full_name"] = "other/repo"
                api = API(self.pulls + [child])
                with self.assertRaises(subject.IdentityError):
                    subject.open_pull(self.repo, api, REPOSITORY, "agent/child", self.child)
                self.assertEqual(api.writes, [])

    def test_lost_create_and_stack_responses_are_read_back_without_duplicate_writes(self):
        api = API(self.pulls)
        api.sha, api.lose_response = self.child, True
        self.assertEqual(subject.open_pull(self.repo, api, REPOSITORY, "agent/child", self.child), (99, 1))
        self.assertEqual(len(api.writes), 2)


class StackTests(unittest.TestCase):
    def test_append_only_new_top_and_recheck_lower_layer(self):
        api = API()
        self.assertEqual(subject.register_stack(api, [1, 2]), 1)
        self.assertEqual(subject.register_stack(api, [1, 2, 3]), 1)
        self.assertEqual(api.writes[-1], ("/stacks/1/add", {"pull_requests": [3]}))
        subject.register_stack(api, [1, 2])
        self.assertEqual(len(api.writes), 2)

    def test_concurrent_different_child_fails_without_mutation(self):
        api = API()
        subject.register_stack(api, [1, 2])
        with self.assertRaisesRegex(subject.IdentityError, "different order"):
            subject.register_stack(api, [1, 3])
        self.assertEqual(len(api.writes), 1)

    def test_stack_api_failure_is_not_reported_as_registered(self):
        api = API()
        with patch.object(api, "request", side_effect=subprocess.CalledProcessError(1, "gh")):
            with self.assertRaisesRegex(subject.IdentityError, "did not read back"):
                subject.register_stack(api, [1, 2])

    def test_cycles_and_missing_parents_fail(self):
        a = pull(1, "agent/a", "a" * 40, "agent/b")
        b = pull(2, "agent/b", "b" * 40, "agent/a")
        for parents in ([a, b], [a]):
            with self.assertRaises(subject.IdentityError):
                subject.chain_for(a, parents, REPOSITORY)


if __name__ == "__main__":
    unittest.main()
