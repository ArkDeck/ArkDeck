"""Invoke the unchanged fixed-source CLI once; preserve every refusal/result."""
import hashlib,json,os,pathlib,subprocess,sys
from bench import clocks
root=pathlib.Path(__file__).resolve().parent
source=root/'source';manifest=json.loads((source/'source-manifest.json').read_text());provenance=json.loads((root/'bin/provenance.json').read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 assert manifest['sourceCommit']==provenance['sourceCommit']=='4c3ed7491a96921a5a48f908f168cd27438e1064'
 for name,digest in manifest['files'].items():assert sha(source/name)==digest,name
 for name,facts in provenance['files'].items():assert sha(root/'bin'/name)==facts['sha256'],name
verify();out=root/'baseline';out.mkdir(exist_ok=False)
args=[sys.executable,'-m','bench','capture','--daemon',str(root/'bin/arkdeck-agentd'),'--soak',str(root/'bin/arkdeck-soak'),'--runtime-kind','rust','--build-configuration','release','--runs','3','--cold-start-samples','50','--ipc-samples','1000','--idle-seconds','600','--calibration-samples','200','--seed-seconds','6','--seed-jobs-per-cycle','10','--quiet-wait-seconds','0','--out-dir',str(out)]
record={'sourceCommit':provenance['sourceCommit'],'startedAtUtc':clocks.utc_now(),'arguments':args,'instrumentManifestSha256':sha(source/'source-manifest.json')}
(out/'invocation.json').write_text(json.dumps(record,indent=2)+'\n')
try:
 result=subprocess.run(args,check=False)
 record.update(returnCode=result.returncode,finishedAtUtc=clocks.utc_now());verify()
 (out/'exit.json').write_text(json.dumps(record,indent=2)+'\n')
 raise SystemExit(result.returncode)
finally:verify()
