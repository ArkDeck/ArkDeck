"""E0 read-only identity/mode readback for the CHG-2026-025 TASK-AIN-004 standing
authorization (AUTH-2026-025-DAYU200-001).

Purpose (E0, read-only): confirm the physical target attached to the host IS the
authorized DAYU200 by matching its serial digest against the value pinned in the
standing authorization, and record its USB mode. This produces the identity half
of the r2 finalization. It deliberately does NOT read or fabricate a device
``bindingRevision``: that value has no host read-path (neither the ``arkdeck`` CLI
nor hdc exposes it); it is ArkDeck durable-journal state, resolved at execution
time. See README.md "Binding revision" for how r2 sets it.

Model and safety properties mirror ``scripts/m0b_capture/capture.py`` (the M0B
read-only capture precedent), enforced here rather than merely documented:

  * closed read-only command allowlist — argv is built only from a fixed spec
    that IS the registered allowlist entry (identity check, not name check); no
    operator-composed command string is ever run. No install/file/reboot/flash/
    tmode verb appears; the only device-state change in the whole AIN-004 flow is
    the E2 flash, which is not this script.
  * no shell — subprocess argv arrays only, never a host shell.
  * serial-bearing output lives OUTSIDE any git repository — the out-dir real
    path is walked for a ``.git`` and refused if inside a checkout, so raw serial
    bytes never land in the ArkDeck tree.
  * repo-safe redacted summary — the summary that may be quoted into the run
    record carries only SHA-256 digests, match booleans and the USB mode; it is
    re-scanned by an output-side gate and withheld if any sensitive value
    survives.

The pinned expectations below come from AUTH-2026-025-DAYU200-001.json and the
DAYU200 hard facts; a serial-digest mismatch means the attached device is not the
authorized target and the readback fails closed (exit 1).

Exit codes: 0 = readback ok AND serial digest matches the pinned target; 1 =
readback ran but the device is not the authorized target (serial digest mismatch)
or the sensitive-content self-check failed; 2 = usage or harness error (refused
out-dir, unexecutable hdc, existing output file, redaction-gate failure).
"""

from __future__ import annotations

import argparse
import copy
import dataclasses
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time
from typing import Callable, Optional

SUMMARY_SCHEMA = "arkdeck-e0-readback-1.0.0"
REDACTED_SCHEMA = "arkdeck-e0-readback-redacted-1.0.0"

# --- pinned expectations (AUTH-2026-025-DAYU200-001 / DAYU200 hard facts) -------

# SHA-256 of the DAYU200 serial recorded in-repo by EVD-M0B-DAYU200-20260718-001.
# The authorized device's serial must digest to exactly this. Raw serial bytes are
# never embedded here — only the digest.
PINNED_SERIAL_SHA256 = "958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e"

# USB identity of the RK3568/DAYU200 across its modes (hard-facts memory / FA-001).
USB_VENDOR_ID = 0x2207
USB_MODE_BY_PRODUCT_ID = {
    0x0018: "normalSystemHdc",
    0x5000: "updaterHdc",
    0x350A: "rockUsbLoader",
}

DEFAULT_TIMEOUT_SECONDS = 60
MAX_STREAM_BYTES = 1 * 1_024 * 1_024


class ReadbackError(Exception):
    """A harness/usage error that is not a captured command failure."""


# --- closed read-only command allowlist ---------------------------------------


@dataclasses.dataclass(frozen=True)
class CommandSpec:
    """A single allowlisted read-only hdc command. ``tokens`` are FIXED; this
    script supplies no operator-composed argument at all (identity readback needs
    no ``-t`` target: discovery output already carries the connect key/serial)."""

    ident: str
    tokens: tuple[str, ...]
    purpose: str


COMMAND_SPECS: tuple[CommandSpec, ...] = (
    CommandSpec("hdc-version", ("-v",), "hdc client version"),
    CommandSpec("hdc-checkserver", ("checkserver",), "hdc server/daemon version"),
    CommandSpec("hdc-list-targets", ("list", "targets"), "device discovery (connect key/serial)"),
    CommandSpec(
        "hdc-list-targets-verbose", ("list", "targets", "-v"),
        "device discovery with detail (serial + state)"),
)

SPECS_BY_ID = {spec.ident: spec for spec in COMMAND_SPECS}


def build_argv(hdc_path: str, spec: CommandSpec) -> list[str]:
    """Compose the argv for one allowlisted spec. The spec must BE the registered
    allowlist object (identity, not name): a look-alike carrying a known ident
    with different tokens is refused. No operator value is ever concatenated."""
    if SPECS_BY_ID.get(spec.ident) is not spec:
        raise ReadbackError(f"refusing command outside the closed allowlist: {spec.ident}")
    return [hdc_path, *spec.tokens]


# --- runner injection (tests pass a fake; production spawns hdc) ---------------


@dataclasses.dataclass(frozen=True)
class RunnerResult:
    exit_code: Optional[int]
    timed_out: bool
    stdout: bytes
    stderr: bytes
    duration_ms: int


Runner = Callable[[list[str], int], RunnerResult]


def subprocess_runner(argv: list[str], timeout: int) -> RunnerResult:
    started = time.monotonic()
    try:
        completed = subprocess.run(  # noqa: S603 - argv array, never shell
            argv, capture_output=True, stdin=subprocess.DEVNULL, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as expired:
        return RunnerResult(
            exit_code=None, timed_out=True,
            stdout=expired.stdout or b"", stderr=expired.stderr or b"",
            duration_ms=int((time.monotonic() - started) * 1_000))
    return RunnerResult(
        exit_code=completed.returncode, timed_out=False,
        stdout=completed.stdout[:MAX_STREAM_BYTES],
        stderr=completed.stderr[:MAX_STREAM_BYTES],
        duration_ms=int((time.monotonic() - started) * 1_000))


# --- serial digest + USB mode logic (pure, host-testable) ---------------------

# A DAYU200 discovery line is a connect key/serial token: 32 hex chars (the M0B
# form) or a hyphenated variant. We digest the exact token bytes as reported.
_SERIAL_TOKEN = re.compile(rb"\b([0-9A-Fa-f]{16,64})\b")


def serial_digest(serial_token: bytes) -> str:
    """SHA-256 of the exact serial token bytes, lowercase hex. The pinned digest
    is computed the same way over the same canonical token, so a match proves the
    attached device is the authorized target without the raw serial ever entering
    the repo."""
    return hashlib.sha256(serial_token).hexdigest()


def extract_serial_tokens(discovery_stdout: bytes) -> list[bytes]:
    """Return candidate serial tokens from ``hdc list targets`` stdout, in order.
    ``[Empty]`` and non-token lines yield nothing (a device that is absent or only
    in Loader mode produces no hdc serial — that is handled by the caller as
    ``no-serial``, never as a match)."""
    tokens: list[bytes] = []
    for line in discovery_stdout.splitlines():
        stripped = line.strip()
        if not stripped or stripped.lower() == b"[empty]":
            continue
        match = _SERIAL_TOKEN.match(stripped)
        if match:
            tokens.append(match.group(1))
    return tokens


def matches_pinned_serial(discovery_stdout: bytes, pinned: str = PINNED_SERIAL_SHA256) -> dict:
    """Compare every discovered serial token's digest against the pinned target.
    Returns a verdict dict. A match requires exactly one token whose digest equals
    the pinned value; zero tokens (no hdc serial) or any non-matching set is NOT a
    match (fail closed)."""
    tokens = extract_serial_tokens(discovery_stdout)
    digests = [serial_digest(token) for token in tokens]
    matched = pinned.lower() in digests
    return {
        "serialTokenCount": len(tokens),
        "observedDigests": digests,
        "pinnedDigest": pinned.lower(),
        "matched": matched,
    }


def classify_usb_mode(product_id: int) -> str:
    """Map a 0x2207 product id to a DAYU200 mode name; unknown ids classify as
    ``unknown`` (never guessed into a known mode)."""
    return USB_MODE_BY_PRODUCT_ID.get(product_id, "unknown")


def parse_usb_identities(system_profiler_json: bytes) -> list[dict]:
    """Extract every 0x2207 USB device from ``system_profiler SPUSBDataType -json``
    output. Read-only host introspection; no device state is touched. Returns a
    list of {vendorId, productId, mode}. Malformed/absent input yields []."""
    try:
        document = json.loads(system_profiler_json or b"{}")
    except (json.JSONDecodeError, ValueError):
        return []
    found: list[dict] = []

    def walk(node: object) -> None:
        if isinstance(node, dict):
            vendor = _hex_id(node.get("vendor_id"))
            product = _hex_id(node.get("product_id"))
            if vendor == USB_VENDOR_ID and product is not None:
                found.append(
                    {"vendorId": vendor, "productId": product, "mode": classify_usb_mode(product)})
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(document)
    return found


def _hex_id(raw: object) -> Optional[int]:
    """system_profiler renders ids like ``"0x2207"`` (sometimes with a trailing
    vendor name). Parse the leading hex; return None if absent/unparseable."""
    if not isinstance(raw, str):
        return None
    match = re.match(r"\s*0x([0-9A-Fa-f]+)", raw)
    return int(match.group(1), 16) if match else None


# --- redaction (repo-safe summary) --------------------------------------------

# One pattern literal, compiled for both str (redaction of the summary) and bytes
# (sensitive-content scan of raw device stdout), so the two can never drift.
_USER_PATH_PATTERN = r"/(?:Users|home)/[^/\s\x00:]+|/var/root"
_USER_PATH = re.compile(_USER_PATH_PATTERN)
_USER_PATH_BYTES = re.compile(_USER_PATH_PATTERN.encode("ascii"))


def _mask_home(text: str, home: str) -> str:
    root = home.rstrip("/") if home else ""
    if root:
        text = re.compile(re.escape(root) + r'(?=/|$|[\s:"])', re.IGNORECASE).sub("~", text)
    return _USER_PATH.sub("<redacted-user-dir>", text)


def _assert_redacted_clean(payload_text: str, home: str, serial_tokens: list[str]) -> None:
    """Output-side gate: re-scan the serialized redacted summary. A surviving user
    path or raw serial token means the summary is withheld and the run fails."""
    leaks = []
    root = home.rstrip("/") if home else ""
    if root and re.search(re.escape(root) + r'(?=/|$|[\s:"])', payload_text, re.IGNORECASE):
        leaks.append("operator home path")
    if _USER_PATH.search(payload_text):
        leaks.append("user directory path")
    for token in serial_tokens:
        if token and token in payload_text:
            leaks.append("raw serial token")
            break
    if leaks:
        raise ReadbackError(
            "redaction gate failed (" + ", ".join(sorted(set(leaks))) + " present in the "
            "redacted summary); redacted-summary.json NOT written — investigate before "
            "referencing anything from this run")


# --- output-location safety ---------------------------------------------------


def assert_outside_repository(path: str) -> None:
    """Refuse to write readback output anywhere inside a git working tree, walking
    the symlink-resolved real path so a symlinked out-dir into a checkout is
    refused too."""
    current = os.path.realpath(path)
    while True:
        if os.path.exists(os.path.join(current, ".git")):
            raise ReadbackError(
                "refusing to write readback output inside a git repository "
                f"(.git found at {current}); choose a controlled location outside any repo")
        parent = os.path.dirname(current)
        if parent == current:
            return
        current = parent


# --- capture pipeline ---------------------------------------------------------


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _json_bytes(document: dict) -> bytes:
    return (json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
        "utf-8")


def _write_new(out_dir: str, name: str, data: bytes) -> None:
    target = os.path.join(out_dir, name)
    try:
        with open(target, "xb", opener=lambda p, f: os.open(p, f, 0o600)) as handle:
            handle.write(data)
    except FileExistsError:
        raise ReadbackError(
            f"refusing to overwrite existing output file: {target}; use a fresh --out-dir"
        ) from None


def readback(
    hdc_path: str,
    out_dir: str,
    runner: Runner = subprocess_runner,
    usb_reader: Optional[Callable[[], bytes]] = None,
    timeout: int = DEFAULT_TIMEOUT_SECONDS,
    home: Optional[str] = None,
) -> dict:
    """Run the closed read-only identity allowlist plus a USB enumeration, compute
    the serial-digest verdict and USB modes, and write the raw streams + a full
    and a redacted summary into ``out_dir``. Returns the full summary dict."""
    if timeout <= 0:
        raise ReadbackError(f"--timeout must be a positive number of seconds, got {timeout}")
    assert_outside_repository(out_dir)
    home = home if home is not None else os.path.expanduser("~")

    resolved_hdc = os.path.realpath(hdc_path)
    if not os.path.isfile(resolved_hdc) or not os.access(resolved_hdc, os.X_OK):
        raise ReadbackError(f"hdc binary is not an executable regular file: {resolved_hdc}")
    with open(resolved_hdc, "rb") as handle:
        hdc_sha256 = hashlib.sha256(handle.read()).hexdigest()

    os.makedirs(out_dir, mode=0o700, exist_ok=True)

    commands: list[dict] = []
    discovery_stdout = b""
    for index, spec in enumerate(COMMAND_SPECS):
        argv = build_argv(resolved_hdc, spec)
        try:
            result = runner(argv, timeout)
        except OSError as error:
            raise ReadbackError(f"failed to execute hdc for {spec.ident}: {error}") from None
        _write_new(out_dir, f"{index:02d}-{spec.ident}.stdout", result.stdout)
        _write_new(out_dir, f"{index:02d}-{spec.ident}.stderr", result.stderr)
        if spec.ident == "hdc-list-targets":
            discovery_stdout = result.stdout
        commands.append({
            "commandId": spec.ident,
            "purpose": spec.purpose,
            "argv": [resolved_hdc, *spec.tokens],
            "exitCode": result.exit_code,
            "timedOut": result.timed_out,
            "durationMs": result.duration_ms,
            "stdout": {"sha256": _sha256(result.stdout), "bytes": len(result.stdout)},
            "stderr": {"sha256": _sha256(result.stderr), "bytes": len(result.stderr)},
        })

    usb_bytes = (usb_reader or _default_usb_reader)()
    _write_new(out_dir, "usb-enumeration.json", usb_bytes)
    usb_identities = parse_usb_identities(usb_bytes)
    serial_verdict = matches_pinned_serial(discovery_stdout)

    raw_serial_tokens = [token.decode("latin-1") for token in extract_serial_tokens(discovery_stdout)]
    sensitive_ok = not _USER_PATH_BYTES.search(discovery_stdout)

    summary = {
        "schema": SUMMARY_SCHEMA,
        "change": "CHG-2026-025-ai-native-unattended-device-ops",
        "task": "TASK-AIN-004",
        "authorization": "AUTH-2026-025-DAYU200-001",
        "evidenceClass": "controlledReadback",
        "toolchain": {"hdcPath": resolved_hdc, "hdcSha256": hdc_sha256, "transport": "usb"},
        "host": {
            "os": platform.system(),
            "osVersion": platform.mac_ver()[0] or platform.release(),
            "arch": platform.machine(),
        },
        "commands": commands,
        "usbIdentities": usb_identities,
        "serialVerdict": {
            "serialTokenCount": serial_verdict["serialTokenCount"],
            "observedDigests": serial_verdict["observedDigests"],
            "pinnedDigest": serial_verdict["pinnedDigest"],
            "matched": serial_verdict["matched"],
        },
        "sensitiveSelfCheckPassed": sensitive_ok,
        "bindingRevisionNote": (
            "This readback confirms identity only. target.bindingRevision has no host "
            "read-path; resolve it at r2 from ArkDeck's durable device-binding journal "
            "(initial durable binding == revision 1 per Core DeviceBindingHistory), and "
            "supply the same value in --unattended-context at execution. The gate fails "
            "closed if the two ever diverge."),
        "boundary": (
            "read-only identity/mode readback; no device state changed; not a support or "
            "hardware-acceptance claim. Serial-bearing bytes remain in this controlled "
            "non-repository location; only digests and match booleans are repo-safe."),
    }

    _write_new(out_dir, "summary.json", _json_bytes(summary))
    redacted = _redacted_summary(summary, home)
    redacted_bytes = _json_bytes(redacted)
    _assert_redacted_clean(redacted_bytes.decode("utf-8"), home, raw_serial_tokens)
    _write_new(out_dir, "redacted-summary.json", redacted_bytes)
    return summary


def _redacted_summary(summary: dict, home: str) -> dict:
    """Deep copy with the schema id swapped and the hdc path masked. Digests and
    booleans flow through unchanged; the serialized result still passes the
    redaction gate before it is written."""
    redacted = copy.deepcopy(summary)
    redacted["schema"] = REDACTED_SCHEMA
    redacted["toolchain"]["hdcPath"] = _mask_home(summary["toolchain"]["hdcPath"], home)
    return redacted


def _default_usb_reader() -> bytes:
    """Read USB enumeration via system_profiler (read-only). Returns b'{}' if the
    tool is unavailable, so a host without it degrades to 'no USB identities' rather
    than crashing."""
    try:
        completed = subprocess.run(  # noqa: S603 - argv array, never shell
            ["/usr/sbin/system_profiler", "SPUSBDataType", "-json"],
            capture_output=True, stdin=subprocess.DEVNULL, timeout=DEFAULT_TIMEOUT_SECONDS,
            check=False)
    except (OSError, subprocess.TimeoutExpired):
        return b"{}"
    return completed.stdout or b"{}"


# --- host self-test (no device) -----------------------------------------------


def selftest_host() -> bool:
    """Exercise every pure decision the readback makes, with synthetic inputs and
    no device, so the device-window operator can confirm the crib is sane before
    use. Returns True on success."""
    checks: list[tuple[str, bool]] = []

    # argv is closed: a look-alike spec is refused.
    try:
        build_argv("/hdc", CommandSpec("hdc-version", ("shell", "rm"), "x"))
        checks.append(("closed-allowlist-refuses-lookalike", False))
    except ReadbackError:
        checks.append(("closed-allowlist-refuses-lookalike", True))
    checks.append(
        ("argv-is-fixed-tokens", build_argv("/hdc", SPECS_BY_ID["hdc-list-targets"])
         == ["/hdc", "list", "targets"]))

    # serial digest: the pinned serial's known preimage digests to the pinned value.
    known_serial = b"150100424a544434520325874bbf4900"
    checks.append(("pinned-preimage-digests-to-pin", serial_digest(known_serial) == PINNED_SERIAL_SHA256))
    match = matches_pinned_serial(known_serial + b"\tstate\n")
    checks.append(("matching-device-verdict-true", match["matched"] is True))
    checks.append(
        ("wrong-device-verdict-false",
         matches_pinned_serial(b"deadbeefdeadbeefdeadbeefdeadbeef\n")["matched"] is False))
    checks.append(
        ("empty-discovery-verdict-false",
         matches_pinned_serial(b"[Empty]\n")["matched"] is False))

    # USB mode classification and 0x2207 extraction.
    checks.append(("loader-mode", classify_usb_mode(0x350A) == "rockUsbLoader"))
    checks.append(("normal-mode", classify_usb_mode(0x0018) == "normalSystemHdc"))
    checks.append(("unknown-mode", classify_usb_mode(0x1234) == "unknown"))
    usb_json = json.dumps(
        {"SPUSBDataType": [{"_items": [{"vendor_id": "0x2207", "product_id": "0x350a"}]}]}
    ).encode()
    parsed = parse_usb_identities(usb_json)
    checks.append(("usb-parse-finds-loader", parsed == [{"vendorId": 0x2207, "productId": 0x350A, "mode": "rockUsbLoader"}]))
    checks.append(("usb-parse-malformed-empty", parse_usb_identities(b"not json") == []))

    # redaction gate catches a raw serial leak.
    try:
        _assert_redacted_clean('{"x": "150100424a544434520325874bbf4900"}', "/Users/op",
                               ["150100424a544434520325874bbf4900"])
        checks.append(("redaction-gate-catches-serial", False))
    except ReadbackError:
        checks.append(("redaction-gate-catches-serial", True))

    # exit-code mapping: matched → 0, mismatch → 1.
    checks.append(("exit-map-match-0", _exit_code(True, True) == 0))
    checks.append(("exit-map-mismatch-1", _exit_code(False, True) == 1))
    checks.append(("exit-map-sensitive-1", _exit_code(True, False) == 1))

    ok = all(passed for _, passed in checks)
    for name, passed in checks:
        print(f"  [{'PASS' if passed else 'FAIL'}] {name}")
    print(f"selftest-host: {'PASS' if ok else 'FAIL'} ({sum(p for _, p in checks)}/{len(checks)})")
    return ok


def _exit_code(serial_matched: bool, sensitive_ok: bool) -> int:
    """Success requires BOTH the authorized device (serial digest match) and a
    clean sensitive-content check; either failing is exit 1 (fail closed)."""
    return 0 if (serial_matched and sensitive_ok) else 1


# --- CLI ----------------------------------------------------------------------


def _positive_int(value: str) -> int:
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not an integer: {value!r}") from None
    if number <= 0:
        raise argparse.ArgumentTypeError(f"must be a positive number of seconds, got {number}")
    return number


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="capture.py",
        description="E0 read-only DAYU200 identity/mode readback for AUTH-2026-025-DAYU200-001.")
    parser.add_argument(
        "--selftest-host", action="store_true",
        help="run all pure-logic self-checks with no device and exit")
    parser.add_argument("--hdc", help="absolute path to the hdc binary")
    parser.add_argument(
        "--out-dir", help="controlled output directory OUTSIDE any git repository")
    parser.add_argument("--timeout", type=_positive_int, default=DEFAULT_TIMEOUT_SECONDS)
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    arguments = build_arg_parser().parse_args(argv)
    if arguments.selftest_host:
        return 0 if selftest_host() else 1
    if not arguments.hdc or not arguments.out_dir:
        print("usage: --hdc <path> --out-dir <dir>  (or --selftest-host)", file=sys.stderr)
        return 2
    try:
        summary = readback(hdc_path=arguments.hdc, out_dir=arguments.out_dir,
                           timeout=arguments.timeout)
    except ReadbackError as error:
        print(f"readback error: {error}", file=sys.stderr)
        return 2

    verdict = summary["serialVerdict"]
    sensitive_ok = summary["sensitiveSelfCheckPassed"]
    modes = sorted({identity["mode"] for identity in summary["usbIdentities"]}) or ["<none>"]
    print(f"E0 readback complete. USB 0x2207 modes: {', '.join(modes)}")
    print(f"serial digest match vs pinned target: {verdict['matched']} "
          f"({verdict['serialTokenCount']} token(s) seen)")
    print(f"controlled output: {os.path.abspath(arguments.out_dir)}")
    if not sensitive_ok:
        print("WARNING: user path found in discovery output; do not copy raw bytes into the repo.",
              file=sys.stderr)
    if not verdict["matched"]:
        print("device is NOT the authorized target (serial digest mismatch or no hdc serial); "
              "fail closed — do not proceed to r2 with this device.", file=sys.stderr)
    return _exit_code(verdict["matched"], sensitive_ok)


if __name__ == "__main__":
    sys.exit(main())
