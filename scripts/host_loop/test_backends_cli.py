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
    mint_installation_token,
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
    EXPECTED_ROUTES = {
        ("GET", "/repos/{owner}/{repo}/pulls"),
        ("GET", "/repos/{owner}/{repo}/pulls?head&state&per_page"),
        ("POST", "/repos/{owner}/{repo}/pulls"),
        ("GET", "/repos/{owner}/{repo}/pulls/{number}"),
        ("PATCH", "/repos/{owner}/{repo}/pulls/{number}"),
        ("GET", "/repos/{owner}/{repo}/issues"),
        ("POST", "/repos/{owner}/{repo}/issues"),
        ("GET", "/repos/{owner}/{repo}/issues/{number}"),
        ("PATCH", "/repos/{owner}/{repo}/issues/{number}"),
        ("GET", "/repos/{owner}/{repo}/commits/{oid}/check-runs?per_page&page"),
    }

    def test_allowlist_is_unchanged_in_size(self):
        self.assertEqual(len(transport_mod.ALLOWED_ROUTES), 10)

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

    def test_the_token_never_reaches_a_child_process_argv(self):
        source = Path(backends_mod.__file__).read_text()
        signing = source.split("def _openssl_sign", 1)[1]
        self.assertIn("input=signing_input", signing,
                      "the payload must go over stdin")
        self.assertNotIn("self.token", signing)

    def test_jwt_signing_is_delegated_so_the_pem_never_enters_this_process(self):
        source = Path(backends_mod.__file__).read_text()
        self.assertIn('"sudo", "openssl", "dgst"', source)
        self.assertNotIn("PRIVATE KEY-----\\n", source)
        # no direct read of the PEM anywhere
        self.assertNotIn("pem_path).read", source)
        self.assertNotIn("open(pem_path", source)

    def test_mint_discards_the_jwt_and_returns_only_sanitised_metadata(self):
        seen = {}

        def fake_sender_factory(jwt):
            seen["jwt"] = jwt

            def send(method, path, body):
                self.assertEqual(method, "POST")
                self.assertIn("/access_tokens", path)
                return 201, {"token": "ghs_" + "c" * 30,
                             "expires_at": "2026-07-25T12:00:00Z",
                             "permissions": {"issues": "write"},
                             "repository_selection": "selected"}
            return send

        token, meta = mint_installation_token(
            app_id=4388667, installation_id=148855345, pem_path="/nonexistent.pem",
            sender_factory=fake_sender_factory,
            signer=lambda payload, path: b"signature-bytes",
            now=lambda: 1000,
        )
        self.assertTrue(token.startswith("ghs_"))
        self.assertEqual(sorted(meta), ["expires_at", "permissions",
                                        "repository_selection"])
        self.assertNotIn("token", meta, "the token must not be echoed in metadata")

    def test_a_failed_mint_is_an_error(self):
        with self.assertRaises(BackendError):
            mint_installation_token(
                app_id=1, installation_id=2, pem_path="/x.pem",
                sender_factory=lambda jwt: (lambda m, p, b: (403, {"message": "no"})),
                signer=lambda payload, path: b"sig", now=lambda: 1)


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
    def test_the_body_is_a_valid_envelope_for_a_real_task(self):
        from host_loop.pr_envelope import parse_and_validate

        render = body_renderer(str(REPO_ROOT), change_id="CHG-2026-030-host-loop-runtime",
                              producer="host-loop/worker", run_id="r-1")
        candidate = TaskCandidate(task_id="TASK-HLR-003", status="ready",
                                  decision_grade="D0", hardware_required=False,
                                  dependencies=(), allowed_paths=("scripts/host_loop/**",),
                                  base_pin=None)
        body = render(candidate, "a" * 40, "b" * 40)
        parsed = parse_and_validate(body, REPO_ROOT)
        self.assertEqual(parsed.envelope.task, "TASK-HLR-003")
        self.assertEqual(parsed.envelope.base_oid, "a" * 40)
        self.assertEqual(parsed.envelope.head_oid, "b" * 40)

    def test_the_body_carries_no_dispatch_marker_so_nesting_cannot_occur(self):
        from host_loop.worker import DISPATCH_MARKER

        render = body_renderer(str(REPO_ROOT), change_id="CHG-2026-030-host-loop-runtime",
                              producer="p", run_id="r")
        candidate = TaskCandidate(task_id="TASK-HLR-003", status="ready",
                                  decision_grade="D0", hardware_required=False,
                                  dependencies=(), allowed_paths=("x/**",),
                                  base_pin=None)
        self.assertNotIn(DISPATCH_MARKER, render(candidate, "a" * 40, "b" * 40))

    def test_the_body_states_green_is_not_merge_permission(self):
        render = body_renderer(str(REPO_ROOT), change_id="CHG-2026-030-host-loop-runtime",
                              producer="p", run_id="r")
        candidate = TaskCandidate(task_id="TASK-HLR-003", status="ready",
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

        found = discover_candidates(REPO_ROOT, "CHG-2026-030-host-loop-runtime")
        ids = {c.task_id for c in found}
        self.assertIn("TASK-HLR-003", ids)
        self.assertIn("TASK-HLR-004", ids)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
