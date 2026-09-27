import gzip,hashlib,json,pathlib,subprocess,sys,tarfile
root=pathlib.Path('/private/tmp/arkdeck-xpa025-formal-evidence')
out=root/'openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-025/formal-scale-20260927'
sys.dont_write_bytecode=True;sys.path.insert(0,str(root/'scripts'))
from bench.baseline import assert_no_host_identity
manifest=json.loads((out/'files.json').read_text());plan=json.loads((out/'plan.json').read_text())
for name,facts in manifest['files'].items():
 stored=(out/name).read_bytes();raw=gzip.decompress(stored) if name.endswith('.gz') else stored
 assert len(stored)==facts['storedBytes'] and hashlib.sha256(stored).hexdigest()==facts['storedSha256'],name
 assert len(raw)==facts['uncompressedBytes'] and hashlib.sha256(raw).hexdigest()==facts['uncompressedSha256'],name
 assert pathlib.Path(facts['sourcePath']).read_bytes()==raw,name
 if name!='instrument-source.tar.gz':
  text=raw.decode()
  if name=='archive-check-initial.log.gz':
   # This exact placeholder caused the documented false positive; bytes stay intact.
   text=text.replace(chr(47)+'Users'+chr(47)+'<name>','HOME_PATH_PLACEHOLDER')
  assert_no_host_identity(text)
with tarfile.open(out/'instrument-source.tar.gz') as tar:
 members=tar.getmembers();assert len(members)==len(plan['instrumentFiles'])
 for member in members:
  assert member.isfile();raw=tar.extractfile(member).read()
  assert hashlib.sha256(raw).hexdigest()==plan['instrumentFiles'][member.name]
  assert raw==subprocess.check_output(['git','show',plan['toolSource']+':'+member.name],cwd=root)
assert_no_host_identity((out/'README.md').read_text())
# Existing README examples contain a literal home-path placeholder.
# Check only this PR's added entry text; all newly archived data is checked above.
diff=subprocess.check_output(['git','diff','--','scripts/bench/README.md'],cwd=root).decode()
assert_no_host_identity('\n'.join(line[1:] for line in diff.splitlines() if line.startswith('+') and not line.startswith('+++')))
independent=json.loads((out/'independent-statistics.json').read_text())
assert hashlib.sha256((out/'perf-baseline-2026-09-27.json').read_bytes()).hexdigest()==independent['baselineSHA256']
print('PASS:',len(manifest['files']),'stored/uncompressed/original files; 22 fixed-source inputs; data/log/privacy and README checks; independent baseline SHA.')
