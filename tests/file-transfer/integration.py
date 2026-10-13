import hashlib, http.server, json, pathlib, subprocess, tempfile, threading, urllib.parse, uuid
ROOT = pathlib.Path(__file__).resolve().parents[2]
EXE = pathlib.Path('/private/tmp/android-wireless-file-tests')
subprocess.run(['swiftc', str(ROOT/'FileTransferClient.swift'), str(ROOT/'WifiConnection.swift'), str(ROOT/'PairPhone.swift'), str(ROOT/'tests/TestSupport.swift'), str(pathlib.Path(__file__).with_name('main.swift')), '-module-cache-path', '/private/tmp/android-wireless-swift-cache', '-o', str(EXE)], check=True)
files = []
for name, data in [('report.txt', b'first file'), ('report.txt', b'second file'), ('../Photo.jpg', bytes(range(256))*10000), ('corruption.bin', bytes(range(256))*9000), ('empty.txt', b'')]:
    files.append(dict(id=str(uuid.uuid4()), name=name, size=len(data), sha256=hashlib.sha256(data).hexdigest(), data=data))
pending = {f['id']:f for f in files}
chunk_requests = []; acks = []; dropped = False; corrupted = False; ack_failed = False
class Server(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def respond(self, status, data):
        self.send_response(status); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        global dropped, corrupted
        if self.headers.get('Authorization') != 'Bearer '+'a'*64: self.respond(401,b''); return
        path = urllib.parse.urlparse(self.path)
        if path.path == '/files':
            self.respond(200, json.dumps({'files':[{k:v for k,v in f.items() if k!='data'} for f in list(pending.values())]}).encode()); return
        fid = path.path.split('/')[-1]; f = pending[fid]
        query = urllib.parse.parse_qs(path.query); offset=int(query['offset'][0]); size=int(query['length'][0]); chunk_requests.append((fid,offset))
        if f['name']=='../Photo.jpg' and offset==1048576 and not dropped:
            dropped=True; self.respond(503,b''); return
        data=f['data'][offset:offset+size]
        if f['name']=='corruption.bin' and offset==0 and not corrupted:
            corrupted=True; data=b'X'+data[1:]
        self.respond(200,data)
    def do_POST(self):
        global ack_failed
        if self.headers.get('Authorization') != 'Bearer '+'a'*64: self.respond(401,b''); return
        path=urllib.parse.urlparse(self.path); fid=path.path.split('/')[2]; f=pending[fid]
        assert urllib.parse.parse_qs(path.query)['sha256'][0]==f['sha256']
        acks.append(fid)
        if f['name']=='report.txt' and not ack_failed:
            ack_failed=True; self.respond(503,b''); return
        del pending[fid]; self.respond(200,b'{"saved":true}')
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Server)
threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory(prefix='wireless-file-tests-') as temp:
    folder=pathlib.Path(temp)/'received'; folder.mkdir(); (folder/'report.txt').write_bytes(b'existing user file')
    result=subprocess.run([str(EXE),str(server.server_port),str(folder),str(len(files))],capture_output=True,text=True,timeout=20)
    if result.returncode: print(result.stdout); print(result.stderr); raise RuntimeError('Client failed')
    assert not pending, 'Phone queue must be ACKed only after verified saves'
    assert (folder/'report.txt').read_bytes()==b'existing user file', 'Existing file was overwritten'
    assert (folder/'report (2).txt').read_bytes()==b'first file'
    assert (folder/'report (3).txt').read_bytes()==b'second file'
    for f in files[2:]:
        path=folder/('_Photo.jpg' if f['name']=='../Photo.jpg' else f['name'])
        assert path.read_bytes()==f['data'], f['name']
    assert not list((folder/'.incoming').glob('*.partial'))
    large=files[2]['id']; corrupt=files[3]['id']; first=files[0]['id']
    assert chunk_requests.count((large,0))==1, 'Reconnect should resume, not start over'
    assert chunk_requests.count((large,1048576))==2, 'Failed chunk must be retried'
    assert chunk_requests.count((corrupt,0))==2, 'Corrupted download must restart'
    assert chunk_requests.count((first,0))==1 and acks.count(first)==2, 'ACK retry must not duplicate download'
    assert len(list(folder.iterdir()))==len(files)+2
server.shutdown()
print('PASS: interrupted transfer resumes; corrupt content restarts; ACK retry is idempotent; original names never overwrite existing files; traversal names are sanitized; zero-byte file saves.')
