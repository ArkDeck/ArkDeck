#!/usr/bin/env python3
"""Turn the maintainer's Windows HDC and DAYU200 USB sample roots into sanitized
fixtures and run records (CHG-2026-078 draft, TASK-WHR-001).

The raw roots are written by `rust/scripts/windows-hdc-sample.ps1` and
`rust/scripts/windows-usb-sample.ps1` outside every git work tree. They hold connect keys
(board serials), user paths, account and machine names and the identities of every other USB
device on the host. This script reads them and writes only redacted material, applying the
"What the agent does" rules of the two cribs:

- `evidence/runs/TASK-XPA-002/hdc-windows-sampling-crib-20260930.md`
- `evidence/runs/TASK-XPA-004/dayu200-usb-properties-crib-20260930.md`

Redaction rules:

- **Connect keys and serials.** Every occurrence is replaced by a same-length run of `a`, and
  every other byte (tabs, CR, LF, state literals) is kept. Only lengths and character classes
  are recorded, never a value or a hash of one. No SHA-256 of raw bytes that held a key is
  written; only the redacted bytes' SHA-256 and the raw byte count.
- **User paths.** They become `%USERPROFILE%` / `%LOCALAPPDATA%`-relative. A candidate's tool
  directory becomes `<candidate-N-dir>`. Account and machine names never appear.
- **Zone.Identifier.** It is reduced to `ZoneId` and the host of `HostUrl`.
- **Process ids and GUIDs.** They become stable labels (`pid-1`, `<container-1>`).
- **Times.** Absolute times become order and deltas (seconds from the first observation).
- **Other USB devices.** Only the DAYU200 (VID_2207), its interfaces and its hub chain are kept;
  every other device is dropped.

Every written file is scanned for each secret before the command succeeds. A leak removes the
output and fails. The script never runs `hdc`, never touches a device and never writes into the
raw roots.

Usage (Windows or any host with the raw roots):

    windows_sample_process.py hdc --root RAW --label c1 --tool-dir DIR --out OUT
    windows_sample_process.py usb --root RAW --hdc-root RAW_HDC [--hdc-root ...] --out OUT
    windows_sample_process.py render --hdc OUT_C1 [--hdc OUT_C2] [--usb OUT_USB] --date YYYYMMDD --out DIR
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import sys
from typing import Iterable
from urllib.parse import urlparse

HDC_PHASES = ["no-board", "board-connected", "board-removed", "stop-server"]
USB_PHASES = ["before", "after", "removed", "replugged"]
ROCKCHIP = "VID_2207"
DOTNET_EPOCH_TICKS = 621355968000000000
# Windows hdc lists the host's serial ports (`COM1`, ...) as `UART` targets beside the boards.
# Their names are host port names, not board serials, so they are never redacted.
UART_PORT = re.compile(r"COM[0-9]+")
# A device instance ID `ENUMERATOR\hardware-id\suffix`; hardware and compatible IDs have two parts.
INSTANCE_ID = re.compile(r"[A-Za-z0-9_]+\\[^\\]+\\[^\\]+")

# What the macOS registrations state, compared against each Windows candidate. These are the
# registered macOS facts (openspec/integrations/openharmony/profile.md), never Windows evidence.
MACOS_REGISTERED = {
    "versionForm": "Ver: X",
    "checkserverForm": "Client version:Ver: X, server version:Ver: X",
    "emptyMarker": "[Empty]",
    "emptyMarkerTerminator": "CRLF",
    "rowColumns": 5,
    "rowTerminator": "LF",
    "rowStates": ["Connected", "Offline"],
    "rowTransport": ["USB"],
    "removedRowKeptOffline": True,
    "endpoint": "127.0.0.1:8710",
}


class Leak(Exception):
    """A secret survived into an output file."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def character_classes(value: str) -> list[str]:
    classes = []
    for name, test in [
        ("upper", str.isupper),
        ("lower", str.islower),
        ("digit", str.isdigit),
    ]:
        if any(test(c) for c in value):
            classes.append(name)
    if any(not c.isalnum() for c in value):
        classes.append("other")
    return sorted(classes)


def terminator(data: bytes) -> str:
    if data.endswith(b"\r\n"):
        return "CRLF"
    if data.endswith(b"\n"):
        return "LF"
    if data.endswith(b"\r"):
        return "CR"
    return "none" if data else "empty"


# ---- redaction ---------------------------------------------------------------------------


class Redactor:
    """The secrets of one processing run and their replacements, applied longest first."""

    def __init__(self) -> None:
        self.byte_secrets: dict[bytes, bytes] = {}
        self.text_secrets: dict[str, str] = {}

    def secret(self, value: str, replacement: str | None = None) -> None:
        if not value:
            return
        if replacement is None:
            replacement = "a" * len(value)
        self.text_secrets[value] = replacement
        for encoded, replaced in [
            (value.encode("utf-8"), replacement.encode("utf-8")),
            (value.encode("utf-16-le"), replacement.encode("utf-16-le")),
        ]:
            self.byte_secrets[encoded] = replaced

    def text(self, value: str) -> str:
        for secret in sorted(self.text_secrets, key=len, reverse=True):
            value = re.sub(re.escape(secret), self.text_secrets[secret].replace("\\", "\\\\"),
                           value, flags=re.IGNORECASE)
        return value

    def data(self, value: bytes) -> bytes:
        for secret in sorted(self.byte_secrets, key=len, reverse=True):
            value = value.replace(secret, self.byte_secrets[secret])
        return value

    def json(self, value):
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, list):
            return [self.json(item) for item in value]
        if isinstance(value, dict):
            return {self.text(key): self.json(item) for key, item in value.items()}
        return value

    def scan(self, directory: Path, forbidden_hashes: Iterable[str] = ()) -> None:
        """Fail when any file below `directory` still holds a secret or a forbidden hash."""
        hashes = [h for h in forbidden_hashes if h]
        for path in sorted(directory.rglob("*")):
            if not path.is_file():
                continue
            data = path.read_bytes()
            lowered = data.lower()
            for secret in self.byte_secrets:
                if secret and (secret in data or secret.lower() in lowered):
                    raise Leak(f"{path.relative_to(directory)} still holds a redacted value")
            for digest in hashes:
                if digest.encode() in lowered:
                    raise Leak(f"{path.relative_to(directory)} holds the hash of raw key-bearing bytes")


def account_secrets(redactor: Redactor, environment: dict[str, str]) -> None:
    """Account, machine and user-directory spellings, from this host and from the roots."""
    profile = environment.get("USERPROFILE")
    local = environment.get("LOCALAPPDATA")
    # The longer path first, so %LOCALAPPDATA% wins inside the profile.
    if local:
        redactor.secret(local.rstrip("\\"), "%LOCALAPPDATA%")
    if profile:
        redactor.secret(profile.rstrip("\\"), "%USERPROFILE%")
    for name in ("USERNAME", "COMPUTERNAME", "USERDOMAIN"):
        value = environment.get(name)
        if value and len(value) >= 3:
            redactor.secret(value, f"<{name.lower()}>")


def paths_in(value) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from paths_in(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from paths_in(item)


def discover_user_directories(redactor: Redactor, documents: list) -> None:
    """`C:\\Users\\<name>` prefixes seen in the roots, even without this host's environment."""
    for text in (t for document in documents for t in paths_in(document)):
        for match in re.finditer(r"[A-Za-z]:\\Users\\([^\\/\"]+)", text):
            name = match.group(1)
            if name.lower() not in ("public", "default", "all users"):
                redactor.secret(match.group(0), "%USERPROFILE%")
                if len(name) >= 3:
                    redactor.secret(name, "<username>")


# ---- HDC --------------------------------------------------------------------------------


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def list_rows(data: bytes) -> list[list[str]]:
    """Tab-separated rows of `list targets -v` stdout, CR kept inside the last field."""
    text = data.decode("utf-8", errors="replace")
    rows = []
    for line in text.split("\n"):
        if "\t" in line:
            rows.append(line.split("\t"))
    return rows


def connect_keys(root: Path) -> list[str]:
    keys = []
    for phase in HDC_PHASES:
        for path in sorted((root / phase).glob("list-targets*.stdout.bin")) if (root / phase).is_dir() else []:
            for row in list_rows(path.read_bytes()):
                key = row[0].strip()
                if UART_PORT.fullmatch(key):
                    continue
                if key and key not in keys:
                    keys.append(key)
    return keys


class Labels:
    """Stable labels: `pid-1`, or `<container-1>` for a bracketed prefix such as `<container`."""

    def __init__(self, prefix: str) -> None:
        self.prefix = prefix
        self.close = ">" if prefix.startswith("<") else ""
        self.seen: dict = {}

    def __call__(self, value):
        if value is None:
            return None
        if value not in self.seen:
            self.seen[value] = f"{self.prefix}-{len(self.seen) + 1}{self.close}"
        return self.seen[value]


def zone(value: str | None):
    if not value:
        return None
    fields = {}
    for line in value.splitlines():
        if "=" in line:
            key, _, item = line.partition("=")
            fields[key.strip()] = item.strip()
    host = urlparse(fields["HostUrl"]).hostname if fields.get("HostUrl") else None
    return {"zoneId": fields.get("ZoneId"), "hostUrlHost": host}


def server_state(state: dict | None, tool_sha: str, pid: Labels, clock) -> dict | None:
    if state is None:
        return None

    def owner(facts: dict) -> dict:
        return {
            "pid": pid(facts.get("pid")),
            "alive": facts.get("alive"),
            "name": facts.get("name"),
            "parentPid": pid(facts.get("parentPid")),
            "imageIsSelectedTool": facts.get("sha256") == tool_sha if facts.get("sha256") else None,
            "imageSha256": facts.get("sha256"),
            "startSeconds": clock(facts.get("startTimeUtcTicks")),
        }

    return {
        "listeners8710": [
            {"localAddress": l.get("localAddress"), "localPort": l.get("localPort"), "pid": pid(l.get("pid"))}
            for l in state.get("listeners8710") or []
        ],
        "listenerOwners": [owner(o) for o in state.get("listenerOwners") or []],
        "hdcProcesses": [owner(o) for o in state.get("hdcProcesses") or []],
    }


def classify_list(data: bytes, stderr: bytes, exit_code) -> dict:
    """The `list targets -v` output family, stated as found."""
    facts: dict = {"bytes": len(data), "terminator": terminator(data), "stderrEmpty": not stderr,
                   "exitCode": exit_code}
    if not data:
        facts["form"] = "zeroBytes"  # never empty: unknown
        return facts
    if data.strip(b"\r\n") == b"[Empty]":
        facts["form"] = "emptyMarker"
        facts["markerBytes"] = len(data)
        return facts
    rows = list_rows(data)
    if not rows:
        facts["form"] = "unrecognized"
        return facts
    lines = [line for line in data.split(b"\n") if line]
    facts["form"] = "rows"
    facts["rowCount"] = len(rows)
    facts["columnCounts"] = sorted({len(row) for row in rows})
    facts["rowTerminators"] = sorted({"CRLF" if line.endswith(b"\r") else "LF" for line in lines})
    facts["rowByteLengths"] = [len(line) + 1 for line in lines]
    facts["carriageReturnInsideField"] = any("\r" in field for row in rows for field in row[:-1])
    if all(len(row) >= 5 for row in rows):
        facts["transports"] = sorted({row[2] for row in rows})
        facts["states"] = sorted({row[3] for row in rows})
        facts["hostTags"] = sorted({row[4].rstrip("\r") for row in rows})
        facts["connectKeyLengths"] = [len(row[0]) for row in rows]
        facts["connectKeyCharacterClasses"] = sorted({c for row in rows for c in character_classes(row[0])})
    return facts


def process_hdc(root: Path, label: str, tool_dir: str | None, out: Path,
                environment: dict[str, str] | None = None) -> dict:
    environment = dict(os.environ if environment is None else environment)
    if out.exists():
        raise SystemExit(f"{out} exists; choose a new output directory")
    tool_sha = (root / "selected-tool.sha256").read_text(encoding="ascii").strip()
    samples = {
        phase: read_json(root / phase / "sample.json")
        for phase in HDC_PHASES
        if (root / phase / "sample.json").is_file()
    }
    if "no-board" not in samples:
        raise SystemExit(f"{root} has no no-board phase")
    started = read_json(root / "server-started-by-sampling.json") \
        if (root / "server-started-by-sampling.json").is_file() else None

    redactor = Redactor()
    keys = connect_keys(root)
    for key in keys:
        redactor.secret(key)
    if tool_dir:
        redactor.secret(tool_dir.rstrip("\\"), f"<candidate-{label.lstrip('c')}-dir>")
    account_secrets(redactor, environment)
    discover_user_directories(redactor, list(samples.values()))

    ticks = []
    for sample in samples.values():
        for state in [sample.get("serverBefore"), sample.get("serverAfter")] + \
                [c.get(k) for c in sample.get("commands") or [] for k in ("serverBefore", "serverAfter")]:
            for facts in (state or {}).get("listenerOwners", []) + (state or {}).get("hdcProcesses", []):
                if facts.get("startTimeUtcTicks"):
                    ticks.append(facts["startTimeUtcTicks"])
    origin = min(ticks) if ticks else None

    def clock(value):
        if value is None or origin is None:
            return None
        return round((value - origin) / 10_000_000, 3)

    pid = Labels("pid")
    forbidden = []
    out.mkdir(parents=True)
    tool = samples["no-board"]["tool"]
    tool_record = {
        "label": label,
        "path": redactor.text(tool.get("path") or ""),
        "sha256": tool_sha,
        "bytes": tool.get("bytes"),
        "versionResource": tool.get("versionResource"),
        "authenticodeStatus": tool.get("authenticodeStatus"),
        "signerSubject": tool.get("signerSubject"),
        "markOfTheWeb": tool.get("markOfTheWeb"),
        "zoneIdentifier": zone(tool.get("zoneIdentifier")),
        "siblingFiles": tool.get("siblingFiles"),
        "os": samples["no-board"].get("os"),
        "environment": {
            "ohosHdc": sorted((samples["no-board"].get("environment") or {}).get("ohosHdc", {}) or {}),
            "hdcOnPath": [redactor.text(p) for p in
                          (samples["no-board"].get("environment") or {}).get("hdcOnPath") or []],
        },
    }
    (out / "tool.json").write_text(json.dumps(redactor.json(tool_record), indent=2) + "\n", encoding="utf-8", newline="\n")

    phases = {}
    for phase, sample in samples.items():
        directory = out / phase
        directory.mkdir()
        commands = []
        for command in sample.get("commands") or []:
            name = command["name"]
            raw_out = (root / phase / f"{name}.stdout.bin").read_bytes()
            raw_err = (root / phase / f"{name}.stderr.bin").read_bytes()
            out_key = any(k.encode() in raw_out for k in keys)
            err_key = any(k.encode() in raw_err for k in keys)
            held_key = out_key or err_key
            # The hashes the capture recorded of key-bearing streams, and their own.
            if out_key:
                forbidden += [sha256(raw_out), command.get("stdoutSha256")]
            if err_key:
                forbidden += [sha256(raw_err), command.get("stderrSha256")]
            clean_out, clean_err = redactor.data(raw_out), redactor.data(raw_err)
            if len(clean_out) != len(raw_out) or len(clean_err) != len(raw_err):
                # A path placeholder changed a length; only same-length key redaction may touch
                # command output, so a path inside output is reported rather than rewritten.
                raise Leak(f"{phase}/{name}: output holds a path or name; redact it by hand review")
            (directory / f"{name}.stdout.bin").write_bytes(clean_out)
            (directory / f"{name}.stderr.bin").write_bytes(clean_err)
            entry = {
                "name": name,
                "argv": command.get("argv"),
                "exitCode": command.get("exitCode"),
                "timedOut": command.get("timedOut"),
                "durationMs": command.get("durationMs"),
                "streamsClosedWithin5s": command.get("streamsClosedWithin5s"),
                "stdoutBytes": len(raw_out),
                "stderrBytes": len(raw_err),
                "stdoutRedactedSha256": sha256(clean_out),
                "stderrRedactedSha256": sha256(clean_err),
                "keyRedacted": held_key,
                "stdoutTerminator": terminator(raw_out),
                "stdoutHasCR": b"\r" in raw_out,
                "serverBefore": server_state(command.get("serverBefore"), tool_sha, pid, clock),
                "serverAfter": server_state(command.get("serverAfter"), tool_sha, pid, clock),
            }
            if name.startswith("list-targets"):
                entry["listFamily"] = classify_list(raw_out, raw_err, command.get("exitCode"))
            if name == "version" or name.startswith("checkserver"):
                entry["text"] = clean_out.decode("utf-8", errors="replace")
            commands.append(entry)
        record = {
            "schema": "arkdeck-windows-hdc-sample-sanitized/v1",
            "phase": phase,
            "refused": sample.get("refused"),
            "serverBefore": server_state(sample.get("serverBefore"), tool_sha, pid, clock),
            "serverAfter": server_state(sample.get("serverAfter"), tool_sha, pid, clock),
            "commands": commands,
        }
        record = redactor.json(record)
        (directory / "sample.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8", newline="\n")
        phases[phase] = record

    summary = compare_hdc(label, tool_record, phases, server_state(started, tool_sha, pid, clock))
    summary["connectKeys"] = {"count": len(keys), "lengths": [len(k) for k in keys],
                              "characterClasses": sorted({c for k in keys for c in character_classes(k)})}
    (out / "summary.json").write_text(json.dumps(redactor.json(summary), indent=2) + "\n", encoding="utf-8", newline="\n")
    try:
        redactor.scan(out, forbidden)
    except Leak:
        shutil.rmtree(out)
        raise
    return summary


def command(phases: dict, phase: str, name: str) -> dict | None:
    for entry in (phases.get(phase) or {}).get("commands", []):
        if entry["name"] == name:
            return entry
    return None


def compare_hdc(label: str, tool: dict, phases: dict, started: dict | None) -> dict:
    """The crib's comparison, each Windows fact beside the macOS-registered one."""
    rows = []

    def row(topic, windows, macos, same):
        rows.append({"topic": topic, "windows": windows, "macos": macos, "sameAsMacos": same})

    version = command(phases, "no-board", "version")
    if version:
        text = version.get("text", "")
        form = "Ver: X" if re.fullmatch(r"Ver: \S+\r?\n?", text) else "other"
        row("`-v` stdout form", f"{form} ({text.strip()!r})", MACOS_REGISTERED["versionForm"], form == "Ver: X")
        row("`-v` terminator / stderr / exit",
            f"{version['stdoutTerminator']} / {version['stderrBytes']} B / {version['exitCode']}",
            "registered bytes / empty / 0", None)
    for name in ("checkserver-no-server", "checkserver-server-up"):
        entry = command(phases, "no-board", name)
        if entry:
            text = entry.get("text", "")
            form = "Client version:Ver: X, server version:Ver: X" \
                if re.fullmatch(r"Client version:Ver: \S+, server version:Ver: \S+\r?\n?", text) else "other"
            before = len((entry["serverBefore"] or {}).get("listeners8710", []))
            after = len((entry["serverAfter"] or {}).get("listeners8710", []))
            row(f"`{name}`", f"{form} ({text.strip()!r}); listeners {before}→{after}",
                MACOS_REGISTERED["checkserverForm"], form == MACOS_REGISTERED["checkserverForm"])
    for name in ("list-targets-first", "list-targets-empty"):
        entry = command(phases, "no-board", name)
        if entry:
            family = entry["listFamily"]
            same = family.get("form") == "emptyMarker" and family.get("terminator") == "CRLF"
            row(f"`{name}` (no board)", f"{family.get('form')} / {family.get('terminator')} / "
                f"{family.get('bytes')} B", "`[Empty]` CRLF (9 B); zero bytes is unknown", same)
    connected = command(phases, "board-connected", "list-targets-board-connected")
    if connected:
        family = connected["listFamily"]
        row("`list targets -v`, board connected",
            f"{family.get('form')}; columns {family.get('columnCounts')}; row terminators "
            f"{family.get('rowTerminators')}; states {family.get('states')}; transports "
            f"{family.get('transports')}; row bytes {family.get('rowByteLengths')}; CR in field "
            f"{family.get('carriageReturnInsideField')}",
            "5 tab columns, LF, `Connected`, `USB`, 58 B (32-character key)",
            family.get("columnCounts") == [5] and family.get("rowTerminators") == ["LF"]
            and family.get("states") == ["Connected"])
    removed = command(phases, "board-removed", "list-targets-board-removed")
    if removed:
        family = removed["listFamily"]
        kept = family.get("form") == "rows" and family.get("states") == ["Offline"]
        row("`list targets -v`, board removed",
            f"{family.get('form')}; states {family.get('states')}; row bytes {family.get('rowByteLengths')}",
            "row kept with `Offline` (56 B); no `[Empty]` marker", kept)
    owners = [
        entry["serverAfter"]["listenerOwners"]
        for phase in phases.values() for entry in phase.get("commands", [])
        if entry.get("serverAfter") and entry["serverAfter"]["listenerOwners"]
    ]
    pids = sorted({o["pid"] for group in owners for o in group})
    addresses = sorted({
        f"{l['localAddress']}:{l['localPort']}"
        for phase in phases.values() for entry in phase.get("commands", [])
        for l in (entry.get("serverAfter") or {}).get("listeners8710", [])
    })
    starter = None
    for phase in HDC_PHASES:
        for entry in (phases.get(phase) or {}).get("commands", []):
            if not (entry.get("serverBefore") or {}).get("listeners8710") and \
                    (entry.get("serverAfter") or {}).get("listeners8710"):
                starter = starter or f"{phase}/{entry['name']}"
    row("server identity", f"listener owners {pids}; addresses {addresses}; started by {starter}; "
        f"owner is selected tool: {sorted({o['imageIsSelectedTool'] for g in owners for o in g}, key=str)}",
        "exactly one listener on 127.0.0.1:8710 owned by the selected executable",
        len(pids) == 1 and addresses == ["127.0.0.1:8710"])
    anomalies = []
    for phase, record in phases.items():
        for entry in record.get("commands", []):
            if entry.get("stderrBytes"):
                anomalies.append(f"{phase}/{entry['name']}: stderr {entry['stderrBytes']} B")
            if entry.get("exitCode") not in (0, None):
                anomalies.append(f"{phase}/{entry['name']}: exit {entry['exitCode']}")
            if entry.get("timedOut"):
                anomalies.append(f"{phase}/{entry['name']}: timed out")
            if entry.get("streamsClosedWithin5s") is False:
                anomalies.append(f"{phase}/{entry['name']}: pipes left open after the client exited")
        if record.get("refused"):
            anomalies.append(f"{phase}: refused ({record['refused']})")
    return {
        "schema": "arkdeck-windows-hdc-sample-summary/v1",
        "label": label,
        "tuple": {
            "executableSha256": tool["sha256"],
            "versionBytes": (version or {}).get("text"),
            "versionTerminator": (version or {}).get("stdoutTerminator"),
            "sourcePath": tool["path"],
            "authenticode": tool["authenticodeStatus"],
            "markOfTheWeb": tool["markOfTheWeb"],
        },
        "phases": sorted(phases),
        "comparison": rows,
        "anomalies": anomalies,
        "samplingServer": started,
    }


# ---- USB --------------------------------------------------------------------------------


def instance_parts(instance: str) -> tuple[str, str, str]:
    parts = instance.split("\\")
    return (parts + ["", "", ""])[:3]


def instance_like(item) -> bool:
    return isinstance(item, str) and INSTANCE_ID.fullmatch(item) is not None


def property_value(node: dict, key: str):
    entry = (node.get("properties") or {}).get(key)
    return entry.get("data") if isinstance(entry, dict) else None


def process_usb(root: Path, hdc_roots: list[Path], out: Path,
                environment: dict[str, str] | None = None) -> dict:
    environment = dict(os.environ if environment is None else environment)
    if out.exists():
        raise SystemExit(f"{out} exists; choose a new output directory")
    samples = {
        phase: read_json(root / f"usb-{phase}.json")
        for phase in USB_PHASES if (root / f"usb-{phase}.json").is_file()
    }
    keys = [key for hdc in hdc_roots for key in connect_keys(hdc)]

    # The board's device-level nodes: VID_2207, no interface suffix.
    devices = {}
    for sample in samples.values():
        for node in sample.get("rockchipNodes") or []:
            bus, hardware, suffix = instance_parts(node["instanceId"])
            if bus.upper() == "USB" and ROCKCHIP in hardware.upper() and "&MI_" not in hardware.upper():
                devices.setdefault(node["instanceId"], node)
    serials = []
    for instance in devices:
        suffix = instance_parts(instance)[2]
        if suffix and "&" not in suffix and suffix not in serials:
            serials.append(suffix)

    redactor = Redactor()
    for value in serials + keys:
        redactor.secret(value)
    account_secrets(redactor, environment)
    discover_user_directories(redactor, list(samples.values()))
    guid = Labels("<container")

    def keep_chain(sample: dict) -> list[dict]:
        # Keyed by the upper-cased instance ID: Windows spells one ID in different letter cases
        # (`Parent` and the relation lists lower-case it), and instance IDs compare ignoring case.
        nodes = {n["instanceId"].upper(): n for n in (sample.get("presentUsbNodes") or [])}
        for n in sample.get("rockchipNodes") or []:
            nodes.setdefault(n["instanceId"].upper(), n)
        kept = [i for i in nodes if ROCKCHIP in i]
        frontier = list(kept)
        while frontier:
            parent = property_value(nodes[frontier.pop()], "DEVPKEY_Device_Parent")
            if isinstance(parent, str) and parent.upper() in nodes and parent.upper() not in kept:
                kept.append(parent.upper())
                frontier.append(parent.upper())
        return [nodes[i] for i in kept]

    times = []
    for sample in samples.values():
        for node in keep_chain(sample):
            for key in ("DEVPKEY_Device_LastArrivalDate", "DEVPKEY_Device_LastRemovalDate",
                        "DEVPKEY_Device_InstallDate", "DEVPKEY_Device_FirstInstallDate"):
                if isinstance(property_value(node, key), str):
                    times.append(property_value(node, key))

    def clean_node(node: dict, kept: set[str]) -> dict:
        properties = {}
        for key, entry in (node.get("properties") or {}).items():
            data = entry.get("data") if isinstance(entry, dict) else entry
            # Relation lists (Children, Siblings, removal and bus relations) name other
            # devices: only the kept chain may be named. Only instance-ID-shaped items name a
            # device; hardware and compatible IDs are kept. `kept` holds upper-cased IDs.
            if isinstance(data, list) and any(instance_like(item) for item in data):
                data = [item for item in data if not instance_like(item) or item.upper() in kept]
            elif (instance_like(data) and data.upper() not in kept and key != "DEVPKEY_Device_InstanceId"):
                data = "<other-device>"
            if key.endswith("Date") and isinstance(data, str):
                data = {"order": sorted(set(times)).index(data) if data in times else None}
            elif isinstance(data, str) and re.fullmatch(r"\{?[0-9a-fA-F-]{36}\}?", data):
                data = guid(data.lower())
            properties[key] = {"type": entry.get("type") if isinstance(entry, dict) else None, "data": data}
        return {
            "instanceId": node["instanceId"],
            "present": node.get("present"),
            "class": node.get("class"),
            "status": node.get("status"),
            "problem": node.get("problem"),
            "properties": properties,
        }

    out.mkdir(parents=True)
    phases = {}
    for phase, sample in samples.items():
        chain = keep_chain(sample)
        kept = {node["instanceId"].upper() for node in chain}
        record = {
            "schema": "arkdeck-windows-usb-sample-sanitized/v1",
            "phase": phase,
            "nodes": [clean_node(node, kept) for node in chain],
        }
        record = redactor.json(record)
        (out / f"usb-{phase}.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8", newline="\n")
        phases[phase] = record
    summary = compare_usb(devices, serials, keys, phases)
    (out / "summary.json").write_text(json.dumps(redactor.json(summary), indent=2) + "\n", encoding="utf-8", newline="\n")
    try:
        redactor.scan(out)
    except Leak:
        shutil.rmtree(out)
        raise
    return summary


def compare_usb(devices: dict, serials: list[str], keys: list[str], phases: dict) -> dict:
    device_nodes = sorted(devices)
    suffixes = [instance_parts(i)[2] for i in device_nodes]
    serial_facts = []
    for serial in serials:
        serial_facts.append({
            "length": len(serial),
            "characterClasses": character_classes(serial),
            "equalsConnectKey": serial in keys,
            "equalsConnectKeyIgnoringCase": serial.lower() in [k.lower() for k in keys],
        })
    by_phase = {}
    for phase, record in phases.items():
        board = [n for n in record["nodes"] if ROCKCHIP in n["instanceId"].upper()
                 and "&MI_" not in n["instanceId"].upper()]
        interfaces = [n for n in record["nodes"] if "&MI_" in n["instanceId"].upper()]
        first = board[0] if board else None

        def value(key):
            return property_value(first, key) if first else None

        by_phase[phase] = {
            "boardNodes": len(board),
            "boardPresent": [n.get("present") for n in board],
            "interfaceNodes": len(interfaces),
            "hardwareIds": value("DEVPKEY_Device_HardwareIds"),
            "locationPaths": value("DEVPKEY_Device_LocationPaths"),
            "locationInfo": value("DEVPKEY_Device_LocationInfo"),
            "busReportedDeviceDesc": value("DEVPKEY_Device_BusReportedDeviceDesc"),
            "arrivalOrder": value("DEVPKEY_Device_LastArrivalDate"),
            "services": sorted({str(property_value(n, "DEVPKEY_Device_Service")) for n in interfaces + board}),
        }
    stable_location = None
    if "after" in by_phase and "replugged" in by_phase:
        stable_location = by_phase["after"]["locationPaths"] == by_phase["replugged"]["locationPaths"]
    return {
        "schema": "arkdeck-windows-usb-sample-summary/v1",
        "deviceInstanceCount": len(device_nodes),
        "suffixKinds": ["serial" if s and "&" not in s else "portDerived" for s in suffixes],
        "serials": serial_facts,
        "phases": by_phase,
        "locationSurvivesReplugSamePort": stable_location,
    }


# ---- run records ------------------------------------------------------------------------


def render(hdc_outputs: list[Path], usb_output: Path | None, date: str, out: Path) -> list[Path]:
    out.mkdir(parents=True, exist_ok=True)
    written = []
    if hdc_outputs:
        summaries = [read_json(p / "summary.json") for p in hdc_outputs]
        lines = [f"# TASK-XPA-002: Windows HDC samples, sanitized, {date}", "",
                 "Processed by `rust/scripts/windows_sample_process.py hdc` from the maintainer's "
                 "roots. Connect keys are replaced by same-length `a` runs, and no hash of "
                 "key-bearing raw bytes is kept. Paths are `%USERPROFILE%`/`%LOCALAPPDATA%`-relative "
                 "or `<candidate-N-dir>`. Neither candidate is chosen here.", "",
                 "## Tuples", "", "| Candidate | Executable SHA-256 | `-v` bytes | Terminator | "
                 "Authenticode | MotW | Source |", "| --- | --- | --- | --- | --- | --- | --- |"]
        for s in summaries:
            t = s["tuple"]
            lines.append(f"| {s['label']} | `{t['executableSha256']}` | `{(t['versionBytes'] or '').strip()}` | "
                         f"{t['versionTerminator']} | {t['authenticode']} | {t['markOfTheWeb']} | "
                         f"`{t['sourcePath']}` |")
        for s in summaries:
            lines += ["", f"## Candidate {s['label']}: comparison with the macOS registrations", "",
                      "| Topic | Windows (as found) | macOS registered | Same |", "| --- | --- | --- | --- |"]
            for r in s["comparison"]:
                same = {True: "yes", False: "**no**", None: "n/a"}[r["sameAsMacos"]]
                lines.append(f"| {r['topic']} | {r['windows']} | {r['macos']} | {same} |")
            lines += ["", "Anomalies (each a Windows-specific difference to report, not to smooth):", ""]
            lines += [f"- {a}" for a in s["anomalies"]] or ["- none"]
            keys = s["connectKeys"]
            lines += ["", f"Connect keys: {keys['count']} redacted, lengths {keys['lengths']}, "
                      f"character classes {keys['characterClasses']}."]
        path = out / f"hdc-windows-sample-{date}-run.md"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        written.append(path)
    if usb_output:
        s = read_json(usb_output / "summary.json")
        lines = [f"# TASK-XPA-004: DAYU200 USB properties on Windows, sanitized, {date}", "",
                 "Processed by `rust/scripts/windows_sample_process.py usb`. Only the DAYU200, its "
                 "interfaces and its hub chain are kept; the serial is a same-length `a` run; GUIDs are "
                 "labels; times are order only.", "",
                 f"- Device-level instances: {s['deviceInstanceCount']}; instance suffix kinds: "
                 f"{s['suffixKinds']}.",
                 f"- Serial facts: {json.dumps(s['serials'])}.",
                 f"- Location path survives a replug into the same port: {s['locationSurvivesReplugSamePort']}.",
                 "", "| Phase | Board nodes (present) | Interfaces | HardwareIds | LocationPaths | "
                 "LocationInfo | BusReportedDeviceDesc | Arrival order | Services |",
                 "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for phase, p in s["phases"].items():
            lines.append(f"| {phase} | {p['boardNodes']} ({p['boardPresent']}) | {p['interfaceNodes']} | "
                         f"{p['hardwareIds']} | {p['locationPaths']} | {p['locationInfo']} | "
                         f"{p['busReportedDeviceDesc']} | {p['arrivalOrder']} | {p['services']} |")
        path = out / f"dayu200-usb-properties-{date}-run.md"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        written.append(path)
    return written


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    hdc = sub.add_parser("hdc")
    hdc.add_argument("--root", type=Path, required=True)
    hdc.add_argument("--label", required=True)
    hdc.add_argument("--tool-dir")
    hdc.add_argument("--out", type=Path, required=True)
    usb = sub.add_parser("usb")
    usb.add_argument("--root", type=Path, required=True)
    usb.add_argument("--hdc-root", type=Path, action="append", default=[])
    usb.add_argument("--out", type=Path, required=True)
    rendering = sub.add_parser("render")
    rendering.add_argument("--hdc", type=Path, action="append", default=[])
    rendering.add_argument("--usb", type=Path)
    rendering.add_argument("--date", required=True)
    rendering.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "hdc":
            process_hdc(args.root, args.label, args.tool_dir, args.out)
        elif args.command == "usb":
            process_usb(args.root, args.hdc_root, args.out)
        else:
            for path in render(args.hdc, args.usb, args.date, args.out):
                print(path)
    except Leak as leak:
        print(f"refused: {leak}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
