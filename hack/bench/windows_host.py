"""Windows counterparts of the harness's host facts (TASK-XPA-025, WM6).

The harness was written against Darwin: `clock_gettime` clocks, `getloadavg`,
`ps`, and a Unix domain socket in the state directory.  None of those exists on
Windows, and each is replaced here by the Windows API that answers the same
question, named in every document that uses it:

| question | Darwin | Windows (this module) |
| --- | --- | --- |
| continuous clock (wait budgets) | `CLOCK_MONOTONIC` | `QueryInterruptTimePrecise` (advances through sleep) |
| awake-work clock (durations) | `CLOCK_UPTIME_RAW` | `QueryUnbiasedInterruptTimePrecise` (stops in sleep) |
| one-minute load | `getloadavg()[0]` | busy CPUs over a 1 s `GetSystemTimes` window |
| conflicting builds | `ps -axo comm=,args=` | Toolhelp process names; a Python process's own command line |
| resident set | `ps -o rss=` | working set (`K32GetProcessMemoryInfo`) |
| CPU share | `ps -o %cpu=` | lifetime CPU time over lifetime wall time (`GetProcessTimes`) |
| thread count | `ps -M` | Toolhelp `cntThreads` |
| descriptors | `lsof` / `/proc/<pid>/fd` | open handles (`GetProcessHandleCount`), a separate metric |
| — | — | private bytes (`PrivateUsage`), a Windows-only metric |
| transport | `AF_UNIX` socket | the daemon's named pipe, whose server process id must be the daemon the harness started |
| graceful stop | `SIGTERM` | the daemon's named stop event (`InstanceScope::request_stop`) |

The load figure is not a load average: Windows has no run-queue average.  It is
the number of CPUs kept busy over one second, which the same "at most half the
CPUs" ceiling can be compared with; a document records which one it holds.

Standard library only (`ctypes`, `_winapi`), and importable anywhere: every
function that needs Windows refuses elsewhere instead of failing at import.
"""

from __future__ import annotations

import os
import sys
import time

IS_WINDOWS = sys.platform == "win32"

CONTINUOUS_CLOCK = "QueryInterruptTimePrecise"
AWAKE_CLOCK = "QueryUnbiasedInterruptTimePrecise"
LOAD_SOURCE = "GetSystemTimes busy CPUs over 1 s"
LOAD_WINDOW_SECONDS = 1.0
PIPE_PREFIX = "\\\\.\\pipe\\"

if IS_WINDOWS:
    import ctypes
    from ctypes import wintypes

    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _kernelbase = ctypes.WinDLL("kernelbase", use_last_error=True)
    _advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    _ntdll = ctypes.WinDLL("ntdll")

    _kernelbase.QueryInterruptTimePrecise.argtypes = [ctypes.POINTER(ctypes.c_ulonglong)]
    _kernelbase.QueryUnbiasedInterruptTimePrecise.argtypes = [ctypes.POINTER(ctypes.c_ulonglong)]

    class _FILETIME(ctypes.Structure):
        _fields_ = [("low", wintypes.DWORD), ("high", wintypes.DWORD)]

        def value(self) -> int:
            return (self.high << 32) | self.low

    class _MEMORY(ctypes.Structure):
        _fields_ = [
            ("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
            ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
            ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t),
            ("PrivateUsage", ctypes.c_size_t),
        ]

    class _PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
            ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
            ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long),
            ("dwFlags", wintypes.DWORD), ("szExeFile", ctypes.c_wchar * 260),
        ]

    class _UNICODE_STRING(ctypes.Structure):
        _fields_ = [("Length", wintypes.USHORT), ("MaximumLength", wintypes.USHORT),
                    ("Buffer", ctypes.c_void_p)]

    _PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    _PROCESS_VM_READ = 0x0010
    _TH32CS_SNAPPROCESS = 0x2
    _EVENT_MODIFY_STATE = 0x0002
    _TOKEN_QUERY = 0x0008
    _TOKEN_USER = 1
    _PROCESS_COMMAND_LINE_INFORMATION = 60

    _kernel32.OpenProcess.restype = wintypes.HANDLE
    _kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    _kernel32.GetSystemTimes.argtypes = [ctypes.POINTER(_FILETIME)] * 3
    _kernel32.GetSystemTimeAsFileTime.argtypes = [ctypes.POINTER(_FILETIME)]
    _kernel32.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(_FILETIME)] * 4
    _kernel32.K32GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(_MEMORY), wintypes.DWORD]
    _kernel32.GetProcessHandleCount.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    _kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    _kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    _kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PROCESSENTRY32W)]
    _kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PROCESSENTRY32W)]
    _kernel32.WaitNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD]
    _kernel32.GetNamedPipeServerProcessId.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.ULONG)]
    _kernel32.OpenEventW.restype = wintypes.HANDLE
    _kernel32.OpenEventW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
    _kernel32.SetEvent.argtypes = [wintypes.HANDLE]
    _kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    _advapi32.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    _advapi32.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                              wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    _advapi32.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(wintypes.LPWSTR)]
    _kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    _ntdll.NtQueryInformationProcess.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                                 wintypes.ULONG, ctypes.POINTER(wintypes.ULONG)]
    _ntdll.NtQueryInformationProcess.restype = ctypes.c_long


def _require_windows() -> None:
    if not IS_WINDOWS:
        raise OSError("this host fact is read through a Windows API")


def _check(result) -> None:
    if not result:
        raise ctypes.WinError(ctypes.get_last_error())


# --- clocks -----------------------------------------------------------------

def continuous_seconds() -> float:
    """Interrupt time, which keeps counting while the machine sleeps."""
    _require_windows()
    value = ctypes.c_ulonglong()
    _kernelbase.QueryInterruptTimePrecise(ctypes.byref(value))
    return value.value / 10_000_000


def awake_seconds() -> float:
    """Unbiased interrupt time, which excludes sleep and hibernation."""
    _require_windows()
    value = ctypes.c_ulonglong()
    _kernelbase.QueryUnbiasedInterruptTimePrecise(ctypes.byref(value))
    return value.value / 10_000_000


# --- load and conflicting processes -----------------------------------------

def _system_times() -> tuple[int, int, int]:
    idle, kernel, user = _FILETIME(), _FILETIME(), _FILETIME()
    _check(_kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)))
    return idle.value(), kernel.value(), user.value()


def busy_fraction(before: tuple[int, int, int], after: tuple[int, int, int]) -> float:
    """Share of all CPU time that was not idle; kernel time includes idle."""
    idle = after[0] - before[0]
    total = (after[1] - before[1]) + (after[2] - before[2])
    if total <= 0:
        return 0.0
    return min(1.0, max(0.0, (total - idle) / total))


def load_equivalent(cpu_count: int, window_seconds: float = LOAD_WINDOW_SECONDS) -> float:
    """CPUs kept busy over the window: the stand-in for a one-minute load."""
    _require_windows()
    before = _system_times()
    time.sleep(window_seconds)
    return busy_fraction(before, _system_times()) * cpu_count


def _processes():
    snapshot = _kernel32.CreateToolhelp32Snapshot(_TH32CS_SNAPPROCESS, 0)
    if snapshot in (None, wintypes.HANDLE(-1).value):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = _PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(entry)
        more = _kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while more:
            yield entry.th32ProcessID, entry.szExeFile, entry.cntThreads
            more = _kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        _kernel32.CloseHandle(snapshot)


def command_line(pid: int) -> str | None:
    """A process's command line, or None when this user may not read it."""
    _require_windows()
    process = _kernel32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not process:
        return None
    try:
        size = wintypes.ULONG(0)
        _ntdll.NtQueryInformationProcess(process, _PROCESS_COMMAND_LINE_INFORMATION, None, 0,
                                         ctypes.byref(size))
        if not size.value:
            return None
        buffer = ctypes.create_string_buffer(size.value)
        if _ntdll.NtQueryInformationProcess(process, _PROCESS_COMMAND_LINE_INFORMATION, buffer,
                                            size, ctypes.byref(size)) != 0:
            return None
        text = ctypes.cast(buffer, ctypes.POINTER(_UNICODE_STRING)).contents
        return ctypes.wstring_at(text.Buffer, text.Length // 2) if text.Buffer else ""
    finally:
        _kernel32.CloseHandle(process)


def conflicting_command(is_conflict) -> str | None:
    """The first process `is_conflict(stem, arguments)` names, or None.

    The stem is the image name without `.exe`, lowercased.  Arguments are read
    only for Python processes, the one case the rule needs them, and only where
    this user may read them: a process of another account is not this
    repository's build.
    """
    _require_windows()
    for pid, image, _threads in _processes():
        stem = image.lower().removesuffix(".exe")
        arguments = (command_line(pid) or "") if stem.startswith("python") else ""
        if is_conflict(stem, arguments):
            return stem
    return None


# --- one process's resources -------------------------------------------------

def process_resources(pid: int) -> dict[str, float | int]:
    """Working set, private bytes, handles, threads and lifetime CPU share."""
    _require_windows()
    process = _kernel32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION | _PROCESS_VM_READ, False, pid)
    if not process:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        memory = _MEMORY()
        memory.cb = ctypes.sizeof(memory)
        _check(_kernel32.K32GetProcessMemoryInfo(process, ctypes.byref(memory), memory.cb))
        handles = wintypes.DWORD()
        _check(_kernel32.GetProcessHandleCount(process, ctypes.byref(handles)))
        created, ended, kernel, user = _FILETIME(), _FILETIME(), _FILETIME(), _FILETIME()
        _check(_kernel32.GetProcessTimes(process, ctypes.byref(created), ctypes.byref(ended),
                                         ctypes.byref(kernel), ctypes.byref(user)))
        now = _FILETIME()
        _kernel32.GetSystemTimeAsFileTime(ctypes.byref(now))
    finally:
        _kernel32.CloseHandle(process)
    lifetime = now.value() - created.value()
    threads = next((count for candidate, _image, count in _processes() if candidate == pid), None)
    return {
        "workingSetBytes": int(memory.WorkingSetSize),
        "privateBytes": int(memory.PrivateUsage),
        "handleCount": int(handles.value),
        "threadCount": threads,
        # ps's %cpu is a share of one CPU; so is this.
        "cpuPercent": (100.0 * (kernel.value() + user.value()) / lifetime) if lifetime > 0 else 0.0,
    }


# --- the daemon's pipe and stop event ----------------------------------------

def pipe_exists(name: str) -> bool:
    """Whether a server instance of the pipe exists, without connecting to it."""
    _require_windows()
    if _kernel32.WaitNamedPipeW(name, 1):
        return True
    # ERROR_SEM_TIMEOUT: every instance is busy, but the pipe exists.
    return ctypes.get_last_error() == 121


def user_sid() -> str:
    _require_windows()
    token = wintypes.HANDLE()
    _check(_advapi32.OpenProcessToken(_kernel32.GetCurrentProcess(), _TOKEN_QUERY, ctypes.byref(token)))
    try:
        size = wintypes.DWORD()
        _advapi32.GetTokenInformation(token, _TOKEN_USER, None, 0, ctypes.byref(size))
        buffer = ctypes.create_string_buffer(size.value)
        _check(_advapi32.GetTokenInformation(token, _TOKEN_USER, buffer, size, ctypes.byref(size)))
        sid = ctypes.cast(buffer, ctypes.POINTER(ctypes.c_void_p)).contents.value
        text = wintypes.LPWSTR()
        _check(_advapi32.ConvertSidToStringSidW(sid, ctypes.byref(text)))
        try:
            return text.value
        finally:
            _kernel32.LocalFree(text)
    finally:
        _kernel32.CloseHandle(token)


def temporary_private_directory(prefix: str):
    """Create a fresh token-user-only root; never rewrite an existing ACL."""
    _require_windows()
    import pathlib
    import secrets
    import tempfile

    if not prefix or any(character in prefix for character in "/\\:\0"):
        raise ValueError("a single-segment temporary prefix is required")

    class SecurityAttributes(ctypes.Structure):
        _fields_ = [("length", wintypes.DWORD), ("descriptor", ctypes.c_void_p),
                    ("inherit", wintypes.BOOL)]

    convert = _advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW
    convert.argtypes = [wintypes.LPCWSTR, wintypes.DWORD,
                        ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.DWORD)]
    convert.restype = wintypes.BOOL
    create = _kernel32.CreateDirectoryW
    create.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(SecurityAttributes)]
    create.restype = wintypes.BOOL
    sid = user_sid()
    descriptor = ctypes.c_void_p()
    _check(convert(f"O:{sid}D:P(A;OICI;FA;;;{sid})", 1, ctypes.byref(descriptor), None))
    try:
        attributes = SecurityAttributes(ctypes.sizeof(SecurityAttributes), descriptor, False)
        base = pathlib.Path(tempfile.gettempdir()).resolve()
        for _ in range(16):
            path = base / (prefix + secrets.token_hex(8))
            if create(str(path), ctypes.byref(attributes)):
                return path.resolve()
            error = ctypes.get_last_error()
            if error != 183:  # ERROR_ALREADY_EXISTS: choose another fresh name.
                raise ctypes.WinError(error)
        raise FileExistsError("temporary private directory name collision")
    finally:
        _kernel32.LocalFree(descriptor)


def root_identity(endpoint: str) -> str:
    """The state root's identity a development daemon names its pipe after:
    `<16 hex volume>-<32 hex file id>` (`FileIdentity::text`)."""
    parts = endpoint.rsplit("-", 2)
    if (len(parts) != 3 or len(parts[1]) != 16 or len(parts[2]) != 32
            or any(c not in "0123456789abcdef" for c in parts[1] + parts[2])):
        raise ValueError("not a development daemon's pipe name")
    return f"{parts[1]}-{parts[2]}"


def stop_event_name(sid: str, endpoint: str, pid: int) -> str:
    """`InstanceScope::stop_event_name` of a development root's daemon."""
    return f"Local\\ArkDeck.Agentd.Dev.{sid}.{root_identity(endpoint)}.Stop.{pid}"


def request_stop(endpoint: str, pid: int) -> None:
    """Ask the development daemon to drain and stop, as SIGTERM does on Unix."""
    _require_windows()
    event = _kernel32.OpenEventW(_EVENT_MODIFY_STATE, False, stop_event_name(user_sid(), endpoint, pid))
    if not event:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        _check(_kernel32.SetEvent(event))
    finally:
        _kernel32.CloseHandle(event)


class PipeStream:
    """A client end of the daemon's byte-mode pipe with the calls ControlClient
    makes on a socket: `sendall`, `recv`, `settimeout`, `close`.

    Overlapped I/O bounds every read and write by the timeout, as a socket
    timeout does.  The server's process id must be the one the caller started:
    a pipe name is not inside a private directory, so this is the counterpart
    of the Unix socket living in the harness's own state directory.
    """

    def __init__(self, name: str, timeout: float | None, expected_server_pid: int | None) -> None:
        _require_windows()
        import _winapi
        self._winapi = _winapi
        if not name.startswith(PIPE_PREFIX):
            raise ValueError("not a local named pipe")
        self._timeout = timeout
        self._handle = _winapi.CreateFile(
            name, _winapi.GENERIC_READ | _winapi.GENERIC_WRITE, 0, _winapi.NULL,
            _winapi.OPEN_EXISTING, _winapi.FILE_FLAG_OVERLAPPED, _winapi.NULL)
        try:
            server = wintypes.ULONG()
            _check(_kernel32.GetNamedPipeServerProcessId(self._handle, ctypes.byref(server)))
            if expected_server_pid is not None and server.value != expected_server_pid:
                raise ConnectionRefusedError(
                    f"pipe server is process {server.value}, not the daemon this harness started")
        except BaseException:
            _winapi.CloseHandle(self._handle)
            self._handle = None
            raise

    def settimeout(self, seconds: float | None) -> None:
        self._timeout = seconds

    def _complete(self, overlapped) -> int:
        winapi = self._winapi
        milliseconds = winapi.INFINITE if self._timeout is None else max(0, int(self._timeout * 1000))
        try:
            waited = winapi.WaitForMultipleObjects([overlapped.event], False, milliseconds)
            if waited == winapi.WAIT_TIMEOUT:
                overlapped.cancel()
                try:
                    overlapped.GetOverlappedResult(True)
                except OSError:
                    pass
                raise TimeoutError("named pipe operation timed out")
        except BaseException:
            overlapped.cancel()
            raise
        transferred, _error = overlapped.GetOverlappedResult(True)
        return transferred

    def sendall(self, data: bytes) -> None:
        if self._handle is None:
            raise OSError("pipe is closed")
        view = memoryview(data)
        while view:
            overlapped, error = self._winapi.WriteFile(self._handle, bytes(view), overlapped=True)
            written = self._complete(overlapped) if error == self._winapi.ERROR_IO_PENDING else \
                overlapped.GetOverlappedResult(True)[0]
            view = view[written:]

    def recv(self, size: int) -> bytes:
        if self._handle is None:
            raise OSError("pipe is closed")
        try:
            overlapped, error = self._winapi.ReadFile(self._handle, size, overlapped=True)
            if error == self._winapi.ERROR_IO_PENDING:
                read = self._complete(overlapped)
            else:
                read = overlapped.GetOverlappedResult(True)[0]
        except BrokenPipeError:
            return b""
        return bytes(overlapped.getbuffer()[:read])

    def close(self) -> None:
        if self._handle is not None:
            self._winapi.CloseHandle(self._handle)
            self._handle = None


def host_tag(arch: str) -> str:
    return f"windows-{arch.lower()}"


def os_version() -> str:
    import platform
    return platform.version()


def cpu_count() -> int:
    return os.cpu_count() or 1
