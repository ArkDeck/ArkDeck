#!/usr/bin/env python3
"""AC-6 host fixture: a macOS administrator-authenticated foreign-euid client.

The elevated executable only connects to the isolated test socket and sends one
health frame. It never runs a device command or touches installed Runtime state.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('facade_fixture', Path(__file__).with_name('test-macos-facade.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
case = fixture.FacadeTests()
case.setUp()
try:
    ordinary = case.start()
    source = case.root / 'foreign-peer.c'
    binary = case.root / 'foreign-peer'
    source.write_text('''#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 3 || geteuid() == (uid_t)strtoul(argv[2], NULL, 10)) return 64;
    struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    if (strlen(argv[1]) >= sizeof(addr.sun_path)) return 65;
    strcpy(addr.sun_path, argv[1]);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 66;
    struct timeval deadline = {3, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, sizeof(deadline));
    signal(SIGPIPE, SIG_IGN);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr))) return 67;
    const char *frame = ''' + json.dumps(fixture.FRAME.decode() + '\n') + ''';
    send(fd, frame, strlen(frame), 0);
    char reply[64]; ssize_t count = recv(fd, reply, sizeof(reply), 0);
    int denied = count == 0 || (count < 0 && (errno == ECONNRESET || errno == EPIPE));
    close(fd);
    printf("{\\"uid\\":%u,\\"connected\\":true,\\"denied\\":%s}\\n", geteuid(), denied ? "true" : "false");
    return denied ? 0 : 68;
}
''')
    subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(binary)], check=True)
    script = '''on run argv
    set commandText to quoted form of item 1 of argv & " " & quoted form of item 2 of argv & " " & quoted form of item 3 of argv
    do shell script commandText with administrator privileges
end run'''
    result = subprocess.run(['osascript', '-e', script, str(binary), str(case.root / 'agentd.sock'), str(os.geteuid())],
                            check=True, capture_output=True, text=True, timeout=120)
    proof = json.loads(result.stdout)
    case.assertNotEqual(proof['uid'], os.geteuid())
    case.assertTrue(proof['connected'])
    case.assertTrue(proof['denied'])
    case.assertEqual(case.rows(), [])
    # A denied peer must not take down the listener or poison other clients.
    ordinary.sendall(fixture.FRAME + b'\n')
    case.assertEqual(ordinary.makefile('rb').readline(), fixture.RESPONSE)
    case.assertEqual(len(case.wait_rows()), 1)
    print(json.dumps({'result': 'PASS', 'foreignPeer': proof, 'sameUIDStillServed': True,
                      'foreignFramesForwarded': 0, 'hardwareEvidence': False}))
finally:
    case.tearDown()
    case.doCleanups()
