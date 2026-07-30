#!/usr/bin/env python3
"""Torrent streaming engine: buffers a single episode file from a magnet.

stdout: the ready video file path (one line, when buffered)
stderr: "[torrent] ..." progress lines (rendered as one live line by the app)
"""
import warnings
warnings.filterwarnings("ignore", category=DeprecationWarning)
import libtorrent as lt
import time
import sys
import os
import re
import signal
import argparse
import atexit
import shutil
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

running = True
BUFFER_MB = 50
STREAM_DIR = "/tmp/ani-cli_torrent_stream"
os.makedirs(STREAM_DIR, exist_ok=True)
cleanup_dirs = []

# Sweep stale stream dirs from previous runs (crashes / SIGKILL skip the
# atexit cleanup) — streaming is ephemeral, nothing here is worth keeping.
try:
    _now = time.time()
    for _d in os.listdir(STREAM_DIR):
        _p = os.path.join(STREAM_DIR, _d)
        if os.path.isdir(_p) and _now - os.path.getmtime(_p) > 12 * 3600:
            shutil.rmtree(_p, ignore_errors=True)
except OSError:
    pass

DHT_BOOTSTRAP_NODES = [
    ("router.bittorrent.com", 6881),
    ("dht.transmissionbt.com", 6881),
    ("router.utorrent.com", 6881),
    ("dht.libtorrent.org", 25401),
]

FALLBACK_TRACKERS = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.openbittorrent.com:6969/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.dler.org:6969/announce",
    "https://tracker.nanoha.org:443/announce",
]

VIDEO_EXTS = {".mkv", ".mp4", ".m2ts", ".ts", ".webm", ".mov", ".avi", ".flv", ".wmv"}
_EXTRA_WORD_RE = re.compile(
    r"(?i)\b(ova|oad|movie|movies|special|specials|extra|extras|ncop|nced|op\d*|ed\d*|"
    r"creditless|trailer|ost|finale|junior high)\b")

def cleanup():
    for d in cleanup_dirs:
        if os.path.exists(d):
            try:
                shutil.rmtree(d, ignore_errors=True)
            except OSError:
                pass

def signal_handler(signum, frame):
    global running
    running = False

signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)
atexit.register(cleanup)

def log(msg):
    print(f"[torrent] {msg}", file=sys.stderr, flush=True)

# ── Episode file selection (batch-aware) ─────────────────────────

_SXE_RE = re.compile(r"[Ss](\d{1,2})\s*[-._]?\s*[Ee](\d{1,4})")
_SEASON_DIR_RE = re.compile(r"(?:season|s)[\s_.\-]*0*(\d{1,2})(?:\s|$|/|\\)", re.I)
_EP_RE = re.compile(r"(?:^|[\s_\-\[\(])(?:[Ee][Pp]\.?\s?)?0*(\d{1,4})(?:[vV](\d+))?(?=[\s_\-\]\)\.]|$)")
_VERSION_RE = re.compile(r"[vV](\d+)")
_RES_RE = re.compile(r"(\d{3,4})p")

def _path_season(fpath):
    """Season number from directory parts, e.g. 'Season 2/', 'S02/'."""
    for part in fpath.replace("\\", "/").split("/")[:-1]:
        m = _SEASON_DIR_RE.search(part + " ")
        if m:
            return int(m.group(1))
    return None

def _file_ep(fname):
    """(episode, version, sxe_season) from a filename; fields may be None."""
    base = os.path.splitext(os.path.basename(fname))[0]
    m = _SXE_RE.search(base)
    if m:
        return int(m.group(2)), _version(base), int(m.group(1))
    # strip things that look like resolution/year/hash so they aren't
    # mistaken for episode numbers
    work = _RES_RE.sub(" ", base)
    work = re.sub(r"(19|20)\d{2}", " ", work)
    work = re.sub(r"[0-9a-fA-F]{8}", " ", work)
    candidates = []
    for m in _EP_RE.finditer(work):
        n = int(m.group(1))
        if 0 < n <= 2000:
            candidates.append(n)
    if candidates:
        return candidates[-1], _version(base), None
    return None, _version(base), None

def _version(fname):
    m = _VERSION_RE.search(fname)
    return int(m.group(1)) if m else 1

def _is_extra(fpath):
    # Only look below the torrent root dir — batch root names often
    # contain "(S01-S04+OVA+Movies)" which would poison every file.
    parts = fpath.replace("\\", "/").split("/")
    rel = "/".join(parts[1:]) if len(parts) > 1 else parts[0]
    return bool(_EXTRA_WORD_RE.search(rel))

def pick_episode_file(torrent_info, target_ep, target_season=None, abs_ep=None):
    """Return (file_index, rel_path) of the best file for the episode.

    Handles: single-file torrents, per-episode torrents, per-season
    batches ("Show S2 - 01", "Show.S02E01"), and cumulative multi-season
    batches ("Show - 26" for season 2 ep 1 — pass abs_ep=26).
    Extras (movies/OVAs/creditless ops) are avoided.
    """
    fs = torrent_info.files()
    cands = []
    for idx in range(fs.num_files()):
        fpath = fs.file_path(idx)
        fsize = fs.file_size(idx)
        ext = os.path.splitext(fpath)[1].lower()
        try:
            flags = fs.file_flags(idx)
            if flags & lt.file_flags_t.flag_pad_file:
                continue
        except Exception:
            pass
        if ext in VIDEO_EXTS and fsize > 1024 * 1024:
            cands.append((idx, fpath, fsize))
    if not cands:
        return None, None
    if len(cands) == 1:
        return cands[0][0], cands[0][1]

    ep = int(target_ep)
    season = int(target_season) if target_season else None
    target_eps = {ep}
    if abs_ep:
        try:
            a = int(abs_ep)
            if a != ep:
                target_eps.add(a)
        except (TypeError, ValueError):
            pass
    scored = []
    for idx, fpath, fsize in cands:
        fep, fver, sxe_season = _file_ep(fpath)
        fseason = _path_season(fpath)
        if fseason is None:
            fseason = sxe_season
        extra = _is_extra(fpath)
        # hard exclusions
        if fep is not None and fep not in target_eps:
            continue
        if season is not None and fseason is not None and fseason != season:
            continue
        score = 0
        if fep in target_eps:
            score += 100
        if season is not None and fseason == season:
            score += 50
        if extra:
            score -= 200
        score += fver * 5
        scored.append((score, fsize, idx, fpath))
    if not scored:
        # nothing matched cleanly: fall back to a bare-pattern search over
        # every acceptable episode number, then to the largest non-extra video
        for n in sorted(target_eps):
            ep_pat = re.compile(rf"(?:^|\D)(0*{n})(?:\D|$)")
            for idx, fpath, fsize in cands:
                if ep_pat.search(os.path.basename(fpath)) and not _is_extra(fpath):
                    return idx, fpath
        non_extra = [c for c in cands if not _is_extra(c[1])] or cands
        non_extra.sort(key=lambda x: x[2], reverse=True)
        return non_extra[0][0], non_extra[0][1]
    scored.sort(key=lambda x: (x[0], x[1]), reverse=True)
    best = scored[0]
    return best[2], best[3]

# ── mkv layout probing ────────────────────────────────────────────

def _mkv_first_cluster_offset(buf):
    """Offset of the first top-level Cluster element in an mkv/webm, or None.

    Walks top-level EBML element headers (id + vint size) from the Segment
    start. Returns None when the walk reaches the end of `buf` before
    finding a Cluster (caller then downloads more and retries) or when the
    data doesn't look like mkv at all.
    """
    def rd_vint(b, i):
        if i >= len(b):
            return None, 0
        first = b[i]
        mask, l = 0x80, 1
        while l <= 8 and not (first & mask):
            mask >>= 1
            l += 1
        if l > 8 or i + l > len(b):
            return None, 0
        val = first & (mask - 1)
        for j in range(1, l):
            val = (val << 8) | b[i + j]
        if val == (1 << (7 * l)) - 1:
            return -1, l          # unknown size
        return val, l

    seg = buf.find(b"\x18\x53\x80\x67")   # Segment element ID
    if seg < 0:
        return None
    i = seg + 4
    size, l = rd_vint(buf, i)
    if l == 0:
        return None
    i += l
    while i + 2 <= len(buf):
        b0 = buf[i]
        if b0 & 0x80:
            idlen = 1
        elif b0 & 0x40:
            idlen = 2
        elif b0 & 0x20:
            idlen = 3
        elif b0 & 0x10:
            idlen = 4
        else:
            return None                    # not a valid element id → corrupt/hole
        if i + idlen > len(buf):
            return None
        eid = int.from_bytes(buf[i:i + idlen], "big")
        sz, sl = rd_vint(buf, i + idlen)
        if sl == 0:
            return None
        if eid == 0x1F43B675:              # Cluster
            return i
        if sz is None or sz < 0:
            return None                    # unknown-size element before cluster
        nxt = i + idlen + sl + sz
        if nxt + 1 >= len(buf):
            return None                    # next header lives past our data
        i = nxt
    return None

# ── Local HTTP bridge ─────────────────────────────────────────────
# mpv must NEVER read the growing sparse file directly: on a partial file
# it seeks to EOF for the mkv index, its reported duration flaps as data
# arrives, and time-pos becomes garbage (breaking resume points and the
# 80% completion rule). Behind a fixed-length HTTP endpoint the file looks
# complete: positions are accurate, and any range mpv asks for is fetched
# on demand via piece deadlines.

def start_bridge(handle, video_path, f_off, f_size, piece_len):
    def ensure_range(start, end, timeout=120):
        """Block until the torrent pieces covering [start, end) are down."""
        p0 = (f_off + start) // piece_len
        p1 = (f_off + max(start, end - 1)) // piece_len
        deadline = time.time() + timeout
        # First pass: collect missing pieces
        missing = []
        for p in range(p0, p1 + 1):
            if not _have_piece(handle, p):
                missing.append(p)
        if not missing:
            return True
        # Boost priority for all missing pieces at once
        for p in missing:
            try:
                handle.piece_priority(p, 7)
                handle.set_piece_deadline(p, 1000)
            except RuntimeError:
                pass
        # Wait for all missing pieces
        for p in missing:
            while not _have_piece(handle, p):
                if not running or time.time() > deadline:
                    return False
                time.sleep(0.1)
        return True

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_HEAD(self):
            self._serve(head_only=True)

        def do_GET(self):
            self._serve(head_only=False)

        def _serve(self, head_only=False):
            start, end = 0, f_size - 1
            code = 200
            rng = self.headers.get("Range", "")
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                if m.group(2):
                    end = min(end, int(m.group(2)))
                code = 206
            if start > end or start >= f_size:
                self.send_error(416)
                return
            length = end - start + 1
            try:
                self.send_response(code)
                self.send_header("Content-Type", "video/x-matroska")
                self.send_header("Content-Length", str(length))
                self.send_header("Accept-Ranges", "bytes")
                if code == 206:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{f_size}")
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError):
                return
            if head_only:
                return   # HEAD: headers only — NEVER wait for data
            # Stream progressively: ensure data CHUNK BY CHUNK. Ensuring the
            # whole requested range up front would block mpv's open phase
            # for the entire file when it sends a plain sequential GET.
            try:
                with open(video_path, "rb") as vf:
                    vf.seek(start)
                    remaining = length
                    while remaining > 0 and running:
                        pos = vf.tell()
                        want = min(512 * 1024, remaining)
                        if not ensure_range(pos, pos + want, timeout=120):
                            return   # stall: drop the connection, mpv retries
                        chunk = vf.read(want)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1]

def _have_piece(handle, p):
    try:
        return handle.have_piece(p)
    except RuntimeError:
        return False

# ── Streaming ─────────────────────────────────────────────────────

def stream_torrent(magnet_or_path, buffer_mb=50, episode=1, season=None, abs_ep=None, resume_frac=None):
    global running

    ses = lt.session()

    for node in DHT_BOOTSTRAP_NODES:
        try:
            ses.add_dht_node(node)
        except RuntimeError:
            pass

    s = ses.get_settings()
    s["active_downloads"] = 3
    s["connections_limit"] = 500
    s["download_rate_limit"] = 0
    s["upload_rate_limit"] = 0
    s["max_queued_disk_bytes"] = 64 * 1024 * 1024
    s["aio_threads"] = 8
    s["mixed_mode_algorithm"] = 1
    s["enable_dht"] = True
    s["enable_lsd"] = True
    s["dht_announce_interval"] = 30
    ses.apply_settings(s)

    save_path = os.path.join(STREAM_DIR, f"stream_{int(time.time())}")
    os.makedirs(save_path, exist_ok=True)
    cleanup_dirs.append(save_path)

    if magnet_or_path.startswith("magnet:"):
        params = lt.parse_magnet_uri(magnet_or_path)
    else:
        params = lt.add_torrent_params()
        params.ti = lt.torrent_info(magnet_or_path)

    params.save_path = save_path
    # NOTE: sequential_download is deliberately NOT set at add time. In
    # sequential mode the picker requests pieces strictly in order and
    # effectively ignores priority/deadline hints, so the mkv tail (cues +
    # font attachments mpv needs before it will play) arrived only after
    # hundreds of MB. Phase 1 = priority mode (head+tail first); phase 2
    # flips sequential on once playback starts (see below).
    params.flags = params.flags & ~lt.torrent_flags.paused

    handle = ses.add_torrent(params)

    # Add fallback trackers immediately — magnets often carry few or no
    # trackers, and more trackers = faster peer discovery = faster buffer.
    for trk in FALLBACK_TRACKERS:
        try:
            handle.add_tracker({"url": trk})
        except RuntimeError:
            pass

    metadata_waits = 0
    retried = False
    while running:
        try:
            st = handle.status()
        except RuntimeError:
            metadata_waits += 1
            if metadata_waits > 120:
                log("Failed to get torrent status — session error?")
                print("[torrent] FAIL:session", flush=True)
                sys.exit(1)
            time.sleep(0.5)
            continue
        if st.has_metadata:
            break
        metadata_waits += 1
        if metadata_waits >= 10 and not retried:   # ~5s without metadata
            log("No metadata yet — retrying...")
            handle.force_reannounce()
            retried = True
        elif metadata_waits > 120:                 # ~60s hard cap
            log("Failed to get metadata — no peers?")
            print("[torrent] FAIL:metadata", flush=True)
            sys.exit(1)
        time.sleep(0.5)

    if not running:
        sys.exit(0)

    ti = handle.torrent_file()
    video_idx, rel_path = pick_episode_file(ti, episode, season, abs_ep)
    if video_idx is None:
        log("No video files found in torrent")
        print("[torrent] FAIL:no-video", flush=True)
        sys.exit(1)

    # Piece-priority vector is the ONLY reliable selector in libtorrent 2.x:
    # prioritize_files() is re-applied asynchronously and stomps piece-level
    # priorities, and default-7 pieces compete with the hot regions.
    # Phase 1: head+tail at 7, EVERYTHING else 0 (other files included) —
    # nothing but the pieces mpv needs to start gets downloaded.
    piece_len = ti.piece_length()
    f_off = ti.files().file_offset(video_idx)
    f_size = ti.files().file_size(video_idx)
    first_piece = f_off // piece_len
    last_piece = (f_off + f_size - 1) // piece_len
    num_file_pieces = last_piece - first_piece + 1
    num_pieces = ti.num_pieces()
    tail_pieces = min(num_file_pieces, max(4, (16 * 1024 * 1024) // piece_len))
    tail_start = last_piece - tail_pieces + 1

    buffer_bytes_pre = max(5, min(buffer_mb, 500)) * 1024 * 1024
    head_target_pre = min(f_size, buffer_bytes_pre)
    head_pieces_pre = min(num_file_pieces, (head_target_pre + piece_len - 1) // piece_len)

    # Resume window: mpv --start seeks straight to the resume position, so
    # the pieces around it join the hot set (8MB behind for decoder preroll,
    # one buffer ahead). Without this the seek competes with sequential
    # mode via on-demand bridge fetches — tens of seconds of wait.
    resume_start = resume_end = -1
    if resume_frac is not None and f_size > 0:
        center_b = f_size * max(0, min(100, resume_frac)) / 100.0
        win_lo = max(0, center_b - 8 * 1024 * 1024)
        win_hi = min(f_size, center_b + buffer_bytes_pre)
        resume_start = max(first_piece, (f_off + int(win_lo)) // piece_len)
        resume_end = min(last_piece, (f_off + int(win_hi)) // piece_len)
        if resume_start > resume_end:
            resume_start = resume_end = -1

    # mkv container quirk: fansub releases embed a multi-MB Attachments
    # (fonts) section BEFORE the first cluster, so the playable head size
    # cannot be known from the torrent alone. Start with the bare buffer,
    # then GROW the head in steps while scanning for the first Cluster
    # element — the scan can only see data we already pulled, so growth
    # must come first. Non-mkv files skip this (mp4 moov is in the tail).
    ext = os.path.splitext(rel_path)[1].lower()
    is_mkv = ext in (".mkv", ".webm")
    head_step = max(1, (8 * 1024 * 1024) // piece_len)
    head_committed = head_pieces_pre
    head_cap = min(num_file_pieces, (256 * 1024 * 1024) // piece_len)

    hot = set(range(first_piece, first_piece + head_committed)) | set(range(tail_start, last_piece + 1))
    if resume_start >= 0:
        hot |= set(range(resume_start, resume_end + 1))
        log(f"Prioritizing resume window (~{resume_frac}% of file)")
    vec = [7 if p in hot else 0 for p in range(num_pieces)]
    try:
        handle.prioritize_pieces(vec)
    except RuntimeError:
        pass

    video_path = os.path.join(save_path, rel_path)
    # Ready = mkv layout resolved (first cluster found + head extended past
    # it) AND the head is CONTIGUOUSLY downloaded AND the tail (cues/
    # attachments) is complete AND the resume window (if any) is down.
    # Total-bytes checks are not enough: tail pieces count toward
    # file_progress, so mpv used to be handed a file with a holey header —
    # it died instantly with "no clusters found".
    head_pieces_needed = head_committed
    cluster_scanned = not is_mkv   # non-mkv: nothing to resolve

    def ensure_head_pieces():
        """Ensure current head_committed pieces are downloaded; if so, grow head."""
        nonlocal head_committed, head_pieces_needed
        if head_committed >= head_cap:
            return
        have_head = True
        for p in range(first_piece, first_piece + head_committed):
            if not handle.have_piece(p):
                have_head = False
                break
        if have_head:
            head_committed = min(head_cap, head_committed + head_step)
            hot |= set(range(first_piece + head_pieces_needed, first_piece + head_committed))
            head_pieces_needed = head_committed
            try:
                handle.prioritize_pieces([7 if p in hot else 0 for p in range(num_pieces)])
            except RuntimeError:
                pass

    def hot_complete():
        try:
            for p in range(first_piece, first_piece + head_pieces_needed):
                if not handle.have_piece(p):
                    return False
            for p in range(tail_start, last_piece + 1):
                if not handle.have_piece(p):
                    return False
            if resume_start >= 0:
                for p in range(resume_start, resume_end + 1):
                    if not handle.have_piece(p):
                        return False
        except RuntimeError:
            return False
        return True

    reported = False
    stalled_count = 0
    last_progress_log = 0
    prev_total = 0
    last_progress_t = time.time()

    def progress_line():
        # Phase-aware: BUFFERING shows progress toward ready (hot pieces —
        # head+tail+resume window, 100% == playback can start); PLAYING
        # shows how much of THE EPISODE FILE is buffered (not whole-session
        # stats, which are meaningless for batch torrents).
        try:
            st = handle.status()
            fp = handle.file_progress()
            file_done = fp[video_idx] if video_idx < len(fp) else 0
        except RuntimeError:
            return "status unavailable"
        rate = st.download_rate / 1024
        peers = st.num_peers
        bar_len = 25
        if not reported:
            hot_have = sum(1 for p in hot if _have_piece(handle, p))
            hot_total = max(1, len(hot))
            pct = 100.0 * hot_have / hot_total
            label = f"{hot_have * piece_len / (1024 * 1024):.0f}/{hot_total * piece_len / (1024 * 1024):.0f}MB"
        else:
            pct = 100.0 * file_done / max(1, f_size)
            label = f"{file_done / (1024 * 1024):.0f}/{f_size / (1024 * 1024):.0f}MB"
        filled = int(bar_len * pct / 100)
        bar = "█" * filled + "░" * (bar_len - filled)
        return f"{pct:3.0f}%|{bar}| {label} | {rate:.0f}KB/s | {peers}p"

    while running:
        try:
            st = handle.status()
        except RuntimeError:
            time.sleep(1)
            continue

        if st.state == lt.torrent_status.downloading_metadata:
            time.sleep(0.5)
            continue

        now_t = int(time.time())
        if now_t - last_progress_log >= 1:
            log(progress_line())
            last_progress_log = now_t

        # mkv head resolution: walk the top-level EBML element headers
        # (SeekHead/Info/Tracks/Attachments/...) to find the EXACT offset of
        # the first Cluster — a magic-byte scan false-positives inside binary
        # font data. Headers sit at the front (downloaded first); when the
        # walk runs into not-yet-downloaded bytes, grow the head and retry.
        if not reported and not cluster_scanned and now_t % 3 == 0:
            try:
                ensure_head_pieces()
                if head_committed > head_pieces_needed:
                    # New committed head pieces join the hot set immediately.
                    hot |= set(range(first_piece + head_pieces_needed, first_piece + head_committed))
                    head_pieces_needed = head_committed
                    try:
                        handle.prioritize_pieces([7 if p in hot else 0 for p in range(num_pieces)])
                    except RuntimeError:
                        pass
            except RuntimeError:
                pass
            # Scan for first cluster in downloaded head bytes.
            try:
                with open(video_path, "rb") as vf:
                    scan = vf.read(min(f_size, head_committed * piece_len))
                c = _mkv_first_cluster_offset(scan)
                if c is not None:
                    cluster_scanned = True
                    need_bytes = c + buffer_bytes_pre
                    hp = min(num_file_pieces, (need_bytes + piece_len - 1) // piece_len)
                    if hp > head_pieces_needed:
                        hot |= set(range(first_piece + head_pieces_needed, first_piece + hp))
                        head_pieces_needed = hp
                        try:
                            handle.prioritize_pieces([7 if p in hot else 0 for p in range(num_pieces)])
                        except RuntimeError:
                            pass
                elif head_committed < head_cap:
                    have_head = True
                    for p in range(first_piece, first_piece + head_committed):
                        if not handle.have_piece(p):
                            have_head = False
                            break
                    if have_head:
                        head_committed = min(head_cap, head_committed + head_step)
                        hot |= set(range(first_piece + head_pieces_needed, first_piece + head_committed))
                        head_pieces_needed = head_committed
                        try:
                            handle.prioritize_pieces([7 if p in hot else 0 for p in range(num_pieces)])
                        except RuntimeError:
                            pass
                else:
                    cluster_scanned = True   # cap reached — play what we have
            except OSError:
                pass

        if not reported and st.state >= lt.torrent_status.downloading:
            fp = handle.file_progress()
            file_done = fp[video_idx] if video_idx < len(fp) else 0
            # NOTE: no finished/seeding shortcut — with selective priorities
            # the torrent reaches "seeding" as soon as the hot pieces are
            # done, long before the mkv head is resolved.
            ready = (
                (cluster_scanned and hot_complete())
                or file_done >= f_size
            )
            if ready and file_done > 0:
                port = start_bridge(handle, video_path, f_off, f_size, piece_len)
                print(f"http://127.0.0.1:{port}/video", flush=True)
                reported = True
                # Phase 2: head+tail are down and mpv is playing — open up
                # the rest of the target file and switch to sequential mode
                # so it downloads in playback order (other files stay at 0).
                try:
                    vec2 = [7 if first_piece <= p <= last_piece else 0 for p in range(num_pieces)]
                    handle.prioritize_pieces(vec2)
                    handle.set_flags(lt.torrent_flags.sequential_download)
                except (RuntimeError, AttributeError):
                    pass

        cur_total = st.total_done
        if cur_total > prev_total:
            stalled_count = 0
            prev_total = cur_total
            last_progress_t = time.time()
        else:
            stalled_count += 1

        # Nudge missing hot pieces with deadlines every 5s — deadline
        # requests are time-critical and get requested ahead of everything.
        if not reported and now_t % 5 == 0:
            try:
                for p in range(first_piece, first_piece + head_pieces_needed):
                    if not handle.have_piece(p):
                        handle.set_piece_deadline(p, 1500)
                for p in range(tail_start, last_piece + 1):
                    if not handle.have_piece(p):
                        handle.set_piece_deadline(p, 2000)
                if resume_start >= 0:
                    for p in range(resume_start, resume_end + 1):
                        if not handle.have_piece(p):
                            handle.set_piece_deadline(p, 1500)
            except RuntimeError:
                pass

        if stalled_count >= 10:
            stalled_count = 0
            if st.num_peers == 0 and st.download_rate == 0:
                log("Stalled — reannouncing...")
                handle.force_reannounce()
                handle.force_dht_announce()

        # Dead-torrent bound BEFORE ready: 120s without a single new byte
        # means the swarm can't serve us. Bail out so the app falls back to
        # the next-best magnet in ~120s instead of burning the full timeout.
        if not reported and time.time() - last_progress_t > 120:
            log("No download progress for 120s — giving up (app will try the next torrent)")
            print("[torrent] FAIL:no-progress", flush=True)
            sys.exit(1)

        time.sleep(1)

    sys.exit(0)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Torrent streaming engine")
    parser.add_argument("uri", help="Magnet URI or torrent file path")
    parser.add_argument("--buffer", type=int, default=BUFFER_MB, help="Buffer size in MB (5-500)")
    parser.add_argument("--episode", default="1", help="Episode number to pick from the torrent")
    parser.add_argument("--season", default=None, help="Season number (helps pick files in batch torrents)")
    parser.add_argument("--abs-ep", dest="abs_ep", default=None,
                        help="Cumulative episode number (season offset + episode) for cumulative batches")
    parser.add_argument("--resume-frac", dest="resume_frac", type=int, default=None,
                        help="Resume position as 0-100 fraction of the episode file (prioritizes window around it)")
    args = parser.parse_args()

    stream_torrent(args.uri, args.buffer, args.episode, args.season, args.abs_ep, args.resume_frac)
