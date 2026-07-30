import socketserver
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

master_path = sys.argv[1]


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/master.m3u8":
            try:
                with open(master_path, "rb") as f:
                    b = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.apple.mpegurl")
                self.send_header("Content-Length", str(len(b)))
                self.send_header("Connection", "keep-alive")
                self.end_headers()
                self.wfile.write(b)
            except Exception:
                self.send_response(500)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


class T(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


server = T(("127.0.0.1", 0), H)
port = server.server_port
print(f"http://127.0.0.1:{port}/master.m3u8", flush=True)
server.serve_forever()
