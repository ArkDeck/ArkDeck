"""Minimal control-plane client used only to time round trips.

The daemon speaks newline-delimited JSON over a Unix domain socket: one request
object per line, one response object per line
(`Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentClient.swift`).  A session
verifies the current health contract on the same connection before any measured
request. Every frame carries the one current version and contract identity.

This client exists so that an IPC latency sample measures the IPC, not a CLI
process launch.  It is a measurement instrument: it submits nothing, mutates
nothing and calls only read-only methods.  It deliberately does not reimplement
`arkdeck`; anything a caller would actually want to do belongs on the CLI.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import socket
import uuid

from . import clocks

_REGISTRY_PATH = Path(__file__).resolve().parents[2] / "Packages/ArkDeckKit/Contracts/control-protocol.json"
_REGISTRY = json.loads(_REGISTRY_PATH.read_text())
CURRENT_VERSION = _REGISTRY["currentVersion"]
CONTRACT_IDENTITY = hashlib.sha256(json.dumps(_REGISTRY, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
MAXIMUM_FRAME_BYTES = _REGISTRY["maximumRequestFrameBytes"]
MAXIMUM_RESPONSE_BYTES = _REGISTRY["maximumResponseFrameBytes"]


class ControlError(RuntimeError):
    """The daemon refused a frame, or the transport failed."""


class ControlClient:
    """One connection to one daemon socket."""

    def __init__(self, socket_path: str, timeout_seconds: float = 30.0) -> None:
        self.socket_path = socket_path
        self.timeout_seconds = timeout_seconds
        self._socket: socket.socket | None = None
        self._buffer = b""
        self._verified = False

    def __enter__(self) -> "ControlClient":
        self.connect()
        self.verify_contract()
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
        self._verified = False

    def close(self) -> None:
        if self._socket is not None:
            self._socket.close()
            self._socket = None
        self._buffer = b""
        self._verified = False

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
            if len(self._buffer) > MAXIMUM_RESPONSE_BYTES:
                raise ControlError("response frame exceeds its transport limit")
        line, _, self._buffer = self._buffer.partition(b"\n")
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ControlError("duplicate response key")
                result[key] = value
            return result
        if self._buffer or b"\r" in line:
            raise ControlError("unexpected extra response frame")
        response = json.loads(line, object_pairs_hook=unique)
        if not isinstance(response, dict) or response.get("id") != frame["id"]:
            raise ControlError("response identity mismatch")
        expected = {"id", "ok", "result"} if response.get("ok") is True else {"id", "ok", "error"}
        if set(response) != expected or type(response.get("ok")) is not bool:
            raise ControlError("response shape mismatch")
        return response

    def verify_contract(self) -> None:
        response = self._exchange({
            "protocolVersion": CURRENT_VERSION, "contractIdentity": CONTRACT_IDENTITY,
            "id": f"bench-{uuid.uuid4()}", "method": "health",
        })
        health = response.get("result")
        if (response.get("ok") is not True or not isinstance(health, dict)
            or set(health) != {"status", "protocolVersion", "contractIdentity", "publishedMethods", "catalogDigest", "providers"}
            or health["status"] != "ok" or health["protocolVersion"] != CURRENT_VERSION
            or health["contractIdentity"] != CONTRACT_IDENTITY
            or health["publishedMethods"] != _REGISTRY["methods"]
            or not isinstance(health["catalogDigest"], str) or len(health["catalogDigest"]) != 64
            or any(c not in "0123456789abcdef" for c in health["catalogDigest"])
            or not isinstance(health["providers"], list)
            or any(not isinstance(p, str) or not p for p in health["providers"])):
            raise ControlError("connected daemon does not prove the current control contract")
        self._verified = True

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

        if not self._verified:
            raise ControlError("call before current contract verification")
        frame = {
            "protocolVersion": CURRENT_VERSION,
            "contractIdentity": CONTRACT_IDENTITY,
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
