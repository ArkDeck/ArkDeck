#!/usr/bin/env python3
"""Run actual workflow checkout snippets against a ref that already advanced.

Only temporary local Git repositories are used; Git's allowed protocols prevent
network access even if the workflow's remote command changes unexpectedly.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/swift-ci.yml"
JOBS = ("plan", "swift-tests", "app-build", "ds-interactions")


def checkout_script(job: str) -> str:
    text = WORKFLOW.read_text()
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [a-z][a-z-]*:\n|\Z)", text, re.M | re.S)
    if match is None:
        raise AssertionError(f"missing job {job}")
    _, found, checkout = match[1].partition("      - name: Checkout exact revision")
    if not found:
        raise AssertionError(f"missing checkout for {job}")
    _, found, body = checkout.partition("        run: |\n")
    if not found:
        raise AssertionError(f"missing checkout script for {job}")
    lines = []
    for line in body.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line[10:] if line else "")
    return "\n".join(lines)


class EventCheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="arkdeck-ci-checkout-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.origin = self.root / "origin"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_AUTHOR_NAME": "CI checkout fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "CI checkout fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        })
        self.git("init", "--initial-branch=main", str(self.origin), cwd=self.root)
        self.event_sha = self.commit("event contents")
        self.tip_sha = self.commit("later contents")
        self.git("update-ref", "refs/pull/23/merge", self.tip_sha)
        self.env.update({
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": f"url.{self.origin}.insteadOf",
            "GIT_CONFIG_VALUE_0": "https://github.com/checkout-fixture/ArkDeck.git",
            "GITHUB_REPOSITORY": "checkout-fixture/ArkDeck",
        })

    def git(self, *args: str, cwd: Path | None = None):
        return subprocess.run(["git", *args], cwd=cwd or self.origin,
                              env=self.env, check=True, capture_output=True, text=True)

    def commit(self, content: str) -> str:
        (self.origin / "tracked.txt").write_text(content)
        self.git("add", "tracked.txt")
        self.git("-c", "commit.gpgsign=false", "commit", "-m", content)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def checkout(self, job: str, ref: str, sha: str):
        work = self.root / (job + "-" + ref.replace("/", "-"))
        work.mkdir()
        env = self.env | {"ARKDECK_CI_REF": ref, "ARKDECK_CI_SHA": sha}
        result = subprocess.run(["sh", "-c", checkout_script(job)], cwd=work,
                                env=env, capture_output=True, text=True, timeout=20)
        return work, result

    def test_each_lane_builds_event_sha_after_main_or_pr_ref_advances(self):
        for job in JOBS:
            for ref in ("refs/heads/main", "refs/pull/23/merge"):
                with self.subTest(job=job, ref=ref):
                    work, result = self.checkout(job, ref, self.event_sha)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.git("rev-parse", "HEAD", cwd=work).stdout.strip(), self.event_sha)
                    self.assertEqual((work / "tracked.txt").read_text(), "event contents")
                    if job == "plan":
                        self.assertEqual(self.git("rev-parse", "origin/main", cwd=work).stdout.strip(), self.tip_sha)

    def test_missing_event_sha_fails_without_falling_back_to_new_ref(self):
        for job in JOBS:
            with self.subTest(job=job):
                work, result = self.checkout(job, "refs/heads/main", "0" * 40)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((work / "tracked.txt").exists())


if __name__ == "__main__":
    unittest.main()
