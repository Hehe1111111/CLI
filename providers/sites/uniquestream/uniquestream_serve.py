import sys, re, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse
from socketserver import ThreadingMixIn
try:
    import requests
    from requests.adapters import HTTPAdapter
except ImportError:
    requests = None

# UniqueStream HLS proxy.
# Key insight (verified 2026-07-26): the AES-128 HLS key is the media_id
# embedded in the playlist URL, hex-decoded to 16 bytes. No CDN key fetch
# needed. Segments are served as .png on the CDN; renamed to .ts here.
# Perf: segments go through a keep-alive session when 'requests' is
# installed. Without it each PTS-sized .ts was a fresh TLS handshake
# (~300ms each on busy links).

url_file = sys.argv[1]
with open(url_file) as f:
    lines = f.read().splitlines()
master_url = lines[0].strip()
quality = lines[1].strip() if len(lines) > 1 else ""

parsed = urlparse(master_url)
CDN = f"{parsed.scheme}://{parsed.netloc}"
BASE = parsed.path.rsplit("/", 1)[0]
QS = parsed.query

m = re.search(r"/([a-f0-9]{32})_[^/]+/", master_url)
if not m:
    sys.stderr.write("fatal: media_id not found in playlist URL\n")
    sys.exit(1)
KEY = bytes.fromhex(m.group(1))

HDRS = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"}
cache = {}

_session = None
if requests is not None:
    _session = requests.Session()
    _session.headers.update(HDRS)
    _adapter = HTTPAdapter(pool_connections=4, pool_maxsize=16, max_retries=1)
    _session.mount("https://", _adapter)
    _session.mount("http://", _adapter)

_seg_lock = threading.Lock()

def cdn_get(path_qs):
    if _session is not None:
        r = _session.get(f"{CDN}{path_qs}", timeout=15)
        r.raise_for_status()
        return r.content
    import urllib.request
    req = urllib.request.Request(f"{CDN}{path_qs}", headers=HDRS)
    return urllib.request.urlopen(req, timeout=15).read()

def get_master():
    if "master" not in cache:
        text = cdn_get(f"{BASE}/master.m3u8?{QS}").decode().replace("\r\n", "\n")
        lines = text.splitlines()

        # Keep only the closest variant to the requested quality (fallback: nearest).
        variants = []  # (line_index, height)
        for i, ln in enumerate(lines):
            if ln.startswith("#EXT-X-STREAM-INF"):
                rm = re.search(r"RESOLUTION=\d+x(\d+)", ln)
                variants.append((i, int(rm.group(1)) if rm else 0))
        drop = set()
        if quality and variants:
            try:
                tq = int(quality)
            except ValueError:
                tq = 1080
            best = min(variants, key=lambda v: abs(v[1] - tq))[0]
            for i, _ in variants:
                if i != best:
                    drop.add(i)      # #EXT-X-STREAM-INF line
                    drop.add(i + 1)  # its URI line

        out = []
        for i, ln in enumerate(lines):
            if i in drop:
                continue
            if ln.startswith("#EXT-X-MEDIA") and 'URI="' in ln:
                # Keep audio/subtitle renditions; proxy their playlists locally.
                ln = re.sub(r'URI="([^"]+)"', lambda mm: f'URI="/{mm.group(1)}"', ln)
            elif ln and not ln.startswith("#"):
                ln = "/" + ln  # variant playlist URI -> local path
            out.append(ln)
        cache["master"] = "\n".join(out).encode()
    return cache["master"]

def get_playlist(path_qs):
    # path_qs e.g. /v_1920x1080/playlist.m3u8?expires=...&sign=...
    if path_qs not in cache:
        text = cdn_get(f"{BASE}{path_qs}").decode().replace("\r\n", "\n")
        vdir = path_qs.split("/")[1]
        qs = path_qs.split("?", 1)[1] if "?" in path_qs else ""
        out = []
        for ln in text.splitlines():
            if ln.startswith("#EXT-X-KEY"):
                ln = re.sub(r'URI="[^"]+"', 'URI="/key.bin"', ln)
            elif ln and not ln.startswith("#"):
                seg = ln.split("?")[0].replace(".png", ".ts")
                ln = f"/{vdir}/{seg}?{qs}" if qs else f"/{vdir}/{seg}"
            out.append(ln)
        cache[path_qs] = "\n".join(out).encode()
    return cache[path_qs]

class H(BaseHTTPRequestHandler):
    def do_HEAD(self):
        # Headers only — a HEAD must never pull a whole segment from the CDN.
        # Playlists/key are tiny, so serving their (cached) bodies' metadata
        # is fine; for segments we answer from the path alone.
        try:
            p = self.path.split("?")[0]
            if p == "/master.m3u8":
                self._serve(200, "application/vnd.apple.mpegurl", get_master())
            elif p.endswith("/playlist.m3u8"):
                self._serve(200, "application/vnd.apple.mpegurl", get_playlist(self.path))
            elif p == "/key.bin":
                self._serve(200, "application/octet-stream", KEY)
            elif p.endswith(".ts"):
                self.send_response(200)
                self.send_header("Content-Type", "video/mp2t")
                self.end_headers()
            else:
                self._serve(404, "text/plain", b"not found")
        except Exception:
            try:
                self._serve(502, "text/plain", b"")
            except Exception:
                pass

    def do_GET(self):
        try:
            p = self.path.split("?")[0]
            if p == "/master.m3u8":
                self._serve(200, "application/vnd.apple.mpegurl", get_master())
            elif p.endswith("/playlist.m3u8"):
                self._serve(200, "application/vnd.apple.mpegurl", get_playlist(self.path))
            elif p == "/key.bin":
                self._serve(200, "application/octet-stream", KEY)
            elif p.endswith(".ts"):
                seg = p.replace(".ts", ".png")
                qs = self.path.split("?", 1)[1] if "?" in self.path else ""
                data = cdn_get(f"{BASE}{seg}?{qs}" if qs else f"{BASE}{seg}")
                self._serve(200, "video/mp2t", data)
            else:
                self._serve(404, "text/plain", b"not found")
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            try:
                self._serve(502, "text/plain", str(e).encode())
            except Exception:
                pass

    def _serve(self, code, ctype, data):
        if isinstance(data, str):
            data = data.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass

class T(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

server = T(("127.0.0.1", 0), H)
print(f"http://127.0.0.1:{server.server_port}/master.m3u8", flush=True)
server.serve_forever()
