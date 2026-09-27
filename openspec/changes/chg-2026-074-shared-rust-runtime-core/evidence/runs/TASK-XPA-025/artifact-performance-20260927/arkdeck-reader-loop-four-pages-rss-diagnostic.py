import sys,base64,json,tracemalloc,gc,hashlib,os
sys.path.insert(0,sys.argv[1])
from bench import artifact,control
CHUNK=4194304;TOTAL=4*CHUNK;DIGEST=hashlib.sha256(b'x'*TOTAL).hexdigest()
class Socket:
 def sendall(self,wire):
  request=json.loads(wire);params=request.get('params',{});offset=params.get('offset',0)
  result={'artifactId':'ART-test','artifactDigest':DIGEST,'offset':offset,'nextOffset':offset+CHUNK,'totalByteCount':TOTAL,'eof':offset+CHUNK==TOTAL,'byteCount':CHUNK,'base64':base64.b64encode(b'x'*CHUNK).decode()}
  self.wire=json.dumps({'id':request['id'],'ok':True,'result':result}).encode()+b'\n';self.offset=0
 def recv(self,n):
  b=self.wire[self.offset:self.offset+n];self.offset+=len(b);return b
 def settimeout(self,_):pass
 def close(self):pass
class Client(control.ControlClient):
 def __enter__(self):self._socket=Socket();self._verified=True;return self
class Runtime:
 process=type('Process',(),{'pid':os.getpid()})()
 def client(self):return Client('/fake')
receipt={'owner':{'kind':'import','id':'imp-test'},'artifactId':'ART-test','artifactDigest':DIGEST}
tracemalloc.start();before=tracemalloc.take_snapshot()
for index in range(1):
 result=artifact.read_all(Runtime(),receipt,TOTAL,lambda row:None)
 assert result[1]['payloadBytes']==TOTAL
 print('loop',index,'traced',tracemalloc.get_traced_memory(),'RSS',result[1]['rssSummary'],'gc',gc.get_count())
import subprocess
print('postReadNativeRssKiB',subprocess.check_output(['ps','-o','rss=','-p',str(os.getpid())],text=True).strip())
after=tracemalloc.take_snapshot()
for stat in after.compare_to(before,'lineno')[:12]:print(stat)
frames=[obj for obj in gc.get_objects() if type(obj).__name__=='frame' and (obj.f_code.co_filename.endswith('control.py') or obj.f_code.co_filename.endswith('artifact.py'))]
print('retainedFrames',[(f.f_code.co_name,f.f_lineno) for f in frames[:8]],'count',len(frames))
