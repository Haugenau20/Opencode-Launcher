import http.server
import os
import threading
from pathlib import Path

Path('/workspace/fixture-writable').write_text('workspace writable\n')
Path('/home/dev/.local/share/opencode/fixture-ready').write_text(str(os.getuid()))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f'app uid={os.getuid()} gid={os.getgid()}\n'.encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)


ports = [int(os.environ['OPENCODE_INTERNAL_PORT']), int(os.environ['PTY_WEB_PORT'])]
for port in ports:
    server = http.server.ThreadingHTTPServer(('0.0.0.0', port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait()
