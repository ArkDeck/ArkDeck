#!/usr/bin/env python3
"""Exercise actual isolated Rust Session resource RPC/CLI with simulated storage.

These are host tests with fixture manifests, never device acceptance evidence.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import select
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT/'rust/target/debug')
    parser.add_argument('--record-frames', type=Path)
    parser.add_argument('--cli-path', type=Path, help='also verify a current Swift CLI consumer against the Rust owner')
    args = parser.parse_args()
    daemon = (args.bin_dir/'arkdeck-agentd').resolve()
    cli = (args.cli_path or args.bin_dir/'arkdeck').resolve()
    registry = json.loads((ROOT/'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    rows=[]
    children=[]
    with tempfile.TemporaryDirectory(prefix='arkdeck-session-resources-',dir='/private/tmp') as temporary:
        root=Path(temporary).resolve()
        endpoint=root/'a.sock'
        env={k:v for k,v in os.environ.items() if not k.startswith('ARKDECK_')}
        env.update(ARKDECK_DEVELOPMENT_STATE_ROOT=str(root), ARKDECK_ENDPOINT=str(endpoint), ARKDECK_DAEMON_PATH=str(daemon))
        def start():
            child=subprocess.Popen([str(daemon)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            children.append(child)
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                if child.poll() is not None: raise AssertionError(child.stderr.read().decode())
                if endpoint.exists():
                    try:
                        # bind precedes owner initialization. A successful health
                        # response, rather than a connection alone, establishes
                        # readiness before fixture directories can be created.
                        assert result('health',{})['status']=='ok'
                        return child
                    except OSError: pass
                time.sleep(.01)
            raise AssertionError('owner did not start')
        def exchange(method,params):
            request={'protocolVersion':registry['currentVersion'],'contractIdentity':identity,'id':'session-resource-check','method':method,'params':params}
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(10);client.connect(str(endpoint));client.sendall(json.dumps(request).encode()+b'\n')
                with client.makefile('rb') as reader: line=reader.readline(8*1024*1024+1)
                if not line:
                    process=children[-1]
                    diagnostic=os.read(process.stderr.fileno(),4096) if select.select([process.stderr],[],[],0)[0] else b''
                    raise AssertionError(('Runtime closed the exchange without a reply',method,process.poll(),diagnostic))
                reply=json.loads(line)
            row={'protocolVersion':registry['currentVersion'],'method':method,'params':params,**reply};row.pop('id');rows.append(row)
            return reply
        def result(method,params):
            reply=exchange(method,params)
            assert reply['ok'],reply
            return reply['result']
        def refused(method,params,code):
            reply=exchange(method,params)
            assert not reply['ok'] and reply['error']['code']==code,reply
        def command(arguments,expected=0):
            answer=subprocess.run([str(cli),'session',*arguments,'--socket',str(endpoint),'--output','json'],env=env,capture_output=True,timeout=15)
            assert answer.returncode==expected,(answer.returncode,answer.stdout,answer.stderr)
            return json.loads(answer.stdout)
        def canonical_file(path,value):
            path.write_text(json.dumps(value,sort_keys=True,separators=(',',':')));path.chmod(0o600)
        def session(session_id,month,timestamp=None):
            path=root/'sessions'/'2026'/month/session_id
            path.mkdir(mode=0o700,parents=True)
            for parent in (path.parent,path.parent.parent):parent.chmod(0o700)
            job_id='job-'+session_id
            canonical_file(path/'.session-identity.json',{'schemaVersion':'1.0.0','sessionId':session_id,'jobId':job_id})
            timestamp=timestamp or f'2026-{month}-01T00:00:00Z'
            canonical_file(path/'manifest.json',{
                'schemaVersion':'1.0.0','appVersion':'1.0.0-test','coreSpecBaseline':'CORE-2.0.0','platformProfile':'macos-1.0.0',
                'sessionId':session_id,'jobId':job_id,'status':'succeeded','executionMode':'simulated','executionAuthority':'standardAgent',
                'outcomeCertainty':'confirmed','sessionDisposition':'finalized','createdAt':timestamp,'completedAt':timestamp,'archivedAt':None,
                'originalTarget':{'kind':'synthetic','connectKey':None,'transport':'synthetic','identitySnapshot':{'fixture':'session-resources'}},
                'bindingHistory':[{'revision':1,'connectKey':None,'transport':'synthetic','identitySnapshot':{'fixture':'session-resources'},'evidence':['fixture-binding'],'confirmedBy':'simulation','channelProtection':'notApplicable'}],
                'toolchain':{'kind':'none'},'workflow':{'kind':'resourceContract','profileVersion':'1.0.0','providerIdentity':'fixture-provider','fixtureIdentity':'session-resource-fixture','scenarioIdentity':'session-resource-scenario'},
                'steps':[],'parameters':[],'compensations':[],'confirmations':[],'artifacts':[],'warnings':[],'failure':None,'recovery':None})
            return path
        try:
            child=start()
            first=session('session-first','07','2026-07-01T00:00:00.100Z');latest=session('session-latest','08')
            session('session-z-subsecond','07','2026-07-01T00:00:00.900Z')
            initial=result('session.list',{'pageSize':1})
            assert initial['hasMore'] and initial['items'][0]['sessionId']=='session-latest',initial
            assert initial['items'][0]['completedAtUtc']=='2026-08-01T00:00:00Z'
            assert initial['items'][0]['expiresAtUtc']=='2026-10-30T00:00:00Z'
            assert initial['items'][0]['sizeBytes']==str(sum(p.stat().st_size for p in latest.iterdir()))
            assert [row['sessionId'] for row in command(['list'])['result']['items']]==['session-latest','session-first','session-z-subsecond']
            cursor=initial['nextCursor']
            refused('session.list',{'pageSize':2,'cursor':cursor},'invalidCursor')
            refused('session.list',{'pageSize':0},'invalidInput')
            refused('session.show',{'sessionId':'../escape'},'invalidInput')
            refused('session.show',{'sessionId':'missing'},'resourceNotFound')
            shown=command(['show','--session','session-latest'])['result']
            assert shown==initial['items'][0]
            pinned=command(['pin','--session','session-latest','--expected-generation','0'])['result']
            assert pinned['generation']=='1' and pinned['pinned']
            assert result('session.pin',{'sessionId':'session-latest','expectedGeneration':'1'})==pinned
            refused('session.unpin',{'sessionId':'session-latest','expectedGeneration':'0'},'resourceConflict')
            assert command(['unpin','--session','session-latest','--expected-generation','0'],65)['error']['code']=='resourceConflict'
            child.kill();child.wait(timeout=10);child=start()
            assert result('session.show',{'sessionId':'session-latest'})==pinned
            next_page=command(['list','--page-size','1','--cursor',cursor])['result']
            assert next_page['snapshotRevision']==initial['snapshotRevision'] and next_page['hasMore']
            assert next_page['items'][0]['sessionId']=='session-first' and next_page['items'][0]['generation']=='0'
            unpinned=result('session.unpin',{'sessionId':'session-latest','expectedGeneration':'1'})
            assert not unpinned['pinned'] and unpinned['generation']=='2'
            config_bytes=(root/'session-state/session-storage.json').read_bytes() if (root/'session-state/session-storage.json').exists() else None
            catalog_path=root/'sessions/.arkdeck-retention-catalog.json'
            before=catalog_path.read_bytes()
            descriptor=os.open(root/'session-state/.session-storage.lock',os.O_RDWR)
            try:
                fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
                refused('session.pin',{'sessionId':'session-latest','expectedGeneration':'2'},'resourceConflict')
                assert result('session.list',{'pageSize':1,'cursor':cursor})==next_page
            finally:os.close(descriptor)
            assert catalog_path.read_bytes()==before
            descriptor=os.open(root/'sessions/.arkdeck-retention-catalog.lock',os.O_RDWR)
            try:
                fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
                refused('session.pin',{'sessionId':'session-latest','expectedGeneration':'2'},'resourceConflict')
            finally:os.close(descriptor)
            assert catalog_path.read_bytes()==before
            rogue=session('session-unregistered','09')
            assert result('session.show',{'sessionId':'session-latest'})==unpinned
            refused('session.list',{},'operationUnavailable')
            refused('session.pin',{'sessionId':'session-latest','expectedGeneration':'2'},'operationUnavailable')
            assert catalog_path.read_bytes()==before
            shutil.rmtree(rogue)
            duplicate=session('session-latest','06')
            refused('session.show',{'sessionId':'session-latest'},'operationUnavailable')
            shutil.rmtree(duplicate)
            custom=root/'custom';custom.mkdir(mode=0o700)
            result('runtime.storage.root',{'rootPath':str(custom),'expectedGeneration':'1'})
            assert result('session.list',{})['items']==[]
            refused('session.pin',{'sessionId':'session-latest','expectedGeneration':'2'},'resourceConflict')
            assert command(['list','--page-size','1','--cursor',cursor])['result']==next_page
            # The old cursor remains readable even if the current root vanishes.
            shutil.rmtree(custom)
            assert result('session.list',{'pageSize':1,'cursor':cursor})==next_page
            refused('session.list',{},'recordUnreadable')
            assert first.exists() and latest.exists()
            assert config_bytes is None
        finally:
            for child in children:
                if child.poll() is None:child.terminate()
                child.wait(timeout=10);child.stderr.close()
    if args.record_frames:
        args.record_frames.write_text(''.join(json.dumps(row,sort_keys=True,separators=(',',':'))+'\n' for row in rows))
    print(f'PASS: isolated Rust Session resources, {len(rows)} actual control exchanges plus CLI, restart, CAS and immutable cursor checks')

if __name__=='__main__':main()
