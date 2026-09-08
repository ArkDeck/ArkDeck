# Platform boundary (TASK-XPA-002)

The crate supplies authenticated local byte streams and bounded, hash-pinned
read-only process execution. No wire contract contains its executable paths,
argument arrays or installation identity configuration. It has no capability,
recovery, journal or device-mutation API.

- Unix sockets require a physical owner-only `0700` parent and a `0600` socket;
  both ends verify peer effective UID. Bind never unlinks an existing endpoint.
- Windows listeners explicitly use the current logon SID DACL,
  `FILE_FLAG_FIRST_PIPE_INSTANCE` and `PIPE_REJECT_REMOTE_CLIENTS`. The accepted
  connection's client PID is held through a process handle and checked against
  the daemon's user SID and elevation before a handler can receive it.
- Windows clients use identification SQOS, compare pipe owner SID to their own
  token owner SID, then verify this connection's server PID, installed image
  path, and a trusted Authenticode signing-certificate SHA256 or exact MSIX family.
  They retain the process and image handles until disconnect. If server PID is
  unavailable, they fail before sending frames; no identity fallback is enabled.
- `VerifiedTool` retains the hashed regular file. macOS launches its `/.vol`
  inode path suspended, revalidates before resuming, and retains the child PID
  with `WNOWAIT` until process-group cleanup. Windows denies file writes/deletion,
  holds physical parent directories against replacement, starts suspended,
  checks the child image, assigns a kill-on-close job and then resumes it. Both
  use argv arrays, a clean child environment, combined stdout/stderr limits and
  deadlines. The only provider environment override is a numeric
  `OHOS_HDC_SERVER_PORT`; it never changes the user's environment.
- Process output completion uses bounded channel waits. Unix readers are
  nonblocking; the Windows reader peeks before reading available bytes, with one
  reader per pipe. Termination errors are returned, and Windows cleanup waits for
  the retained process and an empty Job Object within a five-second budget.
  Named-pipe I/O expiry requests cancellation, then drains kernel completion to
  keep the borrowed buffer safe. A strict cancellation wall-clock bound is not
  established by this implementation or cross compilation; native cancellation
  latency and races remain part of SPK-3 validation.
- The Windows `LoopbackServerLease` reads the kernel TCP owner table without a
  network connection or process spawn. It requires exactly one listener at the
  specified IPv4 loopback endpoint, the verified tool's file identity, matching
  process user/elevation and a retained process creation identity, checked before
  and after observation. Missing/ambiguous/wildcard/changed identity is refused.
  The macOS equivalent is explicitly unavailable in this delivery: that shadow
  provider must not run HDC without the missing proof.

The trust boundary is the current design F.2: arbitrary same-user code is outside
the boundary; the same user's correctly signed installed daemon is trusted.
The stricter failure when server PID is unavailable does not establish whether
that API works on supported Windows builds. SPK-3 measures it on a `CreateFileW`
client handle, since the [Microsoft reference](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeserverprocessid)
still describes a `CreateNamedPipe` handle. Pipe access rights follow
[Named Pipe Security and Access Rights](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights).

## Validation

```sh
cargo test -p arkdeck-platform
cargo clippy -p arkdeck-platform --all-targets -- -D warnings
cargo check -p arkdeck-platform --target x86_64-pc-windows-msvc --all-targets
cargo run -p arkdeck-platform --example windows_spk3 -- process-selftest
```

The tests create isolated host fixtures. macOS results and a Windows cross build
do not count as Windows OS or hardware acceptance. Windows-native tests cover
actual named-pipe name ownership, same-account wrong-image/unsigned-server
zero-frame refusals, exact completion counts, rapid-disconnect recovery, exit
code 259, open-writer behavior, cleanup failure reporting, checked token/TCP
array lengths, and existing-listener kernel identity. Successful trusted
publisher/package authentication, cross-account/elevation/remote tests and
packaged client access still need the corresponding real host/setup.

## SPK-3 on Windows

Build `cargo build --release -p arkdeck-platform --example windows_spk3` and use
`rust/scripts/windows-spk3.ps1` with the actual daemon, CLI and probe paths plus
the installation's signer/package identity. Supply a new output directory;
the script refuses to overwrite prior records. It only controls its own test
daemon/probe processes. It does not start HDC, install certificates/drivers,
unblock downloaded executables, change policy or create accounts.

The script records binary hashes, OS build/architecture, MotW and Authenticode
state, the client-handle server-PID result, first-instance and same-account squat
refusals, product command output, and remaining setup conditions. A supplied
second-account credential enables cross-account checks. A supplied distinct
remote session plus identical probe enables the remote-client test. A registered
MSIX probe can prove package identity and connection; the script checks the
observed family instead of inferring packaging from its path. Credentials are
never written to the record.

Supply `-PythonPath` with a Python interpreter containing `jsonschema` to validate
the recorded CLI envelopes and method results. The harness first confirms that
all producer processes have exited and all outputs have drained, writes
`spk3.json` with `recordingComplete`, then invokes
`check-readonly.py --spk3-recordings`. The derived `spk3-schema-validation.json`
and `schema-invocation.json` record that later result without rewriting the raw
host record. Missing interpreter/dependencies or unfinished recording remain
unvalidated, never a schema or device acceptance pass.

For an elevated same-user client, first run this in the normal user's terminal
with an isolated `\\.\pipe\arkdeck-spk3-*` endpoint:

```powershell
& $ProbePath guard-server $Endpoint
```

Then run this from a separately elevated terminal:

```powershell
& $ProbePath raw-connect $Endpoint
```

This raw probe sends zero bytes and checks OS connection behavior only. A pipe
open may succeed before the daemon's SID/elevation validation closes it; proving
the server refusal additionally requires the `guard-server-result` record to
show `authenticated: false` and `frameConsumerEntries: 0`.
Do not describe a client-only result as proof that no handler ran.

The host record remains `INCOMPLETE` until its external conditions and actual
DAYU200/current Windows HDC profile are reviewed. A zero exit code for candidates
does not prove the connected board's identity, and an empty result does not pass
hardware acceptance. Existing Windows tuple/driver/signing gaps are not replaced
with a fixture, fabricated hash registration or a support declaration.
