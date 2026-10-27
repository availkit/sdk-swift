"""Loopback-only HTTP fixture; all capabilities and records are synthetic."""
import http.server,json,os,socket,sys,time
ID='1'*32
START='2026-10-26T10:00:00Z'
PAGE={'id':ID,'title':'Fixture','environment':'test'}
OFFERING={'id':ID,'name':'Meeting','durationMinutes':30,'timeZone':'UTC'}
def booking(status='confirmed',start=START):
 return {'id':ID,'start':start,'end':start.replace('10:00:00','10:30:00').replace('11:00:00','11:30:00'),'status':status,'offering':OFFERING,'page':PAGE,'pageEnabled':True}
class Handler(http.server.BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*_):pass
 def do_GET(self):self.handle_api()
 def do_POST(self):self.handle_api()
 def handle_api(self):
  transfer=self.headers.get('Transfer-Encoding')
  length=self.headers.get('Content-Length')
  if transfer:
   if transfer.lower()!='chunked' or length is not None:raise RuntimeError('conflicting or unsupported request framing')
   chunks=[];size=0
   while True:
    line=self.rfile.readline(128)
    count=int(line.strip().split(b';',1)[0],16)
    if count==0:
     if self.rfile.readline(128)!=b'\r\n':raise RuntimeError('invalid chunk terminator')
     break
    size+=count
    if size>16384:raise RuntimeError('fixture request bound')
    chunks.append(self.rfile.read(count))
    if self.rfile.read(2)!=b'\r\n':raise RuntimeError('invalid chunk framing')
   body=b''.join(chunks)
  else:
   body=self.rfile.read(int(length or '0'))
  if self.command=='POST':json.loads(body) # Every admitted mutation has valid original JSON.
  record={'method':self.command,'path':self.path,'headers':dict(self.headers),'body':body.decode()}
  with open(sys.argv[2],'a') as f:f.write(json.dumps(record)+'\n');f.flush()
  mode=sys.argv[1]
  if mode.startswith('example') and self.command=='POST':
   name='move.json' if self.path.endswith('/reschedule') else 'cancel.json' if self.path.endswith('/cancel') else 'create.json'
   if not os.path.isfile(os.path.join(os.path.dirname(sys.argv[2]),name)):raise RuntimeError('intent missing before admission')
  if mode in ('lost','example-lost') and self.command=='POST' and not self.server.lost:
   self.server.lost=True;self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
  if mode=='slow':time.sleep(.3)
  if mode=='unknowncode':self.respond(400,{'error':{'code':'unrecognized-private-code','message':'PRIVATE-UNTRUSTED-RESPONSE'}});return
  if mode=='baderror':self.respond(400,{'error':{'code':'scope_denied'}});return
  if mode=='forbidden':self.respond(403,{'error':{'code':'scope_denied','message':'PRIVATE-UNTRUSTED-RESPONSE'}});return
  if mode=='redirect':
   self.send_response(302);self.send_header('Location','http://127.0.0.1:9/unexpected');self.send_header('Content-Type','application/json');self.send_header('Content-Length','2');self.end_headers();self.wfile.write(b'{}');return
  if mode=='invalid':self.respond(201,b'{"id":1,"id":2}');return
  if mode=='oversize':self.respond(200,b' '+b' '*5000);return
  if self.path.split('?')[0].endswith('/offerings'):value={'items':[OFFERING],'nextAfter':None}
  elif '/availability' in self.path:value={'slots':[{'start':START,'end':'2026-10-26T10:30:00Z','remainingCapacity':1}]+([{'start':'2026-10-26T11:00:00Z','end':'2026-10-26T11:30:00Z','remainingCapacity':1}] if mode.startswith('example') else [])}
  elif self.path.endswith('/cancel'):value=booking('cancelled',self.server.start)
  elif self.path.endswith('/reschedule'):
   self.server.start=json.loads(body)['start'];value=booking(start=self.server.start)
  elif '/bookings' in self.path:value=booking(start=self.server.start)
  else:value=PAGE
  self.respond(201 if self.command=='POST' and self.path.endswith('/bookings') else 200,value)
 def respond(self,status,value):
  raw=value if isinstance(value,bytes) else json.dumps(value,separators=(',',':')).encode()
  self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(raw)));self.end_headers()
  try:self.wfile.write(raw)
  except(BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True;server.lost=False;server.start=START
print(server.server_address[1],flush=True)
server.serve_forever()
