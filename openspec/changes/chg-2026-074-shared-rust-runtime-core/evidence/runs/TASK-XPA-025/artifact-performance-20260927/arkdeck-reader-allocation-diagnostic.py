import sys,pathlib,base64,json,tracemalloc,gc
sys.path.insert(0,sys.argv[1])
from bench.control import ControlClient
class Socket:
 def __init__(self,wire):self.wire=wire;self.offset=0
 def sendall(self,_):self.offset=0
 def recv(self,n):
  b=self.wire[self.offset:self.offset+n];self.offset+=len(b);return b
 def settimeout(self,_):pass
 def close(self):pass
wire=json.dumps({'id':'test','ok':True,'result':{'data':base64.b64encode(b'x'*8192).decode()}}).encode()+b'\n'
client=ControlClient('/fake');client._socket=Socket(wire);client.configure_measurement(None,capture_failure=True)
tracemalloc.start(); before=tracemalloc.take_snapshot()
for i in range(64):
 response=client._exchange({'id':'test'});assert len(response['result']['data'])==10924;del response
 if i in (0,15,31,63):print(json.dumps({'pages':i+1,'traced':tracemalloc.get_traced_memory(),'gcCount':gc.get_count()}))
after=tracemalloc.take_snapshot()
for stat in after.compare_to(before,'lineno')[:12]:print(stat)
# No gc.collect(): inspect actually retained frames and referrers while present.
frames=[obj for obj in gc.get_objects() if type(obj).__name__=='frame' and obj.f_code.co_filename.endswith('control.py')]
print('retainedFrames',[(frame.f_code.co_name,frame.f_lineno) for frame in frames[:10]],'count',len(frames))
for frame in frames[:1]:
 print('frameLocals',[(key,type(value).__name__,len(value) if isinstance(value,(bytes,bytearray,str)) else None) for key,value in frame.f_locals.items()])
 print('frameReferrerTypes',[type(value).__name__ for value in gc.get_referrers(frame)])
