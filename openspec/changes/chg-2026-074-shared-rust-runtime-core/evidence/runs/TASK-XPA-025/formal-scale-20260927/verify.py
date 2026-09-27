import collections,datetime,hashlib,json,pathlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode=True;sys.path.insert(0,str(root/'source/scripts'))
from bench.baseline import summarize_run
plan=json.loads((root/'plan.json').read_text());exit_record=json.loads((root/'exit.json').read_text())
rows=[json.loads(x) for x in next((root/'evidence').glob('capture-samples-*.jsonl')).read_text().splitlines()]
doc=json.loads(next((root/'evidence').glob('perf-baseline-*.json')).read_text())
assert exit_record['returnCode']==0 and exit_record['inputsUnchangedAfterAttempt']
assert doc['baselineEligible'] is False and doc['spikeVerdict']=='PASS' and doc['unstableMetrics']==[]
assert doc['captureObservationVersion']=='phase-checkpoints-v1'
assert all(r['captureObservationVersion']=='phase-checkpoints-v1' for r in rows)
report={'purpose':plan['purpose'],'baselineAdoption':False,'originalExitCode':exit_record['returnCode'],'toolVerdict':doc['spikeVerdict'],'baselineEligible':doc['baselineEligible'],'measuredMetricCount':doc['measuredMetricCount'],'gapCount':doc['gapCount'],'runs':[]}
for index in range(3):
 def one(kind):
  matches=[r for r in rows if r['runIndex']==index and r['kind']==kind];assert len(matches)==1,(index,kind);return matches[0]
 seed=one('seedProcess');assert seed['returnCode']==0 and not seed['timedOut']
 raw=one('seedMetricsInput');assert hashlib.sha256(raw['text'].encode()).hexdigest()==raw['sha256']
 parsed=json.loads(raw['text']);work=one('seedWorkload');probe=one('jobListProbe');run=one('runCheckpoint')
 assert parsed['phase']=='completed' and parsed['activeJobCount']==work['activeJobCount']==0
 assert sum(parsed['jobStates'].values())==work['observedTotalJobCount']
 assert parsed['jobStates']==work['jobStates'] and parsed['terminalJobCount']==work['terminalJobCount']
 assert probe['returnedPageRowCount']==run['scale']['jobStoreRowCount']
 cold=[r for r in rows if r['runIndex']==index and r['kind']=='coldStart']
 assert [r['sampleIndex'] for r in cold]==list(range(50))
 assert [r['milliseconds'] for r in cold]==run['samples']['daemon.coldStart']
 for name,count in [('calibration.busyLoop',200),('daemon.coldStart',50),('ipc.health',1000),('ipc.jobList',1000),('ipc.jobStatus',1000)]:assert len(run['samples'][name])==count
 phases=[r for r in rows if r['runIndex']==index and r['kind']=='phaseCheckpoint'];assert [r['phase'] for r in phases]==['calibration','ipc']
 for phase in phases:
  for name,values in phase['samples'].items():assert values==run['samples'][name]
 for name,values in run['samples'].items():assert summarize_run(values)==doc['metrics'][name]['runs'][index],(index,name)
 assert run['scale']==doc['runs'][index]['scale']
 idle=[r for r in rows if r['runIndex']==index and r['kind']=='idleResources']
 assert len(idle)==run['scale']['residentSetSampleCount']
 assert [{'elapsedSeconds':r['startedAtSeconds'],'bytes':r['residentSetBytes']} for r in idle]==run['scale']['residentSetRawSamples']
 assert idle[-1]['finishedAtSeconds']>=600
 assert run['scale']['residentSetReleaseObserved'] is False and run['scale']['residentSetReleaseAtSeconds'] is None
 assert one('runtimeCleanup')['processReferenceCleared'] is True and one('stateCleanup')['rootAbsent'] is True
 report['runs'].append({'runIndex':index,'actualSeedTotal':work['observedTotalJobCount'],'jobStates':work['jobStates'],'activeJobCount':work['activeJobCount'],'returnedFirstPageCount':probe['returnedPageRowCount'],'sampleCounts':{k:len(v) for k,v in run['samples'].items()},'idleLastStartSeconds':idle[-1]['startedAtSeconds'],'idleLastFinishSeconds':idle[-1]['finishedAtSeconds'],'rssMinBytes':min(r['residentSetBytes'] for r in idle),'rssMaxBytes':max(r['residentSetBytes'] for r in idle),'releaseObserved':False,'processReferenceCleared':True,'ownedRootAbsent':True})
quiet=[r for r in rows if r['kind']=='quietHost'];assert all(r['oneMinuteLoad']<4 and r['conflictingBuildProcesses']==0 and r['processCheckPerformed'] for r in quiet)
report['quietChecks']={'count':len(quiet),'minimumLoad':min(r['oneMinuteLoad'] for r in quiet),'maximumLoad':max(r['oneMinuteLoad'] for r in quiet)}
assert list((root/'state').iterdir())==[]
processes=subprocess.run(['ps','-axo','pid=,command='],capture_output=True,text=True,check=True,timeout=10)
matching=[line for line in processes.stdout.splitlines() if any(str(root/name) in line for name in ['bin/arkdeck-agentd','bin/arkdeck-soak','run.py'])]
report['remainingOwnedProcesses']=matching;assert not matching
report['ownedStateDirectoryEmpty']=True
for name,facts in plan['binaries'].items():
 with (root/'bin'/name).open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==facts['sha256']
for name,expected in plan['instrumentFiles'].items():assert hashlib.sha256((root/'source'/name).read_bytes()).hexdigest()==expected
report['fixedInputsVerified']=True
report['metricSummary']={name:{'perRunP95':[r['p95'] for r in m['runs']],'aggregate':m['aggregate'],'p95SpreadRatio':m['p95SpreadRatio'],'stable':m['stable']} for name,m in doc['metrics'].items() if m['status']=='MEASURED'}
report['steady']=doc['metrics']['daemon.residentSetSteady']
report['verifiedAtUtc']=datetime.datetime.now(datetime.UTC).isoformat()
(root/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
