"""Pure fake-runner tests only; never open an installed image or Runtime."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import entry

REPOSITORY = next((p for p in Path(__file__).resolve().parents
                   if (p / "rust/crates/arkdeck-cli/src/command_registry.json").is_file()), None)
if REPOSITORY is None:
    REPOSITORY = Path(os.environ.get("ARKDECK_MAC_ENTRY_TEST_REPO", r"D:/src/ArkDeck"))


class EntryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(REPOSITORY / "scripts"))
        cls.registry = json.loads((REPOSITORY / "rust/crates/arkdeck-cli/src/command_registry.json").read_text())

    def test_closed_methods_and_trust_options(self):
        for argv in (["runtime", "signing", "install", "--output", "json"],
                     ["agent", "run", "--operation", "flash.full-restore@1", "--execution-id", "fixture",
                      "--maximum-wait", "10m", "--timeout", "11m", "--output", "json"],
                     ["agent", "status", "--execution-id", "fixture", "--capability", "caller", "--output", "json"],
                     ["job", "wait", "--job", "fixture", "--maximum-wait", "10m", "--output", "json"]):
            with self.subTest(argv=argv), self.assertRaises(entry.Stop):
                entry.validate_argv(argv, self.registry)

    def test_published_read_and_wait(self):
        self.assertEqual(entry.validate_argv(["job", "wait", "--job", "fixture", "--timeout", "11m",
                                             "--output", "json"], self.registry), ("job", "wait"))
        with self.assertRaises(entry.Stop):
            entry.validate_argv(["runtime", "service", "verify", "--output", "json"], self.registry)

    def test_no_local_native_runtime_on_other_os(self):
        with self.assertRaises(entry.Stop):
            entry.check_configuration({}, native_system=lambda: "Linux", host_runner=lambda *a, **k: self.fail())

    def workspace(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        image = root / "fake-not-a-runtime"
        image.write_bytes(b"PURE FIXTURE, not an executable")
        return root, image

    @staticmethod
    def launch():
        return ["agent", "run", "--operation", "observe.device@1", "--execution-id", "fixture-only",
                "--maximum-wait", "5m", "--timeout", "11m", "--output", "json"]

    @staticmethod
    def successful(command, **kwargs):
        kwargs["stdout"].write(b'{"schemaVersion":"arkdeck.cli.result/1","ok":true,"result":{"outcomeUnknown":false}}')
        return subprocess.CompletedProcess(command, 0)

    def test_same_identity_not_replayed_after_known_exit(self):
        out, image = self.workspace()
        self.assertEqual(entry.run_once(out, "fixture.first", self.launch(), image, REPOSITORY, image,
                                        runner=self.successful), 0)
        with self.assertRaises(entry.Stop):
            entry.run_once(out, "fixture.other-label", self.launch(), image, REPOSITORY, image,
                           runner=lambda *a, **k: self.fail("replayed"))

    def test_timeout_preserves_bytes_outcome_and_blocks_next_mutation(self):
        out, image = self.workspace()
        def timed_out(command, **kwargs):
            kwargs["stdout"].write(b"retained fixture partial")
            kwargs["stderr"].write(b"retained fixture diagnostic")
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])
        with self.assertRaises(subprocess.TimeoutExpired):
            entry.run_once(out, "fixture.timeout", ["job", "list", "--output", "json"], image,
                           REPOSITORY, image, runner=timed_out)
        outcome = json.loads(next(out.glob("*.outcome.json")).read_text())
        self.assertTrue(outcome["outcomeUnknown"])
        self.assertIsNone(outcome["nativeExitCode"])
        self.assertFalse(outcome["replayAllowed"])
        self.assertEqual(next(out.glob("*.stdout")).read_bytes(), b"retained fixture partial")
        self.assertEqual(next(out.glob("*.stderr")).read_bytes(), b"retained fixture diagnostic")
        with self.assertRaises(entry.Stop):
            entry.run_once(out, "fixture.new", self.launch(), image, REPOSITORY, image,
                           runner=lambda *a, **k: self.fail("new dispatch after unknown"))

    def test_nested_unknown_is_retained(self):
        out, image = self.workspace()
        def unknown(command, **kwargs):
            kwargs["stdout"].write(b'{"schemaVersion":"arkdeck.cli.result/1","ok":false,"error":{"details":{"outcomeUnknown":true}}}')
            return subprocess.CompletedProcess(command, 1)
        with self.assertRaises(entry.Stop):
            entry.run_once(out, "fixture.unknown", self.launch(), image, REPOSITORY, image, runner=unknown)
        value = json.loads(next(out.glob("*.outcome.json")).read_text())
        self.assertEqual(value["nativeExitCode"], 1)
        self.assertTrue(value["outcomeUnknown"])

    def test_post_capture_failure_does_not_allow_forward_dispatch(self):
        out, image = self.workspace()
        from unittest.mock import patch
        def stopped(*args, **kwargs):
            kwargs["runner"]([str(image), *self.launch()])
            raise OSError("pure injected journal-write failure")
        with patch("gj_record.capture.capture", side_effect=stopped), self.assertRaises(OSError):
            entry.run_once(out, "fixture.post-read", self.launch(), image, REPOSITORY, image,
                           runner=self.successful)
        value = json.loads(next(out.glob("*.outcome.json")).read_text())
        self.assertEqual(value["nativeExitCode"], 0)
        self.assertTrue(value["outcomeUnknown"])
        next_argv = self.launch()
        next_argv[next_argv.index("--execution-id") + 1] = "different"
        with self.assertRaises(entry.Stop):
            entry.run_once(out, "fixture.next", next_argv, image, REPOSITORY, image,
                           runner=lambda *a, **k: self.fail())

    def test_wrong_material_zero_call(self):
        out, image = self.workspace()
        (out / "inputs").mkdir()
        wrong = out / "inputs" / "wrong.hap"
        wrong.write_bytes(b"fixture wrong material")
        with self.assertRaises(entry.Stop):
            entry.run_once(out, "fixture.wrong", ["artifact", "import", "hap", "--import-request-id", "fixture",
                                                  "--target", "fixture", "--file", str(wrong), "--output", "json"],
                           image, REPOSITORY, image, runner=lambda *a, **k: self.fail())
        self.assertFalse(list(out.glob("*.intent.json")))

    def test_complete_ledger_unknown_or_attention_refused(self):
        states = {"completed", "failed"}
        entry.closed_ledger([{"state": "completed", "outcomeUnknown": False}], states)
        for row in ({"state": "running", "outcomeUnknown": False},
                    {"state": "completed", "outcomeUnknown": True},
                    {"state": "completed", "outcomeUnknown": False, "nested": {"waitingForHuman": True}}):
            with self.subTest(row=row), self.assertRaises(entry.Stop):
                entry.closed_ledger([row], states)

    def test_source_packet_exact_bytes(self):
        baseline = REPOSITORY / "scripts/gj_record/baselines/gj-pair-armv7-20261006"
        manifest = json.loads((baseline / "manifest.json").read_text())
        self.assertFalse(manifest["hardwareEvidence"])
        self.assertFalse(manifest["formalAcceptance"])
        for row in manifest["sourceFiles"]:
            data = (baseline / row["repositoryRelativePath"]).read_bytes()
            self.assertEqual(len(data), row["byteCount"])
            self.assertEqual(hashlib.sha256(data).hexdigest(), row["sha256"])


class NativeEntryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(REPOSITORY / "scripts"))

    def setUp(self):
        self.config = {"daemon": "/fixture/daemon", "daemonSha256": "d" * 64,
                       "catalogDigest": entry.CATALOG}
        self.service = {"launchAgent": {"installed": True, "loaded": True, "socketPresent": True,
                         "ready": True, "diagnostics": [], "daemonPath": self.config["daemon"],
                         "daemonSHA256": self.config["daemonSha256"],
                         "launchDomain": "gui/501", "socketPath": "/fixture/control.sock"},
                        "daemonHealth": {"status": "ok", "catalogDigest": entry.CATALOG}}
        self.observed = {"pid": 123, "uid": 501, "startSeconds": 10, "startMicroseconds": 20,
                         "liveCodeDirectoryHash": "a" * 40, "socketIdentity": {"device": 1, "inode": 2},
                         "nativeImageVerified": True, "socketOwnerVerified": True}

    def test_not_ready_or_foreign_service_refused_before_native_read(self):
        native = SimpleNamespace(uid=501, snapshot=lambda *args: self.fail("native read after invalid service"))
        changes = [("launchAgent", field, False) for field in ("installed", "loaded", "socketPresent", "ready")]
        changes += [("launchAgent", "diagnostics", ["fixture refusal"]),
                    ("launchAgent", "daemonPath", "/fixture/foreign"),
                    ("launchAgent", "daemonSHA256", "e" * 64),
                    ("launchAgent", "launchDomain", "gui/502"),
                    ("launchAgent", "launchDomain", "gui/501/com.arkdeck.agentd"),
                    ("daemonHealth", "status", "unreachable"),
                    ("daemonHealth", "catalogDigest", "f" * 64)]
        for owner, field, value in changes:
            altered = json.loads(json.dumps(self.service))
            altered[owner][field] = value
            with self.subTest(field=field), self.assertRaises(entry.Stop):
                entry.native_instance(self.config, altered, native)

    def native(self, *, peer_pid=123, birth_drift=False, socket_drift=False, image_drift=False):
        native = entry.MacNative.__new__(entry.MacNative)
        native.uid, native.daemon = 501, self.config["daemon"]
        spec = importlib.util.spec_from_file_location("pure_native_parser", REPOSITORY / "scripts/ci/installed_rust_ui.py")
        existing = importlib.util.module_from_spec(spec)
        # The reused parser module imports POSIX pwd; no test calls its account
        # helpers. Keep these fake-native regressions runnable on Windows too.
        with patch.dict(sys.modules, {"pwd": SimpleNamespace()}):
            spec.loader.exec_module(existing)
        existing.process_path = lambda pid: Path("/fixture/foreign" if image_drift else native.daemon)
        existing.verify_live_code = lambda pid, path: "a" * 40
        native.existing = existing
        native.host_read = lambda *args, **kwargs: (b"pid = 123\nARKDECK_RUNTIME_COMPOSITION => production\n"
                                                    b'"com.arkdeck.agentd" = {\n active = 1\n}\n')
        births, sockets = [], []
        def birth(pid):
            births.append(pid)
            return {"pid": pid, "uid": 501, "startSeconds": 11 if birth_drift and len(births) > 1 else 10,
                    "startMicroseconds": 20}
        def identity(path):
            sockets.append(path)
            return {"device": 1, "inode": 3 if socket_drift and len(sockets) > 1 else 2}
        native.birth, native.socket_identity = birth, identity
        class Peer:
            def __init__(self, *args): pass
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def settimeout(self, value): self.timeout = value
            def connect(self, endpoint): self.endpoint = endpoint
            def getsockopt(self, level, name):
                self.assertions = (level, name)
                return peer_pid
        return native, Peer

    def test_native_snapshot_matches_ready_process_birth_and_socket(self):
        native, peer = self.native()
        with patch.object(entry, "socket", SimpleNamespace(AF_UNIX=1, SOCK_STREAM=1, socket=peer)):
            self.assertEqual(entry.native_instance(self.config, self.service, native),
                             {**self.observed, "daemonSHA256": self.config["daemonSha256"],
                              "socketPath": "/fixture/control.sock", "catalogDigest": entry.CATALOG})

    def test_peer_pid_reuse_file_or_socket_drift_refused(self):
        for altered in ({"peer_pid": 456}, {"birth_drift": True}, {"socket_drift": True}, {"image_drift": True}):
            native, peer = self.native(**altered)
            with self.subTest(altered=altered), patch.object(entry, "socket", SimpleNamespace(AF_UNIX=1, SOCK_STREAM=1, socket=peer)), self.assertRaises(entry.Stop):
                entry.native_instance(self.config, self.service, native)

    def test_dynamic_signature_failure_refused(self):
        native, peer = self.native()
        def refused(*args): raise RuntimeError("pure fixture stale CodeDirectory")
        native.existing.verify_live_code = refused
        with patch.object(entry, "socket", SimpleNamespace(AF_UNIX=1, SOCK_STREAM=1, socket=peer)), self.assertRaises(RuntimeError):
            entry.native_instance(self.config, self.service, native)

    def test_missing_or_duplicate_launchd_owner_refused(self):
        for value in (b"pid = 0\n", b"pid = 123\npid = 456\n", b"pid = 123\n"):
            native, peer = self.native()
            native.host_read = lambda *args, **kwargs: value
            with self.subTest(value=value), patch.object(entry, "socket", SimpleNamespace(AF_UNIX=1, SOCK_STREAM=1, socket=peer)), self.assertRaises(RuntimeError):
                entry.native_instance(self.config, self.service, native)

    def test_native_subprocess_allowlist_rejects_lifecycle_and_shell(self):
        native = entry.MacNative.__new__(entry.MacNative)
        native.uid, native.daemon = 501, "/fixture/daemon"
        native.runner = lambda *args, **kwargs: self.fail("forbidden host command ran")
        for arguments in (("/bin/launchctl", "kickstart", "gui/501/com.arkdeck.agentd"),
                          ("/bin/sh", "-c", "true"), ("/usr/bin/codesign", "--sign", "fixture", "/fixture/daemon"),
                          ("/bin/launchctl", "print", "gui/502/com.arkdeck.agentd"),
                          ("/bin/launchctl", "print", "gui/501/com.arkdeck.foreign")):
            with self.subTest(arguments=arguments), self.assertRaises(entry.Stop):
                native.host_read(*arguments)

    def test_kernel_birth_full_read_owner_and_timestamp_are_required(self):
        native = entry.MacNative.__new__(entry.MacNative)
        native.uid = 501
        for field, value in ((None, None), ("pid", 456), ("uid", 502), ("seconds", 0),
                             ("microseconds", 1000000), ("returned", 0)):
            def read(pid, flavor, argument, pointer, size):
                self.assertEqual((pid, flavor, argument, size), (123, 3, 0, 136))
                info = pointer._obj
                info.pid, info.uid, info.seconds, info.microseconds = 123, 501, 10, 20
                if field not in (None, "returned"):
                    setattr(info, field, value)
                return value if field == "returned" else size
            with self.subTest(field=field), patch.object(entry.ctypes, "CDLL", return_value=SimpleNamespace(proc_pidinfo=read)):
                if field is None:
                    self.assertEqual(native.birth(123), {"pid": 123, "uid": 501, "startSeconds": 10, "startMicroseconds": 20})
                else:
                    with self.assertRaises(entry.Stop):
                        native.birth(123)

    def test_preflight_same_native_instance_brackets_complete_public_facts(self):
        from gj_record import catalog
        built = catalog.at_revision(REPOSITORY, "origin/main")
        for changed in (False, True):
            with self.subTest(reused_pid=changed), tempfile.TemporaryDirectory() as directory:
                out = Path(directory).resolve()
                image = out / "fixture-not-an-image"
                image.write_bytes(b"pure fake runner fixture")
                sha = entry.sha_file(image)
                config = {**self.config, "cli": str(image), "cliSha256": sha,
                          "daemon": str(image), "daemonSha256": sha, "sourceRevision": built.revision}
                service = json.loads(json.dumps(self.service))
                service["launchAgent"].update(daemonPath=str(image), daemonSHA256=sha)
                calls, native_calls = [], []
                def runner(command, **kwargs):
                    leaf = tuple(command[1:3])
                    calls.append(leaf)
                    command_name = ".".join(leaf)
                    if command[1] == "--version":
                        command_name, result = "version", {"buildIdentity": "sha256:" + sha}
                    elif command[1:4] == ["runtime", "service", "status"]:
                        command_name, result = "runtime.service.status", service
                    elif command[1:4] == ["runtime", "hdc", "status"]:
                        command_name, result = "runtime.hdc.status", {"availability": "available", "executableSHA256": "c" * 64,
                                                                     "configuredExecutableSHA256": "c" * 64}
                    elif command[1:4] == ["runtime", "tool", "list"]:
                        command_name, result = "runtime.tool.list", []
                    elif leaf == ("runtime", "health"):
                        result = {"catalogDigest": entry.CATALOG, "status": "ok"}
                    elif leaf == ("operation", "list"):
                        result = [{"reference": op, "availability": "available"} for op in built.operations]
                    elif leaf in (("job", "list"), ("agent", "list")):
                        result = {"items": [], "snapshotRevision": "fixture", "hasMore": False, "nextCursor": None}
                    elif leaf == ("device", "candidates"):
                        result = {"schemaVersion": "arkdeck.device-observations/1", "health": "current", "snapshotGeneration": "1",
                                  "observations": [{"authorizationState": "Connected", "candidateKey": "fixture", "observationId": "fixture",
                                                    "adoptedTargetId": "fixture", "bindingRevision": 1}]}
                    elif leaf == ("target", "show"):
                        result = {"targetId": "fixture", "bindingRevision": 1}
                    elif leaf == ("target", "availability"):
                        result = {"targetId": "fixture", "binding": {"bindingRevision": 1, "state": "ready"},
                                  "operations": {"items": [{"reference": op, "availability": "available"} for op in entry.OPERATIONS]}}
                    else:
                        result = {}
                    kwargs["stdout"].write(json.dumps({"schemaVersion": "arkdeck.cli.result/1", "command": command_name,
                                                      "ok": True, "result": result}).encode())
                    return subprocess.CompletedProcess(command, 0)
                def snapshot(launch):
                    native_calls.append(len(calls))
                    return {**self.observed, "startMicroseconds": 21 if changed and len(native_calls) > 1 else 20}
                native = SimpleNamespace(uid=501, snapshot=snapshot)
                dispatch = lambda *args, **kwargs: entry.run_once(*args, **kwargs, runner=runner)
                with patch("builtins.print"):
                    if changed:
                        with self.assertRaises(entry.Stop):
                            entry.preflight(config, REPOSITORY, out, dispatch=dispatch, native_factory=lambda *args: native)
                        self.assertFalse(list(out.glob("mac-entry-preflight-*.json")))
                    else:
                        self.assertEqual(entry.preflight(config, REPOSITORY, out, dispatch=dispatch,
                                                         native_factory=lambda *args: native), 0)
                        proof = json.loads(next(out.glob("mac-entry-preflight-*.json")).read_text())
                        self.assertEqual(proof["nativeInstance"]["pid"], 123)
                        self.assertFalse(proof["formalAcceptance"])
                self.assertEqual(len(native_calls), 2)
                self.assertIn(("job", "list"), calls)
                self.assertIn(("agent", "list"), calls)
                self.assertFalse(any(c in (("agent", "run"), ("agent", "resume"), ("artifact", "import")) for c in calls))


if __name__ == "__main__":
    unittest.main()
