"""Minimal control-plane client used only to time round trips.

The daemon speaks newline-delimited JSON over a Unix domain socket: one request
object per line, one response object per line
(`Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentClient.swift`).  A session
opens with the bootstrap negotiation frame and then carries the selected exact
version on every domain frame.

This client exists so that an IPC latency sample measures the IPC, not a CLI
process launch.  It is a measurement instrument: it submits nothing, mutates
nothing and calls only read-only methods.  It deliberately does not reimplement
`arkdeck`; anything a caller would actually want to do belongs on the CLI.
"""

from __future__ import annotations

import json
import socket
import uuid

from . import clocks

BOOTSTRAP_VERSION = "arkdeck.control.negotiation/1"
BOOTSTRAP_METHOD = "protocol.negotiate"
SUPPORTED_EXACT_VERSIONS = ("2.0.0", "1.0.0")
MAXIMUM_FRAME_BYTES = 4 * 1024 * 1024


class ControlError(RuntimeError):
    """The daemon refused a frame, or the transport failed."""


class ControlClient:
    """One connection to one daemon socket."""

    def __init__(self, socket_path: str, timeout_seconds: float = 30.0) -> None:
        self.socket_path = socket_path
        self.timeout_seconds = timeout_seconds
        self._socket: socket.socket | None = None
        self._buffer = b""
        self.selected_version: str | None = None

    def __enter__(self) -> "ControlClient":
        self.connect()
        self.negotiate()
        return self

    def __exit__(self, *_exception: object) -> None:
        self.close()

    def connect(self) -> None:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(self.timeout_seconds)
        try:
            connection.connect(self.socket_path)
        except OSError as error:
            connection.close()
            raise ControlError(f"connect {self.socket_path}: {error}") from error
        self._socket = connection

    def close(self) -> None:
        if self._socket is not None:
            self._socket.close()
            self._socket = None
        self._buffer = b""

    def _exchange(self, frame: dict[str, object]) -> dict[str, object]:
        if self._socket is None:
            raise ControlError("client is not connected")
        payload = json.dumps(frame, separators=(",", ":")).encode("utf-8") + b"\n"
        if len(payload) > MAXIMUM_FRAME_BYTES:
            raise ControlError("request frame exceeds the 4 MiB transport limit")
        self._socket.sendall(payload)
        while b"\n" not in self._buffer:
            chunk = self._socket.recv(65536)
            if not chunk:
                raise ControlError("daemon closed the connection")
            self._buffer += chunk
        line, _, self._buffer = self._buffer.partition(b"\n")
        return json.loads(line)

    def negotiate(self, required_major: int = 2) -> str:
        response = self._exchange(
            {
                "bootstrapVersion": BOOTSTRAP_VERSION,
                "id": f"bench-{uuid.uuid4()}",
                "method": BOOTSTRAP_METHOD,
                "supportedExactVersions": list(SUPPORTED_EXACT_VERSIONS),
                "requiredMajor": required_major,
            }
        )
        if not response.get("ok"):
            raise ControlError(f"negotiation refused: {response}")
        version = response.get("selectedExactVersion")
        if not isinstance(version, str):
            raise ControlError(f"negotiation returned no exact version: {response}")
        self.selected_version = version
        return version

    def call(self, method: str, params: dict[str, object] | None = None) -> object:
        """Issue one request and return its result, raising on a refusal."""

        result, _ = self.timed_call(method, params)
        return result

    def timed_call(
        self, method: str, params: dict[str, object] | None = None
    ) -> tuple[object, float]:
        """Issue one request and return `(result, awake-work seconds)`.

        The sample brackets send-through-receive on the awake-work clock, so a
        machine that sleeps mid-sample does not inflate the reading.
        """

        if self.selected_version is None:
            raise ControlError("call before negotiation")
        frame = {
            "protocolVersion": self.selected_version,
            "id": f"bench-{uuid.uuid4()}",
            "method": method,
            "params": params or {},
        }
        started = clocks.awake_seconds()
        response = self._exchange(frame)
        elapsed = clocks.awake_seconds() - started
        if not response.get("ok"):
            error = response.get("error") or {}
            raise ControlError(
                f"{method} refused: {error.get('code')}: {error.get('message')}"
            )
        return response.get("result"), elapsed
