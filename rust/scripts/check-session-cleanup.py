#!/usr/bin/env python3
"""Exercise actual isolated Rust Session cleanup preview/apply RPC/CLI with simulated storage.

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
    parser.add_argument('--record-store-copy', type=Path, help='preserve actual Rust preview record bytes for the current Swift decoder test')
    parser.add_argument('--record-applied-copy', type=Path, help='preserve actual Rust applied record bytes for the current Swift decoder test')
    parser.add_argument('--cli-path', type=Path, help='also verify a current Swift CLI consumer against the Rust owner')
    args = parser.parse_args()
    daemon = (args.bin_dir/'arkdeck-agentd').resolve()
    cli = (args.cli_path or args.bin_dir/'arkdeck').resolve()
    registry = json.loads((ROOT/'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    rows=[]
    children=[]
    with tempfile.TemporaryDirectory(prefix='arkdeck-session-cleanup-',dir='/private/tmp') as temporary:
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
            first=session('session-first','07');latest=session('session-latest','08')
            payload=b'private raw fixture content'
            (first/'raw.bin').write_bytes(payload)
            (first/'raw.bin').chmod(0o600)
            manifest=json.loads((first/'manifest.json').read_text())
            manifest['artifacts']=[{'id':'artifact-raw','role':'raw','origin':'fixture','relativePath':'raw.bin','size':len(payload),'sha256':hashlib.sha256(payload).hexdigest()}]
            canonical_file(first/'manifest.json',manifest)
            result('runtime.storage.policy',{'expectedGeneration':'1','totalQuotaBytes':'1024','safetyMarginBytes':'1023','retentionDays':'1'})
            listed=result('session.list',{})
            generation=listed['items'][0]['generation']
            result('session.pin',{'sessionId':'session-latest','expectedGeneration':generation})
            preview=result('session.cleanup.preview',{})
            assert preview['confirmationRequired'] and preview['newDispatchCount']==0
            assert [row['sessionId'] for row in preview['sessions']]==['session-first','session-latest']
            assert preview['sessions'][0]['disposition']=='reclaim' and preview['sessions'][1]['reason']=='pinned'
            assert preview['sessions'][0]['artifacts']==[{'artifactId':'artifact-raw','artifactDigest':hashlib.sha256(payload).hexdigest(),'byteCount':str(len(payload)),'role':'raw','privacy':'sensitive'}]
            digest=preview['previewDigest'];unsigned={k:v for k,v in preview.items() if k!='previewDigest'}
            assert digest==hashlib.sha256(json.dumps(unsigned,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            record=root/'session-state/session-cleanup-previews'/('cleanup-'+preview['previewId']+'.json')
            stored=record.read_bytes()
            if args.record_store_copy:
                args.record_store_copy.write_bytes(stored)
            assert json.loads(stored)['state']=='ready' and json.loads(stored)['preview']==preview
            assert command(['cleanup','preview'])['result']['schemaVersion']=='arkdeck.session-cleanup-preview/1'
            child.kill();child.wait(timeout=10);child=start()
            assert record.read_bytes()==stored
            assert result('session.cleanup.preview',{})['sessions']==preview['sessions']
            descriptor=os.open(root/'session-state/.session-storage.lock',os.O_RDWR)
            try:
                fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
                refused('session.cleanup.preview',{},'resourceConflict')
            finally:os.close(descriptor)
            refused('session.cleanup.preview',{'sessionId':'unexpected'},'invalidParams')
            tuple_params={'previewId':preview['previewId'],'previewDigest':preview['previewDigest']}
            refused('session.cleanup.apply',dict(tuple_params,previewDigest='f'*64),'resourceConflict')
            assert first.exists() and latest.exists() and (first/'raw.bin').read_bytes()==payload
            applied=command(['cleanup','apply','--preview-id',preview['previewId'],'--preview-digest',preview['previewDigest']])['result']
            assert applied['removedSessionIds']==['session-first'] and applied['newDispatchCount']==0,applied
            assert applied['removedArtifacts']==[{'sessionId':'session-first','artifactId':'artifact-raw','artifactDigest':hashlib.sha256(payload).hexdigest()}],applied
            assert applied['reclaimedBytes']==preview['reclaimBytes'] and applied['remainingBytes']==preview['projectedBytes']
            assert int(applied['resultGeneration'])==int(preview['generation'])+1
            assert not first.exists() and latest.exists()
            stored_applied=record.read_bytes()
            assert json.loads(stored_applied)['state']=='applied' and json.loads(stored_applied)['result']==applied
            if args.record_applied_copy:
                args.record_applied_copy.write_bytes(stored_applied)
            child.kill();child.wait(timeout=10);child=start()
            assert record.read_bytes()==stored_applied
            assert result('session.cleanup.apply',tuple_params)==applied
            assert command(['cleanup','apply','--preview-id',preview['previewId'],'--preview-digest',preview['previewDigest']])['result']==applied
            assert not first.exists() and latest.exists()
            rogue=session('unregistered','09')
            refused('session.cleanup.preview',{},'operationUnavailable')
            assert not first.exists() and latest.exists() and rogue.exists()
        finally:
            for child in children:
                if child.poll() is None:child.terminate()
                child.wait(timeout=10);child.stderr.close()
    if args.record_frames:
        args.record_frames.write_text(''.join(json.dumps(row,sort_keys=True,separators=(',',':'))+'\n' for row in rows))
    print(f'PASS: isolated Rust Session cleanup preview/apply, {len(rows)} actual control exchanges plus CLI, durable restart receipts, pin protection and refusal checks')

if __name__=='__main__':main()
