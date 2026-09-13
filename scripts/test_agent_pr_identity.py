#!/usr/bin/env python3
"""Offline contract tests for the Agent PR identity helper (TASK-RPG-001).

The pull-list, identity and read-back cases are carried over unchanged from
the retired ``test_check_pr_paths.py``; the ``--commit-task`` cases and the
scripts/ boundary-map check are new here.
"""

from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import agent_pr_identity


ZERO_OID = "0" * 40
ONE_OID = "1" * 40
REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = Path(__file__).resolve().parent / "agent_pr_identity.py"


def pull_request_api(
    *,
    number: object = 483,
    state: object = "open",
    merged: object = False,
    title: object = "ci(TASK-HLR-001A): automate Agent PR checks",
    body: object = None,
    base_ref: object = "main",
    base_sha: object = ZERO_OID,
    base_repo: object = "ArkDeck/ArkDeck",
    head_ref: object = "agent/task-hlr-001a-auto-ci",
    head_sha: object = ONE_OID,
    head_repo: object = "ArkDeck/ArkDeck",
    author: object = "github-actions[bot]",
) -> dict[str, object]:
    return {
        "number": number,
        "state": state,
        "merged": merged,
        "title": title,
        "body": body,
        "base": {"ref": base_ref, "sha": base_sha, "repo": {"full_name": base_repo}},
        "head": {"ref": head_ref, "sha": head_sha, "repo": {"full_name": head_repo}},
        "user": {"login": author},
    }


EXPECTED = {
    "expected_repository": "ArkDeck/ArkDeck",
    "expected_number": 483,
    "expected_base_ref": "main",
    "expected_head_ref": "agent/task-hlr-001a-auto-ci",
    "expected_head_oid": ONE_OID,
    "expected_author": "github-actions[bot]",
}
EXPECTED_ARGV = (
    "--expected-repository", "ArkDeck/ArkDeck",
    "--expected-number", "483",
    "--expected-base-ref", "main",
    "--expected-head-ref", "agent/task-hlr-001a-auto-ci",
    "--expected-head-oid", ONE_OID,
    "--expected-author", "github-actions[bot]",
)


class _Assertions(unittest.TestCase):
    def assert_error(self, fragment: str, callable_) -> None:
        with self.assertRaises(agent_pr_identity.IdentityError) as caught:
            callable_()
        self.assertIn(fragment, str(caught.exception))

    def run_helper(self, *argv: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(HELPER), "--repo-root", str(REPO_ROOT), *argv],
            check=False,
            capture_output=True,
            text=True,
        )


class PullListTests(_Assertions):
    def test_paginated_pull_list_create_or_find_matrix_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="agent-pr-list-") as temp:
            list_path = Path(temp) / "pulls.json"

            list_path.write_text("[[]]", encoding="utf-8")
            self.assertIsNone(
                agent_pr_identity.select_unique_pull_request_number(
                    list_path, allow_zero=True
                )
            )
            self.assert_error(
                "found 0",
                lambda: agent_pr_identity.select_unique_pull_request_number(
                    list_path, allow_zero=False
                ),
            )

            list_path.write_text('[[{"number":483}]]', encoding="utf-8")
            self.assertEqual(
                agent_pr_identity.select_unique_pull_request_number(
                    list_path, allow_zero=False
                ),
                483,
            )

            for payload, expected in (
                ('[[{"number":483},{"number":484}]]', "found 2"),
                ('[[{"number":483}],[{"number":484}]]', "found 2"),
                ('[{"number":483}]', "array of page arrays"),
                ('[[{"number":"483"}]]', "positive integer"),
                ('[[{"number":true}]]', "positive integer"),
                ('[[{"number":0}]]', "positive integer"),
                ('[[null]]', "non-object"),
                ("not json", "cannot parse"),
            ):
                with self.subTest(payload=payload):
                    list_path.write_text(payload, encoding="utf-8")
                    self.assert_error(
                        expected,
                        lambda: agent_pr_identity.select_unique_pull_request_number(
                            list_path, allow_zero=False
                        ),
                    )
            # allow_zero tolerates exactly zero, never ambiguity
            list_path.write_text('[[{"number":483},{"number":484}]]', encoding="utf-8")
            self.assert_error(
                "found 2",
                lambda: agent_pr_identity.select_unique_pull_request_number(
                    list_path, allow_zero=True
                ),
            )


class IdentityTests(_Assertions):
    def test_pull_request_api_identity_positive_and_negative_matrix(self):
        context = agent_pr_identity.validate_pull_request_identity(
            pull_request_api(), **EXPECTED
        )
        self.assertEqual(context.base_oid, ZERO_OID)
        self.assertEqual(context.head_oid, ONE_OID)
        self.assertEqual(context.body, "")
        self.assertEqual(context.head_ref, "agent/task-hlr-001a-auto-ci")

        cases = (
            ("number", {"number": 484}, "number does not match"),
            ("number type", {"number": "483"}, "positive integer"),
            ("state", {"state": "closed"}, "state must be open"),
            ("merged", {"merged": True}, "merged must be false"),
            ("merged missing", {"merged": None}, "merged must be false"),
            ("base ref", {"base_ref": "develop"}, "base.ref"),
            ("base repo", {"base_repo": "fork/ArkDeck"}, "base repository"),
            ("head ref", {"head_ref": "agent/other"}, "head.ref"),
            ("head repo", {"head_repo": "fork/ArkDeck"}, "head repository"),
            ("head sha", {"head_sha": ZERO_OID}, "head.sha"),
            ("author", {"author": "lvye"}, "author"),
            ("short base", {"base_sha": "abc"}, "full 40-hex OID"),
            ("null title", {"title": None}, "title must be a string"),
        )
        for label, changes, expected_error in cases:
            with self.subTest(label=label):
                self.assert_error(
                    expected_error,
                    lambda changes=changes: agent_pr_identity.validate_pull_request_identity(
                        pull_request_api(**changes), **EXPECTED
                    ),
                )

    def test_head_oid_comparison_is_case_insensitive_but_full_length(self):
        upper = dict(EXPECTED, expected_head_oid=ONE_OID.upper())
        agent_pr_identity.validate_pull_request_identity(pull_request_api(), **upper)
        short = dict(EXPECTED, expected_head_oid="1" * 39)
        self.assert_error(
            "expected head OID must be a full 40-hex OID",
            lambda: agent_pr_identity.validate_pull_request_identity(
                pull_request_api(), **short
            ),
        )

    def test_shape_errors_name_the_missing_object(self):
        self.assert_error(
            "must be an object",
            lambda: agent_pr_identity.validate_pull_request_identity([], **EXPECTED),
        )
        broken = pull_request_api()
        del broken["user"]
        self.assert_error(
            "user must be an object",
            lambda: agent_pr_identity.validate_pull_request_identity(broken, **EXPECTED),
        )
        self.assert_error(
            "base/head objects are missing",
            lambda: agent_pr_identity.pull_request_context_from_object(
                {"title": "x", "base": None, "head": {}}
            ),
        )


class CommitTaskTests(_Assertions):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="agent-pr-commit-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "Contract Test")
        self.git("config", "user.email", "contract@example.invalid")

    def git(self, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", "-C", str(self.root), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return completed.stdout.strip()

    def commit(self, subject: str, body: str = "") -> str:
        (self.root / "file.txt").write_text(subject + "\n", encoding="utf-8")
        self.git("add", "-A")
        message = subject if not body else f"{subject}\n\n{body}"
        self.git("commit", "--quiet", "-m", message)
        return self.git("rev-parse", "HEAD")

    def test_first_subject_token_or_none_and_never_a_lookup(self):
        cases = (
            ("fix(TASK-AAA-001): x", "TASK-AAA-001"),
            ("docs: no task here", None),
            ("Serve durable Target queries (TASK-XPA-012)", "TASK-XPA-012"),
            ("fix(TASK-AAA-001): port TASK-BBB-002 helper", "TASK-AAA-001"),
            ("chore(TASK-HLR-002A): suffixed token", "TASK-HLR-002A"),
            ("chore(TASK-UD-REDACTOR-001): multi-segment group", "TASK-UD-REDACTOR-001"),
            # A token nothing in openspec/ declares is still printed: the line
            # is traceability, not a lookup.
            ("feat(TASK-ZZZ-999Z): not in any tasks.md", "TASK-ZZZ-999Z"),
            ("XTASK-AAA-001 prefix noise and TASK-AAA-0012 too long", None),
        )
        for subject, expected in cases:
            with self.subTest(subject=subject):
                oid = self.commit(subject)
                self.assertEqual(
                    agent_pr_identity.commit_task_declaration(self.root, oid), expected
                )

    def test_body_tokens_do_not_count(self):
        oid = self.commit("docs: subject without token", "Task: TASK-AAA-001")
        self.assertIsNone(agent_pr_identity.commit_task_declaration(self.root, oid))

    def test_unknown_revision_fails_closed(self):
        self.commit("docs: seed")
        self.assert_error(
            "git rev-parse",
            lambda: agent_pr_identity.commit_task_declaration(self.root, "0" * 40),
        )
        self.assert_error(
            "must not be empty",
            lambda: agent_pr_identity.commit_task_declaration(self.root, ""),
        )

    def test_command_line_prints_token_or_none(self):
        oid = self.commit("fix(TASK-AAA-001): x")
        completed = subprocess.run(
            [sys.executable, str(HELPER), "--repo-root", str(self.root),
             "--commit-task", oid],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "TASK-AAA-001")
        oid = self.commit("docs: none")
        completed = subprocess.run(
            [sys.executable, str(HELPER), "--repo-root", str(self.root),
             "--commit-task", "HEAD"],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "none")


class CommandLineTests(_Assertions):
    def test_pull_list_prints_the_number_or_none(self):
        with tempfile.TemporaryDirectory(prefix="agent-pr-cli-") as temp:
            list_path = Path(temp) / "pulls.json"
            list_path.write_text("[[]]", encoding="utf-8")
            completed = self.run_helper("--pull-list", str(list_path), "--allow-zero")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout.strip(), "none")
            completed = self.run_helper("--pull-list", str(list_path))
            self.assertEqual(completed.returncode, 1)
            self.assertIn("found 0", completed.stderr)
            list_path.write_text('[[{"number":483}]]', encoding="utf-8")
            completed = self.run_helper("--pull-list", str(list_path))
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout.strip(), "483")

    def test_flag_combinations_are_refused(self):
        with tempfile.TemporaryDirectory(prefix="agent-pr-cli-") as temp:
            list_path = Path(temp) / "pulls.json"
            list_path.write_text('[[{"number":483}]]', encoding="utf-8")
            payload = Path(temp) / "pull.json"
            payload.write_text(json.dumps(pull_request_api()), encoding="utf-8")
            cases = (
                (("--pull-list", str(list_path), "--expected-number", "483"),
                 "valid only with --pull-request"),
                (("--commit-task", "HEAD", "--expected-author", "x"),
                 "valid only with --pull-request"),
                (("--pull-request", str(payload), "--allow-zero", *EXPECTED_ARGV),
                 "--allow-zero is valid only with --pull-list"),
                (("--pull-request", str(payload), "--expected-number", "483"),
                 "missing expectations"),
                (("--commit-task", "HEAD", "--allow-zero"),
                 "--allow-zero is valid only with --pull-list"),
            )
            for argv, expected in cases:
                with self.subTest(argv=argv):
                    completed = self.run_helper(*argv)
                    self.assertEqual(completed.returncode, 1, completed.stdout)
                    self.assertIn(expected, completed.stderr)

    def test_pull_request_prints_the_number_carried_by_the_api_response(self):
        temporary = tempfile.TemporaryDirectory(prefix="agent-pr-identity-")
        self.addCleanup(temporary.cleanup)
        payload = Path(temporary.name) / "pull.json"
        pull_request = pull_request_api()
        payload.write_text(json.dumps(pull_request), encoding="utf-8")
        completed = self.run_helper("--pull-request", str(payload), *EXPECTED_ARGV)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "483")

        # Mismatched payload: the value printed must come from the response,
        # so a disagreement is a rejection rather than a confirming echo.
        pull_request["number"] = 484
        payload.write_text(json.dumps(pull_request), encoding="utf-8")
        completed = self.run_helper("--pull-request", str(payload), *EXPECTED_ARGV)
        self.assertEqual(completed.returncode, 1)
        self.assertIn("number does not match", completed.stderr)

    def test_pull_request_reads_the_number_back_rather_than_echoing_it(self):
        """Pins where the printed number comes from, not just its value.

        With identity validation in force the echo and the read-back always
        agree, so no black-box case can tell them apart — which is exactly
        how a guard becomes decorative. Suspending the comparison exposes
        the source: the echo would still print the expectation.
        """
        temporary = tempfile.TemporaryDirectory(prefix="agent-pr-readback-")
        self.addCleanup(temporary.cleanup)
        payload = Path(temporary.name) / "pull.json"
        payload.write_text(json.dumps(pull_request_api(number=901)), encoding="utf-8")

        original = agent_pr_identity.validate_pull_request_identity
        agent_pr_identity.validate_pull_request_identity = (
            lambda pull_request, **expectations: (
                agent_pr_identity.pull_request_context_from_object(pull_request)
            )
        )
        self.addCleanup(
            setattr, agent_pr_identity, "validate_pull_request_identity", original
        )

        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            exit_code = agent_pr_identity.main(
                ["--repo-root", str(REPO_ROOT), "--pull-request", str(payload),
                 *EXPECTED_ARGV]
            )
        self.assertEqual(exit_code, 0)
        self.assertEqual(buffer.getvalue().strip(), "901")


class TokenGrammarTests(unittest.TestCase):
    def test_token_boundaries(self):
        found = agent_pr_identity.TASK_TOKEN_RE.findall(
            "XTASK-A-001 TASK-A-001 TASK-A-0012 TASK-AB-CD-002B task-a-003 TASK-A-004-"
        )
        self.assertEqual(found, ["TASK-A-001", "TASK-AB-CD-002B"])


class ScriptsBoundaryMapTests(unittest.TestCase):
    """scripts/README.md must name every first-level scripts/ entry (TASK-DEC-001)."""

    def test_readme_boundary_map_covers_every_first_level_scripts_entry(self):
        readme_text = (REPO_ROOT / "scripts" / "README.md").read_text(encoding="utf-8")
        completed = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "ls-tree", "--name-only", "HEAD", "scripts/"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        entries = [
            line[len("scripts/"):]
            for line in completed.stdout.splitlines()
            if line.startswith("scripts/")
        ]
        self.assertTrue(entries, "git ls-tree returned no scripts/ entries")
        missing = [
            entry
            for entry in entries
            if f"`{entry}`" not in readme_text and f"`{entry}/`" not in readme_text
        ]
        self.assertEqual(missing, [], f"scripts/README.md does not mention: {missing}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
