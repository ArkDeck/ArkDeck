import base64,ctypes,gc,hashlib,json,os,pathlib,subprocess,sys,tracemalloc
sys.path.insert(0,sys.argv[1])
from bench import artifact,control
PAGE=4*1024*1024;PAGES=12;TOTAL=PAGE*PAGES
encoded=base64.b64encode(b'x'*PAGE)
hash_=hashlib.sha256()
for _ in range(PAGES):hash_.update(b'x'*PAGE)
DIGEST=hash_.hexdigest()
class Stats(ctypes.Structure):
 _fields_=[('blocks',ctypes.c_uint),('inUse',ctypes.c_size_t),('maxInUse',ctypes.c_size_t),('reserved',ctypes.c_size_t)]
lib=ctypes.CDLL(None);lib.malloc_zone_statistics.argtypes=[ctypes.c_void_p,ctypes.POINTER(Stats)];lib.malloc_zone_statistics.restype=None
rows=[]
def point(stage):
 stats=Stats();lib.malloc_zone_statistics(None,ctypes.byref(stats))
 current,peak=tracemalloc.get_traced_memory()
 rss=int(subprocess.check_output(['ps','-o','rss=','-p',str(os.getpid())],text=True))*1024
 rows.append(dict(stage=stage,live=current,peak=peak,rss=rss,malloc={n:getattr(stats,n) for n,_ in Stats._fields_},gcCount=gc.get_count()))
class Socket:
 def sendall(self,wire):
  request=json.loads(wire);offset=request['params']['offset']
  page={'artifactId':'ART-test','artifactDigest':DIGEST,'offset':offset,'nextOffset':offset+PAGE,'totalByteCount':TOTAL,'eof':offset+PAGE==TOTAL,'byteCount':PAGE,'base64':'TOKEN'}
  before,after=json.dumps({'id':request['id'],'ok':True,'result':page}).encode().split(b'TOKEN')
  self.parts=[before,encoded,after+b'\n'];self.part=0;self.offset=0
 def recv(self,n):
  p=self.parts[self.part];b=p[self.offset:self.offset+n];self.offset+=len(b)
  if self.offset==len(p):self.offset=0;self.part+=1
  return b
 def settimeout(self,_):pass
 def close(self):pass
class Client(control.ControlClient):
 def __enter__(self):self._socket=Socket();self._verified=True;return self
 def call(self,*a,**k):
  result=super().call(*a,**k);point('after-exchange');return result
class Runtime:
 process=type('Process',(),{'pid':os.getpid()})()
 def client(self):return Client('/fake')
validate=artifact.validate_page
def observed(*a,**k):
 result=validate(*a,**k);point('after-base64');return result
artifact.validate_page=observed
receipt={'owner':{'kind':'import','id':'imp-test'},'artifactId':'ART-test','artifactDigest':DIGEST}
tracemalloc.start();point('before')
result=artifact.read_all(Runtime(),receipt,TOTAL,lambda row:None);assert result[1]['payloadBytes']==TOTAL
point('after-read')
snapshot=tracemalloc.take_snapshot()
print(json.dumps({'python':sys.version,'pageBytes':PAGE,'pageCount':PAGES,'diagnosticOnly':True,'rows':rows,'topLive':[str(s) for s in snapshot.statistics('lineno')[:15]],'sampledRss':result[1]['rssSummary']},indent=2))
