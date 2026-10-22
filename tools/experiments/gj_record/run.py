"""A capture journal read back: every step's envelope, in order, checked.

Loading refuses outright, before any criterion is applied, what can never be
real-device evidence:

- a stdout file that differs from the bytes the journal hashed when it ran;
- output that is not a published CLI envelope;
- more than one CLI image across the journal;
- a plan-only or simulated Job (`executionMode` other than `execute`), or a
  `job plan` step;
- a development state root (rehearsal; `runtime service status` says
  `stateRoot.kind: development`) or an unverified daemon image;
- any Runtime answer about a Job or the Catalog whose `catalogDigest` is not
  the expected one.
"""

from __future__ import annotations

import base64
import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path

from . import capture

RESULT_SCHEMA = "arkdeck.cli.result/1"
EVENT_SCHEMA = "arkdeck.cli.event/1"
PAGE_SCHEMA = "arkdeck.cli.page/1"
# The commands whose answer is about a Job this run produced or the Catalog it
# ran on. `job list` is not one: it pages over every Job the root holds.
_DIGEST_BEARING = frozenset(
    {
        "operation.list",
        "runtime.health",
        "runtime.service.status",
        "agent.run",
        "agent.status",
        "agent.resume",
        "job.result",
        "job.evidence",
        "job.show",
        "job.status",
    }
)


class RefusedInput(Exception):
    """The inputs can never yield a record."""


@dataclass
class Step:
    entry: dict
    envelope: dict | None
    lines: list[dict] = field(default_factory=list)

    @property
    def sequence(self) -> int:
        return self.entry["sequence"]

    @property
    def file(self) -> str:
        return self.entry["stdoutFile"]

    @property
    def exit_code(self) -> int:
        return self.entry["exitCode"]

    @property
    def command(self) -> str:
        if self.envelope is not None:
            return self.envelope.get("command", "")
        return self.entry.get("streamCommand", "")

    @property
    def ok(self) -> bool:
        return bool(self.envelope and self.envelope.get("ok") is True)

    @property
    def result(self) -> dict:
        value = (self.envelope or {}).get("result")
        return value if isinstance(value, dict) else {}

    @property
    def items(self) -> list:
        value = (self.envelope or {}).get("result")
        if isinstance(value, list):
            return value
        if isinstance(value, dict) and isinstance(value.get("items"), list):
            return value["items"]
        return []

    @property
    def error(self) -> dict:
        value = (self.envelope or {}).get("error")
        return value if isinstance(value, dict) else {}

    def option(self, name: str) -> str | None:
        arguments = self.entry["arguments"]
        for index, token in enumerate(arguments):
            if token == name and index + 1 < len(arguments):
                return arguments[index + 1]
            if token.startswith(name + "="):
                return token.split("=", 1)[1]
        return None

    def has_flag(self, name: str) -> bool:
        return name in self.entry["arguments"]


def _walk(value, key: str):
    if isinstance(value, dict):
        for name, inner in value.items():
            if name == key:
                yield inner
            yield from _walk(inner, key)
    elif isinstance(value, list):
        for inner in value:
            yield from _walk(inner, key)


class Run:
    def __init__(self, steps: list[Step]):
        self.steps = steps

    # -- loading -------------------------------------------------------------

    @classmethod
    def load(cls, out: Path) -> "Run":
        entries = capture.read_journal(out)
        if not entries:
            raise RefusedInput(f"{out} holds no capture journal")
        images = {entry["cliExecutableSHA256"] for entry in entries}
        if len(images) != 1:
            raise RefusedInput("the journal was captured with more than one arkdeck image")
        steps = []
        for entry in entries:
            path = out / entry["stdoutFile"]
            data = path.read_bytes() if path.exists() else None
            if data is None or hashlib.sha256(data).hexdigest() != entry["stdoutSHA256"]:
                raise RefusedInput(f"{entry['stdoutFile']} is not the output the journal recorded")
            steps.append(_parse(entry, data))
        return cls(steps)

    def refuse_non_evidence(self, expected_digest: str) -> None:
        for step in self.steps:
            if step.command == "job.plan" or step.has_flag("--plan-only"):
                raise RefusedInput(f"{step.file} is a plan-only step, never real-device evidence")
            for mode in _walk(step.envelope, "executionMode"):
                if mode != "execute":
                    raise RefusedInput(
                        f"{step.file} carries a {mode!r} Job, never real-device evidence"
                    )
            if step.command == "runtime.service.status" and step.ok:
                _installed_service(step)
            if step.command in _DIGEST_BEARING:
                for digest in _walk(step.envelope, "catalogDigest"):
                    if digest != expected_digest:
                        raise RefusedInput(
                            f"{step.file} answers on Catalog {digest}, not the expected "
                            f"{expected_digest}"
                        )

    # -- reading -------------------------------------------------------------

    def of(self, command: str, predicate=lambda step: True) -> list[Step]:
        return [s for s in self.steps if s.command == command and predicate(s)]

    def last(self, command: str, predicate=lambda step: True) -> Step | None:
        found = self.of(command, predicate)
        return found[-1] if found else None

    def execution(self, execution_id: str) -> list[Step]:
        """Every agent run/status/resume answer about one execution, in order."""
        return [
            s
            for s in self.steps
            if s.command in ("agent.run", "agent.status", "agent.resume")
            and (
                s.result.get("executionId") == execution_id
                or s.option("--execution-id") == execution_id
            )
        ]

    def job_result(self, job_id: str, after: int = 0) -> Step | None:
        return self.last(
            "job.result",
            lambda s: s.ok and s.sequence > after and (s.result.get("job") or {}).get("jobId") == job_id,
        )

    def job_evidence(self, job_id: str) -> Step | None:
        return self.last("job.evidence", lambda s: s.ok and s.result.get("jobId") == job_id)

    def artifact_list(self, job_id: str) -> Step | None:
        return self.last("artifact.list", lambda s: s.ok and s.option("--job") == job_id)

    def artifact_bytes(self, artifact_id: str) -> bytes | None:
        """The Artifact's bytes when `artifact read` returned all of them and
        they hash to the digest the Runtime published; otherwise None."""
        chunks = self.of("artifact.read", lambda s: s.ok and s.result.get("artifactId") == artifact_id)
        if not chunks:
            return None
        by_offset: dict[int, dict] = {}
        for step in chunks:
            by_offset[step.result.get("offset")] = step.result
        data = b""
        digest = None
        total = None
        while True:
            chunk = by_offset.get(len(data))
            if chunk is None:
                return None
            try:
                piece = base64.b64decode(chunk.get("base64", ""), validate=True)
            except ValueError:
                return None
            if len(piece) != chunk.get("byteCount"):
                return None
            digest = chunk.get("artifactDigest")
            total = chunk.get("totalByteCount")
            data += piece
            if chunk.get("eof") is True:
                break
            if not piece:
                return None
        if total != len(data) or not isinstance(digest, str):
            return None
        if hashlib.sha256(data).hexdigest() != digest.removeprefix("sha256:"):
            return None
        return data

    def strings(self, keys: tuple[str, ...]) -> set[str]:
        found: set[str] = set()
        for step in self.steps:
            for key in keys:
                for value in _walk([step.envelope, step.lines], key):
                    if isinstance(value, str):
                        found.add(value)
        return found


def _installed_service(step: Step) -> None:
    """Only the installed account daemon's answers are evidence: on Windows
    `daemonService` names the state root and the verified image; on macOS
    `launchAgent` is the installed service and names its daemon digest."""
    windows = step.result.get("daemonService")
    if isinstance(windows, dict):
        root = windows.get("stateRoot") or {}
        if root.get("kind") != "account":
            raise RefusedInput(
                f"{step.file}: the daemon runs on a {root.get('kind')!r} state root; "
                "only the installed account daemon's results are evidence"
            )
        if (windows.get("daemonImage") or {}).get("verified") is not True:
            raise RefusedInput(f"{step.file}: the installed daemon image is not verified")
        return
    mac = step.result.get("launchAgent")
    if isinstance(mac, dict) and isinstance(mac.get("daemonSHA256"), str):
        return
    raise RefusedInput(f"{step.file}: runtime service status names no installed daemon")


def _parse(entry: dict, data: bytes) -> Step:
    mode = None
    arguments = entry["arguments"]
    for index, token in enumerate(arguments):
        if token == "--output" and index + 1 < len(arguments):
            mode = arguments[index + 1]
    text = data.decode("utf-8")
    if mode == "jsonl":
        lines = [json.loads(line) for line in text.splitlines() if line.strip()]
        if not lines or any(
            line.get("schemaVersion") not in (EVENT_SCHEMA, PAGE_SCHEMA, RESULT_SCHEMA)
            for line in lines
        ):
            raise RefusedInput(f"{entry['stdoutFile']} is not a published CLI event stream")
        envelope = lines[-1] if lines[-1].get("schemaVersion") == RESULT_SCHEMA else None
        return Step(entry, envelope, lines)
    try:
        envelope = json.loads(text)
    except ValueError as error:
        raise RefusedInput(f"{entry['stdoutFile']} is not JSON: {error}") from error
    if not isinstance(envelope, dict) or envelope.get("schemaVersion") not in (
        RESULT_SCHEMA,
        PAGE_SCHEMA,
    ):
        raise RefusedInput(f"{entry['stdoutFile']} is not a published CLI envelope")
    return Step(entry, envelope)
