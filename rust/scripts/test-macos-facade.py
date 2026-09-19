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

# check-contracts.py runs this from its own source view, whose build is beside it.
DAEMON = Path(os.environ.get('ARKDECK_DAEMON_UNDER_TEST') or Path(__file__).resolve().parents[1] / 'target/debug/arkdeck-agentd').resolve()
# The facade validates every frame against this checkout's contract before
# forwarding or serving it, so the identity is derived, never pinned here.
REGISTRY = json.loads((Path(__file__).resolve().parents[2] / 'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
IDENTITY = hashlib.sha256(json.dumps(REGISTRY, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
FRAME = json.dumps(dict(protocolVersion='1.0.0', contractIdentity=IDENTITY, id='host-test', method='health'), separators=(',', ':')).encode()
RESPONSE = b' { "id" : "host-test", "ok" : true, "result" : {} } \n'
FIXTURE = r'''#!/usr/bin/env python3
import json,os,socket,sys,threading,time
from pathlib import Path
secret = sys.stdin.readline().strip()
# A facade already gone leaves an empty pairing line; as the Swift daemon
# (AgentFacadeConfiguration.inherited), do not bind a socket for it.
if not secret: os._exit(0)
p = Path(os.environ['ARKDECK_PRIVATE_SOCKET'])
s = socket.socket(socket.AF_UNIX); s.bind(str(p)); os.chmod(p,0o600); s.listen()
def end():
    # On the pairing pipe's EOF the paired Swift daemon unlinks its socket and
    # removes the facade's directory (drainAndStop); a killed facade leaves
    # that to its authority, so the fixture does the same.
    sys.stdin.read()
    for remove,target in ((os.unlink,p),(os.rmdir,p.parent)):
        try: remove(target)
        except OSError: pass
    os._exit(0)
threading.Thread(target=end,daemon=True).start()
# Bound and listening: the harness reads this to name the facade's directory.
# Its root may already be gone when the facade was killed during startup.
report=Path(os.environ['XPA_AUTHORITY']); partial=report.with_suffix('.partial')
try: partial.write_text(json.dumps({'socket':str(p),'pid':os.getpid()})); partial.replace(report)
except OSError: pass
lock=threading.Lock()
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
        self.process=None;self.children=[];self.instances=[]
    def tearDown(self):
        for process in [self.process,*self.instances]:
            if process and process.poll() is None:
                process.terminate();process.wait(timeout=10)
        for child in self.children:
            try: os.kill(child,signal.SIGTERM)
            except ProcessLookupError: pass
        shutil.rmtree(self.root)
    def launch(self,root,delay=0):
        """One facade over its own public socket directory; its authority is the fixture."""
        env={k:v for k,v in os.environ.items() if not k.startswith('ARKDECK_')}
        env.update(ARKDECK_ENDPOINT=str(root/'agentd.sock'), ARKDECK_SWIFT_DAEMON=str(self.fixture), XPA_RECORD=str(root/'record.jsonl'), XPA_AUTHORITY=str(root/'authority.json'), XPA_DELAY=str(delay))
        log=open(root/'stderr','ab')
        self.addCleanup(log.close)
        process=subprocess.Popen([str(DAEMON)],env=env,stdout=log,stderr=log)
        deadline=time.monotonic()+10
        while not (root/'agentd.sock').exists():
            if process.poll() is not None: self.fail((root/'stderr').read_text())
            if time.monotonic()>deadline:self.fail('startup timeout')
            time.sleep(.01)
        s=socket.socket(socket.AF_UNIX);s.settimeout(5)
        self.addCleanup(s.close)
        while True:
            try: s.connect(str(root/'agentd.sock')); return process,s
            except (ConnectionRefusedError,FileNotFoundError):
                if process.poll() is not None: self.fail((root/'stderr').read_text())
                if time.monotonic()>deadline: self.fail('connect timeout')
                time.sleep(.01)
    def start(self,delay=0):
        self.process,s=self.launch(self.root,delay); return s
    def authority(self,root=None):
        """The fixture authority's bound private socket and pid, as the facade handed them over."""
        # The public socket accepts a connection before the authority is up.
        report=(root or self.root)/'authority.json';end=time.monotonic()+10
        while not report.exists():
            if time.monotonic()>end: self.fail('fixture authority did not report its socket')
            time.sleep(.01)
        return json.loads(report.read_text())
    def private_directory(self,root=None):
        return Path(self.authority(root)['socket']).parent
    def wait_private_directory_removed(self,directory):
        # A killed facade cannot remove its directory; its authority does so on
        # the pairing pipe's EOF, shortly after the facade is gone.
        end=time.monotonic()+5
        while directory.exists():
            if time.monotonic()>end: self.fail(f'facade private directory left behind: {directory}')
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
        # With the authority up, an unforwarded partial frame is a real result;
        # a facade killed before pairing has no authority to clean up after it.
        s=self.start();own=self.private_directory()
        s.sendall(FRAME[:-1]);self.process.kill();self.process.wait(timeout=5)
        try: data=s.recv(4096)
        except ConnectionResetError: data=b''
        self.assertEqual(data,b'');self.assertEqual(self.rows(),[])
        self.wait_private_directory_removed(own)
    def test_kill_after_forward_never_replays(self):
        s=self.start(delay=2);s.sendall(FRAME+b'\n');self.wait_rows()
        self.process.kill();self.process.wait(timeout=5)
        self.assertEqual(s.recv(4096),b'');time.sleep(.05);self.assertEqual(len(self.rows()),1)
    def test_dead_public_socket_can_restart(self):
        s=self.start();s.sendall(FRAME+b'\n');self.assertEqual(s.makefile('rb').readline(),RESPONSE)
        first=self.private_directory()
        self.process.kill();self.process.wait(timeout=5);time.sleep(.1)
        self.wait_private_directory_removed(first)
        again=self.start();again.sendall(FRAME+b'\n');self.assertEqual(again.makefile('rb').readline(),RESPONSE)
        self.assertNotEqual(self.private_directory(),first)
    def test_sigterm_removes_only_its_own_private_directory(self):
        # The facade creates /private/tmp/arkdeck-facade-<nonce> for its
        # authority's socket; SIGTERM stops it as it stops the Swift daemon
        # (status 0) and exactly that directory goes with it, while a second
        # facade's directory and service are untouched.
        self.start();own=self.private_directory()
        self.assertEqual((own.parent,own.name[:15]),(Path('/private/tmp'),'arkdeck-facade-'))
        self.assertTrue((own/'swift.sock').exists())
        other_root=self.root/'other';other_root.mkdir(mode=0o700)
        other_process,other_socket=self.launch(other_root);self.instances.append(other_process)
        other=self.private_directory(other_root);self.assertNotEqual(own,other)
        self.process.terminate();self.assertEqual(self.process.wait(timeout=10),0)
        self.assertFalse(own.exists());self.assertTrue((other/'swift.sock').exists())
        other_socket.sendall(FRAME+b'\n');self.assertEqual(other_socket.makefile('rb').readline(),RESPONSE)
        other_process.terminate();self.assertEqual(other_process.wait(timeout=10),0)
        self.assertFalse(other.exists())
    def test_authority_exit_removes_private_directory(self):
        # The authority's exit ends the facade with status 69; the directory
        # goes before that exit, whatever the authority left in it.
        self.start();own=self.private_directory()
        os.kill(self.authority()['pid'],signal.SIGKILL)
        self.assertEqual(self.process.wait(timeout=10),69)
        self.assertFalse(own.exists())
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
    def test_history_filter_is_owned_here_and_never_forwarded(self):
        # TASK-XPA-012: the facade serves this host-only store from the paired
        # authority's state directory; only other methods reach the authority.
        link={}
        def connect():
            link['socket']=self.start();link['reader']=link['socket'].makefile('rb')
        def ask(method,params):
            frame=dict(protocolVersion='1.0.0',contractIdentity=IDENTITY,id='host-owner',method=method,params=params)
            link['socket'].sendall(json.dumps(frame).encode()+b'\n')
            return json.loads(link['reader'].readline())
        query=dict(search='x',status='all',mode='all',sessionId=None,targetId=None,timeRange='anyTime',activity='all')
        connect()
        self.assertEqual(ask('history.filter.list',{})['result']['generation'],'1')
        self.assertEqual(ask('history.filter.save',dict(query,expectedGeneration='1'))['result']['generation'],'2')
        self.process.kill();self.process.wait(timeout=5);time.sleep(.1)
        connect()
        self.assertEqual(ask('history.filter.list',{})['result']['filters'][0]['query']['search'],'x')
        stale=ask('history.filter.save',dict(query,expectedGeneration='1'))['error']
        self.assertEqual((stale['code'],stale['details']['newDispatchCount']),('resourceConflict',0))
        self.assertEqual(ask('history.filter.delete',dict(expectedGeneration='2'))['result']['generation'],'3')
        self.assertEqual(self.rows(),[])
        link['socket'].sendall(FRAME+b'\n');self.assertEqual(link['reader'].readline(),RESPONSE)
        self.assertEqual(len(self.wait_rows()),1)
        document=json.loads((self.root/'history-filter.json').read_bytes())
        self.assertEqual((document['schemaVersion'],document['generation']),('arkdeck.history-filter-store/1',3))

if __name__=='__main__': unittest.main()
