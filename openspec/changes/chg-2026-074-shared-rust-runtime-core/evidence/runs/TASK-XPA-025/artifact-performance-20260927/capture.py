import hashlib, json, pathlib, sys, traceback
from bench import artifact, clocks
root=pathlib.Path(__file__).resolve().parent
label,daemon,soak,size=sys.argv[1:]
out=root/label;out.mkdir(exist_ok=False)
source=pathlib.Path(artifact.__file__).resolve().parents[2]
manifest=json.loads((source/'source-manifest.json').read_text())
for name,digest in manifest['files'].items():
 if hashlib.sha256((source/name).read_bytes()).hexdigest()!=digest:raise ValueError('pinned instrument changed')
def sha(path):return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
inputs={'kind':'matrixInputs','functionalOnly':True,'baselineEligible':False,'label':label,'instrumentSource':manifest['sourceCommit'],'daemon':daemon,'daemonSha256':sha(daemon),'soak':soak,'soakSha256':sha(soak),'mib':int(size),'requireQuiet':False,'cachePolicy':'fresh owner; no OS cache eviction; fixed ordered single samples'}
with (out/'samples.jsonl').open('x') as stream:
 def record(row):
  stream.write(json.dumps({'utc':clocks.utc_now(),**row},sort_keys=True)+'\n');stream.flush()
 record(inputs)
 try:
  elapsed,scale=artifact.measure(daemon,soak,int(size)*1024*1024,record,False)
  if sha(daemon)!=inputs['daemonSha256'] or sha(soak)!=inputs['soakSha256']:raise ValueError('executable changed')
  (out/'result.json').write_text(json.dumps({**inputs,'milliseconds':elapsed,'scale':scale},indent=2)+'\n')
 except Exception:
  traceback.print_exc();raise
