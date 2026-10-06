"""Real capture-process races with task-local fake runners; no CLI/device runs."""

from __future__ import annotations

import multiprocessing
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from gj_record import capture


def _blocked_capture(root, entered, finish, results):
    root = Path(root)

    def runner(argv, **kwargs):
        entered.set()
        if not finish.wait(15):
            raise RuntimeError("fixture release was not signalled")
        return subprocess.CompletedProcess(argv, 75, stdout=b"original output\n")

    try:
        entry = capture.capture(root / "out", "first", [str(root / "arkdeck.exe"), "--output", "json"],
                                repository=root / "repo", quiet=True, runner=runner)
        results.put(("ok", entry))
    except Exception as error:
        results.put(("error", type(error).__name__))


def _crashed_capture(root):
    root = Path(root)

    def runner(argv, **kwargs):
        (root / "runner-dispatched").write_bytes(b"one fixture dispatch")
        os._exit(23)

    capture.capture(root / "out", "crashed", [str(root / "arkdeck.exe"), "--output", "json"],
                    repository=root / "repo", quiet=True, runner=runner)


class CaptureExclusivityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.out = self.root / "out"
        self.repository = self.root / "repo"
        self.repository.mkdir()
        self.cli = self.root / "arkdeck.exe"
        self.cli.write_bytes(b"task-private fixture image; never executed")
        self.command = [str(self.cli), "--output", "json"]
        self.calls = []

    def runner(self, argv, **kwargs):
        self.calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, stdout=b"fixture output")

    def invoke(self, step="second", runner=None):
        return capture.capture(self.out, step, self.command, repository=self.repository,
                               quiet=True, runner=runner or self.runner)

    def tree(self):
        return {p.name: p.read_bytes() for p in self.out.iterdir() if p.is_file()}

    def test_an_actual_other_process_is_refused_before_runner_then_sequence_advances(self):
        context = multiprocessing.get_context("spawn")
        entered, finish = context.Event(), context.Event()
        results = context.Queue()
        process = context.Process(target=_blocked_capture, args=(str(self.root), entered, finish, results))
        process.start()
        try:
            self.assertTrue(entered.wait(15), "first fixture runner did not start")
            before = self.tree()
            with self.assertRaisesRegex(capture.CaptureError, "active or unfinished"):
                self.invoke()
            self.assertEqual(self.calls, [])
            self.assertEqual(self.tree(), before)
            self.assertFalse((self.out / capture.JOURNAL).exists())
            finish.set()
            process.join(15)
            self.assertFalse(process.is_alive(), "first fixture capture did not finish")
            self.assertEqual(process.exitcode, 0)
            status, first = results.get(timeout=5)
            self.assertEqual(status, "ok")
            self.assertEqual(first["sequence"], 1)
            self.assertEqual(first["exitCode"], 75)
            self.assertEqual((self.out / first["stdoutFile"]).read_bytes(), b"original output\n")
            self.assertFalse((self.out / capture.LOCK).exists())
            second = self.invoke()
            self.assertEqual(second["sequence"], 2)
            self.assertEqual(len(self.calls), 1)
            self.assertEqual([e["sequence"] for e in capture.read_journal(self.out)], [1, 2])
            self.assertEqual((self.out / first["stdoutFile"]).read_bytes(), b"original output\n")
        finally:
            finish.set()
            process.join(5)
            if process.is_alive():
                process.terminate()
                process.join(5)
            results.close()
            results.join_thread()
            process.close()

    def test_existing_stdout_is_preserved_and_refused_before_any_runner(self):
        self.out.mkdir()
        original = self.out / "0001-second.json"
        original.write_bytes(b"existing immutable stdout")
        with self.assertRaisesRegex(capture.CaptureError, "stdout already exists"):
            self.invoke()
        self.assertEqual(self.calls, [])
        self.assertEqual(original.read_bytes(), b"existing immutable stdout")
        self.assertFalse((self.out / capture.JOURNAL).exists())
        self.assertTrue((self.out / capture.LOCK).exists())
        before = self.tree()
        with self.assertRaisesRegex(capture.CaptureError, "active or unfinished"):
            self.invoke("different-label")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.tree(), before)

    def test_runner_timeout_retains_unknown_lock_and_never_replays(self):
        def timeout(argv, **kwargs):
            self.calls.append(argv)
            raise subprocess.TimeoutExpired(argv, 1)

        with self.assertRaises(subprocess.TimeoutExpired):
            self.invoke(runner=timeout)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual((self.out / "0001-second.json").read_bytes(), b"")
        before = self.tree()
        with self.assertRaisesRegex(capture.CaptureError, "active or unfinished"):
            self.invoke()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.tree(), before)
        self.assertFalse((self.out / capture.JOURNAL).exists())

    def test_actual_process_crash_retains_lock_without_pid_or_age_reclaim(self):
        context = multiprocessing.get_context("spawn")
        process = context.Process(target=_crashed_capture, args=(str(self.root),))
        process.start()
        try:
            process.join(15)
            self.assertFalse(process.is_alive(), "fixture did not reach its crash")
            self.assertEqual(process.exitcode, 23)
            self.assertEqual((self.root / "runner-dispatched").read_bytes(), b"one fixture dispatch")
            self.assertTrue((self.out / capture.LOCK).exists())
            self.assertEqual((self.out / "0001-crashed.json").read_bytes(), b"")
            before = self.tree()
            with self.assertRaisesRegex(capture.CaptureError, "active or unfinished"):
                self.invoke()
            self.assertEqual(self.calls, [])
            self.assertEqual(self.tree(), before)
            self.assertFalse((self.out / capture.JOURNAL).exists())
        finally:
            if process.is_alive():
                process.terminate()
                process.join(5)
            process.close()

    def test_preexisting_unreadable_lock_is_not_repaired_or_reclaimed(self):
        self.out.mkdir()
        lock = self.out / capture.LOCK
        lock.write_bytes(b"incomplete legacy or crashed lock")
        os.utime(lock, (1, 1))
        before = self.tree()
        with self.assertRaisesRegex(capture.CaptureError, "active or unfinished"):
            self.invoke()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.tree(), before)

    def test_failure_after_stdout_retains_bytes_and_lock_without_another_dispatch(self):
        with patch.object(capture, "host_facts", side_effect=OSError("fixture metadata failure")):
            with self.assertRaises(OSError):
                self.invoke()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual((self.out / "0001-second.json").read_bytes(), b"fixture output")
        self.assertFalse((self.out / capture.JOURNAL).exists())
        before = self.tree()
        with self.assertRaisesRegex(capture.CaptureError, "active or unfinished"):
            self.invoke()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.tree(), before)

    def test_journal_sync_failure_keeps_lock_even_when_the_entry_is_visible(self):
        real_sync = os.fsync
        syncs = []

        def sync(fd):
            syncs.append(fd)
            if len(syncs) == 3:  # lock, stdout, then journal
                raise OSError("fixture journal sync failure")
            return real_sync(fd)

        with patch.object(capture.os, "fsync", side_effect=sync):
            with self.assertRaises(OSError):
                self.invoke()
        self.assertEqual(len(syncs), 3)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(capture.read_journal(self.out)[0]["sequence"], 1)
        self.assertEqual((self.out / "0001-second.json").read_bytes(), b"fixture output")
        before = self.tree()
        with self.assertRaisesRegex(capture.CaptureError, "active or unfinished"):
            self.invoke()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.tree(), before)

    def test_another_lock_is_not_deleted_after_our_complete_capture(self):
        def changed(argv, **kwargs):
            self.calls.append(argv)
            (self.out / capture.LOCK).write_bytes(b"foreign capture ownership")
            return subprocess.CompletedProcess(argv, 0, stdout=b"fixture output")

        with self.assertRaisesRegex(capture.CaptureError, "lock changed"):
            self.invoke(runner=changed)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual((self.out / capture.LOCK).read_bytes(), b"foreign capture ownership")
        self.assertEqual(capture.read_journal(self.out)[0]["sequence"], 1)
        before = self.tree()
        with self.assertRaisesRegex(capture.CaptureError, "active or unfinished"):
            self.invoke()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.tree(), before)


if __name__ == "__main__":
    unittest.main()
