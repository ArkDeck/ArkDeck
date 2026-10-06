#!/usr/bin/env python3
"""Activation regressions using API fixtures; no runner or remote host is created."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("linux_runner_pool", Path(__file__).with_name("linux_runner_pool.py"))
POOL = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = POOL
SPEC.loader.exec_module(POOL)


def guest(number):
    return {"id": number, "name": f"{POOL.NAME_PREFIX}{number}-fixture", "os": "linux",
            "ephemeral": True, "status": "online", "busy": False,
            "labels": [{"name": name} for name in ("self-hosted", "Linux", "X64", POOL.POOL_LABEL)]}


class FakeGitHub:
    root = f"repos/{POOL.REPOSITORY}/actions"

    def __init__(self, runners=None, route=None):
        self.runners = [guest(1), guest(2)] if runners is None else runners
        self.value = route
        self.writes = []

    def collection(self, name):
        assert name == "runners"
        return self.runners

    def route(self):
        return self.value

    def set_route(self, previous, value):
        assert previous == self.value
        self.writes.append((previous, value))
        self.value = value

    def api(self, path):
        if path.endswith("/git/ref/heads/main"):
            return {"object": {"sha": "a" * 40}}
        if "/workflows/" in path:
            return {"workflow_runs": [{"id": 10, "head_sha": "a" * 40, "head_branch": "main",
                                       "event": "workflow_dispatch", "status": "completed", "conclusion": "success"}]}
        return {"total_count": 2, "jobs": [{"name": f"Linux pool smoke ({suite})", "runner_id": number,
                          "status": "completed", "conclusion": "success",
                          "started_at": "2026-10-06T00:00:00Z", "completed_at": "2026-10-06T00:01:00Z"}
                         for suite, number in (("plan", 8), ("guard", 9))]}


class PoolTests(unittest.TestCase):
    def test_smoke_runs_both_real_suites_only_on_the_isolated_pool(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows" / POOL.WORKFLOW
        text = workflow.read_text()
        for required in (
            "on:\n  workflow_dispatch:\n", "permissions:\n  contents: read\n",
            "    runs-on: [self-hosted, Linux, X64, arkdeck-linux-light]\n",
            "        suite: [plan, guard]\n", "      fail-fast: false\n",
            "          ARKDECK_SMOKE_SUITE: ${{ matrix.suite }}\n",
            '        run: python3 scripts/ci/linux_runner_pool.py check-suite "$ARKDECK_SMOKE_SUITE"\n',
        ):
            self.assertIn(required, text)
        for forbidden in ("continue-on-error:", "secrets.", "  pull_request:", "  push:"):
            self.assertNotIn(forbidden, text)

    def test_empty_single_busy_or_offline_pool_never_activates(self):
        for runners in ([], [guest(1)], [guest(1), guest(2) | {"busy": True}],
                        [guest(1), guest(2) | {"status": "offline"}]):
            github = FakeGitHub(runners)
            with self.subTest(runners=runners), self.assertRaises(POOL.PoolError):
                POOL.switch_route(github, activate=True)
            self.assertEqual(github.writes, [])

    def test_unsafe_matching_runner_poisoning_cannot_be_hidden_by_two_ready_guests(self):
        for bad in (guest(3) | {"ephemeral": False}, guest(3) | {"ephemeral": None},
                    guest(3) | {"os": "windows"}, guest(3) | {"os": None}, guest(3) | {"name": "unmanaged"},
                    guest(3) | {"id": True}, guest(1), guest(3) | {"busy": "false"}):
            github = FakeGitHub([guest(1), guest(2), bad])
            with self.subTest(bad=bad), self.assertRaises(POOL.PoolError):
                POOL.switch_route(github, activate=True)
            self.assertEqual(github.writes, [])

    def test_unknown_ephemeral_or_architecture_facts_fail_closed(self):
        for key in ("ephemeral", "os", "labels"):
            bad = guest(2)
            del bad[key]
            with self.subTest(key=key), self.assertRaises(POOL.PoolError):
                POOL.inspect_pool([guest(1), bad])
        bad = guest(2)
        bad["labels"] = [label for label in bad["labels"] if label["name"] != "X64"]
        with self.assertRaises(POOL.PoolError):
            POOL.inspect_pool([guest(1), bad])

    def test_other_runner_pool_is_ignored(self):
        other = {"id": 99, "labels": [{"name": "another-pool"}]}
        self.assertTrue(POOL.inspect_pool([guest(1), guest(2), other])["ready"])

    def test_two_guests_activate_with_readback_and_are_idempotent(self):
        github = FakeGitHub()
        result = POOL.switch_route(github, activate=True)
        self.assertEqual(result["pool"]["idleRunnerIds"], [1, 2])
        self.assertEqual(github.writes, [(None, POOL.POOL_LABEL)])
        POOL.switch_route(github, activate=True)
        self.assertEqual(len(github.writes), 1)

    def test_existing_external_route_is_preserved(self):
        for activate in (True, False):
            github = FakeGitHub(route="external-label")
            with self.subTest(activate=activate), self.assertRaises(POOL.PoolError):
                POOL.switch_route(github, activate=activate)
            self.assertEqual(github.writes, [])

    def test_smoke_failure_stale_head_shared_guest_or_no_replenishment_blocks_writes(self):
        variants = [
            {"workflow_runs": []},
            {"workflow_runs": [None]},
            {"workflow_runs": [{"id": 10, "head_sha": "b" * 40}]},
            {"workflow_runs": [{"id": 11, "head_sha": "a" * 40, "head_branch": "main",
                                "event": "workflow_dispatch", "status": "completed", "conclusion": "failure"}]},
        ]
        for response in variants:
            github = FakeGitHub()
            api = github.api
            with mock.patch.object(github, "api", side_effect=lambda path: response if "/workflows/" in path else api(path)), \
                    self.assertRaises(POOL.PoolError):
                POOL.switch_route(github, activate=True)
            self.assertEqual(github.writes, [])
        for change in ({"runner_id": 8}, {"runner_id": 1}, {"conclusion": "failure"},
                       {"started_at": "2026-10-06T00:01:01Z"},
                       {"started_at": "2026-10-06T00:00:00"}):
            github = FakeGitHub()
            api = github.api
            def altered(path):
                response = api(path)
                if "/runs/10/jobs" in path:
                    response["jobs"][1].update(change)
                return response
            with self.subTest(change=change), mock.patch.object(github, "api", side_effect=altered), \
                    self.assertRaises(POOL.PoolError):
                POOL.switch_route(github, activate=True)
            self.assertEqual(github.writes, [])

    def test_malformed_main_or_incomplete_smoke_jobs_never_change_routing(self):
        github = FakeGitHub()
        api = github.api
        for target, value in (("/git/ref/heads/main", {"object": None}),
                              ("/runs/10/jobs", {"total_count": 2, "jobs": [None, None]}),
                              ("/runs/10/jobs", api("/runs/10/jobs") | {"total_count": 3})):
            with self.subTest(target=target), mock.patch.object(
                    github, "api", side_effect=lambda path: value if target in path else api(path)), \
                    self.assertRaises(POOL.PoolError):
                POOL.switch_route(github, activate=True)
            self.assertEqual(github.writes, [])

    def test_guest_suite_failure_stops_before_any_later_command(self):
        with mock.patch.object(POOL.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["python3"])), \
                self.assertRaises(subprocess.CalledProcessError):
            POOL.check_suite("plan")

    def test_deactivation_returns_to_hosted_even_if_pool_is_unavailable(self):
        github = FakeGitHub([], route=POOL.POOL_LABEL)
        self.assertEqual(POOL.switch_route(github, activate=False)["route"], POOL.HOSTED)
        self.assertEqual(github.writes, [(POOL.POOL_LABEL, POOL.HOSTED)])

    def test_readback_failure_rolls_back_only_our_value(self):
        github = FakeGitHub()
        real_route = github.route
        # Before mutation; transient failure; retry sees our written value.
        github.route = mock.Mock(side_effect=[None, POOL.PoolError("temporary"), POOL.POOL_LABEL])
        with self.assertRaises(POOL.PoolError):
            POOL.switch_route(github, activate=True)
        self.assertEqual(github.writes, [(None, POOL.POOL_LABEL), (POOL.POOL_LABEL, None)])
        self.assertIsNone(real_route())
        github = FakeGitHub()
        github.route = mock.Mock(side_effect=[None, "operator-change", "operator-change"])
        with self.assertRaises(POOL.PoolError):
            POOL.switch_route(github, activate=True)
        self.assertEqual(github.writes, [(None, POOL.POOL_LABEL)])

    def test_paginated_collection_requires_every_record(self):
        github = POOL.GitHub(POOL.REPOSITORY)
        with mock.patch.object(github, "api", return_value=[
            {"total_count": 2, "runners": [guest(1)]}, {"total_count": 2, "runners": [guest(2)]}
        ]):
            self.assertEqual(len(github.collection("runners")), 2)
        for pages in ([], [{"total_count": 2, "runners": [guest(1)]}],
                      [{"total_count": 0, "runners": [None]}]):
            with self.subTest(pages=pages), mock.patch.object(github, "api", return_value=pages), \
                    self.assertRaises(POOL.PoolError):
                github.collection("runners")

    def test_transport_uses_argv_stdin_and_does_not_log_response_secrets(self):
        github = POOL.GitHub(POOL.REPOSITORY)
        with mock.patch.object(POOL.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            github.set_route(None, POOL.POOL_LABEL)
        argv = run.call_args.args[0]
        self.assertEqual(argv[:4], ["gh", "api", "--method", "POST"])
        self.assertEqual(argv[-2:], ["--input", "-"])
        self.assertEqual(json.loads(run.call_args.kwargs["input"])["value"], POOL.POOL_LABEL)
        with mock.patch.object(POOL.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "secret", "secret")), \
                self.assertRaises(POOL.PoolError) as error:
            github.collection("runners")
        self.assertNotIn("secret", str(error.exception))


if __name__ == "__main__":
    unittest.main()
