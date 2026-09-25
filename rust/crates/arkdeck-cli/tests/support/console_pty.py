"""Isolated CLI/PTY exercise; the socket is a fake Runtime, not device evidence."""
import json
import os
import pty
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import tty
import traceback

config = json.load(sys.stdin)
root = tempfile.mkdtemp(prefix="arkdeck-console-", dir="/private/tmp")
listener = socket.socket(socket.AF_UNIX)
path = os.path.join(root, "a.sock")
listener.bind(path)
os.chmod(path, 0o600)
listener.listen()
listener.settimeout(0.1)
frames, errors = [], []
stop = threading.Event()

def server():
    try:
        while not stop.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(5)
                stream = connection.makefile("rwb", buffering=0)
                health = json.loads(stream.readline())
                assert health["method"] == "health", health
                stream.write((json.dumps({"id": health["id"], "ok": True,
                                          "result": config["health"]}) + "\n").encode())
                request = json.loads(stream.readline())
                frames.append(request)
                assert request["method"] == "human-action.resume", request
                assert len(frames) <= 2, frames
                if len(frames) == 2 and config.get("drop_reply"):
                    connection.shutdown(socket.SHUT_RDWR)
                    stream.close()
                    continue
                answer = config["challenge"] if len(frames) == 1 else config["terminal"]
                stream.write((json.dumps({"id": request["id"], "ok": True,
                                          "result": answer}) + "\n").encode())
                # Keep the socket alive until the bounded client finishes.
                assert stream.read() == b""
    except Exception as error:
        errors.append(traceback.format_exc())

thread = threading.Thread(target=server)
thread.start()
master, slave = pty.openpty()
tty.setraw(slave)
process = None
try:
    command = [config["binary"], "human-action", "resume", "--human-action",
               config["params"]["humanAction"], "--resume-reference",
               config["params"]["resumeReference"], "--output", "json", "--socket", path]
    if config.get("timeout_ms"):
        command += ["--timeout", "%dms" % config["timeout_ms"]]
    process = subprocess.Popen(command, stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os.close(slave)
    slave = None
    diagnostics = b""
    deadline = time.monotonic() + 8
    while b"\n> " not in diagnostics and process.poll() is None:
        assert time.monotonic() < deadline, ("CLI did not prompt", frames, errors, diagnostics)
        ready, _, _ = select.select([process.stderr], [], [], 0.1)
        if ready:
            diagnostics += os.read(process.stderr.fileno(), 65536)
    prompted = time.monotonic()
    if b"\n> " in diagnostics:
        if config.get("timeout_ms"):
            # The CLI's deadline began before its first request, so before it
            # prompted: once the whole budget has passed since the prompt was
            # seen, it has expired, however slowly the CLI started.
            expired = prompted + config["timeout_ms"] / 1000 + 0.05
            while time.monotonic() < expired:
                time.sleep(max(0.0, expired - time.monotonic()))
        os.write(master, bytes(config["input"]))
    stdout, stderr = process.communicate(timeout=8)
    print(json.dumps({"exit": process.returncode, "stdout": stdout.decode(),
                      "stderr": (diagnostics + stderr).decode(), "frames": frames}))
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait()
    stop.set()
    thread.join(timeout=6)
    listener.close()
    os.close(master)
    if slave is not None:
        os.close(slave)
    shutil.rmtree(root)
assert not thread.is_alive(), "fake Runtime did not finish"
assert not errors, errors
