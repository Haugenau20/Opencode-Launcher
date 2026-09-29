import http.server
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Squid's real configuration/image is tested separately. This tiny proxy makes
# engine network-path tests deterministic without relying on external websites.
files = list(Path('/etc/squid/extra-allowlist.d').glob('*.conf'))
assert files, 'allowlist directory was not mounted correctly'
for file in files:
    file.read_text()


class Proxy(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        target = urllib.parse.urlsplit(self.path)
        if target.hostname != 'origin' or target.port != 8080:
            self.send_error(403)
            return
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(self.path, timeout=3) as response:
                body = response.read()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body)
        except (OSError, urllib.error.URLError):
            self.send_error(502)


http.server.ThreadingHTTPServer(('0.0.0.0', 3128), Proxy).serve_forever()
