"""The record carries SHA-256s, IDs, counts, states and UTC times only.

Redaction is by construction: `assemble` copies named fields, never a whole
Runtime answer. This module is the second line. It collects every literal the
raw outputs and arguments carry that could identify a device, a host account
or a path (connect keys, serials, USB instance IDs, paths, display names) and
refuses a record that contains any of them, or anything shaped like a path or
a network connect key.
"""

from __future__ import annotations

import re

from .run import Run

# Keys whose string values in a Runtime answer name a device, a host or a path.
SENSITIVE_KEYS = (
    "connectKey",
    "candidateKey",
    "usbTopology",
    "backupPath",
    "targetPath",
    "serial",
    "serialNumber",
    "usbSerial",
    "instanceId",
    "deviceInstanceId",
    "locationPath",
    "topology",
    "displayName",
    "hostName",
    "account",
    "user",
    "path",
    "daemonPath",
    "socketPath",
    "executablePath",
    "endpoint",
    "root",
    "rootPath",
    "projectRoot",
    "destination",
    "file",
    "workingDirectory",
)
# Arguments whose value is a path or an account literal.
SENSITIVE_OPTIONS = (
    "--file",
    "--destination",
    "--inputs-file",
    "--root",
    "--daemon",
    "--keystore",
    "--certificate",
    "--profile",
    "--java",
    "--jar",
    "--build-profile",
    "--candidate",
)
_PATTERNS = (
    ("a drive path", re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:[\\/]")),
    ("a UNC or escaped path", re.compile(r"\\\\")),
    ("a home path", re.compile(r"/(?:Users|home|private|var/folders)/")),
    ("an environment path", re.compile(r"%[A-Z_]+%")),
    ("an address:port connect key", re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}:\d{1,5}\b")),
)
_DIGEST = re.compile(r"^(?:sha256:)?[0-9a-f]{64}$")


class RedactionError(Exception):
    pass


def sensitive_literals(run: Run) -> set[str]:
    literals = set(run.strings(SENSITIVE_KEYS))
    for step in run.steps:
        arguments = step.entry["arguments"]
        for index, token in enumerate(arguments[:-1]):
            if token in SENSITIVE_OPTIONS:
                literals.add(arguments[index + 1])
    # A digest is published by design; a very short literal would match by
    # accident (a `path` of "/" or a key of "1").
    return {value for value in literals if len(value) >= 6 and not _DIGEST.match(value)}


def check(text: str, literals: set[str]) -> None:
    for literal in sorted(literals, key=len, reverse=True):
        if literal in text:
            raise RedactionError(
                f"the record would carry a raw identifying literal ({len(literal)} characters) "
                "from the Runtime's outputs; refusing"
            )
    for name, pattern in _PATTERNS:
        if pattern.search(text):
            raise RedactionError(f"the record would carry {name}; refusing")
