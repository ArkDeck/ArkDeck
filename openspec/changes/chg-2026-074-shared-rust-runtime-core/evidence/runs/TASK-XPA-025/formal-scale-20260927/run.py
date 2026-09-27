import datetime,hashlib,json,os,pathlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parent
plan=json.loads((root/'plan.json').read_text())
def verify():
 for name,facts in plan['binaries'].items():
  with (root/'bin'/name).open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==facts['sha256']
 for name,expected in plan['instrumentFiles'].items():assert hashlib.sha256((root/'source'/name).read_bytes()).hexdigest()==expected
verify()
record={'purpose':plan['purpose'],'baselineAdoption':False,'startedAtUtc':datetime.datetime.now(datetime.UTC).isoformat(),'python':sys.version,'pythonExecutable':sys.executable}
env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',PYTHONPATH=str(root/'source/scripts'),TMPDIR=str(root/'state'))
with (root/'attempt.json').open('x') as out:json.dump(record,out,indent=2)
try:
 with (root/'stdout.log').open('xb') as out,(root/'stderr.log').open('xb') as err:
  result=subprocess.run(plan['arguments'],env=env,stdout=out,stderr=err,check=False)
 record['returnCode']=result.returncode
finally:
 record['finishedAtUtc']=datetime.datetime.now(datetime.UTC).isoformat()
 verify();record['inputsUnchangedAfterAttempt']=True
 record['ownedStateChildrenAfterExit']=[p.name for p in (root/'state').iterdir()]
 (root/'exit.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,indent=2))
raise SystemExit(result.returncode)
