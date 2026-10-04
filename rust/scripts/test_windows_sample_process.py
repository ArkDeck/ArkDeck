#!/usr/bin/env python3
"""Unit tests of `windows_sample_process.py` on synthetic sample roots only.

No test reads a real sample, runs `hdc` or touches a device. The synthetic roots have the shape
`windows-hdc-sample.ps1` and `windows-usb-sample.ps1` write (schemas `arkdeck-windows-hdc-sample/v2`
and `arkdeck-windows-usb-sample/v2`). Every identifier in them is invented for the test.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import windows_sample_process as processing  # noqa: E402

KEY = "7001005458323933328a01bce0c2bd00"  # invented 32-character connect key
SERIAL = KEY  # the board's USB serial, equal to the key in the synthetic board
USER = "sampleuser"
MACHINE = "SAMPLEHOST"
PROFILE = rf"C:\Users\{USER}"
LOCAL = rf"C:\Users\{USER}\AppData\Local"
TOOL_DIR = r"D:\tools\hdc-drop"
TOOL_SHA = "f" * 64
ENVIRONMENT = {"USERPROFILE": PROFILE, "LOCALAPPDATA": LOCAL, "USERNAME": USER, "COMPUTERNAME": MACHINE}
TICKS = 639000000000000000


def owner(pid: int, ticks: int = TICKS) -> dict:
    return {"pid": pid, "alive": True, "name": "hdc", "parentPid": 4242,
            "path": rf"{TOOL_DIR}\hdc.exe", "sha256": TOOL_SHA, "startTimeUtcTicks": ticks}


def state(listening: bool) -> dict:
    if not listening:
        return {"observedAtUtc": "2026-09-30T00:00:00Z", "listeners8710": [], "listenerOwners": [],
                "hdcProcesses": []}
    return {"observedAtUtc": "2026-09-30T00:00:01Z",
            "listeners8710": [{"localAddress": "127.0.0.1", "localPort": 8710, "pid": 5150}],
            "listenerOwners": [owner(5150)], "hdcProcesses": [owner(5150)]}


class Sample:
    """A synthetic HDC root under a temporary directory."""

    def __init__(self, base: Path) -> None:
        self.root = base / "hdc-c1"
        self.root.mkdir()
        (self.root / "selected-tool.sha256").write_text(TOOL_SHA, encoding="ascii")
        (self.root / "server-started-by-sampling.json").write_text(json.dumps(state(True)), encoding="utf-8")

    def phase(self, phase: str, commands: list[tuple[str, list[str], bytes, bytes, bool, bool]]) -> None:
        directory = self.root / phase
        directory.mkdir()
        entries = []
        for name, argv, stdout, stderr, before, after in commands:
            (directory / f"{name}.stdout.bin").write_bytes(stdout)
            (directory / f"{name}.stderr.bin").write_bytes(stderr)
            entries.append({
                "name": name, "argv": argv, "exitCode": 0, "timedOut": False, "durationMs": 12.5,
                "streamsClosedWithin5s": True, "stdoutBytes": len(stdout),
                "stdoutSha256": processing.sha256(stdout), "stderrBytes": len(stderr),
                "stderrSha256": processing.sha256(stderr), "stdoutHasCR": b"\r" in stdout,
                "serverBefore": state(before), "serverAfter": state(after),
            })
        record = {
            "schema": "arkdeck-windows-hdc-sample/v2", "phase": phase,
            "capturedAtUtc": "2026-09-30T00:00:00Z",
            "os": {"Caption": "Microsoft Windows 11 Pro", "Version": "10.0.26200", "BuildNumber": "26200",
                   "OSArchitecture": "64-bit"},
            "powershell": "7.5.0",
            "environment": {"ohosHdc": {}, "hdcOnPath": [rf"{LOCAL}\Programs\hdc\hdc.exe"]},
            "tool": {
                "path": rf"{TOOL_DIR}\hdc.exe", "sha256": TOOL_SHA, "bytes": 5448704,
                "lastWriteTimeUtc": "2001-01-01T00:00:00Z",
                "versionResource": {"fileVersion": "1.0.0.0", "originalFilename": "WinPthreadGC"},
                "authenticodeStatus": "NotSigned", "signerSubject": None, "markOfTheWeb": True,
                "zoneIdentifier": "[ZoneTransfer]\r\nZoneId=3\r\nReferrerUrl=https://example.test/a\r\n"
                                  "HostUrl=https://downloads.example.test/hdc.zip?user=sampleuser\r\n",
                "siblingFiles": [{"name": "libusb_shared.dll", "bytes": 202240, "sha256": "e" * 64,
                                  "authenticodeStatus": "NotSigned"}],
            },
            "serverBefore": state(False), "commands": entries, "refused": None,
            "serverAfter": state(True),
        }
        (directory / "sample.json").write_text(json.dumps(record), encoding="utf-8")


def standard_sample(base: Path, empty_terminator: bytes = b"\r\n") -> Sample:
    sample = Sample(base)
    row = f"{KEY}\t\tUSB\t{{}}\tlocalhost\n"
    sample.phase("no-board", [
        ("version", ["-v"], b"Ver: 3.2.0x\r\n", b"", False, False),
        ("checkserver-no-server", ["checkserver"], b"Client version:Ver: 3.2.0x, server version:Ver: 3.2.0x\r\n",
         b"", False, True),
        ("list-targets-first", ["list", "targets", "-v"], b"[Empty]" + empty_terminator, b"", True, True),
        ("list-targets-empty", ["list", "targets", "-v"], b"[Empty]" + empty_terminator, b"", True, True),
        ("checkserver-server-up", ["checkserver"], b"Client version:Ver: 3.2.0x, server version:Ver: 3.2.0x\r\n",
         b"", True, True),
    ])
    sample.phase("board-connected", [
        ("list-targets-board-connected", ["list", "targets", "-v"], row.format("Connected").encode(), b"",
         True, True),
    ])
    sample.phase("board-removed", [
        ("list-targets-board-removed", ["list", "targets", "-v"], row.format("Offline").encode(), b"",
         True, True),
    ])
    return sample


class HdcProcessing(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.base = Path(self.scratch.name)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def everything(self, directory: Path) -> bytes:
        return b"".join(p.read_bytes() for p in sorted(directory.rglob("*")) if p.is_file())

    def test_keys_become_same_length_runs_and_every_other_byte_is_kept(self) -> None:
        sample = standard_sample(self.base)
        out = self.base / "out"
        processing.process_hdc(sample.root, "c1", TOOL_DIR, out, ENVIRONMENT)
        connected = (out / "board-connected" / "list-targets-board-connected.stdout.bin").read_bytes()
        self.assertEqual(connected, ("a" * 32 + "\t\tUSB\tConnected\tlocalhost\n").encode())
        raw = (sample.root / "board-connected" / "list-targets-board-connected.stdout.bin").read_bytes()
        self.assertEqual(len(connected), len(raw))
        # CR/LF bytes survive exactly.
        self.assertEqual((out / "no-board" / "list-targets-empty.stdout.bin").read_bytes(), b"[Empty]\r\n")
        blob = self.everything(out)
        for secret in (KEY.encode(), USER.encode(), MACHINE.encode(), TOOL_DIR.encode()):
            self.assertNotIn(secret.lower(), blob.lower())
        # No hash of the raw key-bearing bytes survives; the redacted hash does.
        self.assertNotIn(processing.sha256(raw).encode(), blob)
        record = json.loads((out / "board-connected" / "sample.json").read_text(encoding="utf-8"))
        self.assertEqual(record["commands"][0]["stdoutRedactedSha256"], processing.sha256(connected))
        self.assertTrue(record["commands"][0]["keyRedacted"])

    def test_tool_facts_paths_zone_and_process_ids_are_reduced(self) -> None:
        out = self.base / "out"
        processing.process_hdc(standard_sample(self.base).root, "c1", TOOL_DIR, out, ENVIRONMENT)
        tool = json.loads((out / "tool.json").read_text(encoding="utf-8"))
        self.assertEqual(tool["path"], r"<candidate-1-dir>\hdc.exe")
        self.assertEqual(tool["zoneIdentifier"], {"zoneId": "3", "hostUrlHost": "downloads.example.test"})
        self.assertEqual(tool["environment"]["hdcOnPath"], [r"%LOCALAPPDATA%\Programs\hdc\hdc.exe"])
        record = json.loads((out / "no-board" / "sample.json").read_text(encoding="utf-8"))
        owners = record["commands"][1]["serverAfter"]["listenerOwners"]
        self.assertEqual(owners[0]["pid"], "pid-1")
        self.assertEqual(owners[0]["startSeconds"], 0.0)
        self.assertTrue(owners[0]["imageIsSelectedTool"])
        self.assertNotIn(b"5150", self.everything(out))

    def test_the_comparison_states_what_was_found(self) -> None:
        out = self.base / "out"
        summary = processing.process_hdc(standard_sample(self.base).root, "c1", TOOL_DIR, out, ENVIRONMENT)
        topics = {row["topic"]: row for row in summary["comparison"]}
        self.assertTrue(topics["`-v` stdout form"]["sameAsMacos"])
        self.assertTrue(topics["`list-targets-empty` (no board)"]["sameAsMacos"])
        self.assertTrue(topics["`list targets -v`, board connected"]["sameAsMacos"])
        self.assertTrue(topics["`list targets -v`, board removed"]["sameAsMacos"])
        self.assertIn("started by no-board/checkserver-no-server", topics["server identity"]["windows"])
        self.assertEqual(summary["connectKeys"], {"count": 1, "lengths": [32],
                                                  "characterClasses": ["digit", "lower"]})
        self.assertEqual(summary["anomalies"], [])

    def test_windows_differences_are_reported_not_smoothed(self) -> None:
        sample = standard_sample(self.base, empty_terminator=b"\n")
        sample.phase("stop-server", [("kill-server", ["kill"], b"", b"Kill server finish\r\n", True, False)])
        out = self.base / "out"
        summary = processing.process_hdc(sample.root, "c1", TOOL_DIR, out, ENVIRONMENT)
        topics = {row["topic"]: row for row in summary["comparison"]}
        self.assertFalse(topics["`list-targets-empty` (no board)"]["sameAsMacos"])
        self.assertIn("LF", topics["`list-targets-empty` (no board)"]["windows"])
        self.assertIn("stop-server/kill-server: stderr 20 B", summary["anomalies"])

    def test_zero_bytes_is_unknown_not_empty(self) -> None:
        facts = processing.classify_list(b"", b"", 0)
        self.assertEqual(facts["form"], "zeroBytes")
        self.assertEqual(processing.classify_list(b"[Empty]\r\n", b"", 0)["form"], "emptyMarker")
        rows = processing.classify_list(b"k\tn\tUSB\tConnected\tlocalhost\r\n", b"", 0)
        self.assertEqual(rows["rowTerminators"], ["CRLF"])
        self.assertFalse(rows["carriageReturnInsideField"])

    def test_a_secret_left_in_an_output_refuses_and_removes_the_output(self) -> None:
        sample = standard_sample(self.base)
        # A user path inside command output cannot be redacted to the same length.
        (sample.root / "no-board" / "version.stdout.bin").write_bytes(rf"Ver: 3.2.0x {PROFILE}".encode() + b"\r\n")
        out = self.base / "out"
        with self.assertRaises(processing.Leak):
            processing.process_hdc(sample.root, "c1", TOOL_DIR, out, ENVIRONMENT)

    def test_the_scan_catches_what_redaction_missed(self) -> None:
        redactor = processing.Redactor()
        redactor.secret(KEY)
        directory = self.base / "scan"
        directory.mkdir()
        (directory / "file.json").write_text(json.dumps({"note": KEY.upper()}), encoding="utf-8")
        with self.assertRaises(processing.Leak):
            redactor.scan(directory)
        (directory / "file.json").write_text("{}", encoding="utf-8")
        redactor.scan(directory, ["0" * 64])
        (directory / "file.json").write_text("0" * 64, encoding="utf-8")
        with self.assertRaises(processing.Leak):
            redactor.scan(directory, ["0" * 64])

    def test_uart_rows_are_kept_and_only_the_board_key_is_redacted(self) -> None:
        # Windows hdc lists the host's serial ports as UART targets, in six CRLF columns.
        uart = b"COM1\t\tUART\tReady\tunknown...\thdc\r\nCOM2\t\tUART\tReady\tunknown...\thdc\r\n"
        board = f"{KEY}\t\tUSB\tConnected\tlocalhost\thdc\r\n".encode()
        sample = Sample(self.base)
        sample.phase("no-board", [
            ("version", ["-v"], b"Ver: 3.2.0x\r\n", b"", False, False),
            ("list-targets-first", ["list", "targets", "-v"], uart, b"", True, True),
        ])
        sample.phase("board-connected", [
            ("list-targets-board-connected", ["list", "targets", "-v"], board + uart, b"", True, True),
        ])
        out = self.base / "out"
        summary = processing.process_hdc(sample.root, "c1", TOOL_DIR, out, ENVIRONMENT)
        self.assertEqual((out / "no-board" / "list-targets-first.stdout.bin").read_bytes(), uart)
        self.assertEqual((out / "board-connected" / "list-targets-board-connected.stdout.bin").read_bytes(),
                         ("a" * 32 + "\t\tUSB\tConnected\tlocalhost\thdc\r\n").encode() + uart)
        self.assertEqual(summary["connectKeys"], {"count": 1, "lengths": [32],
                                                  "characterClasses": ["digit", "lower"]})
        record = json.loads((out / "no-board" / "sample.json").read_text(encoding="utf-8"))
        self.assertFalse(record["commands"][1]["keyRedacted"])

    def test_an_existing_output_is_never_overwritten(self) -> None:
        out = self.base / "out"
        out.mkdir()
        with self.assertRaises(SystemExit):
            processing.process_hdc(standard_sample(self.base).root, "c1", TOOL_DIR, out, ENVIRONMENT)


def node(instance: str, present: bool, **properties) -> dict:
    return {"instanceId": instance, "present": present, "class": "USB", "friendlyName": None,
            "status": "OK" if present else "Unknown", "problem": "", "propertyReadFailed": False,
            "properties": {key: {"type": "String", "data": value} for key, value in properties.items()}}


BOARD = rf"USB\VID_2207&PID_5000\{SERIAL}"
INTERFACE = r"USB\VID_2207&PID_5000&MI_00\6&1a2b3c4d&0&0000"
HUB = r"USB\ROOT_HUB30\4&11223344&0&0"
OTHER = r"USB\VID_046D&PID_C52B\OTHERSERIAL123"


def usb_sample(base: Path, port: str = "USB(3)") -> Path:
    root = base / "usb"
    root.mkdir()

    def phase(name: str, present: bool, arrival: str) -> None:
        board = node(BOARD, present,
                     DEVPKEY_Device_HardwareIds=[r"USB\VID_2207&PID_5000&REV_0100", r"USB\VID_2207&PID_5000"],
                     DEVPKEY_Device_LocationPaths=[f"PCIROOT(0)#PCI(1400)#USBROOT(0)#{port}"],
                     DEVPKEY_Device_LocationInfo="Port_#0003.Hub_#0001",
                     DEVPKEY_Device_BusReportedDeviceDesc="rk3568",
                     DEVPKEY_Device_Parent=HUB,
                     DEVPKEY_Device_ContainerId="{0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0}",
                     DEVPKEY_Device_LastArrivalDate=arrival,
                     DEVPKEY_Device_Service="usbccgp")
        interface = node(INTERFACE, present, DEVPKEY_Device_Parent=BOARD, DEVPKEY_Device_Service="WinUSB")
        hub = node(HUB, True, DEVPKEY_Device_Children=[BOARD, OTHER],
                   DEVPKEY_Device_Parent=r"PCI\VEN_8086&DEV_A0ED&SUBSYS_00000000&REV_20\3&11583659&0&A0")
        other = node(OTHER, True, DEVPKEY_Device_Parent=HUB,
                     DEVPKEY_Device_BusReportedDeviceDesc="USB Receiver",
                     DEVPKEY_Device_DriverInfPath=rf"{PROFILE}\drivers\x.inf")
        record = {"schema": "arkdeck-windows-usb-sample/v2", "phase": name,
                  "rockchipNodes": [board, interface],
                  "presentUsbNodes": [hub, other] + ([board, interface] if present else [])}
        (root / f"usb-{name}.json").write_text(json.dumps(record), encoding="utf-8")

    phase("before", False, "2026-09-29T10:00:00Z")
    phase("after", True, "2026-09-30T10:00:00Z")
    phase("removed", False, "2026-09-30T10:00:00Z")
    phase("replugged", True, "2026-09-30T10:05:00Z")
    return root


class UsbProcessing(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.base = Path(self.scratch.name)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def test_only_the_board_chain_is_kept_and_the_serial_is_redacted(self) -> None:
        hdc = standard_sample(self.base)
        out = self.base / "usb-out"
        summary = processing.process_usb(usb_sample(self.base), [hdc.root], out, ENVIRONMENT)
        blob = b"".join(p.read_bytes() for p in out.rglob("*") if p.is_file())
        for secret in (SERIAL.encode(), b"046D", b"OTHERSERIAL123", b"USB Receiver", USER.encode(),
                       b"0f1e2d3c"):
            self.assertNotIn(secret.lower(), blob.lower(), secret)
        after = json.loads((out / "usb-after.json").read_text(encoding="utf-8"))
        ids = [n["instanceId"] for n in after["nodes"]]
        self.assertIn(r"USB\VID_2207&PID_5000" + "\\" + "a" * 32, ids)
        self.assertIn(HUB, ids)
        hub = next(n for n in after["nodes"] if n["instanceId"] == HUB)
        self.assertEqual(hub["properties"]["DEVPKEY_Device_Children"]["data"],
                         [r"USB\VID_2207&PID_5000" + "\\" + "a" * 32])
        self.assertEqual(hub["properties"]["DEVPKEY_Device_Parent"]["data"], "<other-device>")
        self.assertEqual(summary["suffixKinds"], ["serial"])
        self.assertEqual(summary["serials"], [{"length": 32, "characterClasses": ["digit", "lower"],
                                               "equalsConnectKey": True, "equalsConnectKeyIgnoringCase": True}])
        self.assertTrue(summary["locationSurvivesReplugSamePort"])
        self.assertEqual(summary["phases"]["after"]["interfaceNodes"], 1)
        self.assertEqual(summary["phases"]["replugged"]["arrivalOrder"], {"order": 2})

    def test_the_hub_chain_is_kept_when_windows_lower_cases_its_id(self) -> None:
        # As sampled: the hub's own instance ID spells its suffix `4&1A2B3C4D&0&0`, while the
        # board's `Parent` and the hub's `Children` spell suffixes in lower case.
        root = usb_sample(self.base)
        hub = r"USB\ROOT_HUB30\4&1A2B3C4D&0&0"
        parent = r"USB\ROOT_HUB30\4&1a2b3c4d&0&0"
        board_upper = rf"USB\VID_2207&PID_5000\{SERIAL.upper()}"
        for path in root.glob("usb-*.json"):
            record = json.loads(path.read_text(encoding="utf-8"))
            for n in record["rockchipNodes"] + record["presentUsbNodes"]:
                if n["instanceId"] == HUB:
                    n["instanceId"] = hub
                    n["properties"]["DEVPKEY_Device_Children"]["data"] = [BOARD, r"USB\VID_046D&PID_C52B\5&2c3d&0&5"]
                elif n["properties"].get("DEVPKEY_Device_Parent", {}).get("data") == HUB:
                    n["properties"]["DEVPKEY_Device_Parent"]["data"] = parent
                if n["instanceId"] == BOARD:
                    n["instanceId"] = board_upper
                elif n["properties"].get("DEVPKEY_Device_Parent", {}).get("data") == BOARD:
                    n["properties"]["DEVPKEY_Device_Parent"]["data"] = board_upper
            path.write_text(json.dumps(record), encoding="utf-8")
        hdc = standard_sample(self.base)
        out = self.base / "usb-out"
        summary = processing.process_usb(root, [hdc.root], out, ENVIRONMENT)
        self.assertEqual(summary["serials"], [{"length": 32, "characterClasses": ["digit", "upper"],
                                               "equalsConnectKey": False, "equalsConnectKeyIgnoringCase": True}])
        after = json.loads((out / "usb-after.json").read_text(encoding="utf-8"))
        nodes = {n["instanceId"]: n for n in after["nodes"]}
        self.assertIn(hub, nodes)
        board = nodes[r"USB\VID_2207&PID_5000" + "\\" + "a" * 32]
        self.assertEqual(board["properties"]["DEVPKEY_Device_Parent"]["data"], parent)
        self.assertEqual(nodes[hub]["properties"]["DEVPKEY_Device_Children"]["data"],
                         [r"USB\VID_2207&PID_5000" + "\\" + "a" * 32])
        self.assertNotIn(b"5&2c3d&0&5", (out / "usb-after.json").read_bytes().lower())

    def test_hardware_and_compatible_ids_are_kept(self) -> None:
        root = usb_sample(self.base)
        for path in root.glob("usb-*.json"):
            record = json.loads(path.read_text(encoding="utf-8"))
            for n in record["rockchipNodes"] + record["presentUsbNodes"]:
                if n["instanceId"] == BOARD:
                    n["properties"]["DEVPKEY_Device_CompatibleIds"] = {
                        "type": "StringList", "data": [r"USB\MS_COMP_WINUSB", r"USB\Class_FF&SubClass_50"]}
            path.write_text(json.dumps(record), encoding="utf-8")
        out = self.base / "usb-out"
        summary = processing.process_usb(root, [], out, ENVIRONMENT)
        self.assertEqual(summary["phases"]["after"]["hardwareIds"],
                         [r"USB\VID_2207&PID_5000&REV_0100", r"USB\VID_2207&PID_5000"])
        after = json.loads((out / "usb-after.json").read_text(encoding="utf-8"))
        board = next(n for n in after["nodes"] if n["instanceId"].startswith(r"USB\VID_2207&PID_5000" + "\\"))
        self.assertEqual(board["properties"]["DEVPKEY_Device_CompatibleIds"]["data"],
                         [r"USB\MS_COMP_WINUSB", r"USB\Class_FF&SubClass_50"])

    def test_guid_labels_are_closed(self) -> None:
        out = self.base / "usb-out"
        processing.process_usb(usb_sample(self.base), [], out, ENVIRONMENT)
        after = json.loads((out / "usb-after.json").read_text(encoding="utf-8"))
        board = next(n for n in after["nodes"] if n["instanceId"].startswith(r"USB\VID_2207&PID_5000" + "\\"))
        self.assertRegex(board["properties"]["DEVPKEY_Device_ContainerId"]["data"], r"^<container-\d+>$")
        labels = processing.Labels("pid")
        self.assertEqual(labels(5150), "pid-1")

    def test_a_port_derived_suffix_is_no_serial(self) -> None:
        root = usb_sample(self.base)
        for path in root.glob("usb-*.json"):
            text = path.read_text(encoding="utf-8").replace(SERIAL, "5&2c3d4e5f&0&3")
            path.write_text(text, encoding="utf-8")
        summary = processing.process_usb(root, [], self.base / "usb-out", ENVIRONMENT)
        self.assertEqual(summary["suffixKinds"], ["portDerived"])
        self.assertEqual(summary["serials"], [])


class Rendering(unittest.TestCase):
    def test_run_records_hold_no_secret(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            base = Path(scratch)
            hdc = standard_sample(base)
            processing.process_hdc(hdc.root, "c1", TOOL_DIR, base / "c1", ENVIRONMENT)
            processing.process_usb(usb_sample(base), [hdc.root], base / "usb-out", ENVIRONMENT)
            written = processing.render([base / "c1"], base / "usb-out", "20260930", base / "records")
            self.assertEqual([p.name for p in written],
                             ["hdc-windows-sample-20260930-run.md", "dayu200-usb-properties-20260930-run.md"])
            text = "".join(p.read_text(encoding="utf-8") for p in written)
            for secret in (KEY, USER, MACHINE, TOOL_DIR, "OTHERSERIAL123"):
                self.assertNotIn(secret.lower(), text.lower())
            self.assertIn("| c1 | `" + TOOL_SHA + "` | `Ver: 3.2.0x` | CRLF |", text)


if __name__ == "__main__":
    unittest.main()
