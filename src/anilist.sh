# ── AniList Auth + API ────────────────────────────────────────────

ANILIST_CLIENT_ID="46113"
ANILIST_CLIENT_SECRET="zD566sMbVAXTmipF0OZYM9VWb6LgL00wjnvlgWBw"
ANILIST_REDIRECT="http://localhost:8000/callback"
ANILIST_API="https://graphql.anilist.co"
TOKEN_FILE="$DATA_DIR/anilist_token.txt"
USERID_FILE="$DATA_DIR/anilist_user_id.txt"
USERNAME_FILE="$DATA_DIR/anilist_user_name.txt"

anilist_auth() {
    access_token=""; user_id=""; user_name=""
    [ -f "$TOKEN_FILE" ] && access_token=$(cat "$TOKEN_FILE")
    [ -f "$USERID_FILE" ] && user_id=$(cat "$USERID_FILE")
    [ -f "$USERNAME_FILE" ] && user_name=$(cat "$USERNAME_FILE")
    if [ -n "$access_token" ] && [ -n "$user_id" ]; then
        if [ -z "$user_name" ]; then
            local un=$(curl -s -X POST "$ANILIST_API" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $access_token" \
                -d '{"query":"query { Viewer { name } }"}' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1)
            [ -n "$un" ] && user_name="$un" && echo "$user_name" > "$USERNAME_FILE"
        fi
        return 0
    fi

    print_info "AniList authentication required"

    if command -v python3 &>/dev/null; then
        print_info "Opening browser..."
        _open_url "https://anilist.co/api/v2/oauth/authorize?client_id=${ANILIST_CLIENT_ID}&redirect_uri=${ANILIST_REDIRECT}&response_type=code" 2>/dev/null || true
        python3 -c '
import http.server, urllib.parse, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if "code" in q:
            open("/tmp/ani-cli_auth_code","w").write(q["code"][0])
            self.send_response(200); self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(400); self.end_headers()
try:
    s=http.server.HTTPServer(("127.0.0.1",8000),H); s.timeout=120; s.handle_request()
except: sys.exit(1)
' 2>/dev/null || true
        local code=""
        [ -f /tmp/ani-cli_auth_code ] && code=$(cat /tmp/ani-cli_auth_code) && rm -f /tmp/ani-cli_auth_code
        if [ -n "$code" ]; then
            local resp=$(curl -s -X POST "https://anilist.co/api/v2/oauth/token" \
                -d "grant_type=authorization_code" \
                -d "client_id=$ANILIST_CLIENT_ID" \
                -d "client_secret=$ANILIST_CLIENT_SECRET" \
                -d "redirect_uri=$ANILIST_REDIRECT" \
                -d "code=$code")
            access_token=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
        fi
    fi

    if [ -z "$access_token" ]; then
        echo ""
        print_warning "Auto-auth failed. Manual method:"
        echo " ${STYLE_MENU_TEXT}Open in browser:${R}"
        echo " ${STYLE_ANIME_INFO}https://anilist.co/api/v2/oauth/authorize?client_id=${ANILIST_CLIENT_ID}&response_type=token${R}"
        echo ""
        echo -n " ${STYLE_MENU_TEXT}Paste your access token: ${R}"
        read -r access_token || true
    fi

    [ -z "$access_token" ] && print_error "No token" && exit 1
    echo "$access_token" > "$TOKEN_FILE"

    local viewer_json=$(curl -s -X POST "$ANILIST_API" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $access_token" \
        -d '{"query":"query { Viewer { id name } }"}')
    user_id=$(echo "$viewer_json" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' | head -1 || true)
    user_name=$(echo "$viewer_json" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1 || true)

    if [ -z "$user_id" ]; then
        print_error "Bad token"
        exit 1
    fi
    echo "$user_id" > "$USERID_FILE"
    echo "$user_name" > "$USERNAME_FILE"
    print_success "Authenticated ($user_name)"
}

anilist_query() {
    local query="$1" vars="$2"
    local -a auth_hdr=()
    [ -n "$access_token" ] && auth_hdr=(-H "Authorization: Bearer $access_token")
    local body http_code attempt
    # Encode the GraphQL query once OUTSIDE the retry loop: a jq spawn per
    # attempt was pure waste (old code re-encoded on 429/503 retries).
    local jq_query
    jq_query=$(jq -Rs . <<< "$query")
    local payload="{\"query\":${jq_query},\"variables\":${vars}}"
    for attempt in 1 2 3; do
        body=$(curl -s --compressed --max-time 15 --connect-timeout 5 -w $'\n%{http_code}' -X POST "$ANILIST_API" \
            -H "Content-Type: application/json" \
            ${auth_hdr[@]+"${auth_hdr[@]}"} \
            -d "$payload")
        http_code="${body##*$'\n'}"
        body="${body%$'\n'*}"
        case "$http_code" in
            000|429|500|502|503|504)
                # 000 = curl transport failure (timeout/DNS/reset) — the old
                # code returned it instantly, which was the rare "search
                # fails once, works on retry" bug. Back off and retry.
                sleep $((attempt * 2))
                continue ;;
        esac
        break
    done
    echo "$body"
}

# Valid responses have a non-null .data and no .errors — anything else
# (rate-limit JSON, HTML error pages) must NEVER enter the cache, or the
# error gets replayed for the whole TTL ("search randomly not working").
_anilist_valid() {
    [ -n "$1" ] && echo "$1" | jq -e '.data and (.errors | not)' >/dev/null 2>&1
}

# ── Disk cache (per-user, /tmp) ───────────────────────────────────
# AniList GraphQL has ~1s server TTFB; caching makes repeat views instant.
# Writes (progress/status) invalidate the affected entries.

_anilist_cache_get() { # $1=key $2=ttl secs → content if fresh
    local f="/tmp/ani-cli_alcache_$1"
    if [ -s "$f" ]; then
        local age=$(( $(date +%s) - $(_file_mtime "$f") ))
        if [ "$age" -lt "$2" ]; then
            local content; content=$(cat "$f")
            if _anilist_valid "$content"; then
                echo "$content"
                return 0
            else
                # Cached data is invalid (rate-limited/error HTML) — delete and force refetch
                rm -f "$f"
            fi
        fi
    fi
    return 1
}

_anilist_cache_set() { # $1=key; json on stdin
    cat > "/tmp/ani-cli_alcache_$1"
}

# Drop details for one anime + all list caches (called after writes).
_anilist_cache_on_write() { # $1=mid
    rm -f "/tmp/ani-cli_alcache_details_$1" /tmp/ani-cli_alcache_lists_* 2>/dev/null
    # Re-warm the lists cache in the background so Continue Watching stays
    # instant after a progress write instead of paying a ~1s refetch.
    [ -n "${user_id:-}" ] && ( anilist_current_lists "$user_id" >/dev/null 2>&1 ) &
    return 0
}

anilist_search() {
    local q="$1"
    local key="search_$(echo -n "$q" | _md5 | cut -c1-16)"
    local ttl=$((600 + RANDOM % 120 - 60))  # 540-660s jitter (OPT-5)
    _anilist_cache_get "$key" "$ttl" && return 0
    local query='query ($s: String) { Page(page: 1, perPage: 25) { media(search: $s, type: ANIME, sort: SEARCH_MATCH) { id title { userPreferred } format episodes status seasonYear coverImage { large } meanScore genres nextAiringEpisode { episode } } } }'
    local vars; vars=$(jq -n --arg s "$q" '{s:$s}' 2>/dev/null) || vars='{"s":""}'
    local out; out=$(anilist_query "$query" "$vars")
    _anilist_valid "$out" && echo "$out" | _anilist_cache_set "$key"
    echo "$out"
}

# CURRENT + REPEATING entries in a single request.
# NOTE: status_in takes the MediaListStatus ENUM — a String variable
# fails GraphQL validation and silently returns no data.
anilist_current_lists() {
    local uid="$1"
    local key="lists_${uid}"
    _anilist_cache_get "$key" 600 && return 0
    # Extended query with nextAiringEpisode, idMal, and mediaListEntry for OPT-4
    local query='query ($uid: Int, $s: [MediaListStatus]) { MediaListCollection (userId: $uid, type: ANIME, status_in: $s) { lists { entries { mediaId status score progress updatedAt media { id idMal title { userPreferred } episodes format nextAiringEpisode { episode airingAt } mediaListEntry { status progress } } } } } }'
    local out; out=$(anilist_query "$query" "{\"uid\":$uid,\"s\":[\"CURRENT\",\"REPEATING\"]}")
    _anilist_valid "$out" && echo "$out" | _anilist_cache_set "$key"
    echo "$out"
}

anilist_current_season() {
    local year=$(date +%Y) season="SPRING" m=$((10#$(date +%m)))
    case $m in 1|2|3) season="WINTER" ;; 4|5|6) season="SPRING" ;; 7|8|9) season="SUMMER" ;; 10|11|12) season="FALL" ;; esac
    local query='query ($s: MediaSeason, $y: Int) { Page(page: 1, perPage: 30) { media(season: $s, seasonYear: $y, type: ANIME, sort: POPULARITY_DESC) { id title { userPreferred } format episodes status coverImage { large } meanScore genres studios(isMain: true) { nodes { name } } } } }'
    anilist_query "$query" "{\"s\":\"$season\",\"y\":$year}"
}

anilist_all_time_popular() {
    local query='query { Page(page: 1, perPage: 30) { media(type: ANIME, sort: POPULARITY_DESC) { id title { userPreferred } format episodes status coverImage { large } meanScore genres studios(isMain: true) { nodes { name } } } } }'
    anilist_query "$query" "{}"
}

# Cached variants (10 min in /tmp) — popular lists barely change and
# should feel instant.
anilist_current_season_cached()    { _anilist_cached "/tmp/ani-cli_pop_season" 600 anilist_current_season; }
anilist_all_time_popular_cached()  { _anilist_cached "/tmp/ani-cli_pop_alltime" 600 anilist_all_time_popular; }

_anilist_cached() { # $1=cache file $2=max age secs $3=function
    local f="$1" age="$2" fn="$3"
    if [ -f "$f" ] && [ -n "$(find "$f" -mmin -$((age / 60)) 2>/dev/null)" ] && [ -s "$f" ]; then
        cat "$f"; return
    fi
    local out; out=$($fn)
    _anilist_valid "$out" && echo "$out" > "$f"
    echo "$out"
}

anilist_update_progress() {
    [ "$anilist_sync" != "true" ] && return 0
    local media_id="$1" progress="$2" status="${3:-CURRENT}"
    local query='mutation ($mid: Int, $p: Int, $s: MediaListStatus) { SaveMediaListEntry (mediaId: $mid, progress: $p, status: $s) { id mediaId progress status } }'
    local out; out=$(anilist_query "$query" "{\"mid\":$media_id,\"p\":$progress,\"s\":\"$status\"}")
    _anilist_valid "$out" || { echo "$out" >&2; return 1; }
    _anilist_cache_on_write "$media_id"
    echo "$out"
}

anilist_set_status() {
    [ "$anilist_sync" != "true" ] && return 0
    local media_id="$1" status="$2"
    local query='mutation ($mid: Int, $s: MediaListStatus) { SaveMediaListEntry (mediaId: $mid, status: $s) { id mediaId status } }'
    local out; out=$(anilist_query "$query" "{\"mid\":$media_id,\"s\":\"$status\"}")
    _anilist_valid "$out" || { echo "$out" >&2; return 1; }
    _anilist_cache_on_write "$media_id"
    echo "$out"
}

# Entry for one anime on the user's list + MAL id (for skip-times).
# Output: "status<TAB>progress<TAB>idMal" (status empty when not on list).
# IMPORTANT (BUG: aniskip "doesn't work"): mediaListEntry requires the OAuth
# token, but this output ALSO feeds status/progress to tracking.sed. To keep
# calls cheap AND correct we split the reshape across two sources:
#   - Floor: read idMal + list status from the public, 30-min-cached
#     anilist_media_details (no auth dependency — aniskip works signed or not).
#   - Fresh list snapshot: still query mediaListEntry when authed (it changes
#     as the user watches). Non-auth clients skip that round-trip.
anilist_media_entry() {
    local media_id="$1"
    local details="" entry=""
    details=$(anilist_media_details "$media_id" 2>/dev/null)
    # Fresh auth-only list status overlay (skipped entirely when unauthenticated,
    # so skip-times work for logged-out users too).
    if [ -n "$access_token" ]; then
        entry=$(anilist_query 'query ($id: Int) { Media (id: $id) { mediaListEntry { status progress } } }' "{\"id\":$media_id}" 2>/dev/null)
    fi
    ANILIST_DETAILS="$details" ANILIST_ENTRY="$entry" python3 - <<'PYEOF' 2>/dev/null
import sys, json, os
status = ''
progress = 0
mal = ''
try:
    d = json.loads(os.environ.get('ANILIST_DETAILS', '') or '{}')
    m = d.get('data', {}).get('Media', {}) or {}
    mal = m.get('idMal') or ''
    e = m.get('mediaListEntry') or {}
    if e:
        status = e.get('status') or ''
        progress = e.get('progress') or 0
except Exception:
    pass
try:
    d2 = json.loads(os.environ.get('ANILIST_ENTRY', '') or '{}')
    e2 = (d2.get('data', {}).get('Media', {}) or {}).get('mediaListEntry') or {}
    if e2:
        status = e2.get('status') or status
        progress = e2.get('progress') or progress
except Exception:
    pass
print(f"{status}\t{progress}\t{mal}")
PYEOF
}

anilist_media_details() {
    local media_id="$1"
    local key="details_${media_id}"
    _anilist_cache_get "$key" 3600 && return 0
    local query='query ($id: Int) { Media (id: $id) { id idMal title { userPreferred } format episodes duration status seasonYear season meanScore genres studios(isMain: true) { nodes { name } } startDate { year month day } description (asHtml: false) nextAiringEpisode { episode airingAt } mediaListEntry { status progress } } }'
    local out; out=$(anilist_query "$query" "{\"id\":$media_id}")
    _anilist_valid "$out" && echo "$out" | _anilist_cache_set "$key"
    echo "$out"
}

# Warm the home-screen caches in the background so Continue Watching /
# Popular open instantly. Called once after auth in interactive mode.
anilist_prefetch_home() {
    ( anilist_current_lists "$user_id" >/dev/null 2>&1 ) &
    ( anilist_current_season_cached >/dev/null 2>&1 ) &
    ( anilist_all_time_popular_cached >/dev/null 2>&1 ) &
}

# Cumulative episode offset for multi-season anime: sums the episode
# counts of the whole PREQUEL chain (e.g. AoT S4 → 25+12+12+10 = 59,
# so S4 ep 1 = absolute ep 60 in cumulative batch torrents).
# Single-entry shows (One Piece etc.) → 0. Cached 24h in /tmp.
anilist_prequel_offset() {
    local mid="$1"
    [[ "$mid" =~ ^[0-9]+$ ]] || { echo 0; return; }
    [ "$mid" = "0" ] && { echo 0; return; }
    local cache="/tmp/ani-cli_offset_${mid}"
    if [ -f "$cache" ] && [ -n "$(find "$cache" -mtime -1 2>/dev/null)" ]; then
        cat "$cache"; return
    fi
    local offset=0 cur="$mid" depth=0
    local query='query ($id: Int) { Media (id: $id) { relations { edges { relationType node { id episodes status format } } } } }'
    while [ $depth -lt 6 ]; do
        local resp
        resp=$(anilist_query "$query" "{\"id\":$cur}" 2>/dev/null)
        local preq
        preq=$(echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    edges = (d.get('data', {}).get('Media', {}) or {}).get('relations', {}).get('edges', [])
    # follow only main-series (TV) prequels — OVAs/specials/movies are
    # also typed PREQUEL by AniList but are not season content
    best = None
    for e in edges:
        if e.get('relationType') != 'PREQUEL':
            continue
        n = e.get('node', {}) or {}
        if n.get('format') != 'TV':
            continue
        eps = n.get('episodes')
        if eps and n.get('status') != 'NOT_YET_RELEASED':
            best = (n.get('id'), eps)
            break
    if best:
        print(f'{best[0]} {best[1]}')
except Exception:
    pass
" 2>/dev/null)
        [ -z "$preq" ] && break
        local pid peps
        pid=$(echo "$preq" | cut -d' ' -f1)
        peps=$(echo "$preq" | cut -d' ' -f2)
        [[ "$pid" =~ ^[0-9]+$ ]] || break
        [[ "$peps" =~ ^[0-9]+$ ]] || peps=0
        offset=$((offset + peps))
        cur="$pid"
        depth=$((depth + 1))
    done
    echo "$offset" | tee "$cache"
}

# ── Parsers ───────────────────────────────────────────────────────

parse_search_results() {
    echo "$1" | python3 -c "
import sys, json
d = json.load(sys.stdin)
out = []
for m in d.get('data',{}).get('Page',{}).get('media',[]):
    t = m.get('title',{}).get('userPreferred','?')
    y = m.get('seasonYear','?')
    e = m.get('episodes','?') or '?'
    out.append(f\"{m['id']}\t{t} ({y}, {e} eps)\")
print('\n'.join(out))
" 2>/dev/null || return
}

parse_user_list() {
    local json="$1"
    echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
out = []
for lst in d.get('data',{}).get('MediaListCollection',{}).get('lists',[]):
    for e in lst.get('entries',[]):
        m = e.get('media',{})
        nx = m.get('nextAiringEpisode',{}) or {}
        entry = m.get('mediaListEntry',{}) or {}
        out.append(f\"{e['mediaId']}\t{m.get('title',{}).get('userPreferred','?')} ({m.get('seasonYear','?')})\t{e.get('progress',0)}/{m.get('episodes','?')}\t{e.get('status','')}\t{e.get('score',0)}\t{e.get('updatedAt',0) or 0}\t{nx.get('episode','')}\t{nx.get('airingAt','')}\t{m.get('idMal','')}\t{entry.get('status','')}\t{entry.get('progress',0)}\")
print('\\n'.join(out))
" 2>/dev/null || return
}

parse_seasonal() {
    echo "$1" | python3 -c "
import sys, json
d = json.load(sys.stdin)
out = []
for m in d.get('data',{}).get('Page',{}).get('media',[]):
    t = m.get('title',{}).get('userPreferred','?')
    s = m.get('meanScore','?') or '?'
    g = ', '.join(m.get('genres',[]) or [])[:40]
    ep = m.get('episodes','?') or '?'
    sn = ''
    for n in m.get('studios',{}).get('nodes',[]):
        sn = n.get('name','')
    out.append(f\"{m['id']}\t{t}\t{ep}pep\ts{s}\t{g}\t{sn}\")
print('\n'.join(out))
" 2>/dev/null || return
}

parse_media_details() {
    echo "$1" | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
m = d.get('data',{}).get('Media',{})
if not m:
    exit()

def cln(s, mx=0):
    s = str(s) if s is not None else ''
    s = re.sub(r'<[^>]+>', '', s)
    s = s.replace('\t',' ').replace('\n',' ').replace('\r',' ')
    s = re.sub(r'\s+', ' ', s).strip()
    if mx and len(s) > mx:
        s = s[:mx] + '…'
    return s

t = cln(m.get('title',{}).get('userPreferred','?'))
g = cln(', '.join(m.get('genres',[]) or []))
rt = cln(m.get('meanScore','?') or '?')
ep = cln(m.get('episodes','?') or '?')
dur = cln(m.get('duration','?') or '?')
st = cln(m.get('status','?'))
yr = cln(m.get('seasonYear','?') or '?')
sn = ''
for n in m.get('studios',{}).get('nodes',[]):
    sn = n.get('name','')
sn = cln(sn)
desc = cln(m.get('description',''), 1000)
fmt = cln(m.get('format','?'))
season = cln(m.get('season','?'))
sd = m.get('startDate',{}) or {}
sd_str = f\"{sd.get('year','?')}-{sd.get('month','?')}-{sd.get('day','?')}\" if sd.get('year') else ''
nx = m.get('nextAiringEpisode',{}) or {}
nx_ep = nx.get('episode', '')
nx_at = nx.get('airingAt', '')
mal = m.get('idMal') or ''
entry = m.get('mediaListEntry') or {}
e_st = entry.get('status','') or ''
e_pr = entry.get('progress',0) or 0
print(f'{t}\t{g}\t{rt}\t{ep}\t{dur}\t{st}\t{yr}\t{sn}\t{desc}\t{fmt}\t{season}\t{sd_str}\t{nx_ep}\t{nx_at}\t{mal}\t{e_st}\t{e_pr}')
" 2>/dev/null || return
}
