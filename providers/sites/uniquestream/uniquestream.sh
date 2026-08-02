# UniqueStream (anime.uniquestream.net) provider
# Ultra high-res HLS streaming with hard-subbed multi-language support.

# Portable helpers when sourced standalone (the app preloads these).
command -v _file_mtime >/dev/null 2>&1 || \
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/common.sh" 2>/dev/null || true

PROVIDER_NAME="UniqueStream"
PROVIDER_HEADERS=("Referer: https://anime.uniquestream.net" "Origin: https://anime.uniquestream.net")
PROVIDER_LAVF_OPTS=""
UNI_BASE="https://anime.uniquestream.net"
ANILIST_API="https://graphql.anilist.co"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"

UNI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNI_PY="${UNI_PY:-$UNI_DIR/uniquestream_provider.py}"

UNI_TITLE_CACHE="/tmp/uni_title_cache.txt"
UNI_CACHE_DIR="/tmp/uni_cache"
UNI_ANILIST_CACHE="/tmp/uni_anilist_cache.txt"
UNI_CACHE_TTL=604800   # 7 days — these were PERMANENT, so one bad mapping poisoned the show forever
mkdir -p "$UNI_CACHE_DIR" 2>/dev/null

# Append a key|value mapping with a timestamp.
_uni_cache_put() { # $1=file $2=key $3=value
    local now
    printf -v now '%(%s)T' -1 2>/dev/null || now=$(date +%s)
    printf '%s|%s|%s\n' "$2" "$3" "$now" >> "$1"
}

# Look up a FRESH mapping (7d TTL; legacy lines without a timestamp are
# treated as stale and re-resolved). Pure-bash: one file read, no subshell
# chain (was grep+tail+cut+cut+date = ~5 process spawns per call).
_uni_cache_get() { # $1=file $2=plain-key (NOT a regex)
    local key="$2" line="" _l val ts now klen
    [ -f "$1" ] || return 1
    klen=${#key}
    # Take the LAST matching line (newest) — pure-bash scan, prefix match
    # via substring (case would treat [ and * in the key as globs).
    while IFS= read -r _l; do
        [ "${_l:0:klen}" = "$key" ] && [ "${_l:klen:1}" = "|" ] && line="$_l"
    done < "$1"
    [ -z "$line" ] && return 1
    # key|value|timestamp
    val="${line#*|}"; ts="${val##*|}"; val="${val%|*}"
    [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    printf -v now '%(%s)T' -1 2>/dev/null || now=$(date +%s)
    [ $((now - ts)) -lt "$UNI_CACHE_TTL" ] && printf '%s' "$val" && return 0
    return 1
}

_uni_norm() {
    # Pure-bash: strip + normalize × → x (bash glob handles the multibyte char).
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # lstrip
    s="${s%"${s##*[![:space:]]}"}"   # rstrip
    s="${s//×/x}"
    printf '%s' "$s"
}

_uni_urlenc() {
    # jq @uri is ~11x faster than a python spawn (5.6ms vs 61.6ms) and jq is
    # already a hard dependency. Normalize first, then let jq handle quoting.
    local s=$(_uni_norm "$1")
    printf '%s' "$s" | jq -sRr @uri
}

_uni_fetch_series() {
    local id="$1"
    local cache="$UNI_CACHE_DIR/series_${id}.json"
    if [ -f "$cache" ]; then
        local age=$(($(date +%s) - $(_file_mtime "$cache")))
        [ "$age" -lt 86400 ] && { cat "$cache"; return 0; }
    fi
    local data=$(curl -s --max-time 25 --connect-timeout 10 "${UNI_BASE}/api/v1/series/${id}" -H "User-Agent: ${UA}" 2>/dev/null)
    # jq validity probe (was a python spawn on every cold series fetch).
    if [ -n "$data" ] && echo "$data" | jq -e '.title' >/dev/null 2>&1; then
        echo "$data" > "$cache" 2>/dev/null
        echo "$data"
        return 0
    fi
    return 1
}

_uni_fetch_anilist_media() {
    local alid="$1"
    # Reuse the app's own AniList details cache first (same fields, saves a
    # full GraphQL round-trip on the cold path).
    local app_cache="/tmp/ani-cli_alcache_details_${alid}"
    if [ -f "$app_cache" ]; then
        local aage=$(($(date +%s) - $(_file_mtime "$app_cache")))
        if [ "$aage" -lt 1800 ] && grep -q '"idMal"' "$app_cache" 2>/dev/null; then
            cat "$app_cache"; return 0
        fi
    fi
    local cache="$UNI_CACHE_DIR/anilist_${alid}.json"
    if [ -f "$cache" ]; then
        local age=$(($(date +%s) - $(_file_mtime "$cache")))
        if [ "$age" -lt 86400 ]; then
            local cached; cached=$(cat "$cache")
            # Replay only valid responses — a transient API outage body
            # (e.g. AniList's "temporarily disabled" error JSON) used to be
            # cached for 24h and replayed as if it were real data.
            if printf '%s' "$cached" | jq -e '.data.Media.id' >/dev/null 2>&1; then
                printf '%s' "$cached"
                return 0
            fi
            rm -f "$cache"
        fi
    fi
    local q='{"query":"query($id:Int){Media(id:$id){id idMal title{romaji english userPreferred} episodes season seasonYear format}}","variables":{"id":'${alid}'}}'
    local data=$(curl -s --max-time 15 --connect-timeout 10 "$ANILIST_API" -H "Content-Type: application/json" -H "Accept: application/json" -d "$q" 2>/dev/null)
    if [ -n "$data" ] && printf '%s' "$data" | jq -e '.data.Media.id' >/dev/null 2>&1; then
        echo "$data" > "$cache"
        echo "$data"
        return 0
    fi
    return 1
}

# ── Provider interface ─────────────────────────────────────────────

provider_search() {
    local query="$1"
    local encoded=$(_uni_urlenc "$query")
    curl -s --max-time 25 --connect-timeout 10 "${UNI_BASE}/api/v1/search?query=${encoded}&t=all&limit=15&suggest=1" \
        -H "User-Agent: ${UA}" 2>/dev/null | python3 -c "
import sys, json, os, time
try:
    data = json.load(sys.stdin)
    cache_file = os.environ.get('UNI_TITLE_CACHE', '/tmp/uni_title_cache.txt')
    seen = set()
    for key in ('series', 'movies', 'suggestions'):
        for item in data.get(key) or []:
            cid = item.get('content_id', '')
            if cid and cid not in seen:
                seen.add(cid)
                title = item.get('title', '')
                year = str(item.get('year', '') or '')
                eps = str(item.get('episodes_total', '') or item.get('episodes_count', '') or ('1' if key == 'movies' else ''))
                print(f'{cid}\\t{title}\\t{year}\\t{eps}')
                # timestamped — _uni_cache_get treats ts-less lines as stale
                with open(cache_file, 'a') as f:
                    f.write(f'{title}|{cid}|{int(time.time())}\\n')
except: pass
" 2>/dev/null
}

provider_get_stream() {
    local anilist_id="$1" ep_num="$2" quality="$3" title="$4"
    [ -z "$quality" ] && quality="1080"
    local content_id=""
    local anilist_media=""
    local id_mal=""
    local base_title="$title"

    # Fetch AniList media info once (for base title + MAL ID).
    # jq replaces the old python spawn + two sed greps — one ~6ms call
    # instead of ~60+2ms worth of process starts.
    anilist_media=$(_uni_fetch_anilist_media "$anilist_id")
    if [ -n "$anilist_media" ]; then
        local mal_part base_part
        mal_part=$(echo "$anilist_media" | jq -r '.data.Media.idMal // empty' 2>/dev/null)
        base_part=$(echo "$anilist_media" | jq -r '
            .data.Media.title
            | (.english // .userPreferred // .romaji // "")
            | gsub("\\s+(?i:Season|Part|Cour)\\s+\\d+.*$"; "")
            | gsub("\\s+(?i:Final Season).*$"; "")
            | gsub("\\s+[IVXLCDM]+\\s*:\\s*"; " ")
            | gsub("\\s+"; " ")
            | sub("^ "; "") | sub(" $"; "")
        ' 2>/dev/null)
        [ -n "$mal_part" ] && id_mal="$mal_part"
        [ -n "$base_part" ] && [ "$base_part" != "null" ] && base_title="$base_part"
    fi

    # Resolve content_id from AniList ID cache (7d TTL)
    local cached_al=$(_uni_cache_get "$UNI_ANILIST_CACHE" "$anilist_id")
    if [ -n "$cached_al" ]; then
        content_id="$cached_al"
    fi

    # Resolve content_id from title cache or search (use base series title)
    if [ -z "$content_id" ]; then
        # Plain-key lookup (no regex escaping needed — bash prefix compare).
        local cached=$(_uni_cache_get "$UNI_TITLE_CACHE" "$title")
        if [ -n "$cached" ]; then
            content_id="$cached"
        else
            local encoded=$(_uni_urlenc "$base_title" 2>/dev/null)
            [ -z "$encoded" ] && return 1
            content_id=$(curl -s --max-time 25 --connect-timeout 10 "${UNI_BASE}/api/v1/search?query=${encoded}&t=all&limit=5&suggest=1" \
                -H "User-Agent: ${UA}" 2>/dev/null | Q_NORM="$(_uni_norm "$base_title" 2>/dev/null)" python3 -c "
import sys, json, os
try:
    data = json.load(sys.stdin)
    q = os.environ.get('Q_NORM', '').lower().strip()
    skip_keywords = ['movies', 'compilation', 'recap', 'junior high', 'special', 'oad', 'ova']
    # Prefer exact title match in series
    for key in ('series', 'suggestions'):
        for item in data.get(key) or []:
            it = (item.get('title','') or '').lower().strip()
            if it == q:
                cid = item.get('content_id', '')
                if cid: print(cid); raise SystemExit(0)
    # Fallback: first series entry that doesn't look like a spin-off
    for item in data.get('series') or []:
        cid = item.get('content_id', '')
        if not cid: continue
        tl = (item.get('title','') or '').lower()
        if any(kw in tl for kw in skip_keywords): continue
        print(cid); raise SystemExit(0)
    # Fallback: suggestions without keywords.
    # (No last-resort anything fallback: a wild guess resolves the WRONG
    # show and the permanent cache used to make it stick. Better to
    # decline and let the provider race fall back to the other site.)
    for item in data.get('suggestions') or []:
        tl = (item.get('title','') or '').lower()
        if any(kw in tl for kw in skip_keywords): continue
        cid = item.get('content_id', '')
        if cid: print(cid); raise SystemExit(0)
except: pass
" 2>/dev/null)
            if [ -n "$content_id" ]; then
                _uni_cache_put "$UNI_TITLE_CACHE" "${title}" "${content_id}"
                _uni_cache_put "$UNI_ANILIST_CACHE" "${anilist_id}" "${content_id}"
            fi
        fi
    fi
    [ -z "$content_id" ] && return 1

    local series=$(_uni_fetch_series "$content_id")
    [ -z "$series" ] && return 1

    local ep_num_int=$(printf "%.0f" "$ep_num" 2>/dev/null || echo "$ep_num")
    local sub_or_dub="${sub_or_dub:-sub}"

    # Resolved-stream cache: skips season/episode/dash round-trips.
    # TTL is bounded by the playlist URL's own `expires=` signature (~6h) —
    # replaying an expired signed URL is a cache-poisoning playback failure,
    # so the cache dies 10 min before the signature does (24h hard cap).
    local stream_cache="$UNI_CACHE_DIR/stream_${anilist_id}_${ep_num_int}_${quality}_${sub_or_dub}"
    if [ -f "$stream_cache" ]; then
        local age=$(($(date +%s) - $(_file_mtime "$stream_cache")))
        if [ "$age" -lt 86400 ]; then
            local sf=$(head -1 "$stream_cache" 2>/dev/null | sed 's/^serve://')
            if [ -n "$sf" ] && [ -f "$sf" ]; then
                local exp=""
                exp=$(sed -n '1s/.*[?&]expires=\([0-9][0-9]*\).*/\1/p' "$sf" 2>/dev/null | head -1)
                if [[ "$exp" =~ ^[0-9]+$ ]]; then
                    [ "$(date +%s)" -lt $((exp - 600)) ] && { cat "$stream_cache"; return 0; }
                else
                    [ "$age" -lt 10800 ] && { cat "$stream_cache"; return 0; }
                fi
            fi
        fi
    fi

    # Season/episode/dash resolution lives in the companion .py (debuggable
    # standalone, no bash heredoc escaping). Same argv/env interface as the
    # old embedded block.
    local stream_out
    stream_out=$(echo "$series" | \
    TITLE="$title" UNI_BASE="$UNI_BASE" UA="$UA" EP_NUM="$ep_num_int" \
    SUB_OR_DUB="$sub_or_dub" ID_MAL="$id_mal" QUALITY="$quality" AID="$anilist_id" \
    SUBS_LANG="${subs_language:-english}" python3 "$UNI_PY" 2>/dev/null)
    if [ -n "$stream_out" ]; then
        echo "$stream_out" > "$stream_cache" 2>/dev/null
        echo "$stream_out"
    fi
}

# Optional hook (called generically by core after playback): drop old
# one-shot playlist handoff files. Caches stay for instant replays.
# (find -maxdepth is GNU-only — this glob loop works on macOS/BSD too.)
provider_cleanup() {
    local f
    for f in /tmp/*_uni_url.txt; do
        [ -f "$f" ] || continue
        if [ $(( $(date +%s) - $(_file_mtime "$f") )) -gt 7200 ]; then
            rm -f "$f" 2>/dev/null
        fi
    done
    return 0
}

# Hook (generic dispatch, Settings → Clear Cache): wipe all uni caches.
provider_cache_clear() {
    rm -rf /tmp/uni_cache 2>/dev/null
    rm -f /tmp/uni_title_cache.txt /tmp/uni_anilist_cache.txt \
          /tmp/uniquestream_serve_url.txt /tmp/*_uni_url.txt 2>/dev/null
    return 0
}
