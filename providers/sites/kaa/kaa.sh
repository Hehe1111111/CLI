# KickAssAnime (kaa.lt) provider
# Video served via krussdomi.com HLS manifests with subtitles.

# Portable helpers when sourced standalone (the app preloads these).
command -v _file_mtime >/dev/null 2>&1 || \
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/common.sh" 2>/dev/null || true

PROVIDER_NAME="KickAssAnime"
# Playback metadata consumed generically by src/core.sh (see _template.sh)
PROVIDER_HEADERS=("Referer: https://krussdomi.com/" "Origin: https://krussdomi.com")
PROVIDER_LAVF_OPTS="--demuxer-lavf-o=allowed_segment_extensions=jpg"
KAA_BASE="https://kaa.lt"
KRUSS_BASE="https://krussdomi.com"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"

# ── Search API ──────────────────────────────────────────────────────
# Uses POST /api/search (returns all shows, unlike the paginated GET /api/anime)
# and GET /api/show/{slug}/episodes (lists all episodes for a show).

_kaa_api_post() {
    local endpoint="$1"
    # normalize (× → x) + JSON-encode. jq is ~10x lighter than python per
    # call (5.6ms vs 61ms) and is already a hard app dependency.
    local s="${2//×/x}"
    local json_payload
    json_payload=$(jq -cn --arg q "$s" '{query:$q}' 2>/dev/null) || return 1
    curl -s --max-time 15 --connect-timeout 10 -X POST "${KAA_BASE}${endpoint}" \
        -H "Content-Type: application/json" \
        -H "User-Agent: ${UA}" \
        -d "$json_payload" 2>/dev/null
}

# ── ID Resolution ──────────────────────────────────────────────────

# All title variants AniList knows (romaji|english|userPreferred|synonyms)
# — kaa lists shows under romaji names, so the userPreferred title alone
# can miss (e.g. "JoJo's Bizarre Adventure: Stone Ocean" vs kaa's romaji).
_kaa_get_title_variants() { # $1=aid
    local aid="$1"
    curl -s --max-time 15 --connect-timeout 10 "https://graphql.anilist.co" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "{\"query\":\"query(\$id:Int){Media(id:\$id){title{romaji english userPreferred} synonyms}}\",\"variables\":{\"id\":$aid}}" \
      | python3 -c "
import sys, json
try:
    m = json.load(sys.stdin).get('data',{}).get('Media',{}) or {}
    t = m.get('title',{}) or {}
    out = [t.get('romaji',''), t.get('english',''), t.get('userPreferred','')]
    out += m.get('synonyms') or []
    seen, res = set(), []
    for x in out:
        if x and x not in seen:
            seen.add(x); res.append(x)
    print('|'.join(res))
except: pass
" 2>/dev/null
}

# Search kaa and return a slug ONLY on a confident match (exact / prefix /
# strong token overlap against any known title variant). A weak "first tv
# result" guess must never be returned or cached — it resolves the WRONG
# show (part 1 for a later season) and the 24h cache made it stick.
_kaa_search_slug() { # $1=query $2=extra variants (| separated, may be "")
    _kaa_api_post "/api/search" "$1" | Q="$1" VARIANTS="$2" python3 -c "
import sys, json, re, os

def norm(s):
    s = (s or '').lower()
    s = re.sub(r'[^a-z0-9 ]+', ' ', s)
    return re.sub(r'\s+', ' ', s).strip()

STOP = {'the', 'a', 'an', 'of', 'to', 'in', 'and', 'or', 'no', 'wa', 'ga', 'o', 'ni'}

def score(c, t):
    if not c or not t: return 0
    if c == t: return 100
    # One-directional only: the QUERY being a prefix of the title is safe
    # (jujutsu kaisen matches jujutsu kaisen 2). The reverse (title is a
    # prefix of the query) is the franchise season-1-for-season-2 hazard.
    if t.startswith(c): return 80
    ct = {w for w in c.split() if w not in STOP}
    tt = set(t.split())
    if not ct: return 0
    return 60 if len(ct & tt) / len(ct) >= 0.8 else 0

try:
    data = json.load(sys.stdin)
    cands = [norm(os.environ.get('Q',''))]
    cands += [norm(v) for v in os.environ.get('VARIANTS','').split('|') if v]
    best = (0, '')
    for entry in data or []:
        if entry.get('type') not in ('tv', 'ona', 'movie'):
            continue
        tl = norm(entry.get('title_en','') or entry.get('title','') or '')
        s = max((score(c, tl) for c in cands), default=0)
        if s > best[0]:
            best = (s, entry.get('slug',''))
    if best[0] >= 60 and best[1]:
        print(best[1])
except: pass
" 2>/dev/null
}

_kaa_resolve_slug() {
    local aid="$1" title="$2"

    local cache_file="/tmp/kaa_slug_${aid}"
    if [ -f "$cache_file" ]; then
        local cached=$(head -1 "$cache_file" 2>/dev/null)
        local cache_age=$(($(date +%s) - $(_file_mtime "$cache_file")))
        if [ -n "$cached" ] && [ "$cache_age" -lt 86400 ]; then
            echo "$cached"; return 0
        fi
    fi

    # Fire the AniList title-variants POST and the first kaa search POST in
    # PARALLEL — they're independent. Variants only matter when the plain
    # title doesn't match (romaji-named kaa entries), so the first search
    # is scored against the title alone.
    local vf="" vpid=""
    if [[ "$aid" =~ ^[0-9]+$ ]] && [ "$aid" != "0" ]; then
        vf=$(mktemp /tmp/kaa_variants_XXXXXX 2>/dev/null || echo "/tmp/kaa_variants_$$")
        ( _kaa_get_title_variants "$aid" > "$vf" 2>/dev/null ) &
        vpid=$!
    fi
    local slug=""
    [ -n "$title" ] && slug=$(_kaa_search_slug "$title" "$title")

    local variants=""
    if [ -n "$vpid" ]; then
        wait "$vpid" 2>/dev/null
        variants=$(cat "$vf" 2>/dev/null)
        rm -f "$vf"
    fi
    # Empty-title fallback: the variants fetcher is a superset of a plain
    # title fetch — its first entry (romaji) serves as the title.
    [ -z "$title" ] && title=$(echo "$variants" | cut -d'|' -f1)
    [ -z "$title" ] && return 1

    if [ -z "$slug" ]; then
        local q
        for q in "$title" "$(echo "$variants" | cut -d'|' -f1)"; do
            [ -z "$q" ] && continue
            slug=$(_kaa_search_slug "$q" "${title}|${variants}")
            [ -n "$slug" ] && break
        done
    fi

    if [ -n "$slug" ]; then
        echo "$slug" > "$cache_file"; echo "$slug"; return 0
    fi
    return 1
}

# ── Episode data extraction ────────────────────────────────────────

_kaa_find_ep_slug() {
    local slug="$1" ep_num="$2"

    # v2 cache key: episode hex slugs are per-language (sub vs dub) and the
    # app plays Japanese audio, so all lookups use lang=ja-JP. The en-US
    # (dub) index is empty for newly-added shows — ja-JP always has the eps.
    # Entries carry a timestamp and expire after 24h: the site rotates hex
    # slugs, so a permanent cache went stale and needed manual drops — a
    # TTL'd cache is self-healing (legacy 2-field lines read as expired).
    local cache_file="/tmp/kaa_epmap2_${slug}.txt"
    if [ -f "$cache_file" ]; then
        local cached=$(awk -F: -v ep="$ep_num" -v now="$(date +%s)" \
            '$1 == ep && $3 != "" && (now - $3) < 86400 { print $2; exit }' \
            "$cache_file" 2>/dev/null)
        [ -n "$cached" ] && echo "$cached" && return 0
    fi

    # Use episodes API (ja-JP = sub index; populated for every show)
    local hex_slug=$(curl -s --max-time 15 --connect-timeout 10 "${KAA_BASE}/api/show/${slug}/episodes?ep=${ep_num}&lang=ja-JP" \
        -H "User-Agent: ${UA}" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for ep in data.get('result', []):
        if ep.get('episode_number') == $ep_num:
            print(ep['slug'])
except: pass
" 2>/dev/null)

    if [ -n "$hex_slug" ]; then
        local result="ep-${ep_num}-${hex_slug}"
        echo "${ep_num}:${result}:$(date +%s)" >> "$cache_file" 2>/dev/null
        echo "$result"
        return 0
    fi

    return 1
}

# Fetch the episode page and extract the player embed URL (servers:[{src:...}]).
_kaa_fetch_server_url() { # $1=slug $2=ep_slug
    curl -s --max-time 15 --connect-timeout 10 "${KAA_BASE}/$1/$2" -H "User-Agent: ${UA}" | python3 -c "
import sys, re
html = sys.stdin.read()
idx = html.find('servers:[')
if idx < 0: sys.exit(0)
start = html.find('[', idx + 8)
if start < 0: sys.exit(0)
depth = 0; in_str = False; str_char = None; i = start
while i < len(html):
    c = html[i]
    if in_str:
        if c == '\\\\': i += 2; continue
        if c == str_char: in_str = False
    else:
        if c in ('\"', \"'\"): in_str = True; str_char = c
        elif c == '[': depth += 1
        elif c == ']':
            depth -= 1
            if depth == 0:
                body = html[start+1:i]
                for m in re.finditer(r'src:\s*\"([^\"]+)\"', body):
                    url = m.group(1)
                    url = bytes(url, 'utf-8').decode('unicode_escape')
                    print(url)
                break
    i += 1
" 2>/dev/null | head -1
}

# ── Provider interface ─────────────────────────────────────────────

provider_search() {
    local query="$1"
    _kaa_api_post "/api/search" "$query" | Q="$query" python3 -c "
import sys, json, os
try:
    data = json.load(sys.stdin)
    q = os.environ.get('Q','').lower().strip()
    def sort_key(item):
        title = (item.get('title_en','') or item.get('title','') or '').lower().strip()
        typ = item.get('type','')
        exact = title == q
        type_order = {'tv': 0, 'ona': 1, 'movie': 2, 'ova': 3}.get(typ, 4)
        return (not exact, type_order, title)
    sorted_data = sorted(data, key=sort_key)
    seen = set()
    for item in sorted_data[:25]:
        title = item.get('title_en','') or item.get('title','')
        slug = item.get('slug','')
        if slug not in seen:
            seen.add(slug)
            print(f'{slug}\\t{title}')
except: pass
" 2>/dev/null
}

provider_get_stream() {
    local aid="$1" ep_num="$2" quality="$3" title="$4"
    [ -z "$quality" ] && quality="1080"

    # Final-output cache: replay/prefetch = zero network requests.
    # TTL matches the local-master cache (1h); referenced files must exist.
    local out_cache="/tmp/kaa_stream_${aid}_${ep_num}_${quality}"
    if [ -f "$out_cache" ]; then
        local oage=$(($(date +%s) - $(_file_mtime "$out_cache")))
        if [ "$oage" -lt 3500 ]; then
            # Pure-bash line extraction (was: sed × 2 + head × 2 = 4 spawns
            # on EVERY warm resolve — the whole point of a warm cache is
            # to be cheap).
            local c_serve="" c_sub="" _ln
            while IFS= read -r _ln; do
                case "$_ln" in
                    serve:*) [ -z "$c_serve" ] && c_serve="${_ln#serve:}" ;;
                    sub:*)   [ -z "$c_sub" ]   && c_sub="${_ln#sub:}" ;;
                esac
            done < "$out_cache"
            local c_ok=1
            [ -n "$c_serve" ] && [ ! -f "$c_serve" ] && c_ok=0
            case "$c_sub" in /*) [ ! -f "$c_sub" ] && c_ok=0 ;; esac
            if [ "$c_ok" = "1" ]; then
                cat "$out_cache"
                return 0
            fi
        fi
        rm -f "$out_cache"
    fi

    local slug=$(_kaa_resolve_slug "$aid" "$title")
    [ -z "$slug" ] && return 1

    local ep_slug=$(_kaa_find_ep_slug "$slug" "$ep_num")
    [ -z "$ep_slug" ] && return 1

    # server-empty episodes are a kaa content gap (SPY×FAMILY S1 confirmed
    # en-US + ja-JP both servers:[]); do NOT probe alternatives — it doubles
    # the page fetch for zero recovery.

    # v3 cache: manifest_url + server_url + sub_url (24h), keyed by SLUG —
    # a re-resolved slug naturally misses the old entry, so wrong-show
    # staleness can't couple across resolutions.
    # The manifest URL comes from the player page's astro-island props — the
    # old constructed endpoint (hls.krussdomi.com/manifest/<id>) is DEAD (502),
    # so never build the URL by hand; always take the one the site hands out.
    local ep_cache="/tmp/kaa_ep3_${slug}_${ep_num}"
    local manifest_url="" server_url="" sub_url="" sub_retried=""
    if [ -f "$ep_cache" ]; then
        local age=$(($(date +%s) - $(_file_mtime "$ep_cache")))
        if [ "$age" -lt 86400 ]; then
            manifest_url=$(sed -n 's/^manifest_url=//p' "$ep_cache" 2>/dev/null | head -1)
            server_url=$(sed -n 's/^server_url=//p' "$ep_cache" 2>/dev/null | head -1)
            sub_url=$(sed -n 's/^sub_url=//p' "$ep_cache" 2>/dev/null | head -1)
            sub_retried=$(sed -n 's/^sub_retried=//p' "$ep_cache" 2>/dev/null | head -1)
        fi
    fi

    # Resolve server_url from the episode page (servers:[{src:...}])
    if [ -z "$manifest_url" ] && [ -z "$server_url" ]; then
        server_url=$(_kaa_fetch_server_url "$slug" "$ep_slug")
    fi

    # One player-page fetch yields BOTH the manifest URL and the subtitles.
    # Also refetch ONCE when a cached entry has no sub_url — a transient
    # parse failure must not pin the episode to sub-less playback for 24h.
    if [ -n "$server_url" ] && { [ -z "$manifest_url" ] || { [ -z "$sub_url" ] && [ "$sub_retried" != "1" ]; }; }; then
        [ -n "$manifest_url" ] && sub_retried=1
        local pair
        pair=$(curl -s --max-time 15 --connect-timeout 10 "$server_url" \
            -H "User-Agent: ${UA}" -H "Referer: ${KAA_BASE}/" 2>/dev/null | \
            SUBS_LANG="${subs_language:-english}" python3 -c "
import sys, json, re, urllib.parse, html as html_mod, os

def unwrap(v):
    if isinstance(v, list) and len(v) == 2:
        t, val = v
        if t == 0: return unwrap(val)
        if t == 1: return [unwrap(x) for x in val]
    if isinstance(v, dict):
        return {k: unwrap(v[k]) for k in v}
    return v

def fix_url(u):
    if not u: return ''
    u = u.replace('https:///', 'https://').replace('http:///', 'http://')
    if u.startswith('//'): u = 'https:' + u
    return u

pref = os.environ.get('SUBS_LANG', 'english').lower()
html = sys.stdin.read()
m = re.search(r'<astro-island[^>]*props=\"([^\"]+)\"', html)
if not m: sys.exit(0)
try:
    props = unwrap(json.loads(html_mod.unescape(urllib.parse.unquote(m.group(1)))))
    if isinstance(props, list) and props: props = props[0]
    manifest = fix_url(props.get('manifest', '') or '')
    subs = props.get('subtitles', [])
    if isinstance(subs, list) and subs and isinstance(subs[0], list): subs = subs[0]
    tracks = [(s.get('language',''), fix_url(s.get('src',''))) for s in subs if s.get('src')]
    pick = ''
    # exact/prefix language match ('en' vs 'english' etc.), then anything
    for lang, src in tracks:
        l = lang.lower()
        if l == pref or l.startswith(pref) or pref.startswith(l): pick = src; break
    if not pick:
        for lang, src in tracks:
            l = lang.lower()
            if pref in l or l in pref: pick = src; break
    if not pick and tracks: pick = tracks[0][1]
    print(manifest)
    print(pick)
except Exception: pass
" 2>/dev/null)
        # Keep the cached manifest when a sub-only retry fails to parse one.
        local new_manifest; new_manifest=$(echo "$pair" | sed -n '1p')
        [ -n "$new_manifest" ] && manifest_url="$new_manifest"
        [ -z "$sub_url" ] && sub_url=$(echo "$pair" | sed -n '2p')
        [ -n "$sub_url" ] && sub_retried=""
    fi
    [ -z "$manifest_url" ] && return 1

    {
        echo "manifest_url=${manifest_url}"
        echo "server_url=${server_url}"
        [ -n "$sub_url" ] && echo "sub_url=${sub_url}"
        [ "$sub_retried" = "1" ] && echo "sub_retried=1"
    } > "$ep_cache"

    # Quality master + local subtitle download in PARALLEL (the sub CDN
    # requires a Referer mpv will not send for --sub-file, so fetch locally).
    # mktemp-unique handoff files: two kaa dispatches (race + prefetch) must
    # never share a path and strand each other's temp files when killed.
    local sub_tmp master_tmp
    sub_tmp=$(mktemp /tmp/kaa_subdl_XXXXXX 2>/dev/null || echo "/tmp/kaa_subdl_$$")
    master_tmp=$(mktemp /tmp/kaa_masterres_XXXXXX 2>/dev/null || echo "/tmp/kaa_masterres_$$")
    : > "$sub_tmp"; : > "$master_tmp"
    local sub_pid="" master_pid=""
    if [ -n "$sub_url" ]; then
        local sub_base="/tmp/kaa_sub_$(echo -n "$manifest_url" | _md5 | cut -c1-12)"
        # The CDN mislabels extensions (.srt URL serving VTT content), so the
        # extension is decided from the CONTENT after download, not the URL.
        local sub_file=""
        local cand
        for cand in "${sub_base}.vtt" "${sub_base}.srt" "${sub_base}.ass"; do
            if [ -s "$cand" ] && [ $(($(date +%s) - $(_file_mtime "$cand"))) -le 86400 ]; then
                sub_file="$cand"; break
            fi
        done
        if [ -z "$sub_file" ]; then
            ( dl="${sub_base}.dl"
              curl -s --max-time 10 -H "Referer: ${KRUSS_BASE}/" -H "User-Agent: ${UA}" "$sub_url" -o "$dl" 2>/dev/null
              if [ -s "$dl" ]; then
                  if head -1 "$dl" | grep -q "WEBVTT"; then mv "$dl" "${sub_base}.vtt"
                  elif head -3 "$dl" | grep -q "^\[Script Info\]"; then mv "$dl" "${sub_base}.ass"
                  else mv "$dl" "${sub_base}.srt"; fi
              else rm -f "$dl"; fi ) &
            sub_pid=$!
        fi
        echo "$sub_base" > "$sub_tmp"
    fi
    ( _kaa_pick_quality_master "$manifest_url" "$quality" > "$master_tmp" 2>/dev/null ) &
    master_pid=$!

    [ -n "$sub_pid" ] && wait "$sub_pid" 2>/dev/null
    local sub_base=$(cat "$sub_tmp" 2>/dev/null) sub_file=""
    if [ -n "$sub_base" ]; then
        local cand
        for cand in "${sub_base}.vtt" "${sub_base}.srt" "${sub_base}.ass"; do
            [ -s "$cand" ] && sub_file="$cand" && break
        done
    fi
    wait "$master_pid" 2>/dev/null
    local local_master=$(cat "$master_tmp" 2>/dev/null)
    rm -f "$sub_tmp" "$master_tmp"

    local out
    if [ -n "$local_master" ]; then
        out="serve:${local_master}"
    else
        out="$manifest_url"
    fi
    [ -n "$sub_file" ] && out="$out
sub:${sub_file}"
    echo "$out" > "$out_cache"
    echo "$out"
}

# Hook (generic dispatch, Settings → Clear Cache): wipe every kaa cache so
# stale slugs/manifests never survive a cache clear — per-playback temp
# handoff files and legacy artifacts included.
provider_cache_clear() {
    rm -f /tmp/kaa_slug_* /tmp/kaa_epmap2_* \
          /tmp/kaa_ep3_* /tmp/kaa_stream_* /tmp/kaa_q_*.m3u8 \
          /tmp/kaa_sub_* /tmp/kaa_subdl_* /tmp/kaa_masterres_* \
          /tmp/kaa_variants_* /tmp/kaa_serve_url.txt \
          /tmp/kaa_ep_page.html /tmp/kaa_err.log /tmp/kaa_rss.xml 2>/dev/null
    return 0
}

# ── Quality selection: emit a local master.m3u8 ────────────────────

_kaa_pick_quality_master() {
    local manifest_url="$1" target="$2"
    local cache_key=$(echo "${manifest_url}|${target}" | _md5 | cut -c1-16)
    local out="/tmp/kaa_q_${cache_key}.m3u8"
    if [ -f "$out" ]; then
        local age=$(($(date +%s) - $(_file_mtime "$out")))
        if [ "$age" -lt 3600 ]; then
            echo "$out"
            return 0
        fi
    fi
    curl -s --max-time 15 --connect-timeout 10 "$manifest_url" -H "User-Agent: ${UA}" -H "Referer: ${KRUSS_BASE}/" | \
        MANIFEST_URL="$manifest_url" TARGET="$target" OUT="$out" UA="$UA" KRUSS_BASE="$KRUSS_BASE" python3 -c "
import sys, re, os, urllib.parse
content = sys.stdin.read()
manifest_url = os.environ['MANIFEST_URL']
target = os.environ['TARGET']
out_path = os.environ['OUT']
base = manifest_url.rsplit('/', 1)[0] + '/'

def abs_url(u):
    if u.startswith('//'): return 'https:' + u
    if u.startswith('http'): return u
    if u.startswith('/'): return urllib.parse.urljoin(manifest_url, u)
    return base + u

audio_lines = []
for m in re.finditer(r'#EXT-X-MEDIA:TYPE=AUDIO[^\n]*URI=\"([^\"]+)\"[^\n]*', content):
    line = m.group(0)
    line = re.sub(r'URI=\"[^\"]+\"', 'URI=\"' + abs_url(m.group(1)) + '\"', line)
    audio_lines.append(line)

variants = []
lines = content.splitlines()
i = 0
while i < len(lines):
    if lines[i].startswith('#EXT-X-STREAM-INF'):
        inf = lines[i]
        j = i + 1
        while j < len(lines) and (not lines[j].strip() or lines[j].startswith('#')):
            j += 1
        if j < len(lines):
            url = abs_url(lines[j].strip())
            rm = re.search(r'RESOLUTION=\d+x(\d+)', inf)
            res = int(rm.group(1)) if rm else 0
            variants.append((res, inf, url))
        i = j + 1
    else:
        i += 1

if not variants:
    sys.exit(1)

if target == 'best':
    chosen = max(variants, key=lambda v: v[0])
elif target == 'worst':
    chosen = min(variants, key=lambda v: v[0])
else:
    try: ti = int(target)
    except: ti = 1080
    chosen = min(variants, key=lambda v: abs(v[0] - ti))

res, inf, url = chosen
out = ['#EXTM3U', '#EXT-X-INDEPENDENT-SEGMENTS']
out.extend(audio_lines)
out.append(inf)
out.append(url)
with open(out_path, 'w') as f:
    f.write('\\n'.join(out) + '\\n')
" 2>/dev/null
    if [ -s "$out" ]; then
        echo "$out"
    else
        rm -f "$out"
    fi
}
