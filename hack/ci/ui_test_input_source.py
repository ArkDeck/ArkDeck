#!/usr/bin/env python3
"""Run macOS UI tests with an enabled ASCII layout, then restore input settings.

Uses public Text Input Sources and CFPreferences APIs. It never enables or
disables an input source. ``--inspect`` only reads the current configuration.
"""

from __future__ import annotations

import ctypes
from dataclasses import asdict, dataclass
import fcntl
import json
import os
import plistlib
import signal
import stat
import subprocess
import sys


PREFERENCE = "AppleGlobalTextInputProperties"
PER_CONTEXT = "TextInputGlobalPropertyPerContextInput"
GUARDED_ENV = "ARKDECK_UI_TEST_INPUT_SOURCE_GUARDED"


class InputSourceError(RuntimeError):
    pass


@dataclass(frozen=True)
class InputSource:
    source_id: str
    name: str
    enabled: bool
    selectable: bool
    ascii_capable: bool
    keyboard_layout: bool


class MacInputSources:
    def __init__(self) -> None:
        if sys.platform != "darwin":
            raise InputSourceError("UI test input-source preparation requires macOS.")
        self.cf = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )
        self.tis = ctypes.CDLL(
            "/System/Library/Frameworks/Carbon.framework/Frameworks/"
            "HIToolbox.framework/HIToolbox"
        )
        pointer, index = ctypes.c_void_p, ctypes.c_long
        signatures = {
            "CFRelease": ([pointer], None),
            "CFArrayGetCount": ([pointer], index),
            "CFArrayGetValueAtIndex": ([pointer, index], pointer),
            "CFBooleanGetValue": ([pointer], ctypes.c_bool),
            "CFStringGetLength": ([pointer], index),
            "CFStringGetMaximumSizeForEncoding": ([index, ctypes.c_uint32], index),
            "CFStringGetCString": ([pointer, pointer, index, ctypes.c_uint32], ctypes.c_bool),
            "CFStringCreateWithCString": ([pointer, ctypes.c_char_p, ctypes.c_uint32], pointer),
            "CFDataCreate": ([pointer, pointer, index], pointer),
            "CFDataGetLength": ([pointer], index),
            "CFDataGetBytePtr": ([pointer], pointer),
            "CFPropertyListCreateData": ([pointer, pointer, index, index, pointer], pointer),
            "CFPropertyListCreateWithData": ([pointer, pointer, index, pointer, pointer], pointer),
            "CFPreferencesCopyValue": ([pointer, pointer, pointer, pointer], pointer),
            "CFPreferencesSetValue": ([pointer, pointer, pointer, pointer, pointer], None),
            "CFPreferencesSynchronize": ([pointer, pointer, pointer], ctypes.c_bool),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.cf, name)
            function.argtypes, function.restype = arguments, result
        for name, arguments, result in (
            ("TISCreateInputSourceList", [pointer, ctypes.c_ubyte], pointer),
            ("TISCopyCurrentKeyboardInputSource", [], pointer),
            ("TISGetInputSourceProperty", [pointer, pointer], pointer),
            ("TISSelectInputSource", [pointer], ctypes.c_int32),
        ):
            function = getattr(self.tis, name)
            function.argtypes, function.restype = arguments, result
        self.keys = {
            name: pointer.in_dll(self.tis, "kTISProperty" + name).value
            for name in (
                "InputSourceID", "LocalizedName", "InputSourceIsEnabled",
                "InputSourceIsSelectCapable", "InputSourceIsASCIICapable",
                "InputSourceType",
            )
        }
        self.layout_type = self._string(pointer.in_dll(self.tis, "kTISTypeKeyboardLayout").value)
        self.user = pointer.in_dll(self.cf, "kCFPreferencesCurrentUser").value
        self.host = pointer.in_dll(self.cf, "kCFPreferencesAnyHost").value

    def _string(self, value: int | None) -> str:
        if not value:
            return ""
        encoding = 0x08000100  # kCFStringEncodingUTF8
        size = self.cf.CFStringGetMaximumSizeForEncoding(
            self.cf.CFStringGetLength(value), encoding
        ) + 1
        buffer = ctypes.create_string_buffer(size)
        if not self.cf.CFStringGetCString(value, buffer, size, encoding):
            raise InputSourceError("Cannot decode a macOS input-source property.")
        return buffer.value.decode("utf-8")

    def _source(self, reference: int) -> InputSource:
        def property_value(name: str) -> int | None:
            return self.tis.TISGetInputSourceProperty(reference, self.keys[name])

        def boolean(name: str) -> bool:
            value = property_value(name)
            return bool(value and self.cf.CFBooleanGetValue(value))

        return InputSource(
            self._string(property_value("InputSourceID")),
            self._string(property_value("LocalizedName")),
            boolean("InputSourceIsEnabled"),
            boolean("InputSourceIsSelectCapable"),
            boolean("InputSourceIsASCIICapable"),
            self._string(property_value("InputSourceType")) == self.layout_type,
        )

    def sources(self) -> list[InputSource]:
        references = self.tis.TISCreateInputSourceList(None, False)
        if not references:
            raise InputSourceError("macOS did not return its enabled input sources.")
        try:
            return [
                self._source(self.cf.CFArrayGetValueAtIndex(references, i))
                for i in range(self.cf.CFArrayGetCount(references))
            ]
        finally:
            self.cf.CFRelease(references)

    def current(self) -> InputSource | None:
        reference = self.tis.TISCopyCurrentKeyboardInputSource()
        if not reference:
            return None
        try:
            return self._source(reference)
        finally:
            self.cf.CFRelease(reference)

    def select(self, source_id: str) -> None:
        # Re-enumerate immediately before selection: saved references can become
        # disabled while tests run. Selecting them must never re-enable them.
        references = self.tis.TISCreateInputSourceList(None, False)
        if not references:
            raise InputSourceError("macOS did not return its enabled input sources.")
        try:
            for i in range(self.cf.CFArrayGetCount(references)):
                reference = self.cf.CFArrayGetValueAtIndex(references, i)
                source = self._source(reference)
                if source.source_id == source_id and source.enabled and source.selectable:
                    status = self.tis.TISSelectInputSource(reference)
                    if status:
                        raise InputSourceError(f"Cannot select {source_id}: macOS status {status}.")
                    return
        finally:
            self.cf.CFRelease(references)
        raise InputSourceError(f"Input source {source_id} is no longer enabled and selectable.")

    def _preference(self, *, write: bool, value: dict | None = None) -> dict | None:
        application = self.cf.CFStringCreateWithCString(None, b"com.apple.HIToolbox", 0x08000100)
        key = self.cf.CFStringCreateWithCString(None, PREFERENCE.encode(), 0x08000100)
        references = [application, key]
        try:
            if write:
                property_list = None
                if value is not None:
                    encoded = plistlib.dumps(value, fmt=plistlib.FMT_BINARY)
                    data = self.cf.CFDataCreate(None, encoded, len(encoded))
                    references.append(data)
                    property_list = self.cf.CFPropertyListCreateWithData(None, data, 0, None, None)
                    if not property_list:
                        raise InputSourceError("Cannot encode the input-source preference.")
                    references.append(property_list)
                self.cf.CFPreferencesSetValue(key, property_list, application, self.user, self.host)
            if not self.cf.CFPreferencesSynchronize(application, self.user, self.host):
                raise InputSourceError("Cannot synchronize the input-source preference.")
            if write:
                return None
            property_list = self.cf.CFPreferencesCopyValue(key, application, self.user, self.host)
            if not property_list:
                return None
            references.append(property_list)
            data = self.cf.CFPropertyListCreateData(None, property_list, 200, 0, None)
            if not data:
                raise InputSourceError("Cannot read the input-source preference.")
            references.append(data)
            decoded = plistlib.loads(ctypes.string_at(
                self.cf.CFDataGetBytePtr(data), self.cf.CFDataGetLength(data)
            ))
            if not isinstance(decoded, dict):
                raise InputSourceError(f"{PREFERENCE} must be a dictionary; leaving it unchanged.")
            return decoded
        finally:
            for reference in reversed(references):
                if reference:
                    self.cf.CFRelease(reference)

    def read_global_properties(self) -> dict | None:
        return self._preference(write=False)

    def write_global_properties(self, value: dict | None) -> None:
        self._preference(write=True, value=value)


def choose_layout(sources: list[InputSource]) -> InputSource:
    candidates = [source for source in sources if (
        source.enabled and source.selectable and source.ascii_capable and source.keyboard_layout
    )]
    for preferred in ("com.apple.keylayout.US", "com.apple.keylayout.ABC"):
        for source in candidates:
            if source.source_id == preferred:
                return source
    if candidates:
        return candidates[0]
    raise InputSourceError(
        "No enabled, selectable ASCII keyboard layout is available. "
        "Add U.S. or ABC in System Settings > Keyboard > Text Input before running UI tests."
    )


class HostLock:
    """One guard per logged-in user, including runs from other worktrees."""

    def __init__(self, path: str | None = None) -> None:
        self.path = path or f"/tmp/arkdeck-ui-tests-{os.getuid()}.lock"
        self.descriptor: int | None = None

    def __enter__(self) -> HostLock:
        descriptor = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            metadata = os.fstat(descriptor)
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                    or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) & 0o077):
                raise InputSourceError(f"UI test lock is not a private regular file owned by this user: {self.path}")
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise InputSourceError(
                    "Another ArkDeck UI test session is using this user's keyboard. "
                    "Wait for it to finish before starting UI tests."
                ) from error
            self.descriptor = descriptor
            return self
        except BaseException:
            os.close(descriptor)
            raise

    def __exit__(self, *_args: object) -> None:
        if self.descriptor is not None:
            os.close(self.descriptor)
            self.descriptor = None
        # Keep the file: unlinking it would let a contender lock a new inode.


class Cancellation:
    def __init__(self) -> None:
        self.signum: int | None = None
        self.previous: dict = {}

    def __enter__(self) -> Cancellation:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            self.previous[signum] = signal.signal(signum, self.receive)
        return self

    def receive(self, signum: int, _frame: object) -> None:
        # Do not raise during Popen: it must return the child handle before
        # cancellation can terminate and reap that child.
        if self.signum is None:
            self.signum = signum

    def __exit__(self, *_args: object) -> None:
        for signum, handler in self.previous.items():
            signal.signal(signum, handler)


def stop_child(child: subprocess.Popen, signum: int, killpg=os.killpg) -> None:
    if child.poll() is not None:
        return
    try:
        killpg(child.pid, signum)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()


def run_command(command: list[str], backend: MacInputSources, *,
                popen=subprocess.Popen, killpg=os.killpg, lock_path: str | None = None) -> int:
    child = None
    previous_id = None
    original_properties = None
    restore_properties = False
    with HostLock(lock_path), Cancellation() as cancellation:
        try:
            sources = backend.sources()
            layout = choose_layout(sources)
            previous = backend.current()
            if previous and previous.enabled and any(
                source.source_id == previous.source_id and source.enabled and source.selectable
                for source in sources
            ):
                previous_id = previous.source_id
            original_properties = backend.read_global_properties()
            properties = dict(original_properties or {})
            if properties.get(PER_CONTEXT) != 0:
                properties[PER_CONTEXT] = 0
                restore_properties = True
                backend.write_global_properties(properties)
                if (backend.read_global_properties() or {}).get(PER_CONTEXT) != 0:
                    raise InputSourceError("Cannot turn off automatic per-document input-source switching.")
            backend.select(layout.source_id)
            current = backend.current()
            if not current or current.source_id != layout.source_id or not current.enabled:
                raise InputSourceError(f"macOS did not keep {layout.source_id} selected; UI tests were not started.")
            print(f"UI tests input source: {layout.source_id}", file=sys.stderr)
            if cancellation.signum:
                return 128 + cancellation.signum
            environment = os.environ.copy()
            environment[GUARDED_ENV] = "1"
            child = popen(command, env=environment, start_new_session=True)
            while not cancellation.signum:
                try:
                    status = child.wait(timeout=0.25)
                    if cancellation.signum:
                        return 128 + cancellation.signum
                    return status if status >= 0 else 128 - status
                except subprocess.TimeoutExpired:
                    pass
            stop_child(child, cancellation.signum, killpg)
            return 128 + cancellation.signum
        except KeyboardInterrupt:
            if child is not None:
                stop_child(child, signal.SIGINT, killpg)
            return 130
        except BaseException:
            if child is not None:
                stop_child(child, signal.SIGTERM, killpg)
            raise
        finally:
            # Restore the source before restoring per-document switching. Only
            # select a fresh enabled source; stale/disabled sources stay disabled.
            cleanup_errors = []
            if previous_id:
                try:
                    if any(source.source_id == previous_id and source.enabled and source.selectable
                           for source in backend.sources()):
                        backend.select(previous_id)
                    else:
                        print(f"UI tests: previous input source {previous_id} is no longer enabled; skipped restore.",
                              file=sys.stderr)
                except Exception as error:
                    cleanup_errors.append(f"cannot restore previous input source: {error}")
            if restore_properties:
                try:
                    properties = dict(backend.read_global_properties() or {})
                    if original_properties is not None and PER_CONTEXT in original_properties:
                        properties[PER_CONTEXT] = original_properties[PER_CONTEXT]
                    else:
                        properties.pop(PER_CONTEXT, None)
                    restored = properties if properties or original_properties is not None else None
                    backend.write_global_properties(restored)
                    if backend.read_global_properties() != restored:
                        raise InputSourceError("macOS did not preserve the restored preference.")
                except Exception as error:
                    cleanup_errors.append(f"cannot restore automatic input-source switching: {error}")
            if cleanup_errors:
                raise InputSourceError("; ".join(cleanup_errors))


def main(arguments: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if arguments is None else arguments
    if not arguments or arguments == ["--help"]:
        print("usage: ui_test_input_source.py --inspect | [--] command [args ...]")
        return 0 if arguments else 64
    try:
        backend = MacInputSources()
        if arguments == ["--inspect"]:
            current = backend.current()
            print(json.dumps({
                "current": asdict(current) if current else None,
                "enabled_sources": [asdict(source) for source in backend.sources()],
                PREFERENCE: backend.read_global_properties(),
            }, ensure_ascii=False, indent=2))
            return 0
        if arguments[0] == "--":
            arguments = arguments[1:]
        if not arguments:
            raise InputSourceError("No UI test command was supplied.")
        return run_command(arguments, backend)
    except (InputSourceError, OSError) as error:
        print(f"UI tests input-source guard failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
