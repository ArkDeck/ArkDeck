#!/usr/bin/env python3
"""Exercise the UI-test input-source guard without changing macOS settings."""

from __future__ import annotations

from contextlib import redirect_stderr
from dataclasses import replace
import importlib.util
import io
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "ui_test_input_source", Path(__file__).with_name("ui_test_input_source.py")
)
guard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = guard
SPEC.loader.exec_module(guard)

US = guard.InputSource("com.apple.keylayout.US", "U.S.", True, True, True, True)
ABC = replace(US, source_id="com.apple.keylayout.ABC", name="ABC")
IME = guard.InputSource("example.inputmethod", "Example IME", True, True, True, False)


class FakeInputSources:
    def __init__(self, events: list, properties: dict | None = None) -> None:
        self.events = events
        self.available = [IME, US]
        self.selected = IME
        self.properties = properties
        self.pin_error = None
        self.restore_error = None
        self.ignore_pin = False

    def sources(self) -> list:
        return list(self.available)

    def current(self):
        return self.selected

    def select(self, source_id: str) -> None:
        self.events.append(("select", source_id))
        if source_id == US.source_id and self.pin_error:
            raise self.pin_error
        if source_id == IME.source_id and self.restore_error:
            raise self.restore_error
        if source_id != US.source_id or not self.ignore_pin:
            self.selected = next(source for source in self.available if source.source_id == source_id)

    def read_global_properties(self) -> dict | None:
        return None if self.properties is None else dict(self.properties)

    def write_global_properties(self, value: dict | None) -> None:
        self.events.append(("preference", value))
        self.properties = None if value is None else dict(value)


class FakeChild:
    pid = 12345

    def __init__(self, events: list, status: int = 0, on_wait=None) -> None:
        self.events = events
        self.status = status
        self.on_wait = on_wait
        self.returncode = None

    def poll(self):
        return self.returncode

    def wait(self, timeout=None) -> int:
        self.events.append(("wait", timeout))
        callback, self.on_wait = self.on_wait, None
        if callback:
            callback()
        self.returncode = self.status
        self.events.append(("reaped", self.status))
        return self.status


class InputSourceGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.events = []
        self.backend = FakeInputSources(self.events, {guard.PER_CONTEXT: True, "other": "keep"})
        self.child = FakeChild(self.events)
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        self.lock_path = str(Path(temporary) / "host.lock")
        self.output = self.enterContext(redirect_stderr(io.StringIO()))
        self.handlers = {number: signal.getsignal(number)
                         for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}

    def tearDown(self) -> None:
        for number, handler in self.handlers.items():
            self.assertEqual(signal.getsignal(number), handler)

    def spawn(self, command, *, env, start_new_session):
        self.events.append(("spawn", command))
        self.assertTrue(start_new_session)
        self.assertEqual(env[guard.GUARDED_ENV], "1")
        self.assertEqual(self.backend.selected, US)
        self.assertEqual(self.backend.properties[guard.PER_CONTEXT], 0)
        return self.child

    def run_guard(self, popen=None) -> int:
        return guard.run_command(
            ["xcodebuild", "test"], self.backend,
            popen=popen or self.spawn,
            killpg=lambda pid, number: self.events.append(("killpg", pid, number)),
            lock_path=self.lock_path,
        )

    def assert_restored(self) -> None:
        self.assertEqual(self.backend.selected, IME)
        self.assertEqual(self.backend.properties[guard.PER_CONTEXT], True)
        self.assertEqual(self.events[-2][0:2], ("select", IME.source_id))
        self.assertEqual(self.events[-1][0], "preference")

    def test_pins_before_child_and_restores_after_child_exit(self) -> None:
        self.assertEqual(self.run_guard(), 0)
        self.assert_restored()
        self.assertLess(self.events.index(("select", US.source_id)),
                        self.events.index(("spawn", ["xcodebuild", "test"])))
        self.assertLess(self.events.index(("reaped", 0)),
                        self.events.index(("select", IME.source_id)))
        self.assertEqual(self.backend.properties["other"], "keep")

    def test_child_failure_keeps_exit_code_and_restores(self) -> None:
        self.child.status = 65
        self.assertEqual(self.run_guard(), 65)
        self.assert_restored()

    def test_child_signal_uses_shell_exit_status(self) -> None:
        self.child.status = -signal.SIGTERM
        self.assertEqual(self.run_guard(), 128 + signal.SIGTERM)
        self.assert_restored()

    def test_spawn_failure_restores_and_propagates(self) -> None:
        def fail(*args, **kwargs):
            raise OSError("missing executable")

        with self.assertRaisesRegex(OSError, "missing executable"):
            self.run_guard(fail)
        self.assert_restored()

    def test_wait_error_terminates_and_reaps_before_restoring(self) -> None:
        def fail():
            raise RuntimeError("wait failed")

        self.child.on_wait = fail
        with self.assertRaisesRegex(RuntimeError, "wait failed"):
            self.run_guard()
        self.assertIn(("killpg", self.child.pid, signal.SIGTERM), self.events)
        self.assertLess(self.events.index(("reaped", 0)),
                        self.events.index(("select", IME.source_id)))
        self.assert_restored()

    def test_keyboard_interrupt_terminates_and_reaps_before_restoring(self) -> None:
        def interrupt():
            raise KeyboardInterrupt

        self.child.on_wait = interrupt
        self.assertEqual(self.run_guard(), 130)
        self.assertIn(("killpg", self.child.pid, signal.SIGINT), self.events)
        self.assertLess(self.events.index(("reaped", 0)),
                        self.events.index(("select", IME.source_id)))
        self.assert_restored()

    def test_sigterm_during_spawn_still_terminates_returned_child(self) -> None:
        def spawn_and_cancel(*args, **kwargs):
            child = self.spawn(*args, **kwargs)
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
            return child

        self.assertEqual(self.run_guard(spawn_and_cancel), 143)
        self.assertIn(("killpg", self.child.pid, signal.SIGTERM), self.events)
        self.assertLess(self.events.index(("reaped", 0)),
                        self.events.index(("select", IME.source_id)))
        self.assert_restored()

    def test_sigterm_during_wait_escalates_unresponsive_child_then_restores(self) -> None:
        def unresponsive():
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
            self.child.on_wait = timeout_once
            raise subprocess.TimeoutExpired("xcodebuild", 0.25)

        def timeout_once():
            raise subprocess.TimeoutExpired("xcodebuild", 5)

        self.child.on_wait = unresponsive
        self.assertEqual(self.run_guard(), 143)
        self.assertIn(("killpg", self.child.pid, signal.SIGTERM), self.events)
        self.assertIn(("killpg", self.child.pid, signal.SIGKILL), self.events)
        self.assertLess(self.events.index(("reaped", 0)),
                        self.events.index(("select", IME.source_id)))
        self.assert_restored()

    def test_sighup_cancels_child_and_restores(self) -> None:
        def hangup():
            signal.getsignal(signal.SIGHUP)(signal.SIGHUP, None)
            raise subprocess.TimeoutExpired("xcodebuild", 0.25)

        self.child.on_wait = hangup
        self.assertEqual(self.run_guard(), 128 + signal.SIGHUP)
        self.assertIn(("killpg", self.child.pid, signal.SIGHUP), self.events)
        self.assert_restored()

    def test_host_lock_conflict_changes_no_settings_and_starts_no_child(self) -> None:
        with guard.HostLock(self.lock_path):
            with self.assertRaisesRegex(guard.InputSourceError, "Another ArkDeck UI test session"):
                self.run_guard()
        self.assertEqual(self.events, [])
        self.assertEqual(self.run_guard(), 0)

    def test_host_lock_rejects_symlink_without_modifying_its_target(self) -> None:
        target = Path(self.lock_path).with_name("target")
        target.write_text("keep", encoding="utf-8")
        Path(self.lock_path).symlink_to(target)
        with self.assertRaises(OSError):
            self.run_guard()
        self.assertEqual(target.read_text(encoding="utf-8"), "keep")
        self.assertEqual(self.events, [])

    def test_host_lock_rejects_nonprivate_file(self) -> None:
        lock = Path(self.lock_path)
        lock.touch(mode=0o644)
        with self.assertRaisesRegex(guard.InputSourceError, "not a private regular file"):
            self.run_guard()
        self.assertEqual(self.events, [])

    def test_current_disabled_source_is_never_restored(self) -> None:
        self.backend.selected = replace(IME, enabled=False)
        self.assertEqual(self.run_guard(), 0)
        self.assertNotIn(("select", IME.source_id), self.events)
        self.assertEqual(self.backend.selected, US)

    def test_source_disabled_during_child_is_never_restored(self) -> None:
        def disable_ime():
            self.backend.available = [replace(IME, enabled=False), US]

        self.child.on_wait = disable_ime
        self.assertEqual(self.run_guard(), 0)
        self.assertNotIn(("select", IME.source_id), self.events)
        self.assertIn("no longer enabled", self.output.getvalue())
        self.assertEqual(self.backend.properties[guard.PER_CONTEXT], True)

    def test_pin_failure_never_starts_child_and_restores_preferences(self) -> None:
        self.backend.pin_error = guard.InputSourceError("status -50")
        with self.assertRaisesRegex(guard.InputSourceError, "status -50"):
            self.run_guard()
        self.assertFalse(any(event[0] == "spawn" for event in self.events))
        self.assert_restored()

    def test_source_restore_failure_still_restores_preference_and_reports_failure(self) -> None:
        self.backend.restore_error = guard.InputSourceError("restore status -50")
        with self.assertRaisesRegex(guard.InputSourceError, "cannot restore previous input source.*status -50"):
            self.run_guard()
        self.assertEqual(self.child.returncode, 0)
        self.assertEqual(self.backend.properties, {guard.PER_CONTEXT: True, "other": "keep"})
        self.assertEqual(self.events[-1][0], "preference")

    def test_selection_must_be_verified_before_child_starts(self) -> None:
        self.backend.ignore_pin = True
        with self.assertRaisesRegex(guard.InputSourceError, "did not keep"):
            self.run_guard()
        self.assertFalse(any(event[0] == "spawn" for event in self.events))
        self.assert_restored()

    def test_missing_ascii_layout_leaves_settings_unchanged_and_starts_no_child(self) -> None:
        self.backend.available = [IME, replace(US, enabled=False)]
        with self.assertRaisesRegex(guard.InputSourceError, "No enabled, selectable ASCII"):
            self.run_guard()
        self.assertEqual(self.events, [])

    def test_layout_preference_excludes_input_methods_and_disabled_layouts(self) -> None:
        fallback = replace(US, source_id="com.apple.keylayout.British")
        self.assertEqual(guard.choose_layout([IME, fallback, ABC, US]), US)
        self.assertEqual(guard.choose_layout([IME, fallback, ABC, replace(US, enabled=False)]), ABC)
        self.assertEqual(guard.choose_layout([IME, fallback]), fallback)

    def test_restore_preserves_other_preferences_changed_while_child_runs(self) -> None:
        def edit_another_preference():
            self.backend.properties["other"] = "changed during tests"
            self.backend.properties["new"] = "retain"

        self.child.on_wait = edit_another_preference
        self.assertEqual(self.run_guard(), 0)
        self.assertEqual(self.backend.properties, {
            guard.PER_CONTEXT: True, "other": "changed during tests", "new": "retain",
        })

    def test_originally_unset_field_is_removed_without_losing_other_fields(self) -> None:
        self.backend.properties = {"other": "keep"}
        self.assertEqual(self.run_guard(), 0)
        self.assertEqual(self.backend.properties, {"other": "keep"})

    def test_originally_absent_dictionary_is_removed_after_run(self) -> None:
        self.backend.properties = None
        self.assertEqual(self.run_guard(), 0)
        self.assertIsNone(self.backend.properties)

    def test_already_disabled_context_switching_needs_no_preference_writes(self) -> None:
        self.backend.properties = {guard.PER_CONTEXT: 0, "other": "keep"}
        self.assertEqual(self.run_guard(), 0)
        self.assertFalse(any(event[0] == "preference" for event in self.events))


if __name__ == "__main__":
    unittest.main()
