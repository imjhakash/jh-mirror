"""A real RFC6455 loopback server exercises OBS auth and the app's camera session lifecycle."""
from pathlib import Path
import base64, hashlib, json, os, socket, struct, subprocess, tempfile, threading, time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
calls, errors, sessions = [], [], []
state = {'scene': 'User Scene', 'virtual': False, 'source': None}
salt, challenge = 'test-salt', 'test-challenge'
secret = base64.b64encode(hashlib.sha256(('test-password' + salt).encode()).digest()).decode()
authentication = base64.b64encode(hashlib.sha256((secret + challenge).encode()).digest()).decode()

def exact(conn, count):
    data = b''
    while len(data) < count:
        block = conn.recv(count - len(data))
        if not block: raise EOFError()
        data += block
    return data

def send(conn, value):
    data = json.dumps(value).encode()
    length = bytes([len(data)]) if len(data) < 126 else b'\x7e' + struct.pack('!H', len(data))
    conn.sendall(b'\x81' + length + data)

def receive(conn):
    first, second = exact(conn, 2)
    if first & 15 == 8: raise EOFError()
    length = second & 127
    if length == 126: length = struct.unpack('!H', exact(conn, 2))[0]
    if length == 127: length = struct.unpack('!Q', exact(conn, 8))[0]
    if length > 100000: raise AssertionError('oversized frame')
    mask = exact(conn, 4) if second & 128 else None
    data = exact(conn, length)
    if mask: data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
    return json.loads(data)

def connection(conn):
    try:
        conn.settimeout(15)
        header = b''
        while b'\r\n\r\n' not in header: header += exact(conn, 1)
        fields = dict(line.split(': ', 1) for line in header.decode().split('\r\n')[1:] if ': ' in line)
        key = next(value for name, value in fields.items() if name.lower() == 'sec-websocket-key')
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        conn.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
        send(conn, {'op': 0, 'd': {'rpcVersion': 1, 'authentication': {'salt': salt, 'challenge': challenge}}})
        identify = receive(conn)
        assert identify['d']['authentication'] == authentication, 'OBS challenge authentication'
        send(conn, {'op': 2, 'd': {'negotiatedRpcVersion': 1}})
        while True:
            message = receive(conn); request = message['d']; kind = request['requestType']; data = request.get('requestData', {})
            calls.append((kind, data)); response = {}; ok = True
            if kind == 'GetVersion': response = {'obsVersion': 'test'}
            elif kind in ('GetStreamStatus', 'GetRecordStatus'): response = {'outputActive': False}
            elif kind == 'GetVirtualCamStatus': response = {'outputActive': state['virtual']}
            elif kind == 'GetCurrentProgramScene': response = {'currentProgramSceneName': state['scene']}
            elif kind == 'CreateScene': time.sleep(.06); sessions.append(data['sceneName'])
            elif kind == 'CreateInput':
                path = data['inputSettings']['input']; assert os.stat(path).st_mode & 0o777 == 0o600
                assert os.stat(os.path.dirname(path)).st_mode & 0o777 == 0o700
                state['source'] = data['inputName']
                # Read from the real FIFO. The helper fixture writes its first bytes only after OBS is ready.
                def consume(path=path):
                    with open(path, 'rb') as stream: assert stream.read() == b'camera-stream'
                threading.Thread(target=consume, daemon=True).start()
            elif kind == 'GetSceneItemId': response = {'sceneItemId': 1}
            elif kind == 'GetVideoSettings': response = {'baseWidth': 1920, 'baseHeight': 1080}
            elif kind == 'SetCurrentProgramScene': state['scene'] = data['sceneName']
            elif kind == 'StartVirtualCam': state['virtual'] = True
            elif kind == 'StopVirtualCam': state['virtual'] = False
            elif kind == 'GetMediaInputStatus': response = {'mediaState': 'OBS_MEDIA_STATE_PLAYING'}
            elif kind == 'UnsupportedRequest': ok = False
            send(conn, {'op': 5, 'd': {'eventType': 'IgnoredEvent'}})
            send(conn, {'op': 7, 'd': {'requestId': request['requestId'], 'requestStatus': {'result': ok, 'code': 100 if ok else 204}, 'responseData': response}})
    except (EOFError, ConnectionResetError, BrokenPipeError): pass
    except BaseException as error: errors.append(repr(error))
    finally: conn.close()

with tempfile.TemporaryDirectory(prefix='jh-calls-') as folder:
    folder = Path(folder); executable = folder/'tests'; helper = folder/'helper'
    helper.write_text('''#!/usr/bin/python3
import os, sys, time
if os.environ.get('JH_CAMERA_DEVICE_UID'):
    assert '--no-window' in sys.argv and not any(arg.startswith('--record=') for arg in sys.argv)
    if 'crash' in sys.argv: sys.exit(1)
    for _ in range(100):
        print('AW_CAMERA_FRAME', flush=True)
        time.sleep(.2)
    sys.exit(0)
path = next(arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--record='))
with open(path, 'wb', buffering=0) as stream: stream.write(b'camera-stream')
time.sleep(30)
'''); helper.chmod(0o700)
    subprocess.run(['swiftc', *(str(ROOT/name) for name in ['PhoneCalls.swift', 'OBSConnection.swift', 'MenuBarPopover.swift', 'PhoneTools.swift']),
        str(HERE/'main.swift'), '-module-cache-path', '/private/tmp/jh-mirror-swift-cache', '-o', str(executable)], check=True)
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen()
    def serve():
        while True:
            try: conn, _ = listener.accept()
            except OSError: return
            threading.Thread(target=connection, args=(conn,), daemon=True).start()
    threading.Thread(target=serve, daemon=True).start()
    result = subprocess.run([str(executable), str(listener.getsockname()[1]), str(helper)], timeout=45)
    listener.close()
    if result.returncode:
        print('OBS requests:', calls, 'server errors:', errors)
        result.check_returncode()
    assert not errors, errors
    assert not state['virtual'] and state['scene'] == 'User Scene', state
    removed = [data['sceneName'] for kind, data in calls if kind == 'RemoveScene']
    assert set(sessions) == set(removed), 'only owned scenes restored and removed'
    assert any(kind == 'SetInputMute' and data['inputMuted'] for kind, data in calls), 'OBS never plays phone mic'
    print('PASS: private FIFO permissions, streamed bytes, OBS state restoration, temporary scene cleanup.')
