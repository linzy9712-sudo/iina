"""Native mpv smoke test; requires ffmpeg, clang and a signed development app."""
import http.server, pathlib, subprocess, tempfile, threading, sys
root = pathlib.Path(__file__).resolve().parents[2]
frameworks = pathlib.Path(sys.argv[1]).resolve() / 'Contents/Frameworks'
with tempfile.TemporaryDirectory(prefix='iina-mpv-test-') as temp:
    directory = pathlib.Path(temp)
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=black:s=160x90:r=10','-t','0.8','-c:v','libx264','-pix_fmt','yuv420p',str(directory/'clip.mp4')],check=True)
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-i',str(directory/'clip.mp4'),'-c','copy','-hls_time','0.3','-hls_list_size','0',str(directory/'hls.m3u8')],check=True)
    requests=[]
    class Server(http.server.SimpleHTTPRequestHandler):
        def __init__(self,*args,**kwargs):super().__init__(*args,directory=temp,**kwargs)
        def do_GET(self):
            if self.headers.get('X-Emby-Token') != 'test-token':
                self.send_error(403);return
            requests.append(self.path)
            super().do_GET()
        def log_message(self,*args):pass
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Server)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    binary=directory/'queue-test'
    subprocess.run(['clang',str(root/'Tests/NAS/MPVQueueRegression.c'),'-I',str(root/'deps/include'),'-L',str(frameworks),'-lmpv.2',f'-Wl,-rpath,{frameworks}','-o',str(binary)],check=True)
    try:
        subprocess.run([str(binary),f'http://127.0.0.1:{server.server_port}',str(directory/'clip.mp4')],check=True,timeout=30)
        assert any('.m3u8' in p for p in requests) and any('.ts' in p for p in requests)
        print('PASS: authenticated requests reached both HLS manifest and segments')
    finally:server.shutdown()
