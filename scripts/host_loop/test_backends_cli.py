#!/usr/bin/env python3
"""Production backends and the `--once` entry point (TASK-HLR-003 r2).

r2 authorises this surface under three hard constraints, and each has tests
here: the refusal/ambiguity split must survive the real git runner, no typed
route may be added and the negative proof must stay at zero, and no credential
may reach a log, a receipt or a child process argv.
"""

from __future__ import annotations

import os
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

from host_loop import backends as backends_mod  # noqa: E402
from host_loop import transport as transport_mod  # noqa: E402
from host_loop.backends import (  # noqa: E402
    BackendError,
    SubprocessGitRunner,
    UrllibSender,
    assert_no_secret,
    body_renderer,
    branch_preparer,
    commit_writer,
    read_lease_record,
    read_token,
)
from host_loop.transport import ApiPort, PolicyRefused, RefPort, Refused, TransportError  # noqa: E402
from host_loop.worker import TaskCandidate  # noqa: E402


def _executable_source(path: Path) -> str:
    """Source with docstrings and comments removed.

    Used by the "must not do X" scans so documentation that names a forbidden
    action in order to disclaim it does not trip the test.
    """
    import ast
    import io
    import tokenize

    tree = ast.parse(path.read_text())
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef,
                            ast.ClassDef)):
            doc = ast.get_docstring(node, clean=False)
            if doc is not None and node.body:
                first = node.body[0]
                docstrings.add((first.lineno, getattr(first, "end_lineno", first.lineno)))

    kept = []
    with path.open("rb") as handle:
        for token in tokenize.tokenize(handle.readline):
            if token.type == tokenize.COMMENT:
                continue
            if token.type == tokenize.STRING and any(
                start <= token.start[0] and token.end[0] <= end
                for start, end in docstrings
            ):
                continue
            kept.append(token.string)
    return " ".join(kept)

def _repo() -> tempfile.TemporaryDirectory:
    """A throwaway git repo with one commit."""
    tmp = tempfile.TemporaryDirectory(prefix="hostloop-be-")
    run = lambda *a: subprocess.run(a, cwd=tmp.name, capture_output=True, text=True,
                                    check=True)
    run("git", "init", "-q", "-b", "main")
    run("git", "config", "user.name", "t")
    run("git", "config", "user.email", "t@example.invalid")
    Path(tmp.name, "seed.txt").write_text("seed\n")
    run("git", "add", "-A")
    run("git", "commit", "-q", "-m", "seed")
    return tmp


class GitRunnerContract(unittest.TestCase):
    def test_refuses_a_non_git_argv(self):
        with _repo() as path:
            with self.assertRaises(BackendError):
                SubprocessGitRunner(repo_dir=path)(["rm", "-rf", "/"])

    def test_returns_stderr_verbatim_without_classifying(self):
        """Classification belongs to the transport layer, not the runner.

        Collapsing a policy decline into a fence loss here is exactly the
        misreport the transport docstring forbids, so the runner must stay dumb.
        """
        with _repo() as path:
            code, _out, err = SubprocessGitRunner(repo_dir=path)(
                ["git", "rev-parse", "definitely-not-a-ref"])
            self.assertNotEqual(code, 0)
            self.assertTrue(err)
            source = Path(backends_mod.__file__).read_text()
            for token in ("stale info", "non-fast-forward", "Refused", "PolicyRefused"):
                self.assertNotIn(f'"{token}"', source,
                                 "the runner must not classify stderr itself")

    def test_disables_interactive_prompting(self):
        source = Path(backends_mod.__file__).read_text()
        self.assertIn("GIT_TERMINAL_PROMPT", source,
                     "a hung credential prompt would masquerade as a timeout")

    def test_a_timeout_is_reported_as_ambiguous_not_refused(self):
        with _repo() as path:
            runner = SubprocessGitRunner(repo_dir=path, timeout=0)
            code, _out, err = runner(["git", "log"])
            self.assertNotEqual(code, 0)
            self.assertIn("timeout", err)
            for token in ("stale info", "non-fast-forward", "declined"):
                self.assertNotIn(token, err,
                                 "a timeout must not carry refusal wording")


class RefusalSplitSurvivesTheRealRunner(unittest.TestCase):
    """r2: server refusal and ambiguity must still map to distinct types."""

    def _refs(self, stderr: str, code: int = 1) -> RefPort:
        def runner(argv):
            if list(argv)[:2] == ["git", "ls-remote"]:
                return 0, "1" * 40 + "\trefs/heads/agent/host-loop/leases/T\n", ""
            return code, "", stderr
        return RefPort(remote="origin", _run=runner)

    def _cas(self, refs):
        return refs.compare_and_swap(
            "refs/heads/agent/host-loop/leases/T", "1" * 40, "2" * 40)

    def test_stale_info_is_a_fence_loss(self):
        with self.assertRaises(Refused):
            self._cas(self._refs("! [rejected] a -> b (stale info)\n"))

    def test_pre_receive_decline_is_policy_not_fence_loss(self):
        with self.assertRaises(PolicyRefused):
            self._cas(self._refs(
                "! [remote rejected] a -> b (pre-receive hook declined)\n"))

    def test_a_runner_timeout_is_ambiguous(self):
        with self.assertRaises(TransportError) as caught:
            self._cas(self._refs("timeout after 120s running git push"))
        self.assertNotIsInstance(caught.exception, Refused)


class NoNewRouteOrEscapeHatch(unittest.TestCase):
    """r2 forbids adding a typed route or widening a field allowlist."""

    # The exact set, not just its cardinality. Pinning only len() meant swapping
    # one route for another passed silently, which is what the check-runs
    # pagination change did — a substitution no test could see.
    # TASK-TAS-001 removed the two bare-list entries: measured zero
    # construction sites — every pulls/issues GET attaches a query or a
    # /{number} segment, so the bare shapes served nothing while standing as
    # permanently authorized surface. They are now explicit refusals (below),
    # not silently legal.
    EXPECTED_ROUTES = {
        ("GET", "/repos/{owner}/{repo}/pulls?head&state&per_page"),
        ("POST", "/repos/{owner}/{repo}/pulls"),
        ("GET", "/repos/{owner}/{repo}/pulls/{number}"),
        ("PATCH", "/repos/{owner}/{repo}/pulls/{number}"),
        ("POST", "/repos/{owner}/{repo}/issues"),
        ("GET", "/repos/{owner}/{repo}/issues/{number}"),
        ("PATCH", "/repos/{owner}/{repo}/issues/{number}"),
        ("GET", "/repos/{owner}/{repo}/commits/{oid}/check-runs?per_page&page"),
    }

    def test_allowlist_is_unchanged_in_size(self):
        self.assertEqual(len(transport_mod.ALLOWED_ROUTES), 8)

    def test_bare_pull_list_is_refused(self):
        """TAS-ROUTE-001: the dead capability stays dead. A future mis-wired
        bare list call must be a RouteViolation, never silently legal."""
        with self.assertRaises(transport_mod.RouteViolation):
            transport_mod.assert_route_allowed("GET", "/repos/o/r/pulls")

    def test_bare_issue_list_is_refused(self):
        with self.assertRaises(transport_mod.RouteViolation):
            transport_mod.assert_route_allowed("GET", "/repos/o/r/issues")

    def test_allowlist_contents_are_pinned_exactly(self):
        actual = set(transport_mod.ALLOWED_ROUTES)
        self.assertEqual(
            actual, self.EXPECTED_ROUTES,
            f"added={sorted(actual - self.EXPECTED_ROUTES)} "
            f"removed={sorted(self.EXPECTED_ROUTES - actual)}")

    def test_no_route_reaches_a_forbidden_capability(self):
        for method, template in transport_mod.ALLOWED_ROUTES:
            lowered = f"{method} {template}".lower()
            for capability in transport_mod.FORBIDDEN_CAPABILITIES:
                with self.subTest(route=template, capability=capability):
                    self.assertNotIn(capability, lowered)

    def test_field_allowlists_are_unchanged(self):
        self.assertEqual(sorted(transport_mod.ALLOWED_PR_PATCH_FIELDS),
                         ["body", "title"])
        self.assertEqual(sorted(transport_mod.ALLOWED_ISSUE_PATCH_FIELDS),
                         ["body", "title"])

    def test_backends_construct_no_route_of_their_own(self):
        """The sender must hold no route knowledge; ApiPort stays the only gate."""
        source = Path(backends_mod.__file__).read_text()
        for shape in ("/reviews", "/merge", "/update-branch", "/protection",
                      "/rulesets", "graphql"):
            self.assertNotIn(shape, source)

    def test_entrypoint_constructs_no_route_of_its_own(self):
        source = (HOST_LOOP_DIR / "__main__.py").read_text()
        for shape in ("/reviews", "/merge", "/protection", "/rulesets", "graphql"):
            self.assertNotIn(shape, source)

    def test_negative_proof_stays_zero_through_the_real_sender_shape(self):
        calls = []

        def sender(method, path, body):
            calls.append((method, path))
            return 200, {"number": 21, "state": "open"}

        port = ApiPort(owner="ArkDeck", repo="ArkDeck", _send=sender)
        port.get_pull(21)
        port.bound_to_pull(21).update_pull(21, body="x")
        self.assertEqual(transport_mod.forbidden_capability_count(port), 0)
        self.assertTrue(calls)


class CredentialContainment(unittest.TestCase):
    def test_token_from_a_file_is_preferred(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "tok")
            path.write_text("ghs_" + "a" * 30 + "\n")
            value = read_token({"ARKDECK_HOST_LOOP_TOKEN_FILE": str(path),
                                "ARKDECK_HOST_LOOP_TOKEN": "env-value"})
            self.assertTrue(value.startswith("ghs_"))

    def test_missing_credential_is_an_error_not_a_quiet_no_dispatch(self):
        with self.assertRaises(BackendError):
            read_token({})

    def test_an_empty_token_file_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "tok")
            path.write_text("")
            with self.assertRaises(BackendError):
                read_token({"ARKDECK_HOST_LOOP_TOKEN_FILE": str(path)})

    def test_secret_shapes_are_refused_before_emission(self):
        for probe in ("ghs_" + "a" * 30, "github_pat_" + "b" * 25,
                      "-----BEGIN RSA PRIVATE KEY-----",
                      "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiIxIn0."):
            with self.subTest(probe=probe[:24]):
                with self.assertRaises(BackendError):
                    assert_no_secret(probe, "test string")
        self.assertEqual(assert_no_secret("harmless", "t"), "harmless")


    def test_the_python_minter_is_gone_and_stays_gone(self):
        """Retired by TASK-DEC-005; the live minter is the root-owned shell.

        Its _openssl_sign required a NOPASSWD sudoers rule for openssl, which
        is root escalation for the loop account and precisely the design the
        shell minter replaced. Asserted as absence so nothing reintroduces it.
        """
        source = Path(backends_mod.__file__).read_text()
        for gone in ("def mint_installation_token", "def _openssl_sign",
                     '"sudo", "openssl"', "/access_tokens"):
            with self.subTest(gone=gone):
                self.assertNotIn(gone, source)
        self.assertFalse(hasattr(backends_mod, "mint_installation_token"))
        self.assertFalse(hasattr(backends_mod, "_openssl_sign"))


class GitObjectWriters(unittest.TestCase):
    def test_commit_writer_creates_a_message_only_commit(self):
        with _repo() as path:
            base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=path,
                                  capture_output=True, text=True).stdout.strip()
            write = commit_writer(path)
            oid = write("lease record text", base)
            self.assertRegex(oid, r"^[0-9a-f]{40}$")
            body = subprocess.run(["git", "log", "-1", "--format=%B", oid], cwd=path,
                                  capture_output=True, text=True).stdout.strip()
            self.assertEqual(body, "lease record text")
            changed = subprocess.run(["git", "diff", "--name-only", base, oid],
                                     cwd=path, capture_output=True, text=True).stdout
            self.assertEqual(changed.strip(), "",
                             "a lease commit must carry no file content")

    def test_commit_writer_rejects_a_malformed_parent(self):
        with _repo() as path:
            with self.assertRaises(BackendError):
                commit_writer(path)("text", "deadbeef")

    def test_commit_writer_rejects_an_uppercase_parent_oid(self):
        """git itself accepts uppercase hex, so the validation is load-bearing.

        Without it an uppercase 40-hex parent would be written successfully and
        break the lowercase OID invariant every other module relies on — a
        truncated OID is caught by git anyway, but this one is not.
        """
        with _repo() as path:
            oid = subprocess.run(["git", "rev-parse", "HEAD"], cwd=path,
                                 capture_output=True, text=True).stdout.strip()
            # confirm the premise: git would have accepted it
            probe = subprocess.run(["git", "rev-parse", "--verify", oid.upper()],
                                   cwd=path, capture_output=True, text=True)
            self.assertEqual(probe.returncode, 0, "premise: git accepts uppercase")
            with self.assertRaisesRegex(BackendError, r"lowercase full 40-hex"):
                commit_writer(path)("text", oid.upper())

    def test_read_lease_record_round_trips(self):
        with _repo() as path:
            base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=path,
                                  capture_output=True, text=True).stdout.strip()
            oid = commit_writer(path)("the record", base)
            self.assertEqual(read_lease_record(path)(oid), "the record")

    def test_read_lease_record_rejects_a_malformed_oid(self):
        with _repo() as path:
            with self.assertRaises(BackendError):
                read_lease_record(path)("nope")

    def test_read_lease_record_reports_a_missing_object_rather_than_empty(self):
        with _repo() as path:
            with self.assertRaises(BackendError):
                read_lease_record(path)("0" * 40)


class BranchPreparation(unittest.TestCase):
    class FakeRefs:
        def __init__(self, existing=None):
            self.refs = dict(existing or {})
            self.created = []

        def read(self, ref):
            return self.refs.get(ref)

        def create(self, ref, oid):
            self.created.append((ref, oid))
            self.refs[ref] = oid

    def _candidate(self, task="TASK-DEMO-001"):
        return TaskCandidate(task_id=task, status="ready", decision_grade="D0",
                             hardware_required=False, dependencies=(),
                             allowed_paths=("scripts/host_loop/**",), base_pin=None)

    def test_an_existing_branch_is_adopted_not_recreated(self):
        ref = "refs/heads/agent/host-loop/tasks/TASK-DEMO-001"
        refs = self.FakeRefs({ref: "b" * 40})
        prepare = branch_preparer(refs, "/tmp", writer=lambda t, p: "c" * 40)
        self.assertEqual(prepare(self._candidate(), "a" * 40), "b" * 40)
        self.assertEqual(refs.created, [], "a resumed round must not fork a head")

    def test_a_new_branch_is_created_and_read_back(self):
        refs = self.FakeRefs()
        prepare = branch_preparer(refs, "/tmp", writer=lambda t, p: "c" * 40)
        head = prepare(self._candidate(), "a" * 40)
        self.assertEqual(head, "c" * 40)
        self.assertEqual(refs.created,
                         [("refs/heads/agent/host-loop/tasks/TASK-DEMO-001", "c" * 40)])

    def test_a_read_back_mismatch_is_an_error(self):
        class Liar(self.FakeRefs):
            def create(self, ref, oid):
                self.refs[ref] = "d" * 40  # something else landed
        prepare = branch_preparer(Liar(), "/tmp", writer=lambda t, p: "c" * 40)
        with self.assertRaises(BackendError):
            prepare(self._candidate(), "a" * 40)

    def test_a_malformed_base_is_refused(self):
        prepare = branch_preparer(self.FakeRefs(), "/tmp", writer=lambda t, p: "c" * 40)
        with self.assertRaises(BackendError):
            prepare(self._candidate(), "deadbeef")


class BodyRendering(unittest.TestCase):
    """Renders against a dynamically sampled ACTIVE change: envelope
    validation binds Change to active change directories by design, so a
    pinned sample breaks the day its change archives (TASK-NAV-002)."""

    @classmethod
    def setUpClass(cls):
        from host_loop.test_support import first_task_id, live_sample_change

        cls.sample_change = live_sample_change(REPO_ROOT)
        cls.sample_task = first_task_id(REPO_ROOT, cls.sample_change)

    def test_the_body_is_a_valid_envelope_for_a_real_task(self):
        from host_loop.pr_envelope import parse_and_validate

        render = body_renderer(str(REPO_ROOT), change_id=self.sample_change,
                              producer="host-loop/worker", run_id="r-1")
        candidate = TaskCandidate(task_id=self.sample_task, status="ready",
                                  decision_grade="D0", hardware_required=False,
                                  dependencies=(), allowed_paths=("scripts/host_loop/**",),
                                  base_pin=None)
        body = render(candidate, "a" * 40, "b" * 40)
        parsed = parse_and_validate(body, REPO_ROOT)
        self.assertEqual(parsed.envelope.task, self.sample_task)
        self.assertEqual(parsed.envelope.base_oid, "a" * 40)
        self.assertEqual(parsed.envelope.head_oid, "b" * 40)

    def test_the_body_carries_no_dispatch_marker_so_nesting_cannot_occur(self):
        from host_loop.worker import DISPATCH_MARKER

        render = body_renderer(str(REPO_ROOT), change_id=self.sample_change,
                              producer="p", run_id="r")
        candidate = TaskCandidate(task_id=self.sample_task, status="ready",
                                  decision_grade="D0", hardware_required=False,
                                  dependencies=(), allowed_paths=("x/**",),
                                  base_pin=None)
        self.assertNotIn(DISPATCH_MARKER, render(candidate, "a" * 40, "b" * 40))

    def test_the_body_states_green_is_not_merge_permission(self):
        render = body_renderer(str(REPO_ROOT), change_id=self.sample_change,
                              producer="p", run_id="r")
        candidate = TaskCandidate(task_id=self.sample_task, status="ready",
                                  decision_grade="D0", hardware_required=False,
                                  dependencies=(), allowed_paths=("x/**",),
                                  base_pin=None)
        self.assertIn("not merge permission", render(candidate, "a" * 40, "b" * 40))


class EntryPointContract(unittest.TestCase):
    def _run(self, *args, env=None):
        environ = dict(os.environ)
        environ.pop("ARKDECK_HOST_LOOP_TOKEN", None)
        environ.pop("ARKDECK_HOST_LOOP_TOKEN_FILE", None)
        environ["PYTHONPATH"] = str(SCRIPTS_DIR)
        environ.update(env or {})
        return subprocess.run([sys.executable, "-m", "host_loop", *args],
                              cwd=str(SCRIPTS_DIR), capture_output=True, text=True,
                              env=environ, timeout=120)

    def test_once_is_mandatory(self):
        self.assertNotEqual(self._run().returncode, 0)

    def test_exit_codes_are_distinct(self):
        from host_loop import __main__ as entry
        codes = {entry.EXIT_DISPATCHED, entry.EXIT_NO_DISPATCH,
                 entry.EXIT_RECONCILE, entry.EXIT_ERROR}
        self.assertEqual(len(codes), 4, "each outcome needs its own exit code")

    def test_a_missing_credential_exits_error_not_no_dispatch(self):
        from host_loop import __main__ as entry
        done = self._run("--once", "--repo-dir", str(REPO_ROOT))
        self.assertEqual(done.returncode, entry.EXIT_ERROR)
        self.assertIn("no credential", done.stderr)

    def test_a_non_checkout_repo_dir_exits_error(self):
        from host_loop import __main__ as entry
        with tempfile.TemporaryDirectory() as tmp:
            done = self._run("--once", "--repo-dir", tmp,
                             env={"ARKDECK_HOST_LOOP_TOKEN": "ghs_" + "z" * 30})
            self.assertEqual(done.returncode, entry.EXIT_ERROR)

    def test_no_credential_value_appears_in_output(self):
        secret = "ghs_" + "q" * 30
        done = self._run("--once", "--repo-dir", str(REPO_ROOT),
                         env={"ARKDECK_HOST_LOOP_TOKEN": secret})
        self.assertNotIn(secret, done.stdout + done.stderr)

    def test_the_entrypoint_creates_no_scheduler_artefact(self):
        """r2 keeps launchd account/plist/socket creation in the D2 phase.

        Scans executable code only. A raw text scan flagged the module docstring,
        which mentions these words precisely to say it does NOT do them — the
        test has to distinguish prose from behaviour or it just forbids honest
        documentation.
        """
        code = _executable_source(HOST_LOOP_DIR / "__main__.py")
        for shape in ("launchctl", "plist", "LaunchAgents", "LaunchDaemons",
                      "dscl", "kickstart"):
            with self.subTest(shape=shape):
                self.assertNotIn(shape, code)

    def test_the_entrypoint_spawns_no_process_of_its_own(self):
        """Process spawning belongs to the backends, behind the typed ports."""
        code = _executable_source(HOST_LOOP_DIR / "__main__.py")
        for shape in ("subprocess.", "os.system", "os.exec", "os.popen"):
            with self.subTest(shape=shape):
                self.assertNotIn(shape, code)

    def test_no_internal_loop(self):
        source = (HOST_LOOP_DIR / "__main__.py").read_text()
        self.assertNotIn("while True", source,
                         "a wedged round must not be able to hold the host")


class DiscoveryIsAReaderOnly(unittest.TestCase):
    """Discovery grants nothing; the worker's gates still decide claimability."""

    def test_it_parses_the_live_change(self):
        from host_loop.__main__ import discover_candidates
        from host_loop.test_support import first_task_id, live_sample_change

        sample = live_sample_change(REPO_ROOT)
        found = discover_candidates(REPO_ROOT, sample)
        ids = {c.task_id for c in found}
        self.assertGreater(len(ids), 0)
        self.assertIn(first_task_id(REPO_ROOT, sample), ids)

    def test_a_task_without_allowed_paths_is_omitted_not_defaulted(self):
        from host_loop.__main__ import discover_candidates

        with tempfile.TemporaryDirectory() as tmp:
            change = Path(tmp, "openspec", "changes", "chg-x")
            change.mkdir(parents=True)
            # Both sections declare hardware, so the only difference between
            # them is the allowed-paths line this test is about. The fixture
            # previously omitted it, which stopped isolating the variable once
            # an undeclared hardware requirement also began omitting a task.
            (change / "tasks.md").write_text(
                "## TASK-AAA-001 — no allowed paths\n\n- Status:ready\n"
                "- Hardware required:no\n- Depends on:none\n\n"
                "## TASK-BBB-002 — has them\n\n- Status:ready\n"
                "- Hardware required:no\n- Depends on:none\n"
                "- Allowed paths:`x/**`\n")
            found = discover_candidates(Path(tmp), "CHG-X")
            self.assertEqual([c.task_id for c in found], ["TASK-BBB-002"])

    def test_a_missing_tasks_file_is_an_error(self):
        from host_loop.__main__ import discover_candidates

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(BackendError):
                discover_candidates(Path(tmp), "CHG-NOPE")

    def test_hardware_tasks_are_marked_so_the_worker_can_skip_them(self):
        from host_loop.__main__ import discover_candidates

        with tempfile.TemporaryDirectory() as tmp:
            change = Path(tmp, "openspec", "changes", "chg-x")
            change.mkdir(parents=True)
            (change / "tasks.md").write_text(
                "## TASK-HW-001 — device\n\n- Status:ready\n"
                "- Allowed paths:`x/**`\n- Hardware required:yes\n"
                "- Depends on:none\n")
            found = discover_candidates(Path(tmp), "CHG-X")
            self.assertTrue(found[0].hardware_required)

    def test_an_unapproved_change_is_not_dispatchable(self):
        from host_loop.__main__ import _change_is_approved

        with tempfile.TemporaryDirectory() as tmp:
            change = Path(tmp, "openspec", "changes", "chg-x")
            change.mkdir(parents=True)
            (change / "proposal.md").write_text("---\nstatus: draft\n---\n")
            self.assertFalse(_change_is_approved(Path(tmp), "CHG-X"))
            (change / "proposal.md").write_text("---\nstatus: approved\n---\n")
            self.assertTrue(_change_is_approved(Path(tmp), "CHG-X"))

    def test_a_missing_proposal_is_not_approved(self):
        from host_loop.__main__ import _change_is_approved

        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(_change_is_approved(Path(tmp), "CHG-NOPE"))


# ------------------------ DEC-HL-001: the allowlist survives a redirect

class TheSenderNeverFollowsARedirect(unittest.TestCase):
    """urllib followed 301/302/303 on GET and POST transparently.

    assert_route_allowed had already run against the ORIGINAL path, so the
    allowlist could not see where the request actually went, the Authorization
    header — the installation token — was replayed at that host, and only the
    final 200 came back. GitHub answers 301 after an owner or repository
    rename, so this was reachable without an adversary.
    """

    def _servers(self):
        import http.server
        import json
        import threading

        seen = []

        class Second(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, self.headers.get("Authorization")))
                payload = json.dumps({"message": "second host"}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        second = http.server.HTTPServer(("127.0.0.1", 0), Second)
        threading.Thread(target=second.serve_forever, daemon=True).start()
        self.addCleanup(second.shutdown)

        class First(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(301)
                self.send_header(
                    "Location",
                    f"http://127.0.0.1:{second.server_port}/elsewhere/admin")
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args):
                pass

        first = http.server.HTTPServer(("127.0.0.1", 0), First)
        threading.Thread(target=first.serve_forever, daemon=True).start()
        self.addCleanup(first.shutdown)
        return first, second, seen

    def _sender(self, first):
        original = backends_mod.API_ROOT
        backends_mod.API_ROOT = f"http://127.0.0.1:{first.server_port}"
        self.addCleanup(lambda: setattr(backends_mod, "API_ROOT", original))
        return backends_mod.UrllibSender(token="SECRET-TOKEN-VALUE")

    def test_a_redirect_surfaces_as_a_status(self):
        first, _second, _seen = self._servers()
        status, _payload = self._sender(first)("GET", "/repos/o/r/pulls/5", None)
        self.assertEqual(status, 301, "the redirect was followed instead of reported")

    def test_the_token_is_never_replayed_at_the_redirect_target(self):
        first, _second, seen = self._servers()
        self._sender(first)("GET", "/repos/o/r/pulls/5", None)
        self.assertEqual(seen, [], f"the redirect target was contacted: {seen}")

    def test_an_absolute_url_is_refused(self):
        with self.assertRaises(BackendError):
            backends_mod.UrllibSender(token="t")(
                "GET", "https://evil.example/repos/o/r/pulls/5", None)

    def test_a_protocol_relative_url_is_refused(self):
        with self.assertRaises(BackendError):
            backends_mod.UrllibSender(token="t")("GET", "//evil.example/x", None)


class TheGitChildInheritsAnAllowlistedEnvironment(unittest.TestCase):
    """GIT_CONFIG_* injection reaches arbitrary command execution.

    Copying os.environ handed every git child whatever the loop account could
    set; core.sshCommand via GIT_CONFIG_COUNT/KEY/VALUE is code execution on
    the next Deploy-Key push. The deployed unit pins a small environment, but
    that is the plist's property, not this module's.
    """

    def _env_of(self, environ):
        captured = {}

        def fake_run(argv, **kwargs):
            captured.update(kwargs["env"])

            class Done:
                returncode, stdout, stderr = 0, "", ""

            return Done()

        with unittest.mock.patch.dict(os.environ, environ, clear=True), \
             unittest.mock.patch.object(backends_mod.subprocess, "run", fake_run):
            backends_mod.SubprocessGitRunner(repo_dir=".")(["git", "status"])
        return captured

    def test_injected_git_config_is_dropped(self):
        env = self._env_of({
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.sshcommand",
            "GIT_CONFIG_VALUE_0": "/tmp/attacker-ssh",
        })
        self.assertEqual(env.get("GIT_CONFIG_COUNT"), "0")
        self.assertNotIn("GIT_CONFIG_KEY_0", env)
        self.assertNotIn("GIT_CONFIG_VALUE_0", env)

    def test_nosystem_cannot_be_turned_off_by_inheritance(self):
        self.assertEqual(
            self._env_of({"GIT_CONFIG_NOSYSTEM": "0"}).get("GIT_CONFIG_NOSYSTEM"),
            "1")

    def test_the_token_is_not_in_a_git_child_environment(self):
        env = self._env_of({backends_mod.ENV_TOKEN: "ghs_secret",
                            backends_mod.ENV_TOKEN_FILE: "/tmp/tok"})
        self.assertNotIn(backends_mod.ENV_TOKEN, env)
        self.assertNotIn(backends_mod.ENV_TOKEN_FILE, env)

    def test_the_identity_is_pinned_over_an_inherited_one(self):
        """commit_writer, not the runner: that is where the identity is set.

        setdefault let an inherited GIT_AUTHOR_NAME win, so lease commits were
        mis-attributed exactly when the environment was dirty — the opposite of
        what the function's comment claimed.
        """
        with _repo() as path:
            with unittest.mock.patch.dict(
                    os.environ, {"GIT_AUTHOR_NAME": "somebody-else",
                                 "GIT_COMMITTER_EMAIL": "someone@else"},
                    clear=False):
                oid = backends_mod.commit_writer(path)("probe record", None)
            shown = subprocess.run(
                ["git", "log", "-1", "--format=%an <%ae> %cn <%ce>", oid],
                cwd=path, capture_output=True, text=True).stdout.strip()
        self.assertNotIn("somebody-else", shown)
        self.assertNotIn("someone@else", shown)
        self.assertIn("arkdeck-host-loop", shown)

    def test_what_the_push_needs_is_still_passed_through(self):
        env = self._env_of({"HOME": "/home/loop", "SSH_AUTH_SOCK": "/tmp/agent",
                            "PATH": "/usr/bin"})
        self.assertEqual(env["HOME"], "/home/loop")
        self.assertEqual(env["SSH_AUTH_SOCK"], "/tmp/agent")


class LsRemoteMustAnswerAboutTheRefItWasAsked(unittest.TestCase):
    """`git ls-remote <remote> <pattern>` matches the pattern against the TAIL
    of a refname at a `/` boundary — it is not an exact-name lookup.

    read() took line one and validated only its OID, so a shadow such as
    `refs/backup/refs/heads/agent/host-loop/leases/T` answered for the lease and
    won deterministically by sort order. If that shadow pins a previous lease
    commit the record still parses, and assert_still_held then keeps passing
    against a frozen OID after another worker took the real ref over.
    """

    REF = "refs/heads/agent/host-loop/leases/TASK-DEMO-001"

    def _read(self, output):
        return RefPort(remote="origin",
                       _run=lambda argv: (0, output, "")).read(self.REF)

    def test_a_shadow_ref_is_refused(self):
        with self.assertRaises(TransportError) as caught:
            self._read(f"{'6' * 40}\trefs/backup/{self.REF}\n"
                       f"{'a' * 40}\t{self.REF}\n")
        self.assertIn("ambiguous", str(caught.exception))

    def test_a_single_wrong_refname_is_refused(self):
        with self.assertRaises(TransportError) as caught:
            self._read(f"{'6' * 40}\trefs/backup/{self.REF}\n")
        self.assertIn("not the requested", str(caught.exception))

    def test_the_exact_ref_still_reads(self):
        self.assertEqual(self._read(f"{'a' * 40}\t{self.REF}\n"), "a" * 40)

    def test_an_absent_ref_is_still_none(self):
        self.assertIsNone(
            RefPort(remote="origin", _run=lambda argv: (2, "", "")).read(self.REF))


class RenewIsNotABackDoorAroundTakeover(unittest.TestCase):
    """takeover() checks expiry and pr_identity_requeried; renew() checked
    neither, and _advance stamped its own owner_run unconditionally.

    HeldLease is a public dataclass and observe() returns exactly the pair
    needed to build one, so a second worker could renew somebody else's
    UNEXPIRED lease and walk around every precondition takeover documents.
    """

    REF = "refs/heads/agent/host-loop/leases/TASK-DEMO-001"

    def _record(self, owner):
        from host_loop.lease import LeaseRecord, task_branch
        return LeaseRecord(
            task_id="TASK-DEMO-001", base_oid="b" * 40, owner_run=owner,
            fence=1, expires_at=10_000, pr_branch=task_branch("TASK-DEMO-001"),
            pr_number=None, create_attempted=False,
            checks_dispatched_head=None, previous_lease_oid=None)

    def _manager(self, owner):
        from host_loop.lease import LeaseManager
        refs = RefPort(remote="origin",
                       _run=lambda argv: (0, f"{'a' * 40}\t{self.REF}\n", ""))
        return LeaseManager(refs, owner_run=owner, now=lambda: 1_000,
                            commit_writer=lambda text, parent: "c" * 40)

    def test_a_foreign_unexpired_lease_cannot_be_renewed(self):
        from host_loop.lease import FenceLost, HeldLease
        held = HeldLease(self._record("run-A"), "a" * 40)
        with self.assertRaises(FenceLost) as caught:
            self._manager("run-B").renew(held)
        self.assertIn("owned by", str(caught.exception))

    def test_the_owner_can_still_renew(self):
        from host_loop.lease import HeldLease
        held = HeldLease(self._record("run-A"), "a" * 40)
        renewed = self._manager("run-A").renew(held)
        self.assertEqual(renewed.record.fence, 2)
        self.assertEqual(renewed.record.owner_run, "run-A")


if __name__ == "__main__":
    unittest.main(verbosity=2)
