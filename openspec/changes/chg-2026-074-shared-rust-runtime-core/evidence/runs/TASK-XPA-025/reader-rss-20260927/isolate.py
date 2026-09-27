import base64,ctypes,hashlib,json,os,subprocess,sys,tracemalloc
sys.path.insert(0,sys.argv[1])
from bench import artifact,control
mode=sys.argv[2];PAGE=4*1024*1024;COUNT=12
raw=b'x'*PAGE;text=base64.b64encode(raw).decode('ascii')
page={'artifactId':'ART-test','artifactDigest':hashlib.sha256(raw).hexdigest(),'offset':0,'nextOffset':PAGE,'totalByteCount':PAGE,'eof':True,'byteCount':PAGE,'base64':text}
wire=json.dumps({'id':'test','ok':True,'result':page}).encode()+b'\n'
receipt={'artifactId':page['artifactId'],'artifactDigest':page['artifactDigest']}
class Stats(ctypes.Structure):_fields_=[('blocks',ctypes.c_uint),('inUse',ctypes.c_size_t),('maxInUse',ctypes.c_size_t),('reserved',ctypes.c_size_t)]
lib=ctypes.CDLL(None);lib.malloc_zone_statistics.argtypes=[ctypes.c_void_p,ctypes.POINTER(Stats)];lib.malloc_zone_statistics.restype=None
rows=[]
def point(i):
 st=Stats();lib.malloc_zone_statistics(None,ctypes.byref(st));live,peak=tracemalloc.get_traced_memory();rss=int(subprocess.check_output(['ps','-o','rss=','-p',str(os.getpid())],text=True))*1024
 rows.append(dict(iteration=i,rss=rss,live=live,peak=peak,mallocInUse=st.inUse,mallocReserved=st.reserved))
def unique(pairs):
 out={}
 for k,v in pairs:
  if k in out:raise ValueError('duplicate')
  out[k]=v
 return out
tracemalloc.start();point(-1)
for i in range(COUNT):
 if mode=='receive':
  result=bytearray()
  for offset in range(0,len(wire),65536):result.extend(wire[offset:offset+65536])
 elif mode=='receive-fixed':
  result=bytearray(control.MAXIMUM_RESPONSE_BYTES)
  for offset in range(0,len(wire),65536):
   chunk=wire[offset:offset+65536];result[offset:offset+len(chunk)]=chunk
 elif mode=='b64encode-chunks':
  view=memoryview(raw)
  for offset in range(0,len(raw),48*1024):
   result=base64.b64encode(view[offset:offset+48*1024]).decode('ascii')
   assert result==text[offset//3*4:offset//3*4+len(result)]
 elif mode=='json':result=json.loads(wire,object_pairs_hook=unique)
 elif mode=='validate':result=artifact.validate_page(page,receipt,0,PAGE)
 elif mode=='b64decode':result=base64.b64decode(text,validate=True)
 elif mode=='b64encode':result=base64.b64encode(raw).decode('ascii')
 elif mode=='ascii':result=text.encode('ascii')
 else:raise ValueError(mode)
 del result;point(i)
print(json.dumps({'mode':mode,'count':COUNT,'pageBytes':PAGE,'diagnosticOnly':True,'rows':rows},indent=2))
