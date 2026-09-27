import gzip,hashlib,json,pathlib,sys,tarfile
root=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(root/'source/scripts'))
from bench.baseline import summarize_run,spread_ratio
from bench.metrics import split_at_release
manifest=json.loads((root/'source/source-manifest.json').read_text())
for name,digest in manifest['files'].items():assert hashlib.sha256((root/'source'/name).read_bytes()).hexdigest()==digest
provenance=json.loads((root/'bin/provenance.json').read_text())
for name,facts in provenance['files'].items():assert hashlib.sha256((root/'bin'/name).read_bytes()).hexdigest()==facts['sha256']
report={'sourceCommit':manifest['sourceCommit'],'inputFilesVerified':len(manifest['files']),'binariesVerified':len(provenance['files']),'baselineEligible':False,'artifact':{},'coldStart':[],'idle':[]}
for label,size in [('artifact-128m',128*1024**2),('artifact-1g',1024**3)]:
 rows=[json.loads(x) for x in (root/label/'samples.jsonl').read_text().splitlines()]
 result=json.loads((root/label/'result.json').read_text()); pages=[x for x in rows if x['kind']=='artifactPage'];offset=0
 for index,p in enumerate(pages):
  assert p['pageIndex']==index and p['offset']==offset and p['byteCount']==4194304
  offset+=p['byteCount'];assert p['nextOffset']==offset and p['eof']==(offset==size)
 assert offset==size and result['status']=='complete'
 guards=[x for x in rows if x['kind']=='quietHost'];assert len(guards)==4 and all(x['oneMinuteLoad']<4 and x['conflictingBuildProcesses']==0 for x in guards)
 complete=next(x for x in rows if x['kind']=='artifactReadComplete')
 report['artifact'][label]={'pageCount':len(pages),'verifiedBytes':offset,'completeRecord':complete,'quietLoads':[x['oneMinuteLoad'] for x in guards]}
rows=[json.loads(x) for x in next((root/'baseline').glob('*.jsonl')).read_text().splitlines()]
for run in range(3):
 cold=[x for x in rows if x['kind']=='coldStart' and x['runIndex']==run]
 assert [x['sampleIndex'] for x in cold]==list(range(50))
 assert all(x['diagnostics']['observationVersion']=='startup-observation-v2' for x in cold)
 report['coldStart'].append(summarize_run([x['milliseconds'] for x in cold]))
 idle=[x for x in rows if x['kind']=='idleResources' and x['runIndex']==run]
 values=[x['residentSetBytes'] for x in idle];plateau,steady,index=split_at_release(values)
 report['idle'].append({'sampleCount':len(idle),'firstStartSeconds':idle[0]['startedAtSeconds'],'lastFinishSeconds':idle[-1]['finishedAtSeconds'],'minRssBytes':min(values),'maxRssBytes':max(values),'releaseIndex':index,'steadySampleCount':len(steady)})
report['coldStartP95SpreadRatio']=spread_ratio([x['p95'] for x in report['coldStart']])
assert rows[-1]['status']=='FAILED' and rows[-1]['errorType']=='HostTooBusy'
assert json.loads((root/'baseline/exit.json').read_text())['returnCode']==1
report['failure']=rows[-1]
(root/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
