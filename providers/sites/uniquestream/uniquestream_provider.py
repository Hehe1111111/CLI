#!/usr/bin/env python3
"""UniqueStream stream resolver — called by uniquestream.sh provider_get_stream.

stdin:  series JSON (GET /api/v1/series/<id>)
env:    TITLE UNI_BASE UA EP_NUM SUB_OR_DUB ID_MAL QUALITY AID SUBS_LANG
stdout: "serve:<playlist handoff file>" plus an optional "sub:<url>" line;
        nothing on failure. Debuggable standalone:
          curl -s "$UNI_BASE/api/v1/series/<id>" | \
            EP_NUM=1 UNI_BASE=... UA=... python3 uniquestream_provider.py

Chain shape (proven minimal — do not "optimize" away): series (cached 24h)
→ season eplist (cached 1h) → dash (live only). The API caps limit<=20
(422 above), embeds no episodes in the series response, and episode items
carry no media URLs. Warm path = 1 request.
"""
import time
import sys
import json
import urllib.request
import re
import os
import tempfile
from concurrent.futures import ThreadPoolExecutor


def _season_range(title):
    """(start, end) episode range from a season title, e.g. 'Alabasta
    (62-135)' (inclusive end) or 'Wano (892-)' (end=None = open-ended).
    None when the title carries no range. Single source for the season-
    range regex — it used to be open-coded in three places."""
    m = re.search(r'\((\d+)-(\d+)\)', title or '')
    if m and m.group(2).isdigit():
        return int(m.group(1)), int(m.group(2))
    m = re.search(r'\((\d+)-', title or '')
    if m:
        return int(m.group(1)), None
    return None


def _range_covers(rng, ep):
    if rng is None:
        return False
    start, end = rng
    return start <= ep <= end if end is not None else ep >= start


def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        sys.exit(1)

    seasons = data.get('seasons', [])
    if not seasons:
        sys.exit(1)

    ep_num = float(os.environ['EP_NUM'])
    ua = os.environ['UA']
    base = os.environ['UNI_BASE']
    id_mal = os.environ.get('ID_MAL', '')

    seasons.sort(key=lambda s: s.get('season_seq_number', 0))

    def fetch_ep_page(sid, p):
        url = f'{base}/api/v1/season/{sid}/episodes?page={p}&limit=20&order_by=asc'
        req = urllib.request.Request(url, headers={'User-Agent': ua})
        try:
            resp = urllib.request.urlopen(req, timeout=20)
            d = json.loads(resp.read())
            return d if isinstance(d, list) else []
        except Exception:
            return []

    _season_cache = '/tmp/uni_cache/season_' + os.environ.get('AID', '') + '.txt'
    target_season_id = None
    _from_cache = False
    if len(seasons) == 1:
        target_season_id = seasons[0]['content_id']
    elif os.path.exists(_season_cache):
        try:
            if time.time() - os.path.getmtime(_season_cache) < 86400:
                cid = open(_season_cache).read().strip()
                if any(s['content_id'] == cid for s in seasons):
                    target_season_id = cid
                    _from_cache = True
        except Exception:
            pass

    # Cached season provably wrong for this episode (title range doesn't
    # cover it, e.g. One Piece sagas) — drop it and let the strategies
    # re-resolve.
    if _from_cache and target_season_id:
        _ct = ''
        for s in seasons:
            if s['content_id'] == target_season_id:
                _ct = s.get('title', '')
                break
        rng = _season_range(_ct)
        if rng and not _range_covers(rng, ep_num):
            target_season_id = None
            _from_cache = False

    # Strategy 1: MAL ID match (most reliable)
    if id_mal and target_season_id is None:
        for s in seasons:
            if str(s.get('mal_id', '')) == id_mal:
                target_season_id = s['content_id']
                break

    # Strategy 2: match AniList part name against season titles
    if target_season_id is None:
        series_title = data.get('title', '').lower().strip()
        anilist_title = os.environ.get('TITLE', '').lower().strip()
        if anilist_title and anilist_title != series_title:
            part = anilist_title.replace(series_title, '', 1).strip().lstrip(':').lstrip('-').strip()
            if part:
                for s in seasons:
                    if part in s.get('title', '').lower():
                        target_season_id = s['content_id']
                        break
            if target_season_id is None:
                for s in seasons:
                    st = s.get('title', '').lower()
                    if anilist_title == st:
                        target_season_id = s['content_id']
                        break

    # Strategy 3: episode range in the season title
    if target_season_id is None:
        for s in seasons:
            if _range_covers(_season_range(s.get('title', '')), ep_num):
                target_season_id = s['content_id']
                break

    # Strategy 4: probe seasons in PARALLEL (the backend takes 10-23s per
    # call; sequential probing multiplied that by the season count)
    if target_season_id is None:
        def probe_season(s):
            sid = s['content_id']
            for page in range(1, 4):
                ep_data = fetch_ep_page(sid, page)
                if not ep_data:
                    break
                for ep in ep_data:
                    en = ep.get('episode_number')
                    if en == ep_num or str(en) == str(ep_num):
                        return sid
                if len(ep_data) < 20:
                    break
            return None
        with ThreadPoolExecutor(max_workers=min(4, len(seasons))) as ex:
            for res in ex.map(probe_season, seasons):
                if res is not None:
                    target_season_id = res
                    break

    if target_season_id is None:
        target_season_id = seasons[0]['content_id']

    try:
        os.makedirs('/tmp/uni_cache', exist_ok=True)
        open(_season_cache, 'w').write(target_season_id)
    except Exception:
        pass

    def collect_eps(sid, ep_target):
        # Episode lists change rarely (hourly at most for airing shows), so
        # cache them per season for 1h: later episodes resolve with only the
        # dash request. A miss for the target ep falls through to live fetch.
        eplist_cache = f'/tmp/uni_cache/eplist_{sid}.json'
        try:
            if os.path.exists(eplist_cache) and time.time() - os.path.getmtime(eplist_cache) < 3600:
                cached = json.load(open(eplist_cache))
                if any(ep.get('episode_number') == ep_target or str(ep.get('episode_number')) == str(ep_target) for ep in cached):
                    return cached, True
        except Exception:
            pass
        # Jump straight to the page containing ep_target, then scan outward
        # if numbering is off. Falls back to a full scan (cumulative).
        eps = []
        seen = set()
        base_off = 0
        for s in seasons:
            if s['content_id'] == sid:
                rng = _season_range(s.get('title', ''))
                if rng:
                    base_off = rng[0] - 1
                break
        start_page = max(1, int((ep_target - base_off - 1) // 20) + 1)
        pages_to_try = [start_page, start_page - 1, start_page + 1, start_page - 2, start_page + 2]
        found = False
        for p in pages_to_try:
            if p < 1:
                continue
            d = fetch_ep_page(sid, p)
            if not d:
                continue
            for ep in d:
                en = ep.get('episode_number')
                if en not in seen:
                    seen.add(en)
                    eps.append(ep)
                if en == ep_target or str(en) == str(ep_target):
                    found = True
            if found:
                break
        if not found:
            # Full scan fallback (cumulative numbering) — pages fetched in
            # parallel batches of 6 instead of strictly sequentially.
            page = 1
            while page <= 60 and not found:
                batch = list(range(page, min(page + 6, 61)))
                with ThreadPoolExecutor(max_workers=len(batch)) as ex:
                    pages = list(ex.map(lambda p: fetch_ep_page(sid, p), batch))
                end_of_list = False
                for d in pages:
                    if not d:
                        end_of_list = True   # empty page = past the end
                        continue
                    for ep in d:
                        en = ep.get('episode_number')
                        if en not in seen:
                            seen.add(en)
                            eps.append(ep)
                        if en == ep_target or str(en) == str(ep_target):
                            found = True
                    if len(d) < 20:
                        end_of_list = True
                    if found:
                        break
                if end_of_list:
                    break
                page += len(batch)
        if found:
            try:
                json.dump(eps, open(eplist_cache, 'w'))
            except Exception:
                pass
        return eps, found

    all_eps, found = collect_eps(target_season_id, ep_num)

    ep_content_id = None
    # Try exact match first (per-season numbering)
    for ep in all_eps:
        en = ep.get('episode_number')
        if en == ep_num or str(en) == str(ep_num):
            ep_content_id = ep['content_id']
            break

    # Cached season was wrong for this episode (single AniList entry
    # spanning multiple site seasons, e.g. One Piece) — drop and re-resolve.
    if ep_content_id is None and _from_cache:
        try:
            os.remove(_season_cache)
        except Exception:
            pass
        new_sid = None
        # Title episode ranges first (no requests, e.g. Alabasta (62-135))
        for s in seasons:
            if _range_covers(_season_range(s.get('title', '')), ep_num):
                new_sid = s['content_id']
                break
        # Fallback: probe seasons (capped)
        if new_sid is None:
            for s in seasons:
                sid = s['content_id']
                for p in range(1, 4):
                    d = fetch_ep_page(sid, p)
                    if not d:
                        break
                    hit = False
                    for ep in d:
                        en = ep.get('episode_number')
                        if en == ep_num or str(en) == str(ep_num):
                            hit = True
                            break
                    if hit:
                        new_sid = sid
                        break
                    if len(d) < 20:
                        break
                if new_sid:
                    break
        if new_sid:
            target_season_id = new_sid
            all_eps, found = collect_eps(target_season_id, ep_num)
            try:
                open(_season_cache, 'w').write(target_season_id)
            except Exception:
                pass
            for ep in all_eps:
                en = ep.get('episode_number')
                if en == ep_num or str(en) == str(ep_num):
                    ep_content_id = ep['content_id']
                    break

    # Fallback: cumulative numbering (e.g., AOT English Dub uses numbering
    # across seasons) — fetch the last episode number of the previous season
    if ep_content_id is None:
        prev_sid = None
        for i, s in enumerate(seasons):
            if s['content_id'] == target_season_id and i > 0:
                prev_sid = seasons[i-1]['content_id']
                break
        if prev_sid:
            try:
                prev_url = f'{base}/api/v1/season/{prev_sid}/episodes?page=1&limit=1&order_by=desc'
                prev_req = urllib.request.Request(prev_url, headers={'User-Agent': ua})
                prev_resp = urllib.request.urlopen(prev_req, timeout=20)
                prev_data = json.loads(prev_resp.read())
                if isinstance(prev_data, list) and len(prev_data) > 0:
                    last_ep_num = prev_data[0].get('episode_number', 0)
                    target_ep_num = int(last_ep_num) + int(ep_num)
                    for ep in all_eps:
                        en = ep.get('episode_number')
                        if en == target_ep_num or str(en) == str(target_ep_num):
                            ep_content_id = ep['content_id']
                            break
            except Exception:
                pass

    if ep_content_id is None:
        sys.exit(1)

    ep_audio_locales = []
    for ep in all_eps:
        if ep.get('content_id') == ep_content_id:
            ep_audio_locales = ep.get('audio_locales', [])
            break
    audio_locales = ep_audio_locales or data.get('audio_locales', ['ja-JP'])

    sod = os.environ.get('SUB_OR_DUB', 'sub')
    if sod == 'dub' and 'en-US' in audio_locales:
        locale = 'en-US'
    elif 'ja-JP' in audio_locales:
        locale = 'ja-JP'
    else:
        locale = audio_locales[0] if audio_locales else 'ja-JP'

    stream_url = f'{base}/api/v1/episode/{ep_content_id}/media/dash/{locale}'
    req = urllib.request.Request(stream_url, headers={'User-Agent': ua})
    try:
        resp = urllib.request.urlopen(req, timeout=20)
        stream_data = json.loads(resp.read())
    except Exception:
        sys.exit(1)

    hls = stream_data.get('hls') or {}
    playlist = ''
    sub_url = ''

    if sod == 'dub':
        for v in (stream_data.get('versions') or {}).get('hls', []) or []:
            if v.get('locale') == 'en-US':
                playlist = v.get('playlist', '')
                break
        if not playlist:
            playlist = hls.get('playlist', '')
    else:
        # ja-JP-only episodes return hard_subs as null — guard and fall back
        # to the clean playlist + soft VTT subtitles.
        hard_subs = hls.get('hard_subs') or []
        for hs in hard_subs:
            if hs.get('locale') == 'en-US':
                playlist = hs.get('playlist', '')
                break
        if not playlist:
            playlist = hls.get('playlist', '')
            # soft subs: prefer configured language, then en-US, then anything
            subs = hls.get('subtitles') or []
            pref = os.environ.get('SUBS_LANG', 'english').lower()
            lang_map = {'english': 'en-US', 'en': 'en-US'}
            want = lang_map.get(pref, pref)
            pick = ''
            for s in subs:
                if s.get('language') == want:
                    pick = s.get('url', '')
                    break
            if not pick:
                for s in subs:
                    if s.get('language') == 'en-US':
                        pick = s.get('url', '')
                        break
            if not pick and subs:
                pick = subs[0].get('url', '')
            sub_url = pick

    if not playlist:
        sys.exit(1)

    fd, tmpf = tempfile.mkstemp(suffix='_uni_url.txt', dir='/tmp')
    os.close(fd)
    with open(tmpf, 'w') as f:
        f.write(playlist + '\n')
        q = os.environ.get('QUALITY', '')
        if q:
            f.write(q + '\n')
    print(f'serve:{tmpf}')
    if sub_url:
        print(f'sub:{sub_url}')


if __name__ == '__main__':
    main()
