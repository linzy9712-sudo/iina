"""Exercise the built app against a loopback Jellyfin fixture, with isolated NAS data.
Creates and deletes one synthetic Keychain entry trusted only by the supplied app.
"""
import base64, http.server, json, os, pathlib, socket, subprocess, sys, tempfile, threading, time, uuid
app = pathlib.Path(sys.argv[1]).resolve()
binary = app/'Contents/MacOS/IINA'
with tempfile.TemporaryDirectory(prefix='iina-app-test-') as temp:
    root = pathlib.Path(temp)
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=black:s=160x90:r=10','-t','4','-c:v','libx264','-g','10','-pix_fmt','yuv420p',str(root/'clip.mp4')],check=True)
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-i',str(root/'clip.mp4'),'-c','copy','-hls_time','1','-hls_list_size','0',str(root/'master.m3u8')],check=True)
    events=[]; denied=[]; reads=[]
    class Fixture(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def respond(self,data,status=200,mime='application/json'):
            self.send_response(status);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        def authorized(self):
            if self.headers.get('X-Emby-Token') != 'iina-synthetic-test-token':
                denied.append(self.path);self.respond(b'{}',401);return False
            return True
        def do_GET(self):
            if not self.authorized():return
            if '/Users/' in self.path:
                self.respond(b'{"UserData":{"PlaybackPositionTicks":0}}');return
            path=self.path.split('?')[0].split('/')[-1]
            file=root/path
            if path in ['master.m3u8','clip.mp4'] or (path.startswith('master') and path.endswith('.ts')):
                reads.append(path);self.respond(file.read_bytes(),mime='application/vnd.apple.mpegurl' if path.endswith('m3u8') else 'video/mp2t');return
            self.respond(b'{}',404)
        def do_POST(self):
            if not self.authorized():return
            body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}')
            if self.path.endswith('/PlaybackInfo'):
                self.respond(json.dumps({'PlaySessionId':'test-session','MediaSources':[{'Id':'source','SupportsDirectPlay':False,'SupportsTranscoding':True,'TranscodingUrl':'Videos/abc123/master.m3u8','MediaStreams':[]}]}).encode())
            else:
                events.append((self.path,body));self.respond(b'',204)
        def do_DELETE(self):
            if not self.authorized():return
            events.append((self.path,{}));self.respond(b'',204)
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    server_uuid=str(uuid.uuid4()).upper(); account=server_uuid+':mock-server:mock-user'
    config={'version':1,'deviceID':'fixture-device','servers':[{'id':server_uuid,'name':'Isolated test server','baseURL':f'http://127.0.0.1:{server.server_port}/','serverID':'mock-server','userID':'mock-user','username':'fixture'}],'mappings':[]}
    (root/'configuration.json').write_text(json.dumps(config))
    entry={'id':str(uuid.uuid4()),'title':'Isolated Jellyfin HLS test','server':server_uuid,'serverID':'mock-server','itemID':'abc123','sourceID':'source'}
    uri='iina-jellyfin://media/'+base64.urlsafe_b64encode(json.dumps(entry).encode()).decode().rstrip('=')
    subprocess.run(['security','add-generic-password','-s','IINA Jellyfin','-a',account,'-w','iina-synthetic-test-token','-T',str(binary)],check=True,stdout=subprocess.DEVNULL)
    process=None;ipc=None
    try:
        # UNIX sockets have a short pathname limit on macOS.
        ipc=pathlib.Path('/tmp')/('iina-check-'+uuid.uuid4().hex[:8]+'.sock')
        env=os.environ.copy();env['IINA_NAS_TEST_DATA']=temp
        with (root/'app-output.log').open('wb') as log:
            process=subprocess.Popen(['open','-W','-n',str(app),'--env','IINA_NAS_TEST_DATA='+temp,'-o',str(root/'app-output.log'),'--stderr',str(root/'app-output.log'),'--args','--mpv-input-ipc-server='+str(ipc),uri],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            print('Test process:', process.pid, 'log:', str(root/'app-output.log'), flush=True)
            deadline=time.monotonic()+35
            played=False
            configured=False
            while time.monotonic()<deadline:
                if any(path.endswith('/Playing') for path,_ in events):played=True
                if played and not configured:
                    # Scope playback settings to this fixture process, without changing preferences.
                    with socket.socket(socket.AF_UNIX) as control:
                        control.settimeout(2); control.connect(str(ipc))
                        replies=control.makefile('r')
                        for key,value in [('loop-file','no'),('loop-playlist','no'),('keep-open','no'),('pause',False)]:
                            control.sendall((json.dumps({'command':['set_property',key,value],'request_id':2})+'\n').encode())
                            while True:
                                reply=json.loads(replies.readline())
                                if reply.get('request_id')==2:
                                    assert reply.get('error')=='success', (key,reply)
                                    break
                    configured=True
                if played and any('/ActiveEncodings' in path for path,_ in events):break
                if process.poll() is not None:raise RuntimeError('Application exited before playback completed')
                time.sleep(.1)
            if not played:
                print('Fixture requests:', reads, 'events:', [p for p,_ in events], 'denied:', denied)
                try:
                    sock=socket.socket(socket.AF_UNIX);sock.settimeout(2);sock.connect(str(ipc)); stream=sock.makefile('r')
                    for key in ['path','stream-open-filename','idle-active','playlist-count','user-data/iina-nas-status','user-data/iina-nas-installed','user-data/iina-nas-hook','user-data/iina-nas-entry-valid']:
                        sock.sendall((json.dumps({'command':['get_property',key],'request_id':1})+'\n').encode())
                        while True:
                            response=json.loads(stream.readline())
                            if response.get('request_id')==1:print(key,response);break
                    sock.close()
                except Exception as error: print('IPC diagnostic:',type(error).__name__)
            assert played, 'No playback-start report from app' 
            assert any(path.endswith('/Stopped') for path,_ in events), 'No playback-stop report'
            assert any('/ActiveEncodings' in path and 'PlaySessionId=test-session' in path for path,_ in events), 'Missing session-specific cleanup'
            assert 'master.m3u8' in reads and any(path.endswith('.ts') for path in reads), 'HLS was not consumed'
            assert not denied, 'A stream or API request lacked authentication'
            assert all(body.get('ItemId')=='abc123' for path,body in events if body), 'Session identity mismatch'
            assert 'iina-synthetic-test-token' not in (root/'app-output.log').read_text(errors='replace'), 'Credential leaked into app output'
            print('PASS: built IINA → Keychain → PlaybackInfo → authenticated HLS → start/stop reports → scoped transcode cleanup')
    finally:
        if process and process.poll() is None:
            try:
                sock=socket.socket(socket.AF_UNIX);sock.settimeout(2);sock.connect(str(ipc));sock.sendall(b'{"command":["quit"]}\n');sock.close();process.wait(timeout=5)
            except Exception:
                # Only terminate the fixture instance, identified by its unique IPC argument.
                import signal
                for line in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines():
                    pieces=line.strip().split(None,1)
                    if len(pieces)==2 and pieces[1].startswith(str(binary)+' ') and str(ipc) in pieces[1]:
                        os.kill(int(pieces[0]),signal.SIGTERM)
                process.terminate();process.wait(timeout=5)
        subprocess.run(['security','delete-generic-password','-s','IINA Jellyfin','-a',account],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        server.shutdown()
        if ipc:ipc.unlink(missing_ok=True)
