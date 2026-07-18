# DAYU200 pinned-image partition decoder — r2

CHG-2026-009 / TASK-PD-001. Offline, read-only research tooling. The result is
non-authoritative and valid only for pinned archive identity
`fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`.
It derives no flash address, protocol, compatibility, product-integration,
hardware-support or release claim.

## Input boundary

`decode.py` has no CLI and accepts no archive path. Its production entry point
is `decode_archive(descriptor, audit=None)`. Before the first byte is read it:

1. rejects non-integer/invalid descriptors;
2. runs `fstat` and accepts only a regular file;
3. runs `F_GETFL` and accepts only `O_RDONLY`;
4. duplicates the caller-owned capability with `dup` and repeats the gates;
5. applies the pinned size/SHA-256 identity gate.

Its complete OS call-target set is `fstat`, `fcntl(F_GETFL)`, `dup`, `fdopen`
and `close`. It contains no `open`, `openat`, `lstat`, pathname resolution,
subprocess, network, transport, device-mutation or extraction path.

The descriptor comes from the separately built and ad-hoc-signed macOS App
Sandbox broker under `macos_input_broker/`. The broker:

- accepts no command-line archive path;
- acquires one file only through `NSOpenPanel`/PowerBox;
- rejects standardized `/dev` paths before its sole archive `open`;
- opens with `O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC`;
- has no USB, serial, raw-disk or network entitlement;
- queries the live App Sandbox policy for raw disk/USB-serial device paths,
  network and process-exec denial without opening a device node;
- calls the embedded decoder in the same process through the CPython C API,
  passing only the integer fd.

The only non-product entitlement exception is a fixed read-only CPython 3.14
framework path required by this local platform-evidence artifact. It does not
grant archive, device, network or write access. Existing `ArkDeckApp` does not
participate in this boundary.

## Stream and grammar boundary

The pinned input is one gzip/DEFLATE tar stream and `parameter.txt` is member 8.
To reach it, the decoder consumes preceding bodies in logical chunks no larger
than 1 MiB. Each application-visible output chunk is counted and its reference
is released before the next read; it is never parsed, hashed, returned to the
parameter decoder, logged or persisted. Reading stops immediately after the
target body. The target size/hash is pinned before the closed CMDLINE/mtdparts
grammar is parsed; every unknown form fails explicitly.

DEFLATE decoding necessarily keeps opaque sliding history inside zlib across
calls. Revision r2 does not say whether that mandatory codec state is exempt
from “not retained across chunks”. The implementation therefore records the
application-visible lifecycle separately and marks the partition AC/task
`BLOCKED` pending governance clarification; it does not report literal zero
cross-chunk retention or a passing three-AC result.

The original parameter text and archive locator never enter evidence.

## Build and verification

The build/sign script requires a new output directory and explicit CPython
header/library directories:

```text
scripts/partition_decode/macos_input_broker/build_and_sign.zsh \
  /private/tmp/pd001-broker-build \
  /opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/include/python3.14 \
  /opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/lib
```

It compiles with explicit argv, signs with the fixed entitlement plist and runs
`codesign --verify --strict`. `collect_platform_evidence.py` accepts only a new
output-directory name: it builds the reviewed source itself, independently
verifies the signed artifact before and after execution, inspects the complete
bundle manifest/entitlements/linkage, and captures a runtime receipt from the
verified child stdout pipe. The Python version comes from embedded CPython in
that child, never from `/usr/bin/python3` or a caller text file.

The receipt binds the running bundle identifier/CDHash to the three exact core
JSON hashes. In the same collector process, `evidence.py` revalidates the
receipt, current reviewed-source hashes, signed manifest, platform evidence and
core bytes together, then publishes six create-only files (three core JSON
files, runtime receipt, platform evidence and blocked summary) into a new run
directory. There is no standalone staging/publication CLI; caller-supplied
artifacts, receipts, core outputs and PASS assertions are not accepted.

Tests:

```text
env PYTHONWARNINGS=error python3 scripts/partition_decode/test_decode.py
```

Device-mode negative tests use mocked `fstat` metadata. They never open a real
character/block device node.
