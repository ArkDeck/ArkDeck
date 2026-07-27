"""Archive-immune access to real change files for live-sample tests.

TASK-HLR-003 established that parsers must be asserted against real
in-repo files, not only hand-built fixtures. The original live sample was
this loop's own change, which #573 measured as an archive blocker: moving
the change into ``openspec/changes/archive/`` broke every test that had
hard-coded the active path. These helpers keep the rule and drop the
path assumption (TASK-NAV-002).

Two access patterns, chosen by what a test exercises:

- ``change_tasks_path`` — for tests that READ a change's ``tasks.md`` as
  text. A change lives in exactly one of the active tree or the archive;
  anything else is a repo inconsistency the test must surface, so 0 or 2+
  locations raise instead of picking one.
- ``live_sample_change`` — for tests whose subject is an *active-changes
  API* (``discover_candidates``, envelope validation). Archived changes
  are rightly invisible to those APIs, so the sample must be an active
  change, picked deterministically: the one discovery sees the most
  candidates in (ties: lexicographically first). The repo always carries
  governance work in flight, so an empty result is a loud failure, not a
  skip.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop.__main__ import _without_code_fences, discover_candidates  # noqa: E402

_TASK_HEADER = re.compile(
    r"^##\s+(TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?)", re.MULTILINE
)


def change_tasks_path(repo_root: Path, change_id: str) -> Path:
    """Return the change's tasks.md from active or archive — exactly one."""

    changes = repo_root / "openspec" / "changes"
    candidates = []
    active = changes / change_id.lower() / "tasks.md"
    if active.is_file():
        candidates.append(active)
    candidates.extend(
        path
        for path in sorted(changes.glob(f"archive/*-{change_id.lower()}/tasks.md"))
        if path.is_file()
    )
    if len(candidates) != 1:
        raise AssertionError(
            f"{change_id}: expected exactly one tasks.md across active and "
            f"archive, found {len(candidates)}: {[str(p) for p in candidates]}"
        )
    return candidates[0]


def _canonical_change_id(change_dir: Path) -> str:
    """The change's frontmatter id when it has one, else the dirname form."""

    proposal = change_dir / "proposal.md"
    if proposal.is_file():
        match = re.search(r"^id:\s*(CHG-[A-Za-z0-9-]+)\s*$",
                          proposal.read_text(encoding="utf-8"), re.MULTILINE)
        if match:
            return match.group(1)
    return "CHG-" + change_dir.name[len("chg-"):]


def live_sample_change(repo_root: Path) -> str:
    """Pick the active change with the most discoverable candidates.

    Restricted to changes whose frontmatter id lowercases to their
    directory name: discovery resolves by directory while envelope
    validation resolves by frontmatter id, and a sample where the two
    disagree (a short-form id such as CHG-2026-026) cannot serve both.
    """

    changes = repo_root / "openspec" / "changes"
    best: tuple[int, str] | None = None
    for tasks_file in sorted(changes.glob("chg-*/tasks.md")):
        change_dir = tasks_file.parent
        change_id = _canonical_change_id(change_dir)
        if change_id.lower() != change_dir.name:
            continue
        found = discover_candidates(repo_root, change_id)
        headers = len(_TASK_HEADER.findall(
            _without_code_fences(tasks_file.read_text(encoding="utf-8"))))
        # Only fully parseable changes serve: the real-file contracts assert
        # header count == candidate count, so a change carrying a
        # field-incomplete section (headers > candidates) cannot be the
        # sample without turning that assertion into noise.
        if len(found) != headers:
            continue
        if found and (best is None or len(found) > best[0]):
            best = (len(found), change_id)
    if best is None:
        raise AssertionError(
            "no active change yields any discovery candidate; the live-sample "
            "tests cannot run against an empty repo"
        )
    return best[1]


def first_task_id(repo_root: Path, change_id: str) -> str:
    """First ``## TASK-…`` header in the change's tasks.md."""

    text = change_tasks_path(repo_root, change_id).read_text(encoding="utf-8")
    match = _TASK_HEADER.search(text)
    if match is None:
        raise AssertionError(f"{change_id}: tasks.md declares no task header")
    return match.group(1)


# --- the helpers' own contract -------------------------------------------

_COMPLETE_TASK = (
    "## {task} — fixture\n"
    "- Status:ready\n"
    "- Hardware required:no\n"
    "- Depends on:none\n"
    "- Allowed paths:`x/**`\n"
)


def _write_change(root: Path, dirname: str, body: str) -> None:
    change_dir = root / "openspec" / "changes" / dirname
    change_dir.mkdir(parents=True)
    (change_dir / "tasks.md").write_text(body, encoding="utf-8")


class ChangeTasksPathContract(unittest.TestCase):
    def _root(self):
        import tempfile

        temporary = tempfile.TemporaryDirectory(prefix="nav002-support-")
        self.addCleanup(temporary.cleanup)
        return Path(temporary.name)

    def test_an_active_change_resolves_to_the_active_file(self):
        root = self._root()
        _write_change(root, "chg-one", "## TASK-AAA-001 — t\n")
        path = change_tasks_path(root, "CHG-ONE")
        self.assertEqual(path, root / "openspec" / "changes" / "chg-one" / "tasks.md")

    def test_an_archived_change_resolves_to_the_archived_file(self):
        root = self._root()
        _write_change(root, "archive/2026-01-01-chg-one", "## TASK-AAA-001 — t\n")
        path = change_tasks_path(root, "CHG-ONE")
        self.assertTrue(str(path).endswith("archive/2026-01-01-chg-one/tasks.md"))

    def test_both_locations_fail_loudly_instead_of_picking_one(self):
        root = self._root()
        _write_change(root, "chg-one", "active\n")
        _write_change(root, "archive/2026-01-01-chg-one", "archived\n")
        with self.assertRaisesRegex(AssertionError, "exactly one"):
            change_tasks_path(root, "CHG-ONE")

    def test_neither_location_fails_loudly(self):
        root = self._root()
        with self.assertRaisesRegex(AssertionError, "exactly one"):
            change_tasks_path(root, "CHG-ONE")


class LiveSampleChangeContract(unittest.TestCase):
    def _root(self):
        import tempfile

        temporary = tempfile.TemporaryDirectory(prefix="nav002-sample-")
        self.addCleanup(temporary.cleanup)
        return Path(temporary.name)

    def test_the_change_with_the_most_candidates_wins(self):
        root = self._root()
        _write_change(
            root, "chg-small", _COMPLETE_TASK.format(task="TASK-AAA-001")
        )
        _write_change(
            root,
            "chg-big",
            _COMPLETE_TASK.format(task="TASK-BBB-001")
            + _COMPLETE_TASK.format(task="TASK-BBB-002"),
        )
        self.assertEqual(live_sample_change(root), "CHG-big")

    def test_an_archived_change_is_never_sampled(self):
        root = self._root()
        _write_change(
            root,
            "archive/2026-01-01-chg-gone",
            _COMPLETE_TASK.format(task="TASK-CCC-001"),
        )
        with self.assertRaisesRegex(AssertionError, "no active change"):
            live_sample_change(root)

    def test_zero_candidates_fail_loudly(self):
        root = self._root()
        _write_change(root, "chg-empty", "prose without any task header\n")
        with self.assertRaisesRegex(AssertionError, "no active change"):
            live_sample_change(root)


class FirstTaskIdContract(unittest.TestCase):
    def test_the_first_header_is_returned(self):
        import tempfile

        temporary = tempfile.TemporaryDirectory(prefix="nav002-first-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        _write_change(
            root,
            "chg-one",
            "## TASK-AAA-002 — second declared first\n## TASK-AAA-001 — t\n",
        )
        self.assertEqual(first_task_id(root, "CHG-ONE"), "TASK-AAA-002")

    def test_a_headerless_file_fails_loudly(self):
        import tempfile

        temporary = tempfile.TemporaryDirectory(prefix="nav002-first-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        _write_change(root, "chg-one", "no headers here\n")
        with self.assertRaisesRegex(AssertionError, "no task header"):
            first_task_id(root, "CHG-ONE")


class AgainstTheRealRepo(unittest.TestCase):
    """The helpers must hold against the actual checkout, not only fixtures."""

    def test_the_frozen_sample_resolves_wherever_it_lives(self):
        path = change_tasks_path(REPO_ROOT, "CHG-2026-030-host-loop-runtime")
        self.assertTrue(path.is_file())
        parts = str(path.relative_to(REPO_ROOT))
        self.assertIn("chg-2026-030-host-loop-runtime", parts)

    def test_the_live_sample_is_an_active_change_with_tasks(self):
        sample = live_sample_change(REPO_ROOT)
        self.assertTrue(sample.startswith("CHG-"))
        active_dir = REPO_ROOT / "openspec" / "changes" / sample.lower()
        self.assertTrue(active_dir.is_dir(), f"{sample} must be active")
        self.assertTrue(first_task_id(REPO_ROOT, sample).startswith("TASK-"))
        self.assertGreater(len(discover_candidates(REPO_ROOT, sample)), 0)


if __name__ == "__main__":
    unittest.main()
