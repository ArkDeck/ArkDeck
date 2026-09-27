"""Bounded capture evidence, separate from comparable performance metrics."""
from __future__ import annotations

import hashlib
import json
import os
import stat
import pathlib
import subprocess
import tempfile

VERSION = "phase-checkpoints-v1"
LOG_LIMIT = 64 * 1024
METRICS_LIMIT = 1024 * 1024


def bounded_log(stream) -> dict:
    """Read only a bounded prefix; never label a prefix hash as a full hash."""
    size = stream.seek(0, 2)
    stream.seek(0)
    prefix = stream.read(LOG_LIMIT)
    return {"byteCount": size, "capturedBytes": len(prefix),
            "sha256": hashlib.sha256(prefix).hexdigest(),
            "hashScope": "complete" if size <= LOG_LIMIT else "prefix",
            "text": prefix.decode("utf-8", errors="replace"),
            "truncated": size > LOG_LIMIT}


def seed_process(arguments: list[str], timeout: float, record) -> subprocess.CompletedProcess:
    # File-backed child output avoids communicate() accumulating an unbounded
    # log in memory. Both reads and the archived prefix are bounded. Temporary
    # output files are removed on success, timeout and recorder failure.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        try:
            result = subprocess.run(arguments, stdout=stdout, stderr=stderr,
                                    timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            record({"kind": "seedProcess", "returnCode": None, "timedOut": True,
                    "timeoutSeconds": timeout, "stdout": bounded_log(stdout),
                    "stderr": bounded_log(stderr)})
            raise
        except OSError as error:
            record({"kind": "seedProcess", "returnCode": None, "timedOut": False,
                    "errorType": type(error).__name__, "stdout": bounded_log(stdout),
                    "stderr": bounded_log(stderr)})
            raise
        out, err = bounded_log(stdout), bounded_log(stderr)
        record({"kind": "seedProcess", "returnCode": result.returncode,
                "timedOut": False, "timeoutSeconds": timeout, "stdout": out, "stderr": err})
        return subprocess.CompletedProcess(arguments, result.returncode, out["text"], err["text"])


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate seed metrics key")
        result[key] = value
    return result


def seed_metrics(root: pathlib.Path, record) -> None:
    """Archive the actual Rust owner's completed counts, not seed estimates."""
    try:
        path = root / "runtime-soak-metrics.json"
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise ValueError("seed metrics must be a regular file")
            raw = source.read(METRICS_LIMIT + 1)
        if len(raw) > METRICS_LIMIT:
            raise ValueError("seed metrics exceed the bounded input limit")
        text = raw.decode("utf-8")
        # Preserve the exact input even when its semantic validation fails.
        record({"kind": "seedMetricsInput", "byteCount": len(raw),
                "sha256": hashlib.sha256(raw).hexdigest(), "text": text})
        value = json.loads(text, object_pairs_hook=unique_object)
        if not isinstance(value, dict) or value.get("schemaVersion") != "arkdeck-runtime-soak/v1" or value.get("phase") != "completed":
            raise ValueError("seed metrics are not a completed soak document")
        states = value.get("jobStates")
        counts = ["terminalJobCount", "activeJobCount", "verifiedArtifactEvidenceJobCount",
                  "stateFileCount", "stateByteCount", "journalCount", "journalByteCount"]
        if (not isinstance(states, dict) or not states
                or any(not isinstance(k, str) or type(v) is not int or v < 0 for k, v in states.items())
                or any(type(value.get(k)) is not int or value[k] < 0 for k in counts)):
            raise ValueError("seed metrics contain invalid observed counts")
        total = sum(states.values())
        terminal = sum(v for k, v in states.items() if k in {"succeeded", "cancelled", "failed", "interrupted"})
        if (value["activeJobCount"] != 0 or value["terminalJobCount"] != terminal
                or total != terminal or value["verifiedArtifactEvidenceJobCount"] > terminal):
            raise ValueError("seed observed counts are inconsistent or still active")
        record({"kind": "seedWorkload", "observedTotalJobCount": total,
                **{k: value[k] for k in counts}, "jobStates": states})
    except (OSError, ValueError) as error:
        record({"kind": "seedMetricsValidation", "status": "FAILED",
                "errorType": type(error).__name__})
        raise
