import gzip,hashlib,io,json,pathlib,tarfile
root=pathlib.Path('/private/tmp/xpa025-formal.l1gvx8k4')
out=pathlib.Path('/private/tmp/arkdeck-xpa025-formal-evidence/openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-025/formal-scale-20260927')
out.mkdir(parents=True,exist_ok=True);entries={}
def save(path,name,compress=False):
 raw=path.read_bytes();stored=gzip.compress(raw,mtime=0) if compress else raw;target=out/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(stored)
 entries[name]={'sourcePath':str(path),'uncompressedBytes':len(raw),'uncompressedSha256':hashlib.sha256(raw).hexdigest(),'storedBytes':len(stored),'storedSha256':hashlib.sha256(stored).hexdigest()}
for name in ['plan.json','preflight-quiet.json','attempt.json','exit.json','prepare.py','run.py','verify.py','verification.json']:
 save(root/name,name)
for name in ['stdout.log','stderr.log','verification.log']:save(root/name,name+'.gz',True)
save(root/'files.json','original-files.json')
for path in (root/'evidence').iterdir():save(path,path.name+('.gz' if path.suffix=='.jsonl' else ''),path.suffix=='.jsonl')
for name in ['summary','statistics']:save(pathlib.Path('/private/tmp/arkdeck-formal-independent-'+name+'.json'),'independent-'+name+'.json')
archive=io.BytesIO()
with tarfile.open(fileobj=archive,mode='w') as tar:
 for path in sorted((root/'source').rglob('*')):
  if path.is_file():
   data=path.read_bytes();info=tarfile.TarInfo(str(path.relative_to(root/'source')));info.size=len(data);info.mode=0o644;info.mtime=0;tar.addfile(info,io.BytesIO(data))
(root/'instrument-source.tar').write_bytes(archive.getvalue());save(root/'instrument-source.tar','instrument-source.tar.gz',True)
save(pathlib.Path(__file__),'archive.py')
(out/'files.json').write_text(json.dumps({'toolSource':'2b049c61238165a88edb6f7cd40b67781f46c3af','files':entries},indent=2)+'\n')
print('archived',len(entries),'files')
