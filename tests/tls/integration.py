import hashlib, http.server, pathlib, ssl, subprocess, tempfile, threading
ROOT = pathlib.Path(__file__).resolve().parents[2]
EXE = pathlib.Path('/private/tmp/android-wireless-tls-tests')
subprocess.run(['swiftc', str(ROOT/'WifiConnection.swift'), str(ROOT/'PairPhone.swift'), str(ROOT/'tests/TestSupport.swift'), str(pathlib.Path(__file__).with_name('main.swift')), '-module-cache-path','/private/tmp/android-wireless-swift-cache','-o',str(EXE)],check=True)
received=[]; redirected=[]
class Destination(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        redirected.append(self.headers.get('Authorization'));self.send_response(200);self.end_headers()
class Phone(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        received.append(self.headers.get('Authorization'))
        self.send_response(302 if self.path=='/redirect' else 200)
        if self.path=='/redirect': self.send_header('Location',f'http://127.0.0.1:{destination.server_port}/')
        self.end_headers(); self.wfile.write(b'{}')
with tempfile.TemporaryDirectory() as temp:
    temp=pathlib.Path(temp);cert=temp/'cert.pem';key=temp/'key.pem'
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-keyout',str(key),'-out',str(cert),'-days','1','-nodes','-subj','/CN=AndroidWirelessTest'],capture_output=True,check=True)
    der=ssl.PEM_cert_to_DER_cert(cert.read_text());pin=hashlib.sha256(der).hexdigest()
    phone=http.server.ThreadingHTTPServer(('127.0.0.1',0),Phone)
    destination=http.server.ThreadingHTTPServer(('127.0.0.1',0),Destination)
    tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(cert,key);phone.socket=tls.wrap_socket(phone.socket,server_side=True)
    for server in [phone,destination]: threading.Thread(target=server.serve_forever,daemon=True).start()
    base=f'https://127.0.0.1:{phone.server_port}'
    subprocess.run([str(EXE),base+'/health',pin,'accept'],check=True)
    count=len(received)
    subprocess.run([str(EXE),base+'/health','0'*64,'reject'],check=True)
    assert len(received)==count,'Wrong certificate received bearer credential'
    subprocess.run([str(EXE),base+'/redirect',pin,'redirect'],check=True)
    assert not redirected,'Redirect leaked credential to another endpoint'
    phone.shutdown();destination.shutdown()
print('PASS: trusted certificate accepted; unknown certificate rejected before HTTP credentials; redirects cannot leak credentials.')
