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
"""

from __future__ import annotations

import os
import pathlib
import platform
import shutil
import subprocess
import tempfile
import time

from . import clocks, control

SOCKET_NAME = "agentd.sock"
# Darwin's sun_path is 104 bytes including the terminator.
MAXIMUM_SOCKET_PATH_BYTES = 103
# A quiet host is one whose one-minute load average is at most half its CPU
# count.  Above that, timing samples stop reproducing; see the module docstring.
QUIET_LOAD_RATIO = 0.5


class HostTooBusy(RuntimeError):
    """The one-minute load average is too high for a reproducible sample."""


class DaemonStartFailed(RuntimeError):
    """The isolated daemon did not reach a healthy state within its budget."""


def load_average() -> tuple[float, float, float]:
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
            "baseline-eligible."
        )
    return one_minute


def host_facts() -> dict[str, object]:
    """Non-identifying host description.

    Deliberately excludes host name, user name and any path under the user's
    home directory: a baseline document is committed to the repository.
    """

    return {
        "os": platform.system(),
        "osVersion": platform.mac_ver()[0] or platform.release(),
        "arch": platform.machine(),
        "cpuCount": cpu_count(),
        "python": platform.python_version(),
    }


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
        self.unmeasured: dict[str, str] = {}

    def as_document(self) -> dict[str, object]:
        return {
            "residentSetBytes": self.resident_set_bytes,
            "cpuPercent": self.cpu_percent,
            "threadCount": self.thread_count,
            "openFileDescriptorCount": self.open_file_descriptor_count,
            "unmeasured": dict(self.unmeasured),
        }


def sample_process_resources(pid: int) -> ProcessResources:
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
    ) -> None:
        self.daemon_executable = daemon_executable
        self.state_directory = state_directory
        self.socket_path = state_directory / SOCKET_NAME
        self.process: subprocess.Popen | None = None
        if len(str(self.socket_path).encode("utf-8")) > MAXIMUM_SOCKET_PATH_BYTES:
            raise ValueError(
                f"socket path {self.socket_path} exceeds {MAXIMUM_SOCKET_PATH_BYTES} "
                "bytes; choose a shorter state directory"
            )

    def start(self, budget_seconds: float = 60.0) -> float:
        """Start the daemon and return awake-work seconds to first healthy call.

        The measurement brackets process spawn through the first successful
        `health` response, which is the cold-start definition in design
        section I.2.
        """

        if self.process is not None and self.process.poll() is None:
            raise DaemonStartFailed(
                "a daemon is already running on this state directory; stop it "
                "before measuring another cold start"
            )
        environment = dict(os.environ)
        # An ArkForge bundle or an inherited HDC path would make the sample
        # depend on host tooling that a CI runner does not have.
        for key in ("ARKDECK_ARKFORGE_BUNDLE_PATH", "ARKDECK_HDC_PATH"):
            environment.pop(key, None)
        started = clocks.awake_seconds()
        self.process = subprocess.Popen(
            [str(self.daemon_executable), "--state-dir", str(self.state_directory)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=environment,
        )
        deadline = clocks.Deadline(budget_seconds)
        while not deadline.expired():
            if self.process.poll() is not None:
                raise DaemonStartFailed(
                    f"daemon exited with status {self.process.returncode} before "
                    "answering health"
                )
            if self.socket_path.exists():
                try:
                    client = control.ControlClient(str(self.socket_path))
                    client.connect()
                    client.negotiate()
                    client.call("health")
                    elapsed = clocks.awake_seconds() - started
                    client.close()
                    return elapsed
                except (control.ControlError, OSError):
                    pass
            # Polling without a pause would spend a core on failed connects and
            # inflate the very number being measured.  One millisecond bounds
            # the quantisation error far below the sub-second reading.
            time.sleep(0.001)
        raise DaemonStartFailed(
            f"daemon did not answer health within {budget_seconds:.0f}s"
        )

    def client(self) -> control.ControlClient:
        return control.ControlClient(str(self.socket_path))

    def stop(self, budget_seconds: float = 30.0) -> None:
        if self.process is None:
            return
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=budget_seconds)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=budget_seconds)
        self.process = None

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
) -> subprocess.CompletedProcess:
    """Populate a state directory with real terminal Jobs.

    `ArkDeckRuntimeSoakFixture` drives the production engine, SQLite repository,
    durable journals and Artifact store through a simulated provider that opens
    no device transport and spawns no child process, so the resulting directory
    is a genuine Runtime state with no hardware in the loop.  Measuring reads
    against an empty store would flatter every projection metric.
    """

    return _run(
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
    )


def temporary_state_directory(prefix: str = "adkb.") -> pathlib.Path:
    """A short-path state directory, as `sun_path` requires."""

    return pathlib.Path(tempfile.mkdtemp(prefix=prefix, dir=tempfile.gettempdir()))
