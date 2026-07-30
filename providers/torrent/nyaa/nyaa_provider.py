#!/usr/bin/env python3
import sys, json, re, math, urllib.request, urllib.parse, xml.etree.ElementTree as ET
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor
import ssl
import hashlib
import os
import time

NYAA_RSS = "https://nyaa.si/?page=rss&q={q}&c=1_2&f=0&s=seeders&o=desc"
TRACKERS = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.openbittorrent.com:6969/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.dler.org:6969/announce",
    "https://tracker.nanoha.org:443/announce",
]

NS = {"nyaa": "https://nyaa.si/xmlns/nyaa"}

TITLE_RE = re.compile(
    r"^\[(?P<group>[^\]]+)\]\s+"
    r"(?P<title>.+?)"
    r"\s*[-–]\s*"
    r"(?P<ep_start>\d+)"
    r"(?:[-–](?P<ep_end>\d+))?\s*"
    r"[\[\(](?P<res>\d+p)"
    r".*$"
)

BATCH_PAREN_RE = re.compile(
    r"^\[(?P<group>[^\]]+)\]\s+"
    r"(?P<title>.+?)"
    r"\s*\((?P<ep_start>\d+)(?:[-–](?P<ep_end>\d+))?\)\s*"
    r"[\[\(](?P<res>\d+p)"
    r".*$"
)

NO_GROUP_RE = re.compile(
    r"^(?P<title>.+?)"
    r"\s*[-–]\s*"
    r"(?:[Ee][Pp]\s*)?(?P<ep_start>\d+)"
    r"(?:[-–](?P<ep_end>\d+))?\s*"
    r"[\[\(](?P<res>\d+p)"
    r".*$"
)

BATCH_KEYWORDS = ["batch", "complete", "series", "collection"]

# Season-range batches: "S01-S04", "S1+2", "Seasons 1-3"
SEASON_RANGE_RE = re.compile(r"\bS(\d{1,2})\s*[-–~+]\s*S?(\d{1,2})\b", re.I)
SEASON_RANGE_WORD_RE = re.compile(r"\bseasons?\s*0*(\d{1,2})\s*[-–~]\s*0*(\d{1,2})\b", re.I)

def is_series_batch(title):
    """True for full-series / multi-season packs with no single ep number."""
    if not title:
        return False
    tl = title.lower()
    if SEASON_RANGE_RE.search(title) or SEASON_RANGE_WORD_RE.search(title):
        return True
    return any(kw in tl for kw in BATCH_KEYWORDS) and " - " not in title

def title_season_range(title):
    """(min, max) season coverage from a release title, or None."""
    if not title:
        return None
    m = SEASON_RANGE_RE.search(title) or SEASON_RANGE_WORD_RE.search(title)
    if m:
        a, b = int(m.group(1)), int(m.group(2))
        return (min(a, b), max(a, b))
    n = parse_season(title)
    return (n, n) if n else None

def build_magnet(info_hash, display_name):
    dn = urllib.parse.quote(display_name)
    tr_params = "".join(f"&tr={urllib.parse.quote(t)}" for t in TRACKERS)
    return f"magnet:?xt=urn:btih:{info_hash}&dn={dn}{tr_params}"

def _default_ssl_ctx():
    """Verified TLS, always. Magnets are security-sensitive (a MITM could
    swap them), so there is NO silent downgrade on verification failure —
    nyaa.si is behind Cloudflare with a valid cert. The single exception:
    a system with no CA bundle at all (some macOS pythons), where verified
    TLS can never work."""
    try:
        paths = ssl.get_default_verify_paths()
        for p in (paths.cafile, paths.capath, paths.openssl_cafile, paths.openssl_capath):
            if p and os.path.exists(p):
                return ssl.create_default_context()
    except Exception:
        pass
    return ssl._create_unverified_context()

_SSL_CTX = _default_ssl_ctx()

def fetch_rss(query):
    url = NYAA_RSS.format(q=urllib.parse.quote(query))
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0"
    })
    try:
        resp = urllib.request.urlopen(req, timeout=6, context=_SSL_CTX)
        return resp.read()
    except Exception:
        return None

def parse_size(s):
    if not s:
        return 0
    s = s.strip().upper()
    m = re.match(r"([\d.]+)\s*(B|KIB|MIB|GIB|TIB|KB|MB|GB|TB|K|M|G|T)", s)
    if not m:
        try:
            return int(s)
        except ValueError:
            return 0
    val = float(m.group(1))
    unit = m.group(2)
    multipliers = {
        "B": 1, "KIB": 1024, "MIB": 1024**2, "GIB": 1024**3, "TIB": 1024**4,
        "KB": 1000, "MB": 1000**2, "GB": 1000**3, "TB": 1000**4,
        "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4,
    }
    return int(val * multipliers.get(unit, 1))

def parse_title(title):
    if not title:
        return {}
    tl = title.lower()
    is_batch = any(kw in tl for kw in BATCH_KEYWORDS)
    for regex in [TITLE_RE, BATCH_PAREN_RE, NO_GROUP_RE]:
        m = regex.match(title)
        if m:
            ep_start = int(m.group("ep_start"))
            ep_end = m.group("ep_end")
            return {
                "group": m.group("group") if "group" in regex.groupindex else None,
                "episode": ep_start,
                "episode_end": int(ep_end) if ep_end else None,
                "is_batch": is_batch or ep_end is not None,
                "resolution": m.group("res"),
            }
    return {}

def extract_resolution(title):
    if not title:
        return None
    m = re.search(r"[\[\(](\d+p)", title)
    if m:
        return m.group(1)
    m = re.search(r"(?:^|\s)(\d{3,4}p)(?:\s|$|\[|\(|,)", title)
    if m:
        return m.group(1)
    # "1920x1080" style (BDRip tags often omit the p)
    m = re.search(r"\b\d{3,4}x(\d{3,4})\b", title)
    if m:
        return f"{m.group(1)}p"
    return None

MIN_SEEDS = 5

ROMAN_SEASONS = {"II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6, "VII": 7, "VIII": 8, "IX": 9, "X": 10}
ROMAN_RE = re.compile(r"\b(VIII|VII|III|II|IV|VI|IX|V|X)\b(?=\s*[::\-]|\s*$)")

def parse_season(name):
    """Season number from ANY title — AniList query side ("Show Season 3",
    "Show Part 2", "Mushoku Tensei III: ...") and release side ("Show S03",
    "Show 3rd Season"). One function for both: the old split (query-only
    part|cour/roman support) read different seasons off the same strings."""
    if not name:
        return None
    m = re.search(r"(?:season|part|cour)\s*0*(\d+)", name, re.I)
    if not m:
        m = re.search(r"\b(\d+)(?:nd|rd|th)\s+season\b", name, re.I)
    if not m:
        m = re.search(r"\bS0*(\d+)\b", name, re.I)
    if m:
        return int(m.group(1))
    # AniList romaji titles use roman numerals for later seasons
    # ("Mushoku Tensei III: ...") while releases use "S3".
    m = ROMAN_RE.search(name)
    if m:
        return ROMAN_SEASONS.get(m.group(1))
    return None

def strip_title(name):
    base = re.sub(r"\s*:.*$", "", name)
    base = re.sub(r"\s*(?:season|part|cour)\s*0*\d+.*$", "", base, flags=re.I)
    base = re.sub(r"\s*\b\d+(?:nd|rd|th)\s+season\b.*$", "", base, flags=re.I)
    base = re.sub(r"\s*\bS0*\d+\b.*$", "", base, flags=re.I)
    base = ROMAN_RE.sub("", base)
    return re.sub(r"\s+", " ", base).strip(" -")

def build_queries(name, target_ep, preferred_group=None):
    """(phase1, phase2, season) — two-phase query firing.
    Phase 1: ep-bearing + full-title variants (fired in parallel, always).
    Phase 2: the bare-base franchise query, fired ONLY when the phase-1
    pool is empty — it exists to rescue shows whose stripped base is the
    only indexed form, and otherwise just doubles the request count."""
    season = parse_season(name)
    base = strip_title(name) or name
    full = name.strip()
    titled = full.lower() != base.lower()
    ep = f"{target_ep:02d}"

    p1 = []
    if season:
        p1.append(f"{base} S{season} {ep}")
    # Titled seasons ("JoJo's …: Diamond is Unbreakable"): the subtitle IS
    # the season marker. Stripping it makes every part's ep 1 compete and
    # the most-seeded wrong part wins — search the full title first.
    if titled:
        p1.append(f"{full} {ep}")
    p1.append(f"{base} {ep}")
    p1.append(full)   # == bare base for plain shows
    p2 = [base] if titled else []

    if preferred_group:
        g = [f"[{preferred_group}] {q}" for q in p1]
        # Group-first, but keep the plain full-title in phase 1: title-only
        # queries surface season batches the ep-bearing queries miss.
        p1 = g + ([full] if titled else [])
        p2 = [f"[{preferred_group}] {q}" for q in p2] + p2

    def dedup(qs):
        seen, out = set(), []
        for q in qs:
            if q not in seen:
                seen.add(q)
                out.append(q)
        return out
    return dedup(p1), dedup(p2), season

def title_season(title):
    # Back-compat alias — unified into parse_season (see its docstring).
    return parse_season(title)

# ── Part-marker matching (titled seasons) ─────────────────────────
# "JoJo's …: Diamond is Unbreakable" vs release "JoJo's … - Stone Ocean":
# both carry a season-distinguishing SUBTITLE, and disjoint subtitles mean
# a DIFFERENT part of the franchise — the most-seeded wrong part used to
# win simply by seed count. Numeric seasons ("S3") are handled separately
# by the target_season logic; this covers named parts only.

_PART_JUNK_WORDS = {
    "batch", "complete", "collection", "series", "season", "part", "the", "a",
    "1080p", "720p", "480p", "360p", "sub", "subs", "dub", "dual", "audio",
    "bd", "bdrip", "web", "webrip", "hevc", "x264", "x265", "aac", "flac",
    "h264", "h265", "eng", "english", "jpn", "multi",
}

def _part_marker(s):
    """Season-distinguishing subtitle words, e.g.
    'Show - Stone Ocean (01-12) [Batch]' → 'stone ocean';
    'Show: Diamond is Unbreakable' → 'diamond is unbreakable'.
    Returns None when there is no usable subtitle (digits/resolutions only).
    """
    if not s:
        return None
    parts = re.split(r"\s+-\s+|:\s*", s, maxsplit=2)
    if len(parts) < 2:
        return None
    cand = re.split(r"[\[\(/]", parts[1])[0].strip().lower()
    cand = re.sub(r"[^a-z ]", " ", cand)
    toks = [t for t in cand.split() if len(t) > 1 and t not in _PART_JUNK_WORDS]
    if not toks:
        return None
    return " ".join(toks[:6])

def _marker_relation(q_marker, name):
    """'match' | 'mismatch' | None, comparing the query's part-marker to a
    release name. Match = the marker tokens appear in the name (handles
    'Show Diamond is Unbreakable - 01' where no delimiter exists).
    Mismatch = a DIFFERENT structural subtitle is present ('Show - Stone
    Ocean'), i.e. another part of the franchise."""
    if not q_marker:
        return None
    qt = set(q_marker.split())
    if not qt:
        return None
    name_toks = set(re.sub(r"[^a-z ]", " ", (name or "").lower()).split())
    if len(qt & name_toks) / len(qt) >= 0.6:
        return "match"
    n_marker = _part_marker(name)
    if n_marker and not (qt & set(n_marker.split())):
        return "mismatch"
    return None

def extract_episode_from_title(title):
    # NOTE: parse_rss already tried parse_title before calling this —
    # re-trying it here doubled the regex work per RSS item.
    if not title:
        return {}
    tl = title.lower()
    is_batch = any(kw in tl for kw in BATCH_KEYWORDS)
    m = re.search(r"[-–]\s*(\d{1,4})(?:\s|$|\)|\]|\[)", title)
    if m:
        ep = int(m.group(1))
        if ep > 2000:
            return {}
        res = extract_resolution(title)
        group_m = re.match(r"^\[([^\]]+)\]", title)
        group = group_m.group(1) if group_m else None
        return {
            "group": group, "episode": ep, "episode_end": None,
            "is_batch": is_batch, "resolution": res,
        }
    m = re.search(r"[Ee][Pp]\.?\s*(\d{1,4})(?:\s|$|\)|\])", title)
    if m:
        ep = int(m.group(1))
        res = extract_resolution(title)
        group_m = re.match(r"^\[([^\]]+)\]", title)
        group = group_m.group(1) if group_m else None
        return {
            "group": group, "episode": ep, "episode_end": None,
            "is_batch": is_batch, "resolution": res,
        }
    return {}

def parse_rss(xml_data):
    """List of entry dicts, [] for a valid-but-empty channel, or None when
    the fetch/parse failed (caller uses None to avoid neg-caching blips)."""
    if not xml_data:
        return None
    try:
        root = ET.fromstring(xml_data)
    except ET.ParseError:
        return None
    results = []
    for item in root.findall(".//item"):
        title_el = item.find("title")
        seeds_el = item.find("nyaa:seeders", NS)
        hash_el = item.find("nyaa:infoHash", NS)
        size_el = item.find("nyaa:size", NS)
        trust_el = item.find("nyaa:trusted", NS)
        remake_el = item.find("nyaa:remake", NS)
        pub_el = item.find("pubDate")

        title = title_el.text if title_el is not None else ""
        seeds = int(seeds_el.text) if seeds_el is not None and seeds_el.text else 0
        info_hash = hash_el.text.strip().lower() if hash_el is not None and hash_el.text else ""
        size_str = size_el.text if size_el is not None else ""
        trusted = trust_el.text == "Yes" if trust_el is not None else False
        remake = remake_el.text == "Yes" if remake_el is not None else False
        pub_date_str = pub_el.text if pub_el is not None else ""

        if not title or not info_hash:
            continue

        size_bytes = parse_size(size_str)
        magnet = build_magnet(info_hash, title)
        parsed = parse_title(title) or extract_episode_from_title(title)
        if not parsed.get("episode") and is_series_batch(title):
            group_m = re.match(r"^\[([^\]]+)\]", title)
            parsed = {
                "group": group_m.group(1) if group_m else None,
                "episode": 1,
                "episode_end": 9999,
                "is_batch": True,
                "resolution": extract_resolution(title),
            }
        res = parsed.get("resolution") or extract_resolution(title)

        pub_date = None
        if pub_date_str:
            try:
                pub_date = datetime.strptime(pub_date_str[:25], "%a, %d %b %Y %H:%M:%S").replace(tzinfo=timezone.utc)
            except ValueError:
                pass

        entry = {
            "name": title,
            "size": size_str,
            "size_bytes": size_bytes,
            "seeds": seeds,
            "magnet": magnet,
            "info_hash": info_hash,
            "trusted": trusted,
            "remake": remake,
            "group": parsed.get("group"),
            "episode": parsed.get("episode"),
            "episode_end": parsed.get("episode_end"),
            "is_batch": parsed.get("is_batch", False),
            "resolution": res,
            "pub_date": pub_date,
        }
        results.append(entry)
    return results

OVA_KEYWORDS = ["oad", "ova", "special", "movie", "film", "extra"]

def is_ova(title):
    if not title:
        return False
    tl = title.lower()
    if SEASON_RANGE_RE.search(title) or SEASON_RANGE_WORD_RE.search(title):
        return False   # multi-season pack, not an OVA
    return any(kw in tl for kw in OVA_KEYWORDS) and not any(kw in tl for kw in ["season", "final", "part"])

W_EXACT_EPISODE = 1000
W_EXACT_RES = 800
W_TRUSTED = 500
W_REMAKE_PEN = -400
W_GROUP_MATCH = 600
W_LOG_SEEDS = 200
W_SIZE_BONUS = 150
W_DEAD_PENALTY = -10000
W_OVA_PENALTY = -2000
W_BATCH_PENALTY = -800
W_AGE_HOURS = -0.02
W_SEASON_MATCH = 1000
W_SEASON_MISMATCH = -1500
W_FRANCHISE_SPAN = -700   # per extra season beyond the target's own (franchise packs)
W_MARKER_MATCH = 800
W_MARKER_MISMATCH = -2000

DEBUG = os.environ.get("NYAA_DEBUG") == "1"

def compute_score(r, target_ep, target_quality, preferred_group, preferred_resolution, now, target_season=None, q_marker=None):
    ep = r.get("episode", 0)
    ep_end = r.get("episode_end")
    is_batch = r.get("is_batch", False)

    # rank_results already filtered to candidates containing the target ep,
    # so the miss case (ep_score = 0.0) is unreachable here.
    ep_score = 1.0
    if is_batch:
        ep_score = 0.6 if ep_end else 0.4

    tq = int(str(target_quality).replace("p", "")) if "p" in str(target_quality) else int(target_quality)
    res_str = r.get("resolution")
    if res_str:
        try:
            rq = int(res_str.replace("p", ""))
        except (ValueError, AttributeError):
            rq = 0
    else:
        rq = 0

    if rq == tq:
        res_score = 1.0
        tier = 0
    elif preferred_resolution:
        try:
            prq = int(preferred_resolution.replace("p", ""))
            if rq == prq:
                res_score = 0.95
                tier = 0
            elif rq and abs(rq - tq) <= 360:
                res_score = 0.5 * (1 - abs(rq - tq) / 360)
                tier = 1
            else:
                res_score = 0.0
                tier = 2
        except (ValueError, AttributeError):
            res_score = 0.0
            tier = 2
    elif rq and abs(rq - tq) <= 360:
        res_score = 0.5 * (1 - abs(rq - tq) / 360)
        tier = 1
    elif rq == 0:
        res_score = 0.0
        tier = 2
    else:
        res_score = 0.0
        tier = 2

    trusted_flag = 1.0 if r.get("trusted", False) else 0.0
    remake_flag = 1.0 if r.get("remake", False) else 0.0

    group_flag = 0.0
    if preferred_group and r.get("group"):
        if r["group"].lower() == preferred_group.lower():
            group_flag = 1.0

    seeds = r.get("seeds", 0)
    log_seeds = math.log2(seeds + 2)

    dead_flag = 1.0 if seeds == 0 else 0.0

    size_b = r.get("size_bytes", 0)
    if size_b > 0:
        size_mib = size_b / (1024 * 1024)
        if 100 <= size_mib <= 400:
            size_score = 1.0
        elif size_mib < 100:
            size_score = 0.5 * (size_mib / 100.0)
        else:
            size_score = max(0, 1.0 - (size_mib - 400) / 1600.0)
    else:
        size_score = 0.0

    pub_date = r.get("pub_date")
    age_hours = 0
    if pub_date:
        age_delta = now - pub_date
        age_hours = age_delta.total_seconds() / 3600.0

    season_score = 0
    if target_season:
        rng = title_season_range(r.get("name", ""))
        if rng and rng[0] <= target_season <= rng[1]:
            season_score = W_SEASON_MATCH
            # Franchise-wide packs (S01-S04) are a worse source for a specific
            # season than a season-specific pack: numbering ambiguity, batch
            # breadth. Penalize per extra season spanned.
            span = rng[1] - rng[0]
            if span > 0:
                season_score += W_FRANCHISE_SPAN * span
        elif rng:
            season_score = W_SEASON_MISMATCH

    # Named-part accuracy: disjoint subtitles = different part of the
    # franchise. Mismatch tanks the score AND bumps the tier so a seeded
    # wrong part can never outrank a viable right one.
    marker_rel = _marker_relation(q_marker, r.get("name", ""))
    marker_score = 0
    if marker_rel == "match":
        marker_score = W_MARKER_MATCH
    elif marker_rel == "mismatch":
        marker_score = W_MARKER_MISMATCH
        tier += 2

    ova_flag = 1.0 if is_ova(r.get("name", "")) else 0.0

    terms = {
        "ep": W_EXACT_EPISODE * ep_score,
        "res": W_EXACT_RES * res_score,
        "trusted": W_TRUSTED * trusted_flag,
        "remake": W_REMAKE_PEN * remake_flag,
        "group": W_GROUP_MATCH * group_flag,
        "seeds": W_LOG_SEEDS * log_seeds,
        "size": W_SIZE_BONUS * size_score,
        "dead": W_DEAD_PENALTY * dead_flag,
        "ova": W_OVA_PENALTY * ova_flag,
        "batch": W_BATCH_PENALTY * (1.0 if is_batch else 0.0),
        "age": W_AGE_HOURS * age_hours,
        "season": season_score,
        "marker": marker_score,
    }
    score = sum(terms.values())

    if DEBUG:
        # NYAA_DEBUG=1 explain mode: which terms decided THIS candidate's
        # rank (stderr → captured by nyaa.sh into /tmp/ani-cli_nyaa_err.log).
        top = sorted((kv for kv in terms.items() if kv[1]), key=lambda kv: -abs(kv[1]))[:4]
        print(f"[nyaa] {score:8.1f} t{tier} {r.get('name', '')[:70]} :: "
              + " ".join(f"{k}={v:+.0f}" for k, v in top), file=sys.stderr)

    return score, tier

def rank_results(results, target_ep, target_quality, preferred_group=None, preferred_resolution=None, target_season=None, q_marker=None):
    now = datetime.now(timezone.utc)

    filtered = []
    for r in results:
        ep = r.get("episode")
        ep_end = r.get("episode_end")
        is_batch = r.get("is_batch", False)
        if ep is None:
            continue
        if is_batch and ep_end:
            if not (ep <= target_ep <= ep_end):
                continue
        elif is_batch and not ep_end:
            if not (ep <= target_ep <= ep + 75):
                continue
        elif not is_batch:
            if ep != target_ep:
                continue
        filtered.append(r)

    seeded = [r for r in filtered if r.get("seeds", 0) >= MIN_SEEDS]
    if seeded:
        filtered = seeded

    if not filtered:
        return filtered

    scored = []
    for r in filtered:
        score, tier = compute_score(r, target_ep, target_quality, preferred_group, preferred_resolution, now, target_season, q_marker)
        r["_score"] = score
        r["_tier"] = tier
        scored.append(r)

    scored.sort(key=lambda r: (r["_tier"], -r["_score"]))
    return scored

SEARCH_CACHE_TTL = 600   # seconds (positive results)
NEG_CACHE_TTL = 60       # seconds (empty results — don't re-hit nyaa on every prefetch)

def _search_cache_path(key):
    h = hashlib.md5(key.encode("utf-8")).hexdigest()[:20]
    return f"/tmp/ani-cli_nyaa_search_{h}.json"

def _neg_cache_path(key):
    return _search_cache_path(key) + ".neg"

def _search_cache_get(key):
    try:
        p = _search_cache_path(key)
        if os.path.getmtime(p) > time.time() - SEARCH_CACHE_TTL:
            with open(p) as f:
                return f.read()
    except OSError:
        pass
    return None

def _search_cache_set(key, data):
    try:
        with open(_search_cache_path(key), "w") as f:
            f.write(data)
    except OSError:
        pass
    try:
        os.remove(_neg_cache_path(key))
    except OSError:
        pass

def _neg_cache_check(key):
    try:
        return os.path.getmtime(_neg_cache_path(key)) > time.time() - NEG_CACHE_TTL
    except OSError:
        return False

def _neg_cache_set(key):
    try:
        with open(_neg_cache_path(key), "w") as f:
            f.write("")
    except OSError:
        pass

def cmd_search(args):
    if len(args) < 3:
        print("[]")
        return
    name, episode, quality = args[0], args[1], args[2]
    preferred_group = args[3] if len(args) > 3 and args[3] else None
    preferred_res = args[4] if len(args) > 4 and args[4] else None

    cache_key = "|".join([name, episode, quality, preferred_group or "", preferred_res or ""])
    cached = _search_cache_get(cache_key)
    if cached is not None:
        print(cached)
        return
    if _neg_cache_check(cache_key):
        print("[]")
        return

    try:
        target_ep = int(episode)
    except ValueError:
        target_ep = int(re.sub(r"\D", "", episode) or 0)

    queries_p1, queries_p2, target_season = build_queries(name, target_ep, preferred_group)
    q_marker = _part_marker(name)

    # Parse ALL query results into one global pool (dedupe by info_hash),
    # then rank ONCE. Per-query ranking let entries from a seedless query
    # bypass the global seed filter and outrank better candidates.
    merged = {}
    any_ok = False   # ≥1 variant returned parseable RSS (vs a network blip)

    def absorb(xml_results):
        nonlocal any_ok
        for xml_data in xml_results:
            items = parse_rss(xml_data)
            if items is None:
                continue
            any_ok = True
            for x in items:
                h = x.get("info_hash") or x.get("name")
                if h not in merged:
                    merged[h] = x

    def fire(queries):
        if not queries:
            return []
        # Fetch all candidate RSS queries in parallel — sequential fetching
        # made searches take tens of seconds when nyaa was slow.
        with ThreadPoolExecutor(max_workers=max(1, len(queries))) as ex:
            return list(ex.map(fetch_rss, queries))

    absorb(fire(queries_p1))
    # Phase 2: bare-base franchise query, only when phase 1 found nothing.
    if not merged and queries_p2:
        absorb(fire(queries_p2))

    ranked = rank_results(list(merged.values()), target_ep, quality, preferred_group, preferred_res, target_season, q_marker)

    # Trimmed output contract: exactly the fields the app consumes.
    output = []
    for r in ranked[:30]:
        entry = {
            "name": r["name"],
            "magnet": r["magnet"],
            "group": r.get("group"),
            "resolution": r.get("resolution"),
            "size": r["size"],
            "seeds": r["seeds"],
            "is_batch": r.get("is_batch", False),
            "trusted": r.get("trusted", False),
            "target_season": target_season,
        }
        if DEBUG:
            entry["_score"] = round(r["_score"], 1)
            entry["_tier"] = r["_tier"]
        output.append(entry)
    out_json = json.dumps(output)
    if output:
        _search_cache_set(cache_key, out_json)
    elif any_ok:
        # Genuinely empty (nyaa answered, nothing matched) — neg-cache.
        # A transient fetch failure (all variants None) must NOT neg-cache,
        # or a blip becomes 60s of false "no results".
        _neg_cache_set(cache_key)
    print(out_json)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: nyaa_provider.py search <name> <episode> <quality> [group] [resolution]"}))
        sys.exit(1)
    command = sys.argv[1]
    args = sys.argv[2:]
    if command == "search":
        cmd_search(args)
    else:
        print(json.dumps({"error": f"Unknown command: {command}"}))
        sys.exit(1)
