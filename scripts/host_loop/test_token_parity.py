# Append to scripts/host_loop/test_pr_envelope.py (HLR-003 source PR, F3 scope).
#
# Guards the seam that produced the divergence: pr_envelope carried its own
# narrower copy of the task token, so 14 of 46 active task headers rendered
# unusable while MECH-004 accepted them. These tests fail if the two
# definitions ever drift apart again.

import importlib.util
import pathlib
import re
import sys
import unittest

HOST_LOOP_DIR = pathlib.Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop import pr_envelope as pr_envelope_module  # noqa: E402

_PARITY_MODULE_NAME = "_check_pr_paths_for_parity"


def _load_check_pr_paths():
    """Load scripts/check_pr_paths.py as a module without importing scripts/ as a package.

    The module must be registered in sys.modules *before* exec_module: dataclass
    field introspection resolves the defining module by name, and a module that
    is absent from sys.modules makes @dataclass raise AttributeError.
    """
    if _PARITY_MODULE_NAME in sys.modules:
        return sys.modules[_PARITY_MODULE_NAME]
    path = pathlib.Path(__file__).resolve().parents[1] / "check_pr_paths.py"
    spec = importlib.util.spec_from_file_location(_PARITY_MODULE_NAME, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[_PARITY_MODULE_NAME] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[_PARITY_MODULE_NAME]
        raise
    return module


class TaskTokenParityTests(unittest.TestCase):
    """The envelope token must stay byte-identical to the MECH-004 token."""

    def test_token_text_is_byte_identical_to_mech004(self):
        mech = _load_check_pr_paths()
        self.assertEqual(
            pr_envelope_module.TASK_TOKEN_TEXT,
            mech.TASK_TOKEN_TEXT,
            "envelope and MECH-004 task-token definitions have diverged; "
            "a narrower envelope copy silently rejects valid active task headers",
        )

    def test_every_active_task_header_is_envelope_acceptable(self):
        repo_root = pathlib.Path(__file__).resolve().parents[2]
        header_re = re.compile(
            rf"^##\s+({pr_envelope_module.TASK_TOKEN_TEXT})(?:\s|$)", re.MULTILINE
        )
        headers = set()
        for tasks_file in sorted(repo_root.glob("openspec/changes/*/tasks.md")):
            headers.update(header_re.findall(tasks_file.read_text(encoding="utf-8")))
        self.assertTrue(headers, "no active task headers discovered")
        rejected = sorted(h for h in headers if not pr_envelope_module.TASK_RE.fullmatch(h))
        self.assertEqual(rejected, [], f"envelope rejects active task headers: {rejected}")

    def test_suffixed_and_multisegment_tokens_are_accepted(self):
        for token in ("TASK-HLR-003", "TASK-HLR-002A", "TASK-M1-001R",
                      "TASK-UD-REDACTOR-001", "TASK-UD-CAP-MUT-001"):
            with self.subTest(token=token):
                self.assertTrue(pr_envelope_module.TASK_RE.fullmatch(token))

    def test_malformed_tokens_are_still_rejected(self):
        # Widening the token must not weaken any of these.
        for token in (
            "TASK-HLR-2A",        # digits not three
            "TASK-HLR-0021",      # four digits
            "TASK-HLR-002AB",     # multi-character suffix
            "TASK-HLR-002a",      # lowercase suffix
            "task-hlr-002",       # lowercase token
            "TASK-002",           # no group
            "TASK-HLR-002-",      # trailing separator
            "TASK-HLR-002 A",     # embedded space
            "XTASK-HLR-002",      # prefix noise
            "none",
            "",
        ):
            with self.subTest(token=token):
                self.assertIsNone(pr_envelope_module.TASK_RE.fullmatch(token))

    def test_widening_does_not_bypass_active_header_uniqueness(self):
        """A well-formed token absent from active tasks.md must still fail."""
        repo_root = pathlib.Path(__file__).resolve().parents[2]
        envelope = pr_envelope_module.Envelope(
            pr_type="implementation",
            change="CHG-2026-030-host-loop-runtime",
            task="TASK-ZZZ-999Z",  # well-formed, not a real header
            base_oid="a" * 40,
            head_oid="b" * 40,
            decision_grade="D0",
            depends_on="none",
            evidence=("openspec/changes/chg-2026-030-host-loop-runtime/design.md",),
            producer="host",
            run="00000000-0000-4000-8000-000000000000",
        )
        self.assertTrue(pr_envelope_module.TASK_RE.fullmatch(envelope.task))
        with self.assertRaises(pr_envelope_module.EnvelopeError):
            pr_envelope_module.validate_envelope(envelope, repo_root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
