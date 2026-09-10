#!/usr/bin/env python3
"""Exercise actual isolated Rust storage control and CLI, without devices."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT/'rust/target/debug')
    parser.add_argument('--record-frames', type=Path)
    args = parser.parse_args()
    daemon = (args.bin_dir/'arkdeck-agentd').resolve()
    cli = (args.bin_dir/'arkdeck').resolve()
    registry = json.loads((ROOT/'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    rows=[]
    children=[]
    with tempfile.TemporaryDirectory(prefix='arkdeck-session-',dir='/private/tmp') as temporary:
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
                        with socket.socket(socket.AF_UNIX) as client: client.connect(str(endpoint))
                        return child
                    except OSError: pass
                time.sleep(.01)
            raise AssertionError('owner did not start')
        def exchange(method,params):
            request={'protocolVersion':registry['currentVersion'],'contractIdentity':identity,'id':'session-check','method':method,'params':params}
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(10);client.connect(str(endpoint));client.sendall(json.dumps(request).encode()+b'\n')
                with client.makefile('rb') as reader: reply=json.loads(reader.readline(8*1024*1024+1))
            row={'protocolVersion':registry['currentVersion'],'method':method,'params':params,**reply};row.pop('id');rows.append(row)
            return reply
        def command(arguments,expected=0):
            answer=subprocess.run([str(cli),'--output','json','runtime','storage',*arguments],env=env,capture_output=True,timeout=15)
            assert answer.returncode==expected,(answer.returncode,answer.stdout,answer.stderr)
            return json.loads(answer.stdout)
        def policy(generation, **extra):
            return {'expectedGeneration':str(generation),'totalQuotaBytes':'500000','safetyMarginBytes':'1000','retentionDays':'30',**extra}
        try:
            first=start()
            value=exchange('runtime.storage.status',{})
            assert value['ok'],value
            assert value['result']['sessionDomain']['generation']=='1'
            assert command(['status'])['result']['artifactDomain']['usedBytes']=='0'
            assert exchange('runtime.storage.policy',policy(1))['result']['sessionDomain']['generation']=='2'
            assert exchange('runtime.storage.policy',policy(1))['error']['code']=='resourceConflict'
            assert command(['policy','--expected-generation','1','--total-quota-bytes','500000','--safety-margin-bytes','1000','--retention-days','30'],65)['error']['code']=='resourceConflict'
            assert exchange('runtime.storage.policy',policy(2,totalQuotaBytes='1000'))['error']['code']=='invalidInput'
            first.kill();first.wait(timeout=10);start()
            assert command(['status'])['result']['sessionDomain']['generation']=='2'
            custom=root/'custom';custom.mkdir(mode=0o700)
            # A closed, explicitly simulated Session fixture exercises real
            # census registration, retained identity and calendar publication.
            year=custom/'2026';year.mkdir(mode=0o700)
            month=year/'07';month.mkdir(mode=0o700)
            session=month/'session-1';session.mkdir(mode=0o700)
            def canonical_file(path,value):
                path.write_text(json.dumps(value,sort_keys=True,separators=(',',':')));path.chmod(0o600)
            canonical_file(session/'.session-identity.json',{'schemaVersion':'1.0.0','sessionId':'session-1','jobId':'job-1'})
            canonical_file(session/'manifest.json',{
                'schemaVersion':'1.0.0','appVersion':'1.0.0-test','coreSpecBaseline':'CORE-2.0.0','platformProfile':'macos-1.0.0',
                'sessionId':'session-1','jobId':'job-1','status':'succeeded','executionMode':'simulated','executionAuthority':'standardAgent',
                'outcomeCertainty':'confirmed','sessionDisposition':'finalized','createdAt':'2026-07-17T08:00:00Z','completedAt':'2026-07-17T08:00:00Z','archivedAt':None,
                'originalTarget':{'kind':'synthetic','connectKey':None,'transport':'synthetic','identitySnapshot':{'fixture':'storage-contract'}},
                'bindingHistory':[{'revision':1,'connectKey':None,'transport':'synthetic','identitySnapshot':{'fixture':'storage-contract'},'evidence':['fixture-binding'],'confirmedBy':'simulation','channelProtection':'notApplicable'}],
                'toolchain':{'kind':'none'},'workflow':{'kind':'storageContract','profileVersion':'1.0.0','providerIdentity':'fixture-provider','fixtureIdentity':'session-storage-fixture-1','scenarioIdentity':'session-storage-scenario-1'},
                'steps':[],'parameters':[],'compensations':[],'confirmations':[],'artifacts':[],'warnings':[],'failure':None,'recovery':None})
            session_bytes=sum(path.stat().st_size for path in session.iterdir())
            assert exchange('runtime.storage.root',{'expectedGeneration':'2','rootPath':str(custom)})['result']['sessionDomain']['generation']=='3'
            (custom/'unknown').write_bytes(b'123456789')
            value=exchange('runtime.storage.status',{})['result']['sessionDomain']
            assert value['usage']['usedBytes']==str(session_bytes+9) and value['usage']['measurementIncomplete']
            assert value['usage']['sessionCount']=='1'
            catalog_path=custom/'.arkdeck-retention-catalog.json'
            catalog=json.loads(catalog_path.read_bytes())
            assert catalog['entries'][0]['expiresAt']=='2026-08-16T08:00:00.000000000Z',catalog
            catalog['entries'][0]['isPinned']=True
            canonical_file(catalog_path,catalog)
            assert exchange('runtime.storage.status',{})['result']['sessionDomain']['usage']['pinnedBytes']==str(session_bytes)
            assert exchange('runtime.storage.root',{'expectedGeneration':'3','rootPath':str(root/'artifacts')})['error']['code']=='invalidInput'
            assert exchange('runtime.storage.root',{'expectedGeneration':'3','rootPath':'/private/tmp'})['error']['code']=='invalidInput'
            assert exchange('runtime.storage.root',{'expectedGeneration':'3','resetToDefault':True})['result']['sessionDomain']['generation']=='4'
            assert command(['root','--expected-generation','4','--root',str(custom)])['result']['sessionDomain']['generation']=='5'
            assert exchange('runtime.storage.status',{})['result']['sessionDomain']['generation']=='5'
            lock=os.open(root/'session-state/.session-storage.lock',os.O_RDWR)
            try:
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                assert exchange('runtime.storage.policy',policy(5))['error']['code']=='resourceConflict'
            finally: os.close(lock)
            # Published bytes are verified before any Session mutation.
            artifact_dir=root/'artifacts/JOB-TEST';artifact_dir.mkdir(mode=0o700)
            artifact_id='ART-'+'a'*32
            payload=artifact_dir/artifact_id;payload.write_bytes(b'hello');payload.chmod(0o600)
            metadata={'artifactID':artifact_id,'jobID':'JOB-TEST','sessionID':'SESSION-TEST','stepID':'STEP-TEST','name':'sample','mediaType':'text/plain',
                'byteCount':5,'sha256':hashlib.sha256(b'hello').hexdigest(),'createdAtUTC':'2026-09-10T00:00:00.000Z','providerID':'host','sourceOperation':'test.fixture',
                'bindingSnapshot':{'targetID':'host'},'privacy':'standard','retention':{'retentionClass':'default','pinned':False},'status':{'published':{}},'redactionApplied':False}
            index=artifact_dir/'index.json';index.write_text(json.dumps({'schemaVersion':'1.0.0','artifacts':[metadata]}));index.chmod(0o600)
            assert exchange('runtime.storage.status',{})['result']['artifactDomain']['usedBytes']=='5'
            before=(root/'session-state/session-storage.json').read_bytes()
            payload.write_bytes(b'world')
            assert exchange('runtime.storage.policy',policy(5))['error']['code']=='recordUnreadable'
            assert (root/'session-state/session-storage.json').read_bytes()==before
            payload.write_bytes(b'hello')
            updated=exchange('runtime.storage.policy',policy(5))['result']['sessionDomain']
            assert updated['generation']=='6' and updated['usage']['pinnedBytes']==str(session_bytes)
            assert json.loads(catalog_path.read_bytes())['entries'][0]['policyGeneration']==6
            # Missing previously initialized retention metadata is incomplete,
            # never silently recreated by status, root, or policy requests.
            (custom/'.arkdeck-retention-catalog.json').unlink()
            assert exchange('runtime.storage.status',{})['result']['sessionDomain']['catalogGeneration'] is None
            assert exchange('runtime.storage.policy',policy(6))['result']['sessionDomain']['catalogGeneration'] is None
            assert exchange('runtime.storage.root',{'expectedGeneration':'7','rootPath':str(custom)})['result']['sessionDomain']['catalogGeneration'] is None
            assert not (custom/'.arkdeck-retention-catalog.json').exists()
            assert exchange('runtime.storage.root',{'expectedGeneration':'8','resetToDefault':False})['error']['code']=='invalidInput'
            assert exchange('runtime.storage.policy',policy('08'))['error']['code']=='invalidInput'
            before=(root/'session-state/session-storage.json').read_bytes()
            custom.chmod(0o500)
            try:
                assert exchange('runtime.storage.root',{'expectedGeneration':'8','rootPath':str(custom)})['error']['code']=='invalidInput'
            finally: custom.chmod(0o700)
            assert (root/'session-state/session-storage.json').read_bytes()==before
        finally:
            for child in children:
                if child.poll() is None:child.terminate()
                child.wait(timeout=10)
                child.stderr.close()
    if args.record_frames:
        args.record_frames.write_text(''.join(json.dumps(row,sort_keys=True,separators=(',',':'))+'\n' for row in rows))
    print(f'PASS: isolated Rust Session owner, {len(rows)} actual control exchanges plus CLI/restart/Artifact verification')
if __name__=='__main__':main()
