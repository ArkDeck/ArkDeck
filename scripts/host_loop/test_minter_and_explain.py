#!/usr/bin/env python3
"""Contracts for the r3 D2 prerequisite: minter, --explain, and two fail-opens.

Four deliverables, four contracts:

  1. mint_installation_token.sh — the root-owned shell minter. Its full minting
     path needs root and a real App key, so CI exercises the argument contract,
     the non-root refusal, and a STATIC contract over the source text. The live
     path is exercised once, by the maintainer, inside the D2 window, and the
     receipt is its evidence. That split is stated here rather than papered over.
  2. --explain — the per-gate dry run the r3 readiness requires a receipt to
     carry. Before it existed the readiness demanded an observation nothing in
     the repository could produce.
  3. done_task_ids over archived changes — archiving a change used to retract
     every task in it.
  4. the "no --cursor-issue means no Issue write" guarantee, including the
     environment variable that silently defeats it.
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

MINTER = HOST_LOOP_DIR / "mint_installation_token.sh"


def run_minter(*args, env=None):
    return subprocess.run(["/bin/sh", str(MINTER), *args],
                          capture_output=True, text=True, timeout=30,
                          env={**os.environ, **(env or {})})


class MinterArgumentContract(unittest.TestCase):
    """Every required argument is required, and digits are checked as digits."""

    def test_the_script_exists_and_is_shell(self):
        self.assertTrue(MINTER.is_file())
        self.assertTrue(MINTER.read_text().startswith("#!/bin/sh"))

    def test_no_argument_at_all_is_a_usage_error(self):
        done = run_minter()
        self.assertEqual(done.returncode, 1)
        self.assertIn("required", done.stderr)

    def test_each_required_flag_is_enforced(self):
        full = ["--app-id", "1", "--installation", "2", "--pem", "/nonexistent",
                "--out", "/tmp/x", "--owner", "root"]
        for drop in ("--app-id", "--installation", "--pem", "--out", "--owner"):
            with self.subTest(missing=drop):
                index = full.index(drop)
                trimmed = full[:index] + full[index + 2:]
                done = run_minter(*trimmed)
                self.assertEqual(done.returncode, 1, done.stderr)
                self.assertIn(drop, done.stderr)

    def test_non_numeric_ids_are_refused(self):
        for flag, bad in (("--app-id", "abc"), ("--installation", "1x"),
                          ("--margin", "-5"), ("--margin", "x")):
            with self.subTest(flag=flag, value=bad):
                args = ["--app-id", "1", "--installation", "2",
                        "--pem", "/nonexistent", "--out", "/tmp/x",
                        "--owner", "root"]
                if flag in args:
                    args[args.index(flag) + 1] = bad
                else:
                    args += [flag, bad]
                done = run_minter(*args)
                self.assertEqual(done.returncode, 1, done.stderr)

    def test_an_unknown_flag_is_refused_rather_than_ignored(self):
        done = run_minter("--app-id", "1", "--installation", "2",
                          "--pem", "/nonexistent", "--out", "/tmp/x",
                          "--owner", "root", "--danger")
        self.assertEqual(done.returncode, 1)
        self.assertIn("unknown argument", done.stderr)

    @unittest.skipIf(os.geteuid() == 0, "this assertion is about the non-root path")
    def test_running_as_non_root_is_refused(self):
        """The PEM is root-only; a non-root run must stop before touching it."""
        done = run_minter("--app-id", "1", "--installation", "2",
                          "--pem", "/nonexistent", "--out", "/tmp/x",
                          "--owner", "root")
        self.assertEqual(done.returncode, 1)
        self.assertIn("root", done.stderr)

    def test_nothing_is_written_by_a_refused_invocation(self):
        with tempfile.TemporaryDirectory() as raw:
            out = Path(raw, "token")
            out.write_text("PRE-EXISTING")
            run_minter("--app-id", "1", "--installation", "2",
                       "--pem", "/nonexistent", "--out", str(out),
                       "--owner", "root")
            self.assertEqual(out.read_text(), "PRE-EXISTING",
                             "a refused run must never touch the existing token")
            self.assertFalse(Path(str(out) + ".meta").exists())
            leftovers = [p.name for p in Path(raw).iterdir()
                         if p.name.startswith(".mint.")]
            self.assertEqual(leftovers, [], f"temp files left behind: {leftovers}")


class MinterSourceContract(unittest.TestCase):
    """Static properties the r3 readiness pins as binary.

    A source-text assertion is a weak form of test and this module has been
    burned by one before — a grep whose window included the comment that
    described the behaviour, so deleting the behaviour left it green. These
    assertions are therefore written against the EXECUTABLE text with comments
    stripped, and each one names a property that cannot be satisfied by prose.
    """

    @classmethod
    def setUpClass(cls):
        cls.raw = MINTER.read_text()
        cls.code = "\n".join(
            line for line in cls.raw.splitlines()
            if not line.lstrip().startswith("#") or line.startswith("#!")
        )

    def test_the_jwt_is_passed_via_config_not_via_argv(self):
        self.assertIn("curl --config -", self.code)
        self.assertNotIn('-H "Authorization', self.code)
        self.assertNotIn("-H 'Authorization", self.code)

    def test_the_curl_config_is_never_written_to_disk(self):
        """`--config -` reads stdin; a config FILE would be a second exposure."""
        self.assertNotIn("--config /", self.code)
        self.assertNotIn("--config $", self.code)

    def test_umask_is_set_before_any_file_is_created(self):
        lines = [l for l in self.code.splitlines() if l.strip()]
        umask_at = next(i for i, l in enumerate(lines) if l.startswith("umask "))
        first_mktemp = next((i for i, l in enumerate(lines) if "mktemp" in l), 10**6)
        self.assertLess(umask_at, first_mktemp)
        self.assertIn("umask 077", self.code)

    def test_permissions_are_set_before_the_rename_not_after(self):
        """Otherwise the token is briefly readable under its final name."""
        code = self.code
        chmod_at = code.index("chmod 600")
        chown_at = code.index('chown "$OWNER"')
        mv_at = code.index('mv -f "$staged" "$OUT"')
        self.assertLess(chmod_at, mv_at)
        self.assertLess(chown_at, mv_at)

    def test_the_install_is_atomic(self):
        self.assertIn("mv -f", self.code)
        self.assertNotIn("> \"$OUT\"", self.code,
                         "the token must never be written to $OUT directly")

    def test_the_directory_mode_and_owner_are_checked_not_assumed(self):
        self.assertIn('stat -f \'%Lp\'', self.code)
        self.assertIn('stat -f \'%Su\'', self.code)
        self.assertIn('= "700"', self.code)

    def test_the_token_value_is_used_in_exactly_three_known_places(self):
        """An exact whitelist, not a heuristic.

        Two earlier versions of this assertion were line-level heuristics and
        both were wrong: the first flagged the redirected install write, the
        second flagged the digest whose output is captured by `$(...)`. A
        heuristic that has to understand shell redirection will keep being wrong,
        so the legitimate uses are enumerated instead. A fourth use fails this
        test, which is the point.
        """
        import re

        uses = [line.strip() for line in self.code.splitlines()
                if re.search(r"\$token(?![A-Za-z0-9_])", line)]
        self.assertEqual(len(uses), 3, f"unexpected use of $token: {uses}")
        emptiness_guard, install, digest = uses
        # 1. presence check — produces no output of its own
        self.assertTrue(emptiness_guard.startswith('[ -n "$token" ]'), emptiness_guard)
        # 2. the install write — redirected into the staged file, never a terminal
        self.assertRegex(install, r'^printf .* "\$token" > "\$staged"$')
        # 3. the digest — output captured by command substitution, and it is the
        #    digest, not the token, that reaches the sidecar
        self.assertRegex(digest, r"^token_digest=\$\(printf .*openssl dgst -sha256")

    def test_no_line_sends_the_token_to_an_unredirected_stream(self):
        """The property the whitelist above exists to guarantee."""
        import re

        for line in self.code.splitlines():
            stripped = line.strip()
            if not re.search(r"\$token(?![A-Za-z0-9_])", stripped):
                continue
            consumed = (">" in stripped or "$(" in stripped
                        or stripped.startswith("[ -n"))
            self.assertTrue(consumed,
                            f"token output is neither redirected nor captured: "
                            f"{stripped!r}")

    def test_the_sidecar_records_a_digest_rather_than_the_token(self):
        self.assertIn("token_sha256=", self.code)
        self.assertIn("openssl dgst -sha256 -r", self.code)

    def test_no_python_and_no_repository_import(self):
        """Root must not execute a user-writable interpreter or user-writable code."""
        for forbidden in ("python", "host_loop", "import "):
            self.assertNotIn(forbidden, self.code,
                             f"root execution surface must not include {forbidden!r}")

    def test_every_external_command_is_a_root_owned_absolute_tool(self):
        """PATH is pinned to system directories, so no user dir can shadow a tool."""
        self.assertIn("PATH=/usr/bin:/bin:/usr/sbin:/sbin", self.code)

    def test_a_failed_mint_exits_two_and_says_the_token_is_untouched(self):
        self.assertIn("existing token untouched", self.code)
        self.assertIn("2", self.code)

    def test_freshness_is_decided_per_run_not_by_the_schedule(self):
        """StartInterval firings are skipped across sleep, never queued."""
        self.assertIn("expires_at_epoch", self.code)
        self.assertIn("MARGIN", self.code)

    def test_a_parsed_expiry_is_capped_by_a_conservative_horizon(self):
        self.assertIn("horizon=$((now + 3600))", self.code)


class ExplainIsANetworkFreeDryRun(unittest.TestCase):
    def _run(self, *extra):
        return subprocess.run(
            [sys.executable, "-m", "host_loop", "--explain",
             "--repo-dir", str(REPO_ROOT), *extra],
            capture_output=True, text=True, timeout=120,
            cwd=str(REPO_ROOT),
            env={**os.environ, "PYTHONPATH": str(SCRIPTS_DIR),
                 "ARKDECK_HOST_LOOP_TOKEN": "", "ARKDECK_HOST_LOOP_TOKEN_FILE": ""},
        )

    def test_it_runs_with_no_credential_at_all(self):
        """A dry run must not need the token the window has not staged yet."""
        done = self._run("--change", "CHG-2026-030-host-loop-runtime")
        self.assertIn(done.returncode, (0, 10), done.stderr)
        self.assertNotIn("no credential", done.stderr)

    def test_it_names_every_candidate_and_a_reason_for_each_rejection(self):
        done = self._run("--change", "CHG-2026-030-host-loop-runtime")
        self.assertIn("TASK-HLR-003", done.stdout)
        self.assertIn("never-claim", done.stdout,
                      "HLR-003 is excluded by the self-claim rule; say so")
        self.assertIn("claimable=", done.stdout)

    def test_it_reports_the_archived_dependency_set_size(self):
        done = self._run("--change", "CHG-2026-030-host-loop-runtime")
        self.assertIn("active + archived changes", done.stdout)

    def test_once_and_explain_are_mutually_exclusive(self):
        done = subprocess.run(
            [sys.executable, "-m", "host_loop", "--once", "--explain",
             "--repo-dir", str(REPO_ROOT)],
            capture_output=True, text=True, timeout=60, cwd=str(REPO_ROOT),
            env={**os.environ, "PYTHONPATH": str(SCRIPTS_DIR)})
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("not allowed with", done.stderr + done.stdout)

    def test_one_of_the_two_modes_is_required(self):
        done = subprocess.run(
            [sys.executable, "-m", "host_loop", "--repo-dir", str(REPO_ROOT)],
            capture_output=True, text=True, timeout=60, cwd=str(REPO_ROOT),
            env={**os.environ, "PYTHONPATH": str(SCRIPTS_DIR)})
        self.assertNotEqual(done.returncode, 0)


class SelectAndExplainShareOneImplementation(unittest.TestCase):
    """The reporting side must not drift from the deciding side.

    This project has already shipped one contract with two implementations that
    diverged (the required/non-required check verdict), so the property is
    asserted rather than assumed.
    """

    def _rig(self, candidates, *, done=frozenset(), approved=True):
        from host_loop.test_fault_matrix import FakeApi, FakeRemote, api_port, manager
        from host_loop.worker import Worker

        remote = FakeRemote()
        mgr, _clock = manager(remote)
        return Worker(
            api_port(FakeApi()), mgr,
            change_approved=lambda c: approved,
            done_tasks=lambda: done,
            read_envelope=lambda body: None,
            read_lease_record=remote.read_record,
            prepare_branch=lambda c, b: "a" * 40,
            render_body=lambda c, b, h: "ENVELOPE",
            now=lambda: 1000)

    @staticmethod
    def _candidate(**over):
        from host_loop.worker import TaskCandidate

        base = dict(task_id="TASK-DEMO-001", status="ready", decision_grade="D0",
                    hardware_required=False, dependencies=(),
                    allowed_paths=("scripts/**",), base_pin=None)
        base.update(over)
        return TaskCandidate(**base)

    def test_the_task_select_picks_is_exactly_the_one_explain_calls_clean(self):
        main = "f" * 40
        shapes = [
            [self._candidate()],
            [self._candidate(status="blocked"), self._candidate(task_id="TASK-B-002")],
            [self._candidate(decision_grade="D1")],
            [self._candidate(decision_grade="unknown")],
            [self._candidate(hardware_required=True)],
            [self._candidate(dependencies=("TASK-X-001",))],
            [self._candidate(allowed_paths=())],
            [self._candidate(base_pin="0" * 40)],
            [self._candidate(task_id="TASK-HLR-003")],
            [],
        ]
        for index, candidates in enumerate(shapes):
            with self.subTest(shape=index):
                worker = self._rig(candidates)
                picked, _outcome, _detail = worker.select(
                    candidates, "CHG-X", main)
                _approved, rows = worker.explain(candidates, "CHG-X", main)
                clean = [task for task, reasons in rows if not reasons]
                if picked is None:
                    self.assertEqual(clean, [],
                                     "explain must not call a task clean that "
                                     "select refused to pick")
                else:
                    self.assertIn(picked.task_id, clean)
                    self.assertEqual(clean[0], picked.task_id)

    def test_every_rejection_carries_at_least_one_stated_reason(self):
        main = "f" * 40
        candidates = [self._candidate(status="blocked", hardware_required=True,
                                      decision_grade="unknown")]
        worker = self._rig(candidates)
        _approved, rows = worker.explain(candidates, "CHG-X", main)
        self.assertEqual(len(rows), 1)
        self.assertGreaterEqual(len(rows[0][1]), 3,
                                "all gates are evaluated, not short-circuited")

    def test_a_never_claim_task_still_reports_its_other_reasons(self):
        """No gate short-circuits, including the first one.

        A mutation that returned early on never-claim survived the rest of this
        file: select() behaves identically either way, so only the explain
        output loses information — and losing it is exactly what the receipt
        would then be missing. TASK-HLR-003 is the live instance: it is
        never-claim AND carries no Decision-Grade, and the operator needs both.
        """
        candidates = [self._candidate(task_id="TASK-HLR-003",
                                      decision_grade="unknown")]
        worker = self._rig(candidates)
        _approved, rows = worker.explain(candidates, "CHG-X", "f" * 40)
        reasons = rows[0][1]
        self.assertGreaterEqual(len(reasons), 2, reasons)
        joined = " | ".join(reasons)
        self.assertIn("never-claim", joined)
        self.assertIn("decision grade", joined,
                      "the grade verdict must survive the never-claim verdict")

    def test_every_gate_is_reported_for_a_maximally_blocked_candidate(self):
        """All seven gates at once, so the count is the contract."""
        candidates = [self._candidate(
            task_id="TASK-HLR-003", status="blocked", decision_grade="unknown",
            hardware_required=True, dependencies=("TASK-MISSING-001",),
            allowed_paths=(), base_pin="0" * 40)]
        worker = self._rig(candidates)
        _approved, rows = worker.explain(candidates, "CHG-X", "f" * 40)
        self.assertEqual(len(rows[0][1]), 7,
                         f"expected every gate to speak: {rows[0][1]}")

    def test_explain_reports_change_approval_separately(self):
        worker = self._rig([self._candidate()], approved=False)
        approved, rows = worker.explain([self._candidate()], "CHG-X", "f" * 40)
        self.assertFalse(approved)
        self.assertEqual(rows[0][1], (),
                         "an unapproved change does not make the task itself dirty")


class ArchivedChangesStillSatisfyDependencies(unittest.TestCase):
    """Archiving a change is a filing fact, not a retraction of its tasks."""

    def _write(self, root, relative, body):
        target = root / "openspec" / "changes" / relative
        target.mkdir(parents=True, exist_ok=True)
        (target / "tasks.md").write_text(body, encoding="utf-8")

    SECTION = """## {task} — demo

- Status:{status}
- Hardware required:no。
- Decision-Grade:D0。
- Allowed paths:`x/**`
- Depends on:none
"""

    def test_a_done_task_in_an_archived_change_counts_as_done(self):
        from host_loop.__main__ import done_task_ids

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self._write(root, "chg-active",
                        self.SECTION.format(task="TASK-ACT-001", status="ready"))
            self._write(root, "archive/2026-01-01-chg-old",
                        self.SECTION.format(task="TASK-OLD-001", status="done"))
            done = done_task_ids(root)
        self.assertIn("TASK-OLD-001", done,
                      "an archived done task must not silently become undone")
        self.assertNotIn("TASK-ACT-001", done)

    def test_the_real_repository_now_closes_the_rpt_dependencies(self):
        """The measured instance: both are done and both are archived."""
        from host_loop.__main__ import done_task_ids

        done = done_task_ids(REPO_ROOT)
        for task in ("TASK-RPT-001", "TASK-RPT-002"):
            with self.subTest(task=task):
                self.assertIn(task, done)

    def test_an_active_change_still_wins_when_both_exist(self):
        """Same id in both places: the union is what the gate consults."""
        from host_loop.__main__ import done_task_ids

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self._write(root, "chg-active",
                        self.SECTION.format(task="TASK-DUP-001", status="done"))
            self._write(root, "archive/2026-01-01-chg-old",
                        self.SECTION.format(task="TASK-DUP-001", status="done"))
            self.assertIn("TASK-DUP-001", done_task_ids(root))


class NoCursorIssueMeansNoIssueWrite(unittest.TestCase):
    """The guarantee Phase 1 and Phase 3 of the D2 window rest on.

    It was carried by a single `if self._cursor_issue is not None` with no test,
    and it is defeasible from the environment: --cursor-issue's default comes
    from ARKDECK_HOST_LOOP_CURSOR_ISSUE, so omitting the flag is NOT the same as
    having no cursor.
    """

    def test_the_flag_default_is_read_from_the_environment(self):
        from host_loop.__main__ import parse_args

        args = parse_args(["--once", "--repo-dir", "."])
        self.assertIsNone(args.cursor_issue)
        os.environ["ARKDECK_HOST_LOOP_CURSOR_ISSUE"] = "4242"
        try:
            leaked = parse_args(["--once", "--repo-dir", "."])
        finally:
            del os.environ["ARKDECK_HOST_LOOP_CURSOR_ISSUE"]
        self.assertEqual(
            leaked.cursor_issue, 4242,
            "omitting the flag does not guarantee no cursor; the window must "
            "clear this variable explicitly")

    def test_a_worker_without_a_cursor_issue_writes_no_issue(self):
        from host_loop.test_fault_matrix import (FakeApi, FakeRemote, HEAD, TASK,
                                                 api_port, envelope_reader,
                                                 manager, pull)
        from host_loop.test_worker_cursor import MAIN, candidate, state, truth
        from host_loop.worker import Worker

        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)], check_runs=[
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "success"}])
        mgr, _clock = manager(remote, run="host-loop/worker")
        worker = Worker(
            api_port(fake), mgr, change_approved=lambda c: True,
            done_tasks=lambda: frozenset(),
            read_envelope=envelope_reader(base=MAIN),
            read_lease_record=remote.read_record,
            prepare_branch=lambda c, b: HEAD,
            render_body=lambda c, b, h: "ENVELOPE",
            now=lambda: 1000,
            cursor_issue=None, cursor_body=None)
        worker.run_once([candidate()], "CHG-X", MAIN, state(),
                        truth(open_pr_numbers=frozenset({21})))
        issue_writes = [c for c in fake.calls
                        if c[0] in ("PATCH", "POST") and "/issues" in c[1]]
        self.assertEqual(issue_writes, [],
                         f"no cursor issue means no Issue write; got {issue_writes}")

    def test_the_same_round_does_write_when_a_cursor_issue_is_given(self):
        """So the negative above cannot pass because the round did nothing."""
        from host_loop.test_fault_matrix import (FakeApi, FakeRemote, HEAD,
                                                 api_port, envelope_reader,
                                                 manager, pull)
        from host_loop.test_worker_cursor import MAIN, candidate, state, truth
        from host_loop.worker import Worker

        remote = FakeRemote()
        fake = FakeApi(pulls=[pull(21)], check_runs=[
            {"name": "guard", "status": "completed", "conclusion": "success"},
            {"name": "allowed-paths", "status": "completed", "conclusion": "success"}])
        mgr, _clock = manager(remote, run="host-loop/worker")
        worker = Worker(
            api_port(fake), mgr, change_approved=lambda c: True,
            done_tasks=lambda: frozenset(),
            read_envelope=envelope_reader(base=MAIN),
            read_lease_record=remote.read_record,
            prepare_branch=lambda c, b: HEAD,
            render_body=lambda c, b, h: "ENVELOPE",
            now=lambda: 1000,
            cursor_issue=7, cursor_body=state().render())
        worker.run_once([candidate()], "CHG-X", MAIN, state(),
                        truth(open_pr_numbers=frozenset({21})))
        issue_writes = [c for c in fake.calls
                        if c[0] == "PATCH" and "/issues/" in c[1]]
        self.assertTrue(issue_writes,
                        "the happy path must write, or the negative proves nothing")


if __name__ == "__main__":
    unittest.main(verbosity=2)
