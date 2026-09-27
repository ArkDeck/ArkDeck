"""One fixed-source quiet-host Artifact attempt; no retries or baseline adoption."""
import hashlib,json,pathlib,sys,traceback
from bench import artifact,clocks
root=pathlib.Path(__file__).resolve().parent
label,mib=sys.argv[1:];size=int(mib)*1024**2
assert size in (128*1024**2,1024**3)
out=root/label;out.mkdir(exist_ok=False)
source=pathlib.Path(artifact.__file__).resolve().parents[2]
manifest=json.loads((source/'source-manifest.json').read_text())
provenance=json.loads((root/'bin/provenance.json').read_text())
def sha(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def verify():
 assert manifest['sourceCommit']==provenance['sourceCommit']=='4c3ed7491a96921a5a48f908f168cd27438e1064'
 for name,digest in manifest['files'].items():assert sha(source/name)==digest,name
 for name,facts in provenance['files'].items():assert sha(root/'bin'/name)==facts['sha256'],name
verify()
with (out/'samples.jsonl').open('x') as stream:
 def record(row):stream.write(json.dumps({'utc':clocks.utc_now(),**row},sort_keys=True)+'\n');stream.flush()
 record({'kind':'captureInputs','sourceCommit':provenance['sourceCommit'],'files':provenance['files'],'readerVersion':artifact.READER_VERSION,'payloadBytes':size,'requireQuiet':True,'readBudgetSeconds':artifact.READ_BUDGET,'baselineEligible':False,'purpose':'single combined implementation validation; not three-run stable baseline'})
 try:
  elapsed,scale=artifact.measure(root/'bin/arkdeck-agentd',root/'bin/arkdeck-soak',size,record,require_quiet=True)
  verify()
  (out/'result.json').write_text(json.dumps({'status':'complete','milliseconds':elapsed,'scale':scale,'baselineEligible':False},indent=2)+'\n')
 except Exception as error:
  record({'kind':'captureFailure','errorType':type(error).__name__,'error':str(error)})
  (out/'failure.txt').write_text(traceback.format_exc());raise
 finally:verify()
