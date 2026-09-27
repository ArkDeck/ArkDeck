"""Archive a completed attempt without changing any measured input or raw byte."""
import gzip,hashlib,json,pathlib,shutil,tarfile
root=pathlib.Path(__file__).resolve().parent
dest=pathlib.Path('/private/tmp/arkdeck-xpa025-artifact-performance/openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-025/cached-runtime-capture-20260927')
assert (root/'baseline/exit.json').exists(), 'capture must exit before archiving'
dest.mkdir(exist_ok=True)
files={}
def save(source,relative):
 raw=source.read_bytes(); target=dest/relative
 target.parent.mkdir(parents=True,exist_ok=True)
 if target.suffix=='.gz':target.write_bytes(gzip.compress(raw,mtime=0))
 else:target.write_bytes(raw)
 stored=target.read_bytes(); files[relative]={'source':str(source.relative_to(root)),'uncompressedBytes':len(raw),'uncompressedSha256':hashlib.sha256(raw).hexdigest(),'storedBytes':len(stored),'storedSha256':hashlib.sha256(stored).hexdigest()}
for name in ['plan.json','prebuild-admission.json','capture_artifact.py','capture_baseline.py','archive_evidence.py','verify_capture.py','verification.json']:
 save(root/name,name)
save(root/'bin/provenance.json','provenance.json')
for name in ['release-build.log','artifact-128m.log','artifact-1g.log','baseline.log','verification.log','sdd.log']:
 save(root/name,name+'.gz')
for label in ['artifact-128m','artifact-1g','baseline']:
 for p in sorted((root/label).iterdir()):
  if p.is_file():save(p,label+'/'+p.name+('.gz' if p.suffix=='.jsonl' else ''))
with tarfile.open(root/'instrument-source.tar','w') as archive:
 for p in sorted((root/'source').rglob('*')):
  if p.is_file() and '__pycache__' not in p.parts:archive.add(p,arcname=str(p.relative_to(root/'source')))
save(root/'instrument-source.tar','instrument-source.tar.gz')
(dest/'files.json').write_text(json.dumps({'sourceCommit':'4c3ed7491a96921a5a48f908f168cd27438e1064','files':files},indent=2)+'\n')
print('archived',len(files),'files')
