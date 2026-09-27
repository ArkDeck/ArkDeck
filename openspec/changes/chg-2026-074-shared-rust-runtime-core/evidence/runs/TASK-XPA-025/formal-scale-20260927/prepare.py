import datetime,hashlib,json,os,pathlib,re,shutil,stat,subprocess,sys,tempfile
repo=pathlib.Path('/private/tmp/arkdeck-xpa025-bench-observability')
tool='2b049c61238165a88edb6f7cd40b67781f46c3af';daemon_source='d330cc01945fcaeff6b59b1ecd9a2eb11b861350';soak_source='0400050d99b0e118491bfbd1324ed8a01054884f'
def git(*args):return subprocess.check_output(['git',*args],cwd=repo)
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
assert git('rev-parse',tool+'^{tree}')==git('rev-parse',daemon_source+'^{tree}')
registry='Packages/ArkDeckKit/Contracts/control-protocol.json'
registry_bytes=git('show',tool+':'+registry)
assert registry_bytes==git('show',daemon_source+':'+registry)==git('show',soak_source+':'+registry)
canonical=json.dumps(json.loads(registry_bytes),sort_keys=True,separators=(',',':')).encode();identity=hashlib.sha256(canonical).hexdigest()
generated='rust/crates/arkdeck-contract/src/control_generated.rs'
for source in [tool,daemon_source,soak_source]:
 text=git('show',source+':'+generated).decode();assert re.search(r'CONTRACT_IDENTITY: &str =\s*"'+identity+'"',text)
assert git('show',tool+':'+generated)==git('show',soak_source+':'+generated)
root=pathlib.Path(tempfile.mkdtemp(prefix='xpa025-formal.',dir='/private/tmp'))
for name in ['bin','source','state','evidence']:(root/name).mkdir(mode=0o700)
pathlib.Path('/private/tmp/arkdeck-xpa025-formal-root.txt').write_text(str(root)+'\n')
inputs={'arkdeck-agentd':('/private/tmp/arkdeck-rust-helpers-d330cc01-pvvk2iz1/presign-bin/arkdeck-agentd','5ecf35b1b4be7aaf01e1a2023a6e4b997109773676356e16491a8af9f9c6abf7',daemon_source),'arkdeck-soak':('/private/tmp/adk24h.x9a5uvr3/bin/arkdeck-soak','c9ab8e5f1d124e54d83f1174fbd454ba44c2531938be42547b9a565c977b0c1c',soak_source)}
binaries={}
for name,(path,expected,source) in inputs.items():
 p=pathlib.Path(path);st=p.lstat();assert stat.S_ISREG(st.st_mode) and stat.S_IMODE(st.st_mode)==0o500
 assert sha(p)==expected
 q=root/'bin'/name;shutil.copyfile(p,q);q.chmod(0o500);assert sha(q)==sha(p)==expected
 binaries[name]={'originalPath':path,'sourceCommit':source,'rustTree':git('rev-parse',source+':rust').decode().strip(),'sha256':expected,'bytes':q.stat().st_size,'mode':'0500','verifiedBeforeAndAfterCopy':True}
paths=[p for p in git('ls-tree','-r','--name-only',tool,'scripts/bench').decode().splitlines() if p.endswith('.py')]+[registry,'rust/tests/fixtures/flash-archive/archives/complete.tar.gz']
files={}
for name in paths:
 data=git('show',tool+':'+name);p=root/'source'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data);files[name]=hashlib.sha256(data).hexdigest()
args=[sys.executable,'-m','bench','capture','--daemon',str(root/'bin/arkdeck-agentd'),'--soak',str(root/'bin/arkdeck-soak'),'--runtime-kind','rust','--build-configuration','release','--runs','3','--cold-start-samples','50','--ipc-samples','1000','--calibration-samples','200','--seed-seconds','6','--seed-jobs-per-cycle','10','--idle-seconds','600','--quiet-wait-seconds','0','--out-dir',str(root/'evidence')]
plan={'purpose':'formal-scale single capture; retain all obtained evidence','baselineAdoption':False,'toolSource':tool,'toolTree':git('rev-parse',tool+'^{tree}').decode().strip(),'daemonCandidateTreeEqualsMain':True,'contractRegistrySha256':hashlib.sha256(registry_bytes).hexdigest(),'contractIdentity':identity,'registryAndGeneratedContractEqualAcrossSources':True,'binaries':binaries,'instrumentFiles':files,'arguments':args,'attempt':1,'automaticRetry':False,'preparedAtUtc':datetime.datetime.now(datetime.UTC).isoformat(),'python':sys.version}
(root/'plan.json').write_text(json.dumps(plan,indent=2)+'\n');shutil.copyfile('/private/tmp/arkdeck-xpa025-formal-prepare.py',root/'prepare.py')
sys.dont_write_bytecode=True;sys.path.insert(0,str(root/'source/scripts'))
from bench import recovery,harness
try:
 quiet=recovery.assert_quiet_host();quiet.update(status='PASS')
except harness.HostTooBusy as error:
 quiet={'status':'REFUSED','error':str(error),**error.facts}
quiet['atUtc']=datetime.datetime.now(datetime.UTC).isoformat();(root/'preflight-quiet.json').write_text(json.dumps(quiet,indent=2)+'\n')
print(json.dumps({'root':str(root),'contractIdentity':identity,'quiet':quiet},indent=2))
if quiet['status']!='PASS':raise SystemExit(1)
