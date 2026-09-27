import json, pathlib, sys, traceback
from bench import artifact, clocks
out = pathlib.Path(sys.argv[1]); out.mkdir(exist_ok=False)
with (out/'samples.jsonl').open('x') as stream:
 def record(row):
  stream.write(json.dumps({'utc':clocks.utc_now(),**row},sort_keys=True)+'\n'); stream.flush()
 try:
  elapsed, scale = artifact.measure('/private/tmp/arkdeck-xpa025-pinned-82f0971c/arkdeck-agentd', '/private/tmp/arkdeck-xpa025-journal-target/debug/arkdeck-soak',int(sys.argv[2])*1024*1024,record,False)
  (out/'result.json').write_text(json.dumps({'functionalOnly':True,'baselineEligible':False,'milliseconds':elapsed,'scale':scale},indent=2)+'\n')
 except Exception:
  traceback.print_exc(); raise
