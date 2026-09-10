#!/usr/bin/env python3
"""Host-only transport fault/origin tests; never hardware or Runtime evidence."""
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import termios
import time
import unittest
import fcntl

DAEMON = Path(os.environ['ARKDECK_DAEMON_UNDER_TEST']).resolve()
IDENTITY = '8a662759721a2081e974306399997801246de4022047365c050107de5dce2912'
FRAME = json.dumps(dict(protocolVersion='1.0.0', contractIdentity=IDENTITY, id='host-test', method='health'), separators=(',', ':')).encode()
RESPONSE = b' { "id" : "host-test", "ok" : true, "result" : {} } \n'
FIXTURE = r'''#!/usr/bin/env python3
import json,os,socket,sys,threading,time
from pathlib import Path
secret = sys.stdin.readline().strip()
p = Path(os.environ['ARKDECK_PRIVATE_SOCKET'])
s = socket.socket(socket.AF_UNIX); s.bind(str(p)); os.chmod(p,0o600); s.listen()
lock=threading.Lock()
def end():
    sys.stdin.read(); os._exit(0)
threading.Thread(target=end,daemon=True).start()
def serve(c):
    with c, c.makefile('rb') as f:
        auth=json.loads(f.readline())
        if auth != {'arkdeckPairing':1,'secret':secret}: return
        while True:
            raw=f.readline()
            if not raw:return
            origin=json.loads(raw); frame=f.readline()
            with lock:
                with open(os.environ['XPA_RECORD'],'a') as out:
                    out.write(json.dumps({'origin':origin,'frame':frame.hex()})+'\n')
            time.sleep(float(os.environ.get('XPA_DELAY','0')))
            c.sendall(b' { "id" : "host-test", "ok" : true, "result" : {} } \n')
while True:
    c,_=s.accept();threading.Thread(target=serve,args=(c,),daemon=True).start()
'''

class FacadeTests(unittest.TestCase):
    def setUp(self):
        self.root=Path(tempfile.mkdtemp(prefix='xpa-transport-',dir='/private/tmp'))
        self.fixture=self.root/'swift-fixture'; self.fixture.write_text(FIXTURE); self.fixture.chmod(0o700)
        self.record=self.root/'record.jsonl';self.record.touch()
        self.process=None;self.children=[]
    def tearDown(self):
        if self.process and self.process.poll() is None:
            self.process.terminate();self.process.wait(timeout=10)
        for child in self.children:
            try: os.kill(child,signal.SIGTERM)
            except ProcessLookupError: pass
        shutil.rmtree(self.root)
    def start(self,delay=0):
        env={k:v for k,v in os.environ.items() if not k.startswith('ARKDECK_')}
        env.update(ARKDECK_ENDPOINT=str(self.root/'agentd.sock'), ARKDECK_SWIFT_DAEMON=str(self.fixture), XPA_RECORD=str(self.record), XPA_DELAY=str(delay))
        self.log=open(self.root/'stderr','ab')
        self.addCleanup(self.log.close)
        self.process=subprocess.Popen([str(DAEMON)],env=env,stdout=self.log,stderr=self.log)
        deadline=time.monotonic()+10
        while not (self.root/'agentd.sock').exists():
            if self.process.poll() is not None: self.fail((self.root/'stderr').read_text())
            if time.monotonic()>deadline:self.fail('startup timeout')
            time.sleep(.01)
        s=socket.socket(socket.AF_UNIX);s.settimeout(5)
        self.addCleanup(s.close)
        while True:
            try: s.connect(str(self.root/'agentd.sock')); return s
            except (ConnectionRefusedError,FileNotFoundError):
                if self.process.poll() is not None: self.fail((self.root/'stderr').read_text())
                if time.monotonic()>deadline: self.fail('connect timeout')
                time.sleep(.01)
    def rows(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()]
    def wait_rows(self):
        end=time.monotonic()+5
        while not self.rows():
            if time.monotonic()>end:self.fail('frame did not reach private fixture')
            time.sleep(.005)
        return self.rows()
    def test_exact_bytes_and_bound_origin(self):
        s=self.start();raw=b' '+FRAME+b' '
        s.sendall(raw+b'\n');self.assertEqual(s.makefile('rb').readline(),RESPONSE)
        row=self.wait_rows()[0];self.assertEqual(bytes.fromhex(row['frame']),raw+b'\n')
        self.assertEqual(row['origin']['frameSHA256'],hashlib.sha256(raw).hexdigest())
        self.assertEqual(row['origin']['peerEUID'],os.geteuid())
        self.assertEqual(row['origin']['peerPID'],os.getpid())
        self.assertEqual(row['origin']['transport'],'unixSocket')
    def test_public_origin_and_extra_envelope_never_forward(self):
        s=self.start();f=s.makefile('rb')
        for fields in [dict(arkdeckOrigin=1),dict(json.loads(FRAME),arkdeckOrigin={'foregroundConsole':True})]:
            s.sendall(json.dumps(fields).encode()+b'\n');self.assertEqual(json.loads(f.readline())['error']['code'],'malformedFrame')
        self.assertEqual(self.rows(),[])
    def test_kill_before_complete_frame_no_forward(self):
        s=self.start();s.sendall(FRAME[:-1]);self.process.kill();self.process.wait(timeout=5)
        try: data=s.recv(4096)
        except ConnectionResetError: data=b''
        self.assertEqual(data,b'');self.assertEqual(self.rows(),[])
    def test_kill_after_forward_never_replays(self):
        s=self.start(delay=2);s.sendall(FRAME+b'\n');self.wait_rows()
        self.process.kill();self.process.wait(timeout=5)
        self.assertEqual(s.recv(4096),b'');time.sleep(.05);self.assertEqual(len(self.rows()),1)
    def test_dead_public_socket_can_restart(self):
        s=self.start();s.sendall(FRAME+b'\n');self.assertEqual(s.makefile('rb').readline(),RESPONSE)
        self.process.kill();self.process.wait(timeout=5);time.sleep(.1)
        again=self.start();again.sendall(FRAME+b'\n');self.assertEqual(again.makefile('rb').readline(),RESPONSE)
    def test_foreground_and_redirected_stdin(self):
        self.start()
        for redirected in [False,True]:
            master,slave=pty.openpty()
            def terminal_setup():
                os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0);os.tcsetpgrp(slave,os.getpgrp())
            code='import socket; s=socket.socket(socket.AF_UNIX); s.connect('+repr(str(self.root/'agentd.sock'))+'); s.sendall('+repr(FRAME+b'\n')+'); print(s.recv(4096))'
            p=subprocess.Popen([sys.executable,'-c',code],stdin=subprocess.DEVNULL if redirected else slave,stderr=slave,stdout=subprocess.PIPE,pass_fds=(slave,),preexec_fn=terminal_setup)
            p.communicate(timeout=5);self.assertEqual(p.returncode,0)
            self.assertEqual(self.rows()[-1]['origin']['foregroundConsole'],not redirected)
            os.close(master);os.close(slave)

if __name__=='__main__': unittest.main()
