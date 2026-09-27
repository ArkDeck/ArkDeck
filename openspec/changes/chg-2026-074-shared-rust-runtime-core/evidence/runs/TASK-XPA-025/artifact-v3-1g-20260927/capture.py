"""One bounded quiet-host attempt, run only after coordinated window release."""
import hashlib,json,pathlib,sys,traceback
from bench import artifact,clocks
root=pathlib.Path(__file__).resolve().parent
label,daemon,soak,mib=sys.argv[1:]
size=int(mib)*1024**2
if size not in (1024**2,1024**3):raise ValueError('only smoke or 1 GiB')
assert artifact.READER_VERSION=='bounded-incremental-json-v3'
source=pathlib.Path(artifact.__file__).resolve().parents[2]
manifest=json.loads((source/'source-manifest.json').read_text())
for name,digest in manifest['files'].items():
 if hashlib.sha256((source/name).read_bytes()).hexdigest()!=digest:raise ValueError('instrument source changed')
out=root/label;out.mkdir(exist_ok=False)
def sha(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
provenance=json.loads((root/'bin'/'provenance.json').read_text())
assert provenance['sourceCommit']=='8616a8220a82cdc4200804b31d5408eea7953ee3'
for path in [daemon,soak]:assert sha(path)==provenance['files'][pathlib.Path(path).name]['sha256']
with (out/'samples.jsonl').open('x') as stream:
 def record(row):stream.write(json.dumps({'utc':clocks.utc_now(),**row},sort_keys=True)+'\n');stream.flush()
 record({'kind':'captureInputs','sourceCommit':provenance['sourceCommit'],'readerVersion':artifact.READER_VERSION,'daemonSha256':sha(daemon),'soakSha256':sha(soak),'payloadBytes':size,'requireQuiet':True,'readBudgetSeconds':artifact.READ_BUDGET,'baselineEligible':False,'purpose':'single current-source validation; no stability or budget acceptance'})
 try:
  elapsed,scale=artifact.measure(daemon,soak,size,record,require_quiet=True)
  for path in [daemon,soak]:assert sha(path)==provenance['files'][pathlib.Path(path).name]['sha256']
  (out/'result.json').write_text(json.dumps({'status':'complete','milliseconds':elapsed,'scale':scale,'baselineEligible':False},indent=2)+'\n')
 except Exception as error:
  record({'kind':'captureFailure','errorType':type(error).__name__,'error':str(error)})
  (out/'failure.txt').write_text(traceback.format_exc());raise
