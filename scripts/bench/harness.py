"""Isolated Runtime under measurement, plus the host guards around it.

Every number this harness produces comes from a daemon the harness started
itself, against a state directory the harness created, seeded and will delete.
It never talks to the installed LaunchAgent, never adopts a target and never
reaches a device: `arkdeck-agentd --state-dir <dir>` with no ArkForge bundle and
no adopted target refuses device work by construction, which is what makes the
measurement repeatable on a CI runner.

Two host facts decide whether a run may become a baseline at all:

* the socket path must fit Darwin's 104-byte `sun_path`, so the state directory
  lives under the system temporary directory rather than a descriptive one
  (`AgentDaemon.swift` says so in its own error text);
* the machine must be quiet.  Wall-clock percentiles on a loaded host are the
  documented failure mode of this repository's earlier timing work
  (`ViewerScalePerformanceTests.swift` refuses wall-clock budgets for exactly
  that reason), and SPK-1 fails outright when p95 moves more than 30% between
  runs.  A loaded host is therefore refused up front instead of quietly
  producing a number that will not reproduce.

On Windows the daemon serves a named pipe named after its development root,
which it records in the root's `instance.json`; every host fact above is read
through the Windows counterpart `windows_host` documents.
"""

from __future__ import annotations

import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import tempfile
import time

from . import clocks, control, observations, windows_host

SOCKET_NAME = "agentd.sock"
# Darwin's sun_path is 104 bytes including the terminator.
MAXIMUM_SOCKET_PATH_BYTES = 103
# A quiet host is one whose one-minute load average is at most half its CPU
# count.  Above that, timing samples stop reproducing; see the module docstring.
QUIET_LOAD_RATIO = 0.5


class HostTooBusy(RuntimeError):
    """The one-minute load average is too high for a reproducible sample."""

    def __init__(self, message, *, facts=None):
        super().__init__(message)
        self.facts = {"oneMinuteLoad": None, "loadThreshold": None,
                      "processCheckPerformed": None, "conflictingBuildProcesses": None,
                      **(facts or {})}


class DaemonStartFailed(RuntimeError):
    """The isolated daemon did not reach a healthy state within its budget."""


def on_windows() -> bool:
    return windows_host.IS_WINDOWS


def load_average() -> tuple[float, ...]:
    """The load figures; callers read only the first, the one-minute load.

    Windows keeps no load average: its one figure is the CPUs kept busy over a
    one-second window (`windows_host.LOAD_SOURCE`).
    """
    if on_windows():
        return (windows_host.load_equivalent(cpu_count()),)
    return os.getloadavg()


def cpu_count() -> int:
    return os.cpu_count() or 1


def quiet_load_ceiling() -> float:
    return cpu_count() * QUIET_LOAD_RATIO


def assert_host_is_quiet() -> float:
    """Return the one-minute load average, or refuse a loaded host."""

    one_minute = load_average()[0]
    ceiling = quiet_load_ceiling()
    if one_minute > ceiling:
        raise HostTooBusy(
            f"one-minute load average {one_minute:.2f} exceeds {ceiling:.2f} "
            f"({cpu_count()} CPUs x {QUIET_LOAD_RATIO}); a sample taken now will "
            "not reproduce.  Wait for the host to go quiet, or pass "
            "--allow-loaded-host to record an advisory run that is not "
            "baseline-eligible.",
            facts={"oneMinuteLoad": one_minute, "loadThreshold": ceiling,
                   "processCheckPerformed": False, "conflictingBuildProcesses": None},
        )
    return one_minute


def wait_for_quiet_host(
    max_wait_seconds: float = 0.0, poll_seconds: float = 5.0
) -> tuple[float, float]:
    """Return `(one-minute load, seconds waited)` once the host is quiet.

    With no wait budget this is exactly `assert_host_is_quiet`.  With one, a
    loaded host is checked again every `poll_seconds` until it is quiet or the
    budget is spent, and is then refused exactly as `assert_host_is_quiet`
    refuses it.  A run still starts only on a quiet host.  The wait exists
    because the check runs at the start of every run: on a shared host whose
    idle load sits near the ceiling, one momentary spike at the second or third
    run's start would otherwise discard the runs already measured.  The budget
    is a wait, so it is timed on the continuous clock (REQ-NFR-001).
    """

    if max_wait_seconds < 0:
        raise ValueError("the quiet-host wait must not be negative")
    if poll_seconds <= 0:
        raise ValueError("the quiet-host poll interval must be positive")
    started = clocks.elapsed_seconds()
    while True:
        try:
            return assert_host_is_quiet(), clocks.elapsed_seconds() - started
        except HostTooBusy:
            if clocks.elapsed_seconds() - started + poll_seconds > max_wait_seconds:
                raise
            time.sleep(poll_seconds)


def host_facts() -> dict[str, object]:
    """Non-identifying host description.

    Deliberately excludes host name, user name and any path under the user's
    home directory: a baseline document is committed to the repository.
    """

    facts = {
        "os": platform.system(),
        "osVersion": platform.mac_ver()[0] or platform.release(),
        "arch": platform.machine(),
        "cpuCount": cpu_count(),
        "python": platform.python_version(),
    }
    if on_windows():
        # platform.release() says only "10" or "11"; the build names the host.
        facts["osVersion"] = windows_host.os_version()
        facts["hostTag"] = windows_host.host_tag(facts["arch"])
        facts["loadSource"] = windows_host.LOAD_SOURCE
    return facts


def _run(arguments: list[str], timeout: float = 30.0) -> subprocess.CompletedProcess:
    return subprocess.run(
        arguments,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
    )


class ProcessResources:
    """One resource sample of a running process.

    A field that could not be read is `None` with a reason, never zero: a
    missing measurement and a measured zero mean different things and this
    repository has paid for conflating them before.
    """

    def __init__(self) -> None:
        self.resident_set_bytes: int | None = None
        self.cpu_percent: float | None = None
        self.thread_count: int | None = None
        self.open_file_descriptor_count: int | None = None
        # Windows only: open handles and private bytes.
        self.handle_count: int | None = None
        self.private_bytes: int | None = None
        self.unmeasured: dict[str, str] = {}

    def as_document(self) -> dict[str, object]:
        document = {
            "residentSetBytes": self.resident_set_bytes,
            "cpuPercent": self.cpu_percent,
            "threadCount": self.thread_count,
            "openFileDescriptorCount": self.open_file_descriptor_count,
            "unmeasured": dict(self.unmeasured),
        }
        if on_windows():
            document["residentSetSource"] = "WorkingSetSize"
            document["handleCount"] = self.handle_count
            document["privateBytes"] = self.private_bytes
        return document


def _sample_windows_process(pid: int) -> ProcessResources:
    sample = ProcessResources()
    try:
        facts = windows_host.process_resources(pid)
    except OSError as error:
        reason = f"process counters unreadable: {type(error).__name__}"
        for field in ("residentSetBytes", "cpuPercent", "threadCount", "handleCount", "privateBytes"):
            sample.unmeasured[field] = reason
        return sample
    sample.resident_set_bytes = facts["workingSetBytes"]
    sample.cpu_percent = facts["cpuPercent"]
    sample.thread_count = facts["threadCount"]
    sample.handle_count = facts["handleCount"]
    sample.private_bytes = facts["privateBytes"]
    if sample.thread_count is None:
        sample.unmeasured["threadCount"] = "process absent from the Toolhelp snapshot"
    sample.unmeasured["openFileDescriptorCount"] = (
        "Windows has no descriptor table; open handles are handleCount")
    return sample


def sample_process_resources(pid: int) -> ProcessResources:
    if on_windows():
        return _sample_windows_process(pid)
    sample = ProcessResources()

    completed = _run(["ps", "-o", "rss=,%cpu=", "-p", str(pid)])
    fields = completed.stdout.split()
    if completed.returncode == 0 and len(fields) >= 2:
        # `ps` reports RSS in kibibytes on both Darwin and Linux.
        sample.resident_set_bytes = int(fields[0]) * 1024
        sample.cpu_percent = float(fields[1])
    else:
        sample.unmeasured["residentSetBytes"] = "ps did not report rss/%cpu"
        sample.unmeasured["cpuPercent"] = "ps did not report rss/%cpu"

    status = pathlib.Path(f"/proc/{pid}/status")
    if status.exists():
        for line in status.read_text(encoding="utf-8").splitlines():
            if line.startswith("Threads:"):
                sample.thread_count = int(line.split()[1])
                break
    else:
        threads = _run(["ps", "-M", "-p", str(pid)])
        if threads.returncode == 0:
            lines = [line for line in threads.stdout.splitlines() if line.strip()]
            if len(lines) > 1:
                sample.thread_count = len(lines) - 1
    if sample.thread_count is None:
        sample.unmeasured["threadCount"] = "no per-thread listing available"

    descriptors = pathlib.Path(f"/proc/{pid}/fd")
    if descriptors.exists():
        sample.open_file_descriptor_count = len(list(descriptors.iterdir()))
    elif shutil.which("lsof"):
        listed = _run(["lsof", "-p", str(pid), "-Fn"], timeout=60.0)
        if listed.returncode == 0:
            sample.open_file_descriptor_count = sum(
                1 for line in listed.stdout.splitlines() if line.startswith("f")
            )
    if sample.open_file_descriptor_count is None:
        sample.unmeasured["openFileDescriptorCount"] = "no descriptor listing available"

    return sample


class IsolatedRuntime:
    """A daemon started on a private state directory, for measurement only."""

    def __init__(
        self,
        daemon_executable: pathlib.Path,
        state_directory: pathlib.Path,
        *,
        runtime_kind: str = "swift",
    ) -> None:
        if runtime_kind not in {"swift", "rust"}:
            raise ValueError("runtime_kind must be swift or rust")
        self.runtime_kind = runtime_kind
        self.daemon_executable = daemon_executable
        self.state_directory = state_directory
        self.socket_path = state_directory / SOCKET_NAME
        self.process: subprocess.Popen | None = None
        self.start_diagnostics: dict[str, object] = {}
        # Windows: the pipe the development root's daemon names in its
        # instance document, learned at the first start (every later start of
        # the root serves the same name, derived from the root's file identity).
        self.endpoint: str | None = None
        self._output = None
        if on_windows():
            if runtime_kind != "rust":
                raise ValueError("the Windows capture measures the Rust daemon only")
            self.socket_path = None
        elif len(str(self.socket_path).encode("utf-8")) > MAXIMUM_SOCKET_PATH_BYTES:
            raise ValueError(
                f"socket path {self.socket_path} exceeds {MAXIMUM_SOCKET_PATH_BYTES} "
                "bytes; choose a shorter state directory"
            )

    def start(self, budget_seconds: float = 60.0) -> float:
        """Start the daemon and return awake-work seconds through verified health.

        The historical boundary includes the contract-verifying health handshake
        and the following explicit health response. Diagnostics preserve that
        boundary; they do not substitute socket appearance or CPU time.
        """

        if self.process is not None and self.process.poll() is None:
            raise DaemonStartFailed(
                "a daemon is already running on this state directory; stop it "
                "before measuring another cold start"
            )
        environment = dict(os.environ)
        # An ArkForge bundle or an inherited HDC path would make the sample
        # depend on host tooling that a CI runner does not have.
        # Never inherit pairing, provider or endpoint configuration from the
        # caller. In particular a Rust measurement must not start the Swift
        # facade or attach a development HDC fixture from another test.
        for key in list(environment):
            if key.startswith("ARKDECK_"):
                environment.pop(key)
        arguments = [str(self.daemon_executable)]
        if on_windows():
            # A development root's pipe is named after the root; naming
            # another endpoint is refused by the daemon.
            environment["ARKDECK_DEVELOPMENT_STATE_ROOT"] = str(self.state_directory)
        elif self.runtime_kind == "rust":
            environment["ARKDECK_DEVELOPMENT_STATE_ROOT"] = str(self.state_directory)
            environment["ARKDECK_ENDPOINT"] = str(self.socket_path)
        else:
            arguments.extend(["--state-dir", str(self.state_directory)])
        self.start_diagnostics = {
            "observationVersion": "startup-observation-v2",
            "connectionAttempts": 0, "connectionFailures": 0,
            "socketPollCount": 0, "lastSocketNegativeSeconds": None,
            "pollSleepCount": 0, "pollSleepTotalSeconds": 0.0,
            "pollSleepMaxSeconds": 0.0,
        }
        # Windows keeps the daemon's own words: a start that fails there is
        # otherwise only an exit status (the Unix harness keeps DEVNULL).
        self._close_output()
        if on_windows():
            self._output = tempfile.TemporaryFile()
        output = self._output if on_windows() else subprocess.DEVNULL
        started = clocks.awake_seconds()
        self.process = subprocess.Popen(
            arguments,
            stdout=output,
            stderr=output,
            env=environment,
        )
        self.start_diagnostics["spawnReturnedSeconds"] = clocks.awake_seconds() - started
        deadline = clocks.Deadline(budget_seconds)
        while not deadline.expired():
            if self.process.poll() is not None:
                said = self._daemon_output()
                raise DaemonStartFailed(
                    f"daemon exited with status {self.process.returncode} before "
                    "answering health" + (f": {said}" if said else "")
                )
            self.start_diagnostics["socketPollCount"] += 1
            if self._endpoint_ready():
                self.start_diagnostics.setdefault("socketObservedSeconds", clocks.awake_seconds() - started)
                self.start_diagnostics["connectionAttempts"] += 1
                # These completion fields describe this connection attempt only.
                for field in ("connectReturnedSeconds", "contractVerifiedSeconds", "healthySeconds"):
                    self.start_diagnostics.pop(field, None)
                phase = "connect"
                try:
                    client = control.ControlClient(
                        self._address(),
                        timeout_seconds=max(0.001, min(1.0, deadline.remaining_seconds())),
                        expected_server_pid=self._expected_server_pid(),
                    )
                    try:
                        client.connect()
                        self.start_diagnostics["connectReturnedSeconds"] = clocks.awake_seconds() - started
                        phase = "contract"
                        client.verify_contract()
                        self.start_diagnostics["contractVerifiedSeconds"] = clocks.awake_seconds() - started
                        phase = "health"
                        client.call("health")
                        elapsed = clocks.awake_seconds() - started
                        self.start_diagnostics["healthySeconds"] = elapsed
                        phase = "close"
                        return elapsed
                    finally:
                        try:
                            client.close()
                        except Exception:
                            phase = "close"
                            raise
                except (control.ControlError, OSError) as error:
                    self.start_diagnostics["connectionFailures"] += 1
                    self.start_diagnostics["lastConnectionFailure"] = {
                        "attempt": self.start_diagnostics["connectionAttempts"],
                        "phase": phase, "errorType": type(error).__name__,
                        "elapsedSeconds": clocks.awake_seconds() - started,
                    }
            else:
                self.start_diagnostics["lastSocketNegativeSeconds"] = clocks.awake_seconds() - started
            # Keep the historical pause; its requested 1 ms is not a bound on
            # scheduler delay. Observe actual awake elapsed time, never subtract it.
            sleep_started = clocks.awake_seconds()
            self.start_diagnostics["pollSleepCount"] += 1
            try:
                time.sleep(0.001)
            finally:
                slept = clocks.awake_seconds() - sleep_started
                self.start_diagnostics["pollSleepTotalSeconds"] += slept
                self.start_diagnostics["pollSleepMaxSeconds"] = max(
                    self.start_diagnostics["pollSleepMaxSeconds"], slept)
        raise DaemonStartFailed(
            f"daemon did not answer health within {budget_seconds:.0f}s"
        )

    def _close_output(self) -> None:
        output = getattr(self, "_output", None)
        if output is not None:
            output.close()
        self._output = None

    def _daemon_output(self) -> str:
        """The daemon's bounded output on Windows, with the state root, the
        profile and every SID replaced, so it can enter the raw record."""
        if getattr(self, "_output", None) is None:
            return ""
        text = observations.bounded_log(self._output)["text"]
        text = text.replace(str(self.state_directory), "<state-root>")
        text = text.replace(os.path.expanduser("~"), "<home>")
        text = re.sub(r"S-1-[0-9]+(?:-[0-9]+)+", "<sid>", text)
        self.start_diagnostics["daemonOutput"] = text
        return " ".join(text.split())

    def _endpoint_ready(self) -> bool:
        """The Unix socket exists; on Windows the daemon's pipe does.

        The pipe's name is learned once, from the instance document of the
        first daemon on the fresh root (published after the pipe is bound);
        every later start of the same root serves the same name, which is
        then only waited for (`WaitNamedPipe`, which does not connect). The
        document is not read again: an open handle on it while a restarting
        daemon replaces it fails that daemon's start with a sharing violation.
        """
        if not on_windows():
            return self.socket_path.exists()
        if self.endpoint is not None:
            return windows_host.pipe_exists(self.endpoint)
        try:
            document = json.loads((self.state_directory / "instance.json").read_bytes())
        except (OSError, ValueError):
            return False
        if not isinstance(document, dict):
            return False
        endpoint = document.get("socketPath")
        if (document.get("pid") != self.process.pid or not isinstance(endpoint, str)
                or not endpoint.startswith(windows_host.PIPE_PREFIX + "arkdeck-agentd-dev-")):
            return False
        self.endpoint = endpoint
        return True

    def _address(self) -> str:
        return self.endpoint if on_windows() else str(self.socket_path)

    def _expected_server_pid(self) -> int | None:
        return self.process.pid if on_windows() and self.process is not None else None

    def client(self) -> control.ControlClient:
        return control.ControlClient(self._address(), expected_server_pid=self._expected_server_pid())

    def _request_stop(self) -> None:
        """SIGTERM, or on Windows the daemon's named stop event: both drain.
        A daemon whose stop event cannot be set is ended outright."""
        if not on_windows():
            self.process.terminate()
            return
        try:
            if self.endpoint is None:
                raise OSError("the daemon never named its pipe")
            windows_host.request_stop(self.endpoint, self.process.pid)
        except (OSError, ValueError):
            self.process.terminate()

    def stop(self, budget_seconds: float = 30.0) -> None:
        if self.process is None:
            return
        if self.process.poll() is None:
            self._request_stop()
            try:
                self.process.wait(timeout=budget_seconds)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=budget_seconds)
        self.process = None
        self._close_output()

    def __enter__(self) -> "IsolatedRuntime":
        return self

    def __exit__(self, *_exception: object) -> None:
        self.stop()


def seed_state_directory(
    soak_executable: pathlib.Path,
    state_directory: pathlib.Path,
    duration_seconds: int,
    jobs_per_cycle: int,
    restart_interval_seconds: int,
    *, recorder=None,
) -> subprocess.CompletedProcess:
    """Populate a state directory with real terminal Jobs.

    The matching Swift or Rust soak drives the production engine, SQLite repository,
    durable journals and Artifact store through a simulated provider that opens
    no device transport and spawns no child process, so the resulting directory
    is a genuine Runtime state with no hardware in the loop.  Measuring reads
    against an empty store would flatter every projection metric.
    """

    return observations.seed_process(
        [
            str(soak_executable),
            "--state-directory",
            str(state_directory),
            "--duration-seconds",
            str(duration_seconds),
            "--restart-interval-seconds",
            str(restart_interval_seconds),
            "--jobs-per-cycle",
            str(jobs_per_cycle),
        ],
        timeout=duration_seconds + 300.0,
        record=recorder or (lambda entry: None),
    )


def temporary_state_directory(prefix: str = "adkb.") -> pathlib.Path:
    """A short-path state directory, as `sun_path` requires."""

    # Rust's owner opens canonical paths only. macOS commonly spells TMPDIR
    # through /var, a symlink to /private/var.
    return pathlib.Path(tempfile.mkdtemp(prefix=prefix, dir=tempfile.gettempdir())).resolve()
