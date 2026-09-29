import http.server


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'origin reachable through proxy\n')


http.server.ThreadingHTTPServer(('0.0.0.0', 8080), Origin).serve_forever()
