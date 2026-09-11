#!/usr/bin/env python3
"""Exercise actual isolated Rust Session export preview/apply RPC/CLI with simulated storage.

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
    parser.add_argument('--applied-record-store-copy', type=Path, help='preserve actual applied record bytes for the Swift decoder test')
    parser.add_argument('--cli-path', type=Path, help='also verify a current Swift CLI consumer against the Rust owner')
    args = parser.parse_args()
    # Isolated contract views copy the Rust test inputs. In the source checkout,
    # also prove these bytes remain the exact Swift capture fixtures.
    captured = ROOT/'Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/SessionStorage'
    if captured.is_dir():
        for fixture in sorted((ROOT/'rust/tests/fixtures/session-export').glob('*.json')):
            assert fixture.read_bytes() == (captured/fixture.name).read_bytes(), fixture.name
    daemon = (args.bin_dir/'arkdeck-agentd').resolve()
    cli = (args.cli_path or args.bin_dir/'arkdeck').resolve()
    registry = json.loads((ROOT/'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    rows=[]
    children=[]
    with tempfile.TemporaryDirectory(prefix='arkdeck-session-export-',dir='/private/tmp') as temporary:
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
            first=session('session-first','07');other=session('session-other','08')
            payload=b'private raw fixture content'
            (first/'raw.bin').write_bytes(payload);(first/'raw.bin').chmod(0o600)
            journal=b'fixture Journal bytes\n'
            (first/'journal.jsonl').write_bytes(journal);(first/'journal.jsonl').chmod(0o600)
            manifest=json.loads((first/'manifest.json').read_bytes())
            manifest['artifacts']=[{'id':'artifact-raw','role':'raw','origin':'fixture','relativePath':'raw.bin','size':len(payload),'sha256':hashlib.sha256(payload).hexdigest()}]
            canonical_file(first/'manifest.json',manifest)
            output=root/'output';output.mkdir(mode=0o755)
            destination=output/'bundle'
            options={'sessionId':'session-first','destinationPath':str(destination),'allowSensitive':False}
            preview=result('session.export.preview',options)
            assert preview['source']['manifestSha256']==hashlib.sha256((first/'manifest.json').read_bytes()).hexdigest()
            assert preview['source']['journalSha256']==hashlib.sha256(journal).hexdigest()
            assert preview['artifacts'][0]['disposition']=='excludeByDefault'
            assert preview['estimatedBytes']==str((first/'manifest.json').stat().st_size)
            assert preview['destination']['expectedState']=='absent' and not destination.exists()
            assert preview['catalogStatus']['complete'] and preview['newDispatchCount']==0
            unsigned={k:v for k,v in preview.items() if k!='previewDigest'}
            assert preview['previewDigest']==hashlib.sha256(json.dumps(unsigned,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            record=root/'session-state/session-export-previews'/('export-'+preview['previewId']+'.json')
            stored=record.read_bytes()
            assert json.loads(stored)['schemaVersion']=='arkdeck.session-export-record/1'
            if args.record_store_copy:args.record_store_copy.write_bytes(stored)
            assert json.loads(stored)['preview']==preview and json.loads(stored)['state']=='ready'
            cli_result=command(['export','preview','--session','session-first','--destination',str(destination)])['result']
            assert cli_result['source']==preview['source'] and cli_result['artifacts']==preview['artifacts']
            included=command(['export','preview','--session','session-first','--destination',str(destination),'--allow-sensitive'])['result']
            assert included['artifacts'][0]['disposition']=='include'
            assert included['estimatedBytes']==str((first/'manifest.json').stat().st_size+len(payload))
            child.kill();child.wait(timeout=10);child=start()
            assert record.read_bytes()==stored
            assert result('session.export.preview',options)['source']==preview['source']
            (other/'manifest.json').write_bytes(b'corrupt registered fixture')
            disclosed=result('session.export.preview',options)
            assert not disclosed['catalogStatus']['complete'] and disclosed['catalogStatus']['unaccountedSessionCount']=='1'
            assert command(['export','preview','--session','session-first','--destination',str(destination)])['result']['catalogStatus']==disclosed['catalogStatus']
            refused('session.export.preview',{**options,'sessionId':'session-other'},'operationUnavailable')
            refused('session.cleanup.preview',{},'operationUnavailable')
            descriptor=os.open(root/'session-state/.session-storage.lock',os.O_RDWR)
            try:
                fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
                refused('session.export.preview',options,'resourceConflict')
            finally:os.close(descriptor)
            refused('session.export.preview',{**options,'destinationPath':str(root/'sessions/export')},'invalidInput')
            destination.write_bytes(b'existing file')
            refused('session.export.preview',options,'resourceConflict')
            assert destination.read_bytes()==b'existing file'
            assert (first/'raw.bin').read_bytes()==payload
            published_path=output/'published-default'
            published_preview=result('session.export.preview',{**options,'destinationPath':str(published_path)})
            tuple_params={'previewId':published_preview['previewId'],'previewDigest':published_preview['previewDigest']}
            refused('session.export.apply',{**tuple_params,'previewDigest':'0'*64},'resourceConflict')
            applied=result('session.export.apply',tuple_params)
            assert applied['schemaVersion']=='arkdeck.session-export-result/1' and applied['newDispatchCount']==0
            assert applied['source']==published_preview['source'] and applied['catalogStatus']==published_preview['catalogStatus']
            assert applied['sourceArtifactIds']==[] and applied['excludedArtifactIds']==['artifact-raw']
            assert applied['exportedPath']==str(published_path)
            exported_manifest=json.loads((published_path/'manifest.json').read_bytes())
            assert exported_manifest['artifacts']==[] and not (published_path/'raw.bin').exists()
            applied_record=root/'session-state/session-export-previews'/('export-'+published_preview['previewId']+'.json')
            applied_bytes=applied_record.read_bytes()
            assert json.loads(applied_bytes)['state']=='applied' and json.loads(applied_bytes)['result']==applied
            if args.applied_record_store_copy:args.applied_record_store_copy.write_bytes(applied_bytes)
            inode=published_path.stat().st_ino
            child.kill();child.wait(timeout=10);child=start()
            assert result('session.export.apply',tuple_params)==applied
            assert command(['export','apply','--preview-id',tuple_params['previewId'],'--preview-digest',tuple_params['previewDigest']])['result']==applied
            assert published_path.stat().st_ino==inode and applied_record.read_bytes()==applied_bytes
            sensitive_path=output/'published-sensitive'
            sensitive=command(['export','preview','--session','session-first','--destination',str(sensitive_path),'--allow-sensitive'])['result']
            sensitive_result=command(['export','apply','--preview-id',sensitive['previewId'],'--preview-digest',sensitive['previewDigest']])['result']
            assert sensitive_result['sourceArtifactIds']==['artifact-raw'] and sensitive_result['excludedArtifactIds']==[]
            assert (sensitive_path/'raw.bin').read_bytes()==payload
            assert (first/'raw.bin').read_bytes()==payload and (first/'journal.jsonl').read_bytes()==journal
        finally:
            for child in children:
                if child.poll() is None:child.terminate()
                child.wait(timeout=10);child.stderr.close()
    if args.record_frames:
        args.record_frames.write_text(''.join(json.dumps(row,sort_keys=True,separators=(',',':'))+'\n' for row in rows))
    print(f'PASS: isolated Rust Session export preview/apply, {len(rows)} actual control exchanges plus CLI, durable restart, idempotent apply, source preservation, sensitive defaults and refusal checks')

if __name__=='__main__':main()
