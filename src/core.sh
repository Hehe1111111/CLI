# ── Core: streaming, torrent, screens ────────────────────────────

MPV_EXTRA_ARGS=()
AUTOPLAYING=false

# Portable file mtime (from providers/common.sh)
source "${BASH_SOURCE[0]%/*}/../providers/common.sh" 2>/dev/null || true

# ── Shared playback helpers ───────────────────────────────────────

# Read one key with timeout; returns 0 and sets $KEY if a key was hit.
# When stdin is not a tty (piped/redirected), read returns instantly at
# EOF — sleep instead, or every esc-poll loop spins at 100% CPU and its
# timeout accounting collapses.
_read_key() { # $1=timeout
    KEY=""
    if [ -t 0 ]; then
        read -s -t "$1" -n 1 KEY 2>/dev/null
    else
        sleep "$1" 2>/dev/null
    fi
}

# Returns 0 if the key in $KEY is a lone ESC (drains escape sequences).
_key_is_esc() {
    [ "$KEY" = $'\e' ] || return 1
    local rest=""
    read -s -t 0.05 -n 2 rest 2>/dev/null || true
    [ -z "$rest" ]
}

# Wait for a background job while polling keys; esc kills the job tree.
# Returns 0 when the job finished, 2 when aborted with esc.
_bg_wait_esc() { # $1=pid
    local pid="$1"
    while kill -0 "$pid" 2>/dev/null; do
        if _read_key 0.2 && _key_is_esc; then
            _kill_tree "$pid"
            wait "$pid" 2>/dev/null
            return 2
        fi
    done
    wait "$pid" 2>/dev/null
    return 0
}

# ── OP/ED skip prefetch (runs in parallel with provider lookup) ───

SKIP_PREFETCH_PID=""
SKIP_PREFETCH_OUT=""

_start_skip_prefetch() { # $1=mid $2=ep
    SKIP_PREFETCH_OUT="/tmp/ani-cli_skiplua_$$"
    SKIP_PREFETCH_PID=""
    : > "$SKIP_PREFETCH_OUT"
    if [ "$1" != "0" ] && [ "$skip_opening" = "true" ]; then
        ( aniskip_lua "$1" "$2" > "$SKIP_PREFETCH_OUT" 2>/dev/null ) &
        SKIP_PREFETCH_PID=$!
    fi
}

_await_skip_prefetch() { # → echoes lua path or ""
    if [ -n "$SKIP_PREFETCH_PID" ]; then
        # Cap the wait: OP/ED skip is nice-to-have and must never stall
        # playback start (AniSkip can take seconds on a cold connection).
        # Increased from 15s to 20s for better reliability (BUG-5)
        local deadline=$((SECONDS + 20))
        while kill -0 "$SKIP_PREFETCH_PID" 2>/dev/null; do
            [ $SECONDS -ge $deadline ] && break
            sleep 0.1 2>/dev/null || sleep 1
        done
        if kill -0 "$SKIP_PREFETCH_PID" 2>/dev/null; then
            # Timed out — leave the job running (its lua cache write makes
            # the NEXT episode instant) and play without skip this time.
            SKIP_PREFETCH_PID=""
            SKIP_PREFETCH_OUT=""
            return 0
        fi
        wait "$SKIP_PREFETCH_PID" 2>/dev/null
        SKIP_PREFETCH_PID=""
    fi
    [ -n "$SKIP_PREFETCH_OUT" ] && head -1 "$SKIP_PREFETCH_OUT" 2>/dev/null
    rm -f "$SKIP_PREFETCH_OUT"
}

# 10s autoplay countdown (replaces the "Playing" line).
# Returns 0 to play next, 1 to stop.
autoplay_countdown() { # $1=next ep number
    local i
    printf '\033[1A\r\033[K' >&2   # erase the "Playing Episode N" line
    for i in 10 9 8 7 6 5 4 3 2 1; do
        echo -ne "\r${STYLE_INFO}Autoplaying Ep $1 in ${i}s ${STYLE_MUTED}(esc to cancel)${R}\033[K" >&2
        if _read_key 1; then
            if _key_is_esc; then
                echo "" >&2
                return 1
            fi
            echo "" >&2
            return 0   # any other key = play now
        fi
    done
    echo "" >&2
    return 0
}

# Play one episode with the chosen method, then handle tracking.
# Returns: 0 = played, 1 = failed, 2 = aborted by user (esc)
play_one() { # $1=mid $2=title $3=ep $4=total $5=method(stream|torrent)
    local mid="$1" title="$2" ep="$3" total="$4" method="$5"
    # Normalize episode input (CLI accepts "08"; $((08+1)) is an octal error)
    [[ "$ep" =~ ^[0-9]+$ ]] || return 1
    ep=$((10#$ep))
    ANIME_TOTAL_EPS="$total"
    [[ "$ANIME_TOTAL_EPS" =~ ^[0-9]+$ ]] || ANIME_TOTAL_EPS=0

    clear_screen; print_logo
    print_anime_title "$title - Episode $ep"
    echo ""

    # Last-watched stamp (drives Continue Watching ordering) — cheap, local.
    [ "$mid" != "0" ] && [ -n "${LAST_WATCHED_DIR:-}" ] && \
        date +%s > "$LAST_WATCHED_DIR/$mid" 2>/dev/null
    # AniList status transition off the critical path (a ~0.5s GraphQL call
    # must not delay playback start).
    # Prime media entry cache for skip prefetch + status tracking
    [ "$mid" != "0" ] && media_entry "$mid" >/dev/null 2>&1 || true
    ( watch_mark_started "$mid" &>/dev/null ) &
    _start_skip_prefetch "$mid" "$ep"

    local rc=0
    if [ "$method" = "torrent" ]; then
        _play_one_torrent "$mid" "$title" "$ep" || rc=$?
    else
        _play_one_stream "$mid" "$title" "$ep" || rc=$?
    fi
    # aborted/failed before playback → stop the skip prefetch too
    if [ $rc -ne 0 ] && [ -n "$SKIP_PREFETCH_PID" ]; then
        kill "$SKIP_PREFETCH_PID" 2>/dev/null
        wait "$SKIP_PREFETCH_PID" 2>/dev/null
        SKIP_PREFETCH_PID=""
        rm -f "$SKIP_PREFETCH_OUT"
    fi
    return $rc
}

# Full play session: play ep, autoplay next, esc drops back to ep list.
play_loop() { # $1=mid $2=title $3=start ep $4=total $5=method
    local mid="$1" title="$2" ep="$3" total="$4" method="$5"
    [[ "$ep" =~ ^[0-9]+$ ]] || return 1
    ep=$((10#$ep))
    while true; do
        play_one "$mid" "$title" "$ep" "$total" "$method"
        local rc=$?
        [ $rc -eq 2 ] && return 0          # esc during buffering → back to list
        [ $rc -ne 0 ] && return 1          # failure → back to list
        if [[ "$total" =~ ^[0-9]+$ ]] && [ "$ep" -ge "$total" ]; then
            print_success "Completed: $title"
            sleep 1
            return 0
        fi
        local next=$((ep + 1))
        # Seamless autoplay: prepare ep N+1 DURING the countdown — the
        # torrent engine starts buffering / the stream proxy pre-starts.
        _prep_start "$mid" "$title" "$next" "$method"
        # Consolidated prefetch for all methods (OPT-2)
        _prefetch_next_episode "$mid" "$title" "$ep" "$method" "$provider"
        autoplay_countdown "$next" || { _prep_cancel "$next"; return 0; }
        AUTOPLAYING=true   # later episodes reuse the same choices, no re-picking
        ep=$next
    done
}

# ── Next-episode prefetch (runs during current playback) ─────────

# Resolve the next episode's stream URL in the background so autoplay
# starts instantly. serve: artifacts are files in /tmp — still valid at
# play time.
_prefetch_next_stream() { # $1=mid $2=title $3=current ep $4=provider
    # NOTE: `next` must be computed in a SEPARATE statement — in
    # `local ep="$3" next=$((ep+1))` the arithmetic expands BEFORE ep is
    # assigned, which read an unbound variable under `set -u` and crashed
    # the whole app from the episode screen.
    local mid="$1" title="$2" ep="$3" prov="$4"
    local next=$((ep + 1))
    if [[ "$ANIME_TOTAL_EPS" =~ ^[0-9]+$ ]] && [ "$ANIME_TOTAL_EPS" -gt 0 ] && [ "$next" -gt "$ANIME_TOTAL_EPS" ]; then
        return 0
    fi
    local pf="/tmp/ani-cli_prefetch_stream_${mid}_${next}"
    [ -f "$pf" ] && return 0
    rm -f "$pf" "${pf}.provider"
    ( call_site_provider "$prov" get_stream "$mid" "$next" "$quality" "$title" > "$pf" 2>/dev/null
      [ -s "$pf" ] && echo "$prov" > "${pf}.provider" ) &
}

# Prefetch the next episode's torrent search results in the background.
_prefetch_next_torrent_search() { # $1=mid $2=clean title $3=current ep $4=provider $5=group $6=res
    local mid="$1" clean="$2" ep="$3" pid="$4" grp="$5" res="$6"
    local next=$((ep + 1))   # separate statement, see _prefetch_next_stream
    if [[ "$ANIME_TOTAL_EPS" =~ ^[0-9]+$ ]] && [ "$ANIME_TOTAL_EPS" -gt 0 ] && [ "$next" -gt "$ANIME_TOTAL_EPS" ]; then
        return 0
    fi
    local pf="/tmp/ani-cli_prefetch_tor_${mid}_${next}"
    [ -f "$pf" ] && return 0
    local ep02=$(printf "%02d" "$next")
    ( call_torrent_provider "$pid" search "$clean" "$ep02" "$quality" "$grp" "$res" > "$pf" 2>/dev/null ) &
}

# Warm the AniSkip lua cache for the next episode in the background, so
# autoplay never waits on the AniSkip API between episodes.
_prefetch_next_skip() { # $1=mid $2=current ep
    local mid="$1" ep="$2"
    [ "$mid" = "0" ] && return 0
    [ "$skip_opening" = "true" ] || return 0
    local next=$((ep + 1))
    if [[ "$ANIME_TOTAL_EPS" =~ ^[0-9]+$ ]] && [ "$ANIME_TOTAL_EPS" -gt 0 ] && [ "$next" -gt "$ANIME_TOTAL_EPS" ]; then
        return 0
    fi
    ( aniskip_lua "$mid" "$next" >/dev/null 2>&1 ) &
}

# Consolidated next-episode prefetch: runs stream, torrent, and skip prefetch
# in one call. $5=method (stream|torrent|both)
_prefetch_next_episode() { # $1=mid $2=title $3=current_ep $4=method $5=provider
    local mid="$1" title="$2" ep="$3" method="$4" provider="$5"
    local next=$((ep + 1))
    [[ "$ANIME_TOTAL_EPS" =~ ^[0-9]+$ ]] && [ "$ANIME_TOTAL_EPS" -gt 0 ] && [ "$next" -gt "$ANIME_TOTAL_EPS" ] && return 0
    
    # Stream prefetch
    if [ "$method" = "stream" ] || [ "$method" = "both" ]; then
        _prefetch_next_stream "$mid" "$title" "$ep" "$provider"
    fi
    # Torrent prefetch
    if [ "$method" = "torrent" ] || [ "$method" = "both" ]; then
        local pf_clean=$(echo "$title" | sed 's/^ *//;s/ *$//')
        local pf_pid=""
        for p in "${TORRENT_PROVIDERS[@]}"; do [ "$p" = "$torrent_provider" ] && pf_pid="$p" && break; done
        [ -z "$pf_pid" ] && [ ${#TORRENT_PROVIDERS[@]} -gt 0 ] && pf_pid="${TORRENT_PROVIDERS[0]}"
        [ -n "$pf_pid" ] && _prefetch_next_torrent_search "$mid" "$pf_clean" "$ep" "$pf_pid" "" ""
    fi
    # Skip prefetch (always)
    _prefetch_next_skip "$mid" "$ep"
}

# ── Site streaming ────────────────────────────────────────────────

_play_one_stream() {
    local mid="$1" title="$2" ep_num="$3"
    [[ "$ep_num" =~ ^[0-9]+$ ]] && ep_num=$((10#$ep_num))
    local clean_title=$(echo "$title" | sed 's/^ *//;s/ *$//')
    local url="" used_provider=""

    if [ ${#SITE_PROVIDERS[@]} -eq 0 ]; then
        print_error "No site providers available"
        return 1
    fi
    local found=0 p
    for p in "${SITE_PROVIDERS[@]}"; do [ "$p" = "$provider" ] && found=1 && break; done
    [ "$found" -eq 0 ] && provider="${SITE_PROVIDERS[0]}"

    # Reuse the stream URL prefetched during the previous episode.
    local pf="/tmp/ani-cli_prefetch_stream_${mid}_${ep_num}"
    if [ -f "$pf" ]; then
        local pf_age=$(($(date +%s) - $(_file_mtime "$pf")))
        if [ "$pf_age" -lt 7200 ]; then
            url=$(cat "$pf" 2>/dev/null)
            used_provider=$(cat "${pf}.provider" 2>/dev/null)
        fi
        rm -f "$pf" "${pf}.provider"
        # Validate before reuse: the provider tag must be present and a
        # serve: artifact must still exist — a /tmp wipe or a mid-write
        # prefetch must degrade to a fresh resolve, not a hard failure.
        if [ -n "$url" ]; then
            case "$url" in
                serve:*)
                    local sf="${url#serve:}"
                    sf="${sf%%$'\n'*}"
                    { [ -z "$used_provider" ] || [ ! -f "$sf" ]; } && url="" used_provider=""
                    ;;
                http://*|https://*)
                    [ -z "$used_provider" ] && url=""
                    ;;
                *)
                    url="" used_provider=""
                    ;;
            esac
        fi
    fi

    if [ -z "$url" ]; then
        local try_providers=("$provider")
        for p in "${SITE_PROVIDERS[@]}"; do
            [ "$p" != "$provider" ] && try_providers+=("$p")
        done
        # Race all site providers in parallel — the first valid stream
        # wins and the losers are killed. Pure speed: playback starts at
        # the fastest provider's latency instead of the preferred one's
        # (plus the fallback's on failure).
        local race_dir="/tmp/ani-cli_race_$$"
        rm -rf "$race_dir"; mkdir -p "$race_dir"
        [ "$AUTOPLAYING" != "true" ] && \
            echo -ne "\r\033[K${STYLE_INFO}Resolving stream... ${STYLE_MUTED}(esc to cancel)${R}" >&2
        local try_p
        local -A rpids=()
        for try_p in "${try_providers[@]}"; do
            ( call_site_provider "$try_p" get_stream "$mid" "$ep_num" "$quality" "$title" > "$race_dir/$try_p" 2>/dev/null ) &
            rpids[$try_p]=$!
        done
        local aborted=0
        while true; do
            local any_alive=0 winner="" out=""
            for try_p in "${try_providers[@]}"; do
                if kill -0 "${rpids[$try_p]}" 2>/dev/null; then
                    any_alive=1
                    continue
                fi
                if [ -z "$winner" ]; then
                    out=$(cat "$race_dir/$try_p" 2>/dev/null)
                    if [ -n "$out" ] && echo "$out" | grep -qE '^(serve:|https?://)'; then
                        winner="$try_p"
                    fi
                fi
            done
            if [ -n "$winner" ]; then
                url=$(cat "$race_dir/$winner" 2>/dev/null)
                used_provider="$winner"
                break
            fi
            [ "$any_alive" -eq 0 ] && break
            if _read_key 0.15 && _key_is_esc; then aborted=1; break; fi
        done
        for try_p in "${try_providers[@]}"; do
            _kill_tree "${rpids[$try_p]}"   # losers: subshell + curl/python descendants
            wait "${rpids[$try_p]}" 2>/dev/null
        done
        rm -rf "$race_dir"
        echo -ne "\r\033[K" >&2
        if [ "$aborted" -eq 1 ]; then
            echo "" >&2
            return 2
        fi
    fi
    if [ -z "$url" ]; then
        print_error "No stream found for $clean_title Ep $ep_num on any provider"
        return 1
    fi
    local sub=""
    echo "$url" | grep -q "^sub:" && sub=$(echo "$url" | grep "^sub:" | sed 's/^sub://') && url=$(echo "$url" | grep -v "^sub:" | head -1)

    # Optional per-provider playback metadata (declared in the provider file)
    PROVIDER_HEADERS=()
    PROVIDER_LAVF_OPTS=""
    source "${PROVIDERS_DIR}/sites/${used_provider}/${used_provider}.sh" 2>/dev/null

    local serve_pid=""
    local lavf_opts="--demuxer-lavf-o=http_persistent=false"
    [ -n "$PROVIDER_LAVF_OPTS" ] && lavf_opts="$lavf_opts $PROVIDER_LAVF_OPTS"

    if echo "$url" | grep -q "^serve:"; then
        local master_path=$(echo "$url" | sed 's/^serve://')
        local serve_script="${PROVIDERS_DIR}/sites/${used_provider}/${used_provider}_serve.py"
        if [ ! -f "$serve_script" ]; then
            print_error "Server script not found: $serve_script"
            return 1
        fi
        local url_file="/tmp/${used_provider}_serve_url.txt"
        # Adopt the proxy prepped during the autoplay countdown — it was
        # started from this same prefetched artifact, so playback skips the
        # proxy boot delay.
        local prep_pid; prep_pid=$(_prep_adopt "$ep_num")
        [ -n "$prep_pid" ] && serve_pid="$prep_pid"
        if [ -z "$serve_pid" ]; then
            : > "$url_file"
            python3 "$serve_script" "$master_path" >"$url_file" 2>/dev/null &
            serve_pid=$!
        fi
        local wait=0
        while [ $wait -lt 100 ]; do
            url=$(head -1 "$url_file" 2>/dev/null)
            [ -n "$url" ] && break
            kill -0 "$serve_pid" 2>/dev/null || break
            if _read_key 0.1 && _key_is_esc; then
                kill "$serve_pid" 2>/dev/null
                rm -f "$url_file"
                echo "" >&2
                return 2
            fi
            wait=$((wait + 1))
        done
        if [ -z "$url" ]; then
            print_error "Failed to start HTTP server for streaming"
            kill "$serve_pid" 2>/dev/null
            rm -f "$url_file"
            return 1
        fi
    fi

    MPV_EXTRA_ARGS=()
    local h
    for h in ${PROVIDER_HEADERS[@]+"${PROVIDER_HEADERS[@]}"}; do
        [ -n "$h" ] && MPV_EXTRA_ARGS+=(--http-header-fields="$h")
    done
    MPV_EXTRA_ARGS+=($lavf_opts)

    local skip_lua; skip_lua=$(_await_skip_prefetch)
    print_success "▶ Playing Episode $ep_num"
    # Consolidated prefetch for next episode (OPT-2)
    _prefetch_next_episode "$mid" "$title" "$ep_num" "stream" "$used_provider"
    # Also start the next episode's serve proxy during playback
    _prep_start "$mid" "$title" "$((ep_num + 1))" "stream" &
    play_mpv "$mid" "$ep_num" "$clean_title - Ep $ep_num" "$url" "$sub" "$skip_lua"
    local play_rc=$?

    [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null
    rm -f "/tmp/${used_provider}_serve_url.txt"
    # provider-owned temp artifacts (generic hook, see _template.sh)
    call_site_provider "$used_provider" cleanup 2>/dev/null
    return $play_rc
}

# ── Torrent streaming ─────────────────────────────────────────────

# Engine --resume-frac args from the local resume point (echoes nothing
# when there's no usable point). mpv seeks to the resume position, so the
# engine must prioritize that window — an un-prioritized seek waits on
# on-demand bridge fetches against sequential mode (tens of seconds).
_resume_frac_args() { # $1=mid $2=ep → "--resume-frac N" or ""
    local resume rp rd
    resume=$(resume_get "$1" "$2")
    [ -z "$resume" ] && return 0
    rp="${resume%% *}"
    rd="${resume##* }"
    if [[ "$rp" =~ ^[0-9]+$ ]] && [ "$rp" -ge "$RESUME_MIN_SECONDS" ] && [[ "$rd" =~ ^[0-9]+$ ]] && [ "$rd" -gt 0 ]; then
        echo "--resume-frac $((rp * 100 / rd))"
    fi
}

# Shared wait for a torrent engine to report ready.
# Echoes the ready URL/path; returns 0=ready 1=died/timeout 2=esc.
_torrent_wait_ready() { # $1=engine_pid $2=ready_file $3=progress_file $4=max_wait(0.5s units)
    local engine_pid="$1" ready_file="$2" progress_file="$3" max_wait="$4"
    local stty_save="" video_path="" wait=0 progress_line=""
    stty_save=$(stty -g 2>/dev/null || true)
    [ -n "$stty_save" ] && stty -echo 2>/dev/null
    while [ $wait -lt $max_wait ]; do
        video_path=$(grep -E "^(http://|/)" "$ready_file" 2>/dev/null | tail -1 || true)
        # engine reports either a local bridge URL (http://127.0.0.1)
        # or a plain file path — only the path needs an existence check
        if [ -n "$video_path" ]; then
            case "$video_path" in
                http://*) break ;;
                /*) [ -f "$video_path" ] && break ;;
            esac
        fi
        kill -0 "$engine_pid" 2>/dev/null || { sleep 0.5; break; }
        progress_line=$(tail -1 "$progress_file" 2>/dev/null | grep "^\[torrent\]" || true)
        [ -n "$progress_line" ] && echo -ne "\r\033[K${STYLE_MUTED}Buffering: ${progress_line#\[torrent\] }${R}" >&2
        if _read_key 0.5 && _key_is_esc; then
            [ -n "$stty_save" ] && stty "$stty_save" 2>/dev/null
            return 2
        fi
        wait=$((wait + 1))
    done
    [ -n "$stty_save" ] && stty "$stty_save" 2>/dev/null
    if [ -n "$video_path" ]; then
        case "$video_path" in
            http://*) echo "$video_path"; return 0 ;;
            /*) [ -f "$video_path" ] && { echo "$video_path"; return 0; } ;;
        esac
    fi
    return 1
}

# ── Next-episode prep state machine (autoplay) ────────────────────
# One mechanism for both methods: after an episode finishes, the next
# episode's heavy work (torrent search + engine buffering / stream serve
# proxy) starts in the background DURING the autoplay countdown, and
# _play_one_* adopts it on countdown accept. Esc during the countdown
# cancels it. The .state file holds "searching" while resolving, then the
# engine/proxy pid — one file per episode, no string protocols beyond that.

_prep_state() { echo "/tmp/ani-cli_prep_$1.state"; }

_prep_start() { # $1=mid $2=title $3=next ep $4=method(stream|torrent)
    local mid="$1" title="$2" next="$3" method="$4"
    if [[ "$ANIME_TOTAL_EPS" =~ ^[0-9]+$ ]] && [ "$ANIME_TOTAL_EPS" -gt 0 ] && [ "$next" -gt "$ANIME_TOTAL_EPS" ]; then
        return 0
    fi
    local state=$(_prep_state "$next")
    if [ -f "$state" ]; then   # already prepping this episode?
        local cur=$(cat "$state" 2>/dev/null)
        { [ "$cur" = "searching" ] || { [[ "$cur" =~ ^[0-9]+$ ]] && kill -0 "$cur" 2>/dev/null; }; } && return 0
    fi
    echo "searching" > "$state"   # claim the slot NOW so adoption waits for us
    case "$method" in
        torrent) _prep_start_torrent "$mid" "$title" "$next" "$state" & ;;
        stream)  _prep_start_stream "$mid" "$title" "$next" "$state" & ;;
        *) rm -f "$state" ;;
    esac
}

# Background worker (torrent): reuse the prefetched search JSON (or search
# live), then launch the engine with the standard ready/progress files.
_prep_start_torrent() { # $1=mid $2=title $3=next $4=statefile
    local mid="$1" title="$2" next="$3" state="$4"
    local pid="" p
    for p in "${TORRENT_PROVIDERS[@]}"; do [ "$p" = "$torrent_provider" ] && pid="$p" && break; done
    [ -z "$pid" ] && [ ${#TORRENT_PROVIDERS[@]} -gt 0 ] && pid="${TORRENT_PROVIDERS[0]}"
    local engine_py="$PROVIDERS_DIR/torrent/${pid}/torrent_stream.py"
    if [ -z "$pid" ] || [ ! -f "$engine_py" ] || ! python3 -c "import libtorrent" 2>/dev/null; then
        rm -f "$state"; return 0
    fi
    local clean=$(echo "$title" | sed 's/^ *//;s/ *$//')
    local pref_file="/tmp/ani-cli_torrent_prefs.txt" grp="" res=""
    [ -f "$pref_file" ] && IFS='|' read -r grp res < "$pref_file" 2>/dev/null || true
    local json
    json=$(cat "/tmp/ani-cli_prefetch_tor_${mid}_${next}" 2>/dev/null)
    echo "$json" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null || \
        json=$(call_torrent_provider "$pid" search "$clean" "$(printf "%02d" "$next")" "$quality" "$grp" "$res" 2>/dev/null)
    local parsed
    parsed=$(echo "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d:
        print(d[0].get('magnet','') or '')
        print(d[0].get('target_season','') or '')
except Exception: pass
" 2>/dev/null)
    local magnet tseas
    magnet=$(echo "$parsed" | sed -n '1p')
    tseas=$(echo "$parsed" | sed -n '2p')
    [ -z "$magnet" ] && { rm -f "$state"; return 0; }
    local -a sargs=()
    [[ "$tseas" =~ ^[0-9]+$ ]] && sargs=(--season "$tseas")
    if [ "$mid" != "0" ]; then
        local off
        off=$(anilist_prequel_offset "$mid")
        [[ "$off" =~ ^[0-9]+$ ]] && [ "$off" -gt 0 ] && sargs+=(--abs-ep "$((next + off))")
    fi
    # cancelled while searching? don't launch
    [ -f "$state" ] || return 0
    local -a rargs=()
    read -r -a rargs <<< "$(_resume_frac_args "$mid" "$next")"
    local ready_file="/tmp/ani-cli_torrent_ready_${next}.txt"
    local progress_file="/tmp/ani-cli_torrent_progress_${next}.txt"
    : > "$ready_file"; : > "$progress_file"
    python3 "$engine_py" "$magnet" --buffer "${torrent_buffer:-50}" --episode "$next" \
        ${sargs[@]+"${sargs[@]}"} ${rargs[@]+"${rargs[@]}"} > "$ready_file" 2>"$progress_file" &
    echo $! > "$state"
}

# Background worker (stream): pre-start the serve proxy when the prefetched
# URL is a serve: artifact — shaves the proxy boot off the autoplay path.
_prep_start_stream() { # $1=mid $2=title $3=next $4=statefile
    local mid="$1" title="$2" next="$3" state="$4"
    local pf="/tmp/ani-cli_prefetch_stream_${mid}_${next}"
    [ -f "$pf" ] || { rm -f "$state"; return 0; }
    local url prov master_path
    url=$(cat "$pf" 2>/dev/null)
    prov=$(cat "${pf}.provider" 2>/dev/null)
    case "$url" in serve:*) ;; *) rm -f "$state"; return 0 ;; esac
    [ -z "$prov" ] && { rm -f "$state"; return 0; }
    master_path="${url#serve:}"
    master_path="${master_path%%$'\n'*}"
    [ -f "$master_path" ] || { rm -f "$state"; return 0; }
    local serve_script="${PROVIDERS_DIR}/sites/${prov}/${prov}_serve.py"
    [ -f "$serve_script" ] || { rm -f "$state"; return 0; }
    local url_file="/tmp/${prov}_serve_url.txt"
    : > "$url_file"
    python3 "$serve_script" "$master_path" >"$url_file" 2>/dev/null &
    echo $! > "$state"
}

# Adopt a prepped engine/proxy: waits (≤15s) for "searching" to turn into
# a pid. Echoes the live pid on success, nothing otherwise. Consumes the
# state file either way — a prep is adopted exactly once.
_prep_adopt() { # $1=ep
    local state=$(_prep_state "$1")
    [ -f "$state" ] || return 1
    local pid waited=0
    pid=$(cat "$state" 2>/dev/null)
    while [ "$pid" = "searching" ] && [ $waited -lt 30 ]; do
        sleep 0.5
        pid=$(cat "$state" 2>/dev/null)
        waited=$((waited + 1))
    done
    rm -f "$state"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        echo "$pid"
        return 0
    fi
    [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
    return 1
}

# Countdown cancelled — tear down whatever was prepped for the next ep.
_prep_cancel() { # $1=next ep
    local state=$(_prep_state "$1") pid=""
    [ -f "$state" ] && pid=$(cat "$state" 2>/dev/null)
    rm -f "$state" "/tmp/ani-cli_torrent_ready_$1.txt" "/tmp/ani-cli_torrent_progress_$1.txt"
    [[ "$pid" =~ ^[0-9]+$ ]] && _kill_tree "$pid"
    return 0
}

_play_one_torrent() {
    local mid="$1" title="$2" ep_num="$3"
    [[ "$ep_num" =~ ^[0-9]+$ ]] && ep_num=$((10#$ep_num))
    local clean=$(echo "$title" | sed 's/^ *//;s/ *$//')
    local pref_file="/tmp/ani-cli_torrent_prefs.txt"
    local preferred_group="" preferred_res=""

    [ -f "$pref_file" ] && IFS='|' read -r preferred_group preferred_res < "$pref_file" 2>/dev/null || true

    local pid="" p
    for p in "${TORRENT_PROVIDERS[@]}"; do [ "$p" = "$torrent_provider" ] && pid="$p" && break; done
    [ -z "$pid" ] && [ ${#TORRENT_PROVIDERS[@]} -gt 0 ] && pid="${TORRENT_PROVIDERS[0]}"
    [ -z "$pid" ] && print_error "No torrent provider" && return 1

    local engine_py="$PROVIDERS_DIR/torrent/${pid}/torrent_stream.py"
    [ ! -f "$engine_py" ] && print_error "Torrent engine missing: $engine_py" && return 1

    local ready_file="/tmp/ani-cli_torrent_ready_${ep_num}.txt"
    local progress_file="/tmp/ani-cli_torrent_progress_${ep_num}.txt"
    local video_path="" attempt=0 aborted=0 adopted=0 engine_pid=""
    local tor_group="" tor_res="" tor_season=""

    # Adopt the engine prepped during the autoplay countdown, if any:
    # skip the search + launch entirely and just wait on its ready file.
    local prep_pid; prep_pid=$(_prep_adopt "$ep_num")
    if [ -n "$prep_pid" ]; then
        engine_pid="$prep_pid" adopted=1
        echo "$engine_pid" > /tmp/ani-cli_torrent_engine.pid
    fi
    if [ "$adopted" -eq 1 ]; then
        video_path=$(_torrent_wait_ready "$engine_pid" "$ready_file" "$progress_file" 600) || {
            local wrc=$?
            if [ $wrc -eq 2 ]; then
                aborted=1
            else
                # Prepped engine failed — show reason (muted), then fall to normal search
                local fail_line=""
                fail_line=$(tail -1 "$progress_file" 2>/dev/null | grep '^\[torrent\] FAIL:' | head -1 || true)
                local code=""
                if [ -n "$fail_line" ]; then
                    code="${fail_line#*FAIL:}"
                fi
                local reason=""
                case "$code" in
                    no-progress) reason="No download progress" ;;
                    metadata)    reason="Failed to get metadata" ;;
                    no-video)    reason="No matching episode file" ;;
                    *)           reason="Failed to start torrent" ;;
                esac
                echo -e "\r\033[K${STYLE_MUTED}${reason}${R}" >&2
                adopted=0 video_path=""
            fi
        }
    fi

    if [ "$adopted" -eq 0 ]; then
    local ep=$(printf "%02d" "$ep_num")

    # Reuse the search results prefetched during the previous episode.
    local json=""
    local pf="/tmp/ani-cli_prefetch_tor_${mid}_${ep_num}"
    if [ -f "$pf" ]; then
        json=$(cat "$pf" 2>/dev/null)
        rm -f "$pf"
        echo "$json" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null || json=""
    fi

    if [ -z "$json" ]; then
        local search_out="/tmp/ani-cli_torsearch_$$" search_pid
        # quiet on autoplay: source lookup happens in the background
        [ "$AUTOPLAYING" != "true" ] && \
            echo -ne "\r\033[K${STYLE_INFO}Trying $pid... ${STYLE_MUTED}(esc to cancel)${R}" >&2
        : > "$search_out"
        (
            local_json=$(call_torrent_provider "$pid" search "$clean" "$ep" "$quality" "$preferred_group" "$preferred_res" 2>/dev/null)
            local_n=$(echo "$local_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
            if [ "$local_n" = "0" ] && [ -n "$preferred_group" ]; then
                retry=$(call_torrent_provider "$pid" search "$clean" "$ep" "$quality" 2>/dev/null)
                retry_n=$(echo "$retry" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
                [ "$retry_n" != "0" ] && local_json="$retry"
            fi
            echo "$local_json"
        ) > "$search_out" 2>/dev/null &
        search_pid=$!
        if ! _bg_wait_esc "$search_pid"; then
            echo "" >&2
            rm -f "$search_out"
            return 2
        fi
        echo -ne "\r\033[K" >&2
        json=$(cat "$search_out" 2>/dev/null)
        rm -f "$search_out"
    fi

    # One python spawn parses the whole candidate list (count + top fields +
    # fallback magnets) — spawning python 9 times per episode was measurable.
    local count magnet tor_group tor_res tor_size tor_season extra
    local parsed
    parsed=$(echo "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
print(len(d))
if d:
    r = d[0]
    print(r.get('magnet','') or '')
    print(r.get('group','') or '')
    print(r.get('resolution','') or '')
    print(r.get('size','') or '')
    print(r.get('target_season','') or '')
" 2>/dev/null)
    count=$(echo "$parsed" | sed -n '1p')
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [ "$count" -eq 0 ] && print_error "No torrent for $clean Ep $ep_num" && return 1
    magnet=$(echo "$parsed" | sed -n '2p')
    tor_group=$(echo "$parsed" | sed -n '3p')
    tor_res=$(echo "$parsed" | sed -n '4p')
    tor_size=$(echo "$parsed" | sed -n '5p')
    tor_season=$(echo "$parsed" | sed -n '6p')
    : "${tor_group:=}" "${tor_res:=}" "${tor_season:=}"

    echo "${tor_group}|${tor_res}" > "$pref_file"

    if [ "$AUTOPLAYING" != "true" ] && [ "$count" -gt 1 ]; then
        local choices=$(echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for i, r in enumerate(d[:5]):
    g = r.get('group', '') or '?'
    res = r.get('resolution', '') or '?'
    sz = r.get('size', '') or '?'
    sd = r.get('seeds', 0) or 0
    batch = ' [BATCH]' if r.get('is_batch') else ''
    trust = ' ✓' if r.get('trusted') else ''
    print(f\"{i+1}\t[{g}] {res} {sz} {sd}s{batch}{trust}\")
" 2>/dev/null)

        local sel=""
        if [ -t 0 ]; then
            sel=$(echo -e "$choices" | menu_choice "${STYLE_MENU_NUM}Select torrent${R}:" --delimiter=$'\t' --with-nth=2..)
        fi
        if [ -z "$sel" ]; then
            if [ -t 0 ]; then
                return 2   # esc on torrent picker → back
            fi
            sel="1	${choices%%$'\n'*}"   # auto-pick first in non-TTY (CLI) mode
        fi
        local idx=$(echo "$sel" | cut -d$'\t' -f1)
        parsed=$(echo "$json" | IDX="$idx" python3 -c "
import sys, json, os
d = json.load(sys.stdin)
i = int(os.environ.get('IDX', '1')) - 1
if 0 <= i < len(d):
    r = d[i]
    print(r.get('magnet', '') or '')
    print(r.get('group', '') or '')
    print(r.get('resolution', '') or '')
    print(r.get('target_season', '') or '')
" 2>/dev/null)
        magnet=$(echo "$parsed" | sed -n '1p')
        tor_group=$(echo "$parsed" | sed -n '2p')
        tor_res=$(echo "$parsed" | sed -n '3p')
        tor_season=$(echo "$parsed" | sed -n '4p')
        : "${tor_group:=}" "${tor_res:=}" "${tor_season:=}"
        echo "${tor_group}|${tor_res}" > "$pref_file"
    fi

    [ -z "$magnet" ] && print_error "No magnet URI" && return 1

    # Candidate magnets: chosen first, then top-ranked fallbacks
    local -a try_magnets=("$magnet")
    extra=$(echo "$json" | CHOSEN="$magnet" python3 -c "
import sys, json, os
d = json.load(sys.stdin)
chosen = os.environ.get('CHOSEN', '')
for r in d[:3]:
    m = r.get('magnet', '') or ''
    if m and m != chosen:
        print(m)
" 2>/dev/null)
    local m
    while IFS= read -r m; do [ -n "$m" ] && try_magnets+=("$m"); done <<< "$extra"

    local -a season_args=()
    [[ "$tor_season" =~ ^[0-9]+$ ]] && season_args=(--season "$tor_season")
    if [ "$mid" != "0" ]; then
        local offset
        offset=$(anilist_prequel_offset "$mid")
        if [[ "$offset" =~ ^[0-9]+$ ]] && [ "$offset" -gt 0 ]; then
            season_args+=(--abs-ep "$((ep_num + offset))")
        fi
    fi

    # Resume point → engine --resume-frac
    local -a resume_args=()
    read -r -a resume_args <<< "$(_resume_frac_args "$mid" "$ep_num")"

    local printed_block=0
    local fail_codes=()

    for magnet in "${try_magnets[@]}"; do
        attempt=$((attempt + 1))
        if [ $attempt -gt 1 ]; then
            if [ $printed_block -eq 1 ]; then
                echo -ne "\033[2A\r\033[K\r\033[K" >&2
                printed_block=0
            fi
            print_warning "Retrying with fallback torrent #${attempt}..."
        fi

        : > "$ready_file" ; : > "$progress_file"
        python3 "$engine_py" "$magnet" --buffer "${torrent_buffer:-50}" --episode "$ep_num" \
            ${season_args[@]+"${season_args[@]}"} ${resume_args[@]+"${resume_args[@]}"} \
            > "$ready_file" 2>"$progress_file" &
        engine_pid=$!
        echo "$engine_pid" > /tmp/ani-cli_torrent_engine.pid

        local max_wait=240
        [ $attempt -gt 1 ] && max_wait=120
        video_path=$(_torrent_wait_ready "$engine_pid" "$ready_file" "$progress_file" "$max_wait") || {
            local wrc=$?
            if [ $wrc -eq 2 ]; then
                aborted=1
                break
            fi
            video_path=""
        }

        if [ -n "$video_path" ]; then
            # Success — clear any failure block and show playing line
            if [ $printed_block -eq 1 ]; then
                echo -ne "\033[2A\r\033[K\r\033[K" >&2
                printed_block=0
            fi
            echo -e "${STYLE_SUCCESS}▶ Playing Episode $ep_num${R}" >&2
            break
        fi

        # Engine died without giving a ready URL — extract FAIL code
        local fail_line=""
        fail_line=$(grep '^\[torrent\] FAIL:' "$progress_file" 2>/dev/null | head -1 || true)
        local code=""
        if [ -n "$fail_line" ]; then
            code="${fail_line#*FAIL:}"
        fi
        local reason=""
        case "$code" in
            no-progress) reason="No download progress" ;;
            metadata)    reason="Failed to get metadata" ;;
            no-video)    reason="No matching episode file" ;;
            *)           reason="Failed to start torrent" ;;
        esac
        echo -e "\r\033[K${STYLE_MUTED}${reason}${R}" >&2
        if [ $attempt -lt ${#try_magnets[@]} ]; then
            echo "Retrying with fallback torrent $((attempt + 1))." >&2
            printed_block=1
        else
            # Final failure — clear block, let the final error print
            if [ $printed_block -eq 1 ]; then
                echo -ne "\033[2A\r\033[K\r\033[K" >&2
                printed_block=0
            fi
        fi
        kill "$engine_pid" 2>/dev/null || true
    done
    fi   # end of the non-adopted (normal search+launch) path

    if [ "$aborted" -eq 1 ]; then
        echo "" >&2
        kill "$engine_pid" 2>/dev/null || true
        rm -f "$ready_file" "$progress_file" /tmp/ani-cli_torrent_engine.pid
        return 2
    fi

    local have_video=0
    case "$video_path" in
        http://*) have_video=1 ;;
        /*) [ -f "$video_path" ] && have_video=1 ;;
    esac
    if [ "$have_video" -eq 0 ]; then
        echo "" >&2
        print_error "Failed to buffer torrent"
        rm -f "$ready_file" "$progress_file" /tmp/ani-cli_torrent_engine.pid
        return 1
    fi

    local skip_lua; skip_lua=$(_await_skip_prefetch)
    # Consolidated prefetch for next episode (OPT-2)
    _prefetch_next_episode "$mid" "$title" "$ep_num" "torrent" "$pid"
    # Also start the next episode's torrent engine during playback
    _prep_start "$mid" "$title" "$((ep_num + 1))" "torrent" &
    MPV_EXTRA_ARGS=()

    # ONE live line for the whole session: the buffering bar turns into
    # the playback bar and keeps updating in place until mpv exits.
    # Only reprints when the engine reports new progress, so error text
    # from play_mpv is never clobbered.
    local follow_pid=""
    (
        local last=""
        while true; do
            pl=$(tail -1 "$progress_file" 2>/dev/null | grep "^\[torrent\]" || true)
            if [ -n "$pl" ] && [ "$pl" != "$last" ]; then
                last="$pl"
                echo -ne "\r\033[K${STYLE_SUCCESS}▶ Playing Episode $ep_num${R}  ${STYLE_MUTED}${pl#\[torrent\] }${R}" >&2
            fi
            sleep 1
        done
    ) &
    follow_pid=$!

    play_mpv "$mid" "$ep_num" "$clean - Ep $ep_num" "$video_path" "" "$skip_lua"
    local play_rc=$?

    kill "$follow_pid" 2>/dev/null
    wait "$follow_pid" 2>/dev/null
    echo "" >&2   # finalize the single bar line
    kill "$engine_pid" 2>/dev/null || true
    rm -f "$ready_file" "$progress_file" /tmp/ani-cli_torrent_engine.pid
    return $play_rc
}

# ── Screen: anime detail ──────────────────────────────────────────

show_anime_detail_screen() {
    local title="$1" genres="$2" rating="$3" total="$4" duration="$5" status="$6" year="$7" studio="$8" desc="$9"
    print_anime_title "$title"
    local line=""
    [ "$total" != "?" ] && [ -n "$total" ] && line="${total} eps"
    [ "$duration" != "?" ] && [ -n "$duration" ] && line="${line:+${line} • }${duration} min"
    [ "$rating" != "?" ] && [ -n "$rating" ] && line="${line:+${line} • }${rating}"
    echo -e "${STYLE_ANIME_INFO}${line}${R}"
    echo ""
    if [ -n "$desc" ] && [ "$desc" != "?" ]; then
        local wrapped
        wrapped=$(echo "$desc" | fold -s -w 80)
        while IFS= read -r dline; do
            echo -e "${STYLE_MUTED}${dline}${R}"
        done <<< "$wrapped"
    fi
    echo ""
    [ -n "$genres" ] && echo -e "${STYLE_ANIME_INFO}${genres}${R}"
    [ -n "$studio" ] && [ "$studio" != "?" ] && echo -e "${STYLE_MUTED}${studio}${R}"
    echo ""
}

# ── Interactive screens ───────────────────────────────────────────

show_search_screen() {
    clear_screen; print_logo
    local query
    query=$(input_text "Search anime") || return   # esc cancels
    [ -z "$query" ] && return
    clear_screen; print_logo; print_info "Searching: $query"
    local json=$(anilist_search "$query")
    local results=$(parse_search_results "$json")
    if [ -z "$results" ]; then
        # Distinguish a dead request (transient network/AniList failure —
        # retrying usually works) from a search that genuinely matched nothing.
        local retry_option=""
        if _anilist_valid "$json"; then
            print_error "No results found"
        else
            print_error "AniList request failed — check your connection and try again"
            retry_option="1. Retry search"$'\n'
        fi
        echo ""
        if [ -n "$retry_option" ]; then
            local action=$(echo -e "${retry_option}2. Back to menu" | menu_choice "${STYLE_MENU_NUM}Search failed${R}:")
            case "$action" in
                1*) show_search_screen; return ;;
                *) return ;;
            esac
        else
            press_any_key
        fi
        return
    fi
    local i=1 display="" map=""
    while IFS=$'\t' read -r mid rest; do
        [ -z "$mid" ] && continue
        [ -n "$display" ] && display+=$'\n'
        display+="${i}. ${rest}"
        map+="${i}|${mid}"$'\n'
        i=$((i+1))
    done <<< "$results"
    # Warm the detail-page cache for the top results in the background.
    ( echo "$map" | head -8 | cut -d'|' -f2 | while read -r pf_mid; do
        [ -n "$pf_mid" ] && anilist_media_details "$pf_mid" >/dev/null 2>&1
      done ) &
    # esc on a detail page comes back to the results; esc here exits
    while true; do
        clear_screen; print_logo
        local choice=$(echo "$display" | menu_choice "${STYLE_MENU_NUM}Search results${R}:")
        [ -z "$choice" ] && return
        local num="${choice%%.*}"
        local mid=$(echo "$map" | grep "^${num}|" | cut -d'|' -f2)
        local field=$(echo "$choice" | sed 's/^[0-9]*\. //')
        local title=$(echo "$field" | sed 's/ (.*//')
        local eps=$(echo "$field" | sed -n 's/.* \([0-9][0-9]*\) eps.*/\1/p' | head -1)
        [ -z "$eps" ] && eps="?"
        show_anime_detail_page "$mid" "$title" "$eps"
    done
}

show_anime_detail_page() {
    local mid="$1" title="$2" total="$3"
    print_info "Loading details..."
    local json=$(anilist_media_details "$mid")
    local details=$(parse_media_details "$json")
    if [ -z "$details" ]; then
        print_warning "Could not load details"
        show_episode_screen "$mid" "$title" "$total" "" "" "" "" "" "$progress"
        return
    fi
    local genres rating eps duration status year studio desc fmt season sd nx_ep nx_at mal_id e_st e_pr
    IFS=$'\t' read -r title genres rating eps duration status year studio desc fmt season sd nx_ep nx_at mal_id e_st e_pr <<< "$details"
    { [ -z "$eps" ] || [ "$eps" = "?" ]; } && eps="$total"
    media_entry_prime "$mid" "$e_st" "$e_pr" "$mal_id"
    while true; do
        clear_screen; print_logo
        show_anime_detail_screen "$title" "$genres" "$rating" "$eps" "$duration" "$status" "$year" "$studio" "$desc"
        echo -e "${STYLE_MUTED}Press any key${R}"
        local key="" extra=""
        read -s -n 1 key
        if [[ "$key" == $'\e' ]]; then
            read -s -t 0.05 -n 2 extra 2>/dev/null || true
            [ -z "$extra" ] && return
        fi
        show_episode_screen "$mid" "$title" "$eps" "$nx_ep" "$nx_at" "$e_st" "$e_pr" ""
    done
}

show_episode_screen() {
    local mid="$1" title="$2" total="$3" nx_ep="$4" nx_at="$5" e_st="${6:-}" e_pr="${7:-}" skip_prefetch="${8:-}" target_ep="${9:-}"

    # List entry (status/progress) for watched/mid-watch styling + start page.
    # Normally primed from the details response (no extra request).
    local entry="" entry_status="$e_st" progress="$e_pr"
    if [ -z "$entry_status" ] && [ -z "$progress" ] && [ "$mid" != "0" ]; then
        entry=$(media_entry "$mid")
        entry_status=$(echo "$entry" | cut -f1)
        progress=$(echo "$entry" | cut -f2)
    fi
    [[ "$progress" =~ ^[0-9]+$ ]] || progress=0

    # Airing shows: `episodes` is the planned total (often null). The real
    # current episode count is nextAiringEpisode - 1.
    if [[ "$nx_ep" =~ ^[0-9]+$ ]] && [ "$nx_ep" -gt 1 ]; then
        local aired=$((nx_ep - 1))
        if [[ "$total" =~ ^[0-9]+$ ]]; then
            [ "$aired" -lt "$total" ] && total=$aired
        else
            total=$aired
        fi
    fi

    # Prefetch the episode the user is most likely to play (progress+1, i.e.
    # resume point or ep 1) while they browse the list — by the time they
    # pick it, the provider lookup is usually already done. Both methods are
    # warmed in the background; unused results just sit in /tmp until cleanup.
    # Skip prefetch when coming from Continue Watching (already done) for speed.
    if [ "$skip_prefetch" != "skip_prefetch" ]; then
        ANIME_TOTAL_EPS="$total"
        # Consolidated prefetch for both stream and torrent (OPT-2)
        _prefetch_next_episode "$mid" "$title" "$progress" "both" "$provider"
        # Multi-season shows: the prequel offset (up to 6 serial GraphQL calls)
        # would otherwise block the first torrent start — warm its 24h cache now.
        [ "$mid" != "0" ] && ( anilist_prequel_offset "$mid" >/dev/null 2>&1 ) &
    fi

    local max=$total
    [[ "$max" =~ ^[0-9]+$ ]] || max=50
    [ "$max" -lt 1 ] && max=50
    local page_size=50
    local page=1
    # Open on the page containing the target episode (or progress+1 if not specified)
    # This handles both normal entry (progress+1) and Continue Watching smart episode
    if [ -n "$target_ep" ] && [[ "$target_ep" =~ ^[0-9]+$ ]]; then
        page=$(( (target_ep - 1) / page_size + 1 ))
    elif [ "$progress" -gt 0 ]; then
        page=$(( progress / page_size + 1 ))
    fi
    local last_page=$(( (max - 1) / page_size + 1 ))
    [ "$page" -gt "$last_page" ] && page=$last_page

    while true; do
        clear_screen; print_logo
        print_anime_title "$title"
        if [[ "$nx_ep" =~ ^[0-9]+$ ]] && [[ "$nx_at" =~ ^[0-9]+$ ]]; then
            local now=$(date +%s)
            local diff=$((nx_at - now))
            if [ "$diff" -gt 0 ] 2>/dev/null; then
                local days=$((diff / 86400))
                local hours=$(((diff % 86400) / 3600))
                echo -e "${STYLE_ANIME_INFO}Next episode (Ep ${nx_ep}) in ${days}d ${hours}h${R}"
            fi
        fi
        echo ""
        local eps_list="" start_ep=$(( (page - 1) * page_size + 1 )) end_ep=$(( page * page_size ))
        [ "$end_ep" -gt "$max" ] && end_ep=$max
        local i rpos rdur
        for ((i=start_ep; i<=end_ep; i++)); do
            local resume; resume=$(resume_get "$mid" "$i")
            if [ -n "$resume" ]; then
                rpos="${resume%% *}"
                local rtime; rtime=$(format_timestamp "$rpos")
                local ep_text="Episode ${i}"
                local time_text="(${rtime})"
                local resume_label="Resume"
                local vis_len=$((${#i} + 2 + ${#ep_text} + 1 + ${#time_text}))
                local term_w="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
                local pad=$((term_w - vis_len - ${#resume_label} - 2))
                [ "$pad" -lt 2 ] && pad=2
                eps_list+="${i}. ${STYLE_ANIME_TITLE}${ep_text}${R} ${STYLE_MUTED}${time_text}${R}$(printf '%*s' "$pad" '')${STYLE_BOLD}${STYLE_ANIME_TITLE}${resume_label}${R}"$'\n'
            elif [ "$i" -le "$progress" ] 2>/dev/null; then
                eps_list+="${i}. ${STYLE_MUTED}Episode ${i}${R}"$'\n'
            else
                eps_list+="${i}. Episode ${i}"$'\n'
            fi
        done
        if [ "$max" -gt "$page_size" ]; then
            [ "$page" -gt 1 ] && eps_list+="←. Previous page"$'\n'
            [ "$end_ep" -lt "$max" ] && eps_list+="→. Next page"$'\n'
            [ "$FZF_QUERY_JUMP" != "1" ] && eps_list+="#. Go to episode..."$'\n'
        fi
        eps_list=${eps_list%$'\n'}   # drop trailing newline → no blank fzf entry
        local choice="" query="" rc=0
        if [ "$FZF_QUERY_JUMP" = "1" ]; then
            local out
            out=$(printf "%s" "$eps_list" | menu_choice "${STYLE_MENU_NUM}Episode (page ${page})${R}:" \
                --print-query --bind 'enter:accept-or-print-query') || rc=$?
            [ $rc -ne 0 ] && return   # esc/abort → back
            query=$(echo "$out" | sed -n '1p')
            choice=$(echo "$out" | sed -n '2p')
            # enter with no fuzzy match → fzf printed the query itself
            [ "$choice" = "$query" ] && choice=""
        else
            choice=$(printf "%s" "$eps_list" | menu_choice "${STYLE_MENU_NUM}Episode (page ${page})${R}:")
        fi
        # Prompt-as-search: a bare number jumps straight to that episode from
        # ANY page (typed into the fzf prompt, or raw typed text from rofi).
        local qnum="${choice:-$query}"
        if [[ "$qnum" =~ ^[0-9]+$ ]]; then
            local jep=$((10#$qnum))
            [ "$jep" -lt 1 ] && jep=1
            [ "$jep" -gt "$max" ] && jep=$max
            _episode_action "$mid" "$title" "$jep" "$total"
            continue
        fi
        [ -z "$choice" ] && return
        if echo "$choice" | grep -q "^→"; then
            page=$((page + 1))
            continue
        fi
        if echo "$choice" | grep -q "^←"; then
            [ "$page" -gt 1 ] && page=$((page - 1))
            continue
        fi
        if echo "$choice" | grep -q "^#"; then
            local ep_input=$(input_text "Episode number")
            [[ "$ep_input" =~ ^[0-9]+$ ]] || continue
            ep_input=$((10#$ep_input))
            [ "$ep_input" -ge 1 ] 2>/dev/null || continue
            [ "$ep_input" -le "$max" ] 2>/dev/null || ep_input=$max
            _episode_action "$mid" "$title" "$ep_input" "$total"
            continue
        fi
        local ep="${choice%%.*}"
        [[ ! "$ep" =~ ^[0-9]+$ ]] && continue
        _episode_action "$mid" "$title" "$ep" "$total"
    done
}

_episode_action() {
    local mid="$1" title="$2" ep="$3" total="$4"
    clear_screen; print_logo
    print_anime_title "$title - Episode $ep"
    echo ""
    local action
    action=$(printf '1. %s▶ Stream%s\n2. %s⬇ Torrent%s\n' \
        "$STYLE_SUCCESS" "$R" "$STYLE_INFO" "$R" \
        | menu_choice "${STYLE_MENU_NUM}Playback options${R}:")
    [ -z "$action" ] && return
    local method="stream"
    case "$action" in *Torrent*) method="torrent" ;; esac
    AUTOPLAYING=false
    # esc/cancel goes straight back to the episode list; only failures pause
    play_loop "$mid" "$title" "$ep" "$total" "$method" || { echo ""; press_any_key; }
    AUTOPLAYING=false
}

# Smart episode selection for Continue Watching:
# 1. Find highest episode with a resume point (pos >= 30s)
# 2. If none: use progress + 1 (next unwatched after last completed)
# 3. Clamp to total episodes
# Then show stream options for that episode directly.
# ESC from stream options -> episode list. ESC from episode list -> continue watching.
_continue_watch_action() {
    local mid="$1" title="$2" total="$3" nx_ep="${4:-}" nx_at="${5:-}" e_st="${6:-}" e_pr="${7:-}" mal_id="${8:-}"
    # Use passed details from list query (OPT-4) - no need to refetch
    if [ -n "$e_st" ] && [ "$e_st" != "" ]; then
        media_entry_prime "$mid" "$e_st" "$e_pr" "$mal_id"
    fi
    # Find last episode with a resume point (pos >= RESUME_MIN_SECONDS)
    local last_resume_ep=0 ep resume
    for ((ep=1; ep<=total; ep++)); do
        resume=$(resume_get "$mid" "$ep")
        [ -n "$resume" ] && last_resume_ep=$ep
    done
    # Calculate start episode
    local start_ep
    if [ "$last_resume_ep" -gt 0 ]; then
        start_ep=$last_resume_ep
    else
        local entry=$(media_entry "$mid")
        local progress=$(echo "$entry" | cut -f2)
        start_ep=$((progress + 1))
        [ "$start_ep" -gt "$total" ] && start_ep=$total
    fi
    # Show stream options for the smart episode
    _episode_action "$mid" "$title" "$start_ep" "$total"
    # If user ESC'd from stream options, show episode list (skip prefetch for speed)
    show_episode_screen "$mid" "$title" "$total" "$nx_ep" "$nx_at" "" "" "skip_prefetch" "$start_ep"
}

_sort_continue_results() { # $1=results → sorted output
    while IFS=$'\t' read -r mid info prog status score uat; do
        [ -z "$mid" ] && continue
        local lw=0
        [ -n "${LAST_WATCHED_DIR:-}" ] && [ -f "$LAST_WATCHED_DIR/$mid" ] && lw=$(cat "$LAST_WATCHED_DIR/$mid" 2>/dev/null)
        [[ "$lw" =~ ^[0-9]+$ ]] || lw=0
        [[ "$uat" =~ ^[0-9]+$ ]] || uat=0
        [ "$uat" -gt "$lw" ] && lw=$uat
        printf '%s\t%s\t%s\t%s\t%s\n' "$lw" "$mid" "$info" "$prog" "$status"
    done <<< "$1" | sort -t$'\t' -k1,1nr
}

show_continue_watching() {
    while true; do
        # Show cached list immediately if available, then refresh in background
        local cached_json="" cached_results=""
        cached_json=$(_anilist_cache_get "lists_${user_id}" 300 2>/dev/null || true)
        if [ -n "$cached_json" ] && _anilist_valid "$cached_json"; then
            cached_results=$(parse_user_list "$cached_json")
        fi
        if [ -n "$cached_results" ]; then
            results="$cached_results"
            clear_screen; print_logo
            local sorted_results
            sorted_results=$(_sort_continue_results "$results")
            _render_continue_list "$sorted_results" "cached" || return
            # Refresh in background
            ( anilist_current_lists "$user_id" >/dev/null 2>&1 ) &
            continue
        fi
        # No cache - fetch fresh
        print_info "Loading your list..."
        local json results
        json=$(anilist_current_lists "$user_id")
        results=$(parse_user_list "$json")
        if [ -z "$results" ]; then
            print_info "Nothing currently watching."; echo ""; press_any_key; return
        fi
        clear_screen; print_logo
        local sorted_results
        sorted_results=$(_sort_continue_results "$results")
        _render_continue_list "$sorted_results" "fresh" || return
    done
}

_render_continue_list() {
    local sorted_results="$1"
    local cache_source="${2:-fresh}"
    local choices="" n=0
    local -a map_mid=() map_total=() map_prog=() map_title=() map_nx_ep=() map_nx_at=() map_mal_id=() map_e_st=() map_e_pr=()
    while IFS=$'\t' read -r lwkey mid info prog status score uat nx_ep nx_at mal_id e_st e_pr; do
        [ -z "$mid" ] && continue
        n=$((n + 1))
        local ep=$(echo "$prog" | cut -d'/' -f1)
        local total=$(echo "$prog" | cut -d'/' -f2)
        local t=$(echo "$info" | sed 's/ ([0-9?]*)$//')
        local tag=""
        [ "$status" = "REPEATING" ] && tag=" ${STYLE_BOLD}(rewatching)${R}"
        choices+="${n}. ${t} (${ep}/${total})${tag}"$'\n'
        map_mid+=("$mid"); map_total+=("$total"); map_prog+=("$ep"); map_title+=("$t")
        map_nx_ep+=("$nx_ep"); map_nx_at+=("$nx_at"); map_mal_id+=("$mal_id")
        map_e_st+=("$e_st"); map_e_pr+=("$e_pr")
    done <<< "$sorted_results"
    [ "$n" -eq 0 ] && return 1
    # Warm detail pages for the top entries in the background.
    ( for pf_mid in "${map_mid[@]:0:8}"; do anilist_media_details "$pf_mid" >/dev/null 2>&1; done ) &
    local choice=$(echo -e "$choices" | menu_choice "${STYLE_MENU_NUM}Continue watching${R}:")
    # ESC from fzf (exit code 130) returns empty choice — return to caller
    # (main menu) instead of looping, so the user can actually back out.
    [ -z "$choice" ] && return 1
    local num="${choice%%.*}"
    [[ "$num" =~ ^[0-9]+$ ]] || return 0
    local idx=$((num - 1))
    [ $idx -lt 0 ] || [ $idx -ge ${#map_mid[@]} ] && return 0
    _continue_watch_action "${map_mid[$idx]}" "${map_title[$idx]}" "${map_total[$idx]}" \
        "${map_nx_ep[$idx]}" "${map_nx_at[$idx]}" "${map_e_st[$idx]}" "${map_e_pr[$idx]}" "${map_mal_id[$idx]}"
    return 0
}

show_popular_flow() {
    local sub=$(echo -e "1. Popular This Season"$'\n'"2. All Time Popular" | menu_choice "${STYLE_MENU_NUM}Popular${R}:")
    [ -z "$sub" ] && return
    local json label
    if echo "$sub" | grep -q "^1"; then
        print_info "Loading popular this season..."
        json=$(anilist_current_season_cached)
        label="Popular this season"
    else
        print_info "Loading all time popular..."
        json=$(anilist_all_time_popular_cached)
        label="All time popular"
    fi
    local results=$(parse_seasonal "$json")
    if [ -z "$results" ]; then
        print_error "Could not load list"; echo ""; press_any_key; return
    fi
    clear_screen; print_logo
    local choices="" n=0
    local -a map_mid=() map_eps=()
    while IFS=$'\t' read -r mid t eps score genres studio; do
        [ -z "$mid" ] && continue
        n=$((n + 1))
        choices+="${n}. ${t}"$'\n'
        map_mid+=("$mid"); map_eps+=("${eps%pep}")
    done <<< "$results"
    # Warm detail pages for the top entries in the background.
    ( for pf_mid in "${map_mid[@]:0:8}"; do anilist_media_details "$pf_mid" >/dev/null 2>&1; done ) &
    local choice=$(echo -e "$choices" | menu_choice "${STYLE_MENU_NUM}${label}${R}:")
    [ -z "$choice" ] && return
    local num="${choice%%.*}"
    [[ "$num" =~ ^[0-9]+$ ]] || return
    local idx=$((num - 1))
    [ $idx -lt 0 ] || [ $idx -ge ${#map_mid[@]} ] && return
    show_anime_detail_page "${map_mid[$idx]}" "" "${map_eps[$idx]}"
}

# ── Settings ──────────────────────────────────────────────────────

show_settings_flow() {
while true; do
        clear_screen; print_logo
        print_title_online "$user_name"
        echo ""
        local sync_label="${STYLE_SUCCESS}On${R}"
        [ "$anilist_sync" != "true" ] && sync_label="${STYLE_ERROR}Off (tracking paused)${R}"
        local items="" i=1
        items+="sync\t${i}. ${STYLE_MENU_TEXT}AniList Sync: ${R}${sync_label}"$'\n'; i=$((i+1))
        items+="source\t${i}. ${STYLE_MENU_TEXT}Preferred Source: ${R}${STYLE_INFO}${provider}${R}"$'\n'; i=$((i+1))
        items+="tprovider\t${i}. ${STYLE_MENU_TEXT}Torrent Provider: ${R}${STYLE_INFO}${torrent_provider}${R}"$'\n'; i=$((i+1))
        items+="quality\t${i}. ${STYLE_MENU_TEXT}Preferred Quality: ${R}$(get_quality_style "${quality}p")${quality}p${R}"$'\n'; i=$((i+1))
        items+="buffer\t${i}. ${STYLE_MENU_TEXT}Torrent Buffer: ${R}${STYLE_ANIME_INFO}${torrent_buffer}MB${R}"$'\n'; i=$((i+1))
        items+="clearcache\t${i}. ${STYLE_MENU_TEXT}Clear Cache${R}"$'\n'; i=$((i+1))
        items+="reset\t${i}. ${STYLE_MENU_TEXT}Reset to Defaults${R}"
        local choice=$(echo -e "$items" | menu_choice "${STYLE_MENU_NUM}Settings${R}:" --delimiter=$'\t' --with-nth=2..)
        [ -z "$choice" ] && return
        local key=$(echo "$choice" | cut -d$'\t' -f1)
        case "$key" in
            sync)
                if [ "$anilist_sync" = "true" ]; then anilist_sync="false"; else anilist_sync="true"; fi
                ;;
            source)
                local sp=$(choose_site_provider | cut -d$'\t' -f1)
                [ -n "$sp" ] && provider="$sp"
                ;;
            tprovider)
                local tp=$(choose_torrent_provider | cut -d$'\t' -f1)
                [ -n "$tp" ] && torrent_provider="$tp"
                ;;
            quality)
                local qitems="" q
                for q in 1080 720 480 360; do
                    local mark=""; [ "$q" = "$quality" ] && mark=" (current)"
                    qitems+="${q}\t$(get_quality_style "${q}p")${q}p${R}${mark}"$'\n'
                done
                local sel=$(echo -e "$qitems" | menu_choice "${STYLE_MENU_NUM}Quality${R}:" --delimiter=$'\t' --with-nth=2..)
                [ -n "$sel" ] && quality=$(echo "$sel" | cut -d$'\t' -f1)
                ;;
            buffer)
                local bitems="" b
                for b in 5 10 20 30 50 75 100 200 500; do
                    local mark=""; [ "$b" = "$torrent_buffer" ] && mark=" (current)"
                    bitems+="${b}\t${b}MB${mark}"$'\n'
                done
                local sel=$(echo -e "$bitems" | menu_choice "${STYLE_MENU_NUM}Buffer (MB)${R}:" --delimiter=$'\t' --with-nth=2..)
                [ -n "$sel" ] && torrent_buffer=$(echo "$sel" | cut -d$'\t' -f1)
                ;;
            clearcache)
                clear_all_caches
                print_success "Cache cleared"
                sleep 0.5
                ;;
            reset)
                quality="1080"
                [ ${#SITE_PROVIDERS[@]} -gt 0 ] && provider="${SITE_PROVIDERS[0]}"
                [ ${#TORRENT_PROVIDERS[@]} -gt 0 ] && torrent_provider="${TORRENT_PROVIDERS[0]}"
                torrent_buffer="50"
                subs_language="english"
                sub_or_dub="sub"
                anilist_sync="true"
                print_success "Defaults restored"
                sleep 0.5
                ;;
        esac
        : "${quality:=1080}" "${torrent_buffer:=50}" "${anilist_sync:=true}"
        [ -z "${provider:-}" ] && [ ${#SITE_PROVIDERS[@]} -gt 0 ] && provider="${SITE_PROVIDERS[0]}"
        [ -z "${torrent_provider:-}" ] && [ ${#TORRENT_PROVIDERS[@]} -gt 0 ] && torrent_provider="${TORRENT_PROVIDERS[0]}"
        save_config
    done
}

# ── Main Menu ─────────────────────────────────────────────────────

main_menu() {
    while true; do
        clear_screen; print_logo
        print_title_online "$user_name"
        echo ""
        local items="1. Search Anime"$'\n'"2. Continue Watching"$'\n'"3. Popular"$'\n'"4. Settings"$'\n'"5. Exit"
        local choice=$(echo "$items" | menu_choice "${STYLE_MENU_NUM}Main menu${R}:")
        case "$choice" in
            *"Search"*)     show_search_screen ;;
            *"Continue"*)   show_continue_watching ;;
            *"Popular"*)    show_popular_flow ;;
            *"Setting"*)    show_settings_flow ;;
            *"Exit"*|"")    cleanup_exit ;;
        esac
    done
}

# ── CLI mode ──────────────────────────────────────────────────────

cli_direct() {
    case "$1" in
        search|s)
            shift; local q="$*"
            [ -z "$q" ] && q=$(input_text "Search"); [ -z "$q" ] && exit 1
            local json=$(anilist_search "$q")
            parse_search_results "$json" | while IFS=$'\t' read -r mid rest; do
                [ -n "$mid" ] && echo "$mid: $rest"
            done
            ;;
        continue|c)  show_continue_watching ;;
        popular)     local j=$(anilist_all_time_popular); parse_seasonal "$j" ;;
        seasonal)    local j=$(anilist_current_season); parse_seasonal "$j" ;;
        stream)
            shift; local mid="$1" ep="$2"
            [ -z "$mid" ] && print_error "Usage: ani-cli stream <media_id> <ep>" && exit 1
            [ -z "$ep" ] && ep=$(input_text "Episode")
            [[ "$ep" =~ ^[0-9]+$ ]] || { print_error "Episode must be a number"; exit 1; }
            ep=$((10#$ep))
            local json=$(anilist_media_details "$mid")
            local title=$(echo "$json" | sed -n 's/.*"userPreferred":"\([^"]*\)".*/\1/p' | head -1)
            [ -z "$title" ] && title="Anime #$mid"
            local total=$(echo "$json" | sed -n 's/.*"episodes":\([0-9][0-9]*\).*/\1/p' | head -1) || true
            [ -z "$total" ] && total="?"
            # Prime media entry cache for skip prefetch (status, progress, idMal)
            local details=$(parse_media_details "$json")
            if [ -n "$details" ]; then
                local e_st e_pr mal_id
                IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ mal_id e_st e_pr <<< "$details"
                [ -n "$e_st" ] && media_entry_prime "$mid" "$e_st" "$e_pr" "$mal_id"
            fi
            AUTOPLAYING=false
            play_loop "$mid" "$title" "$ep" "$total" "stream"
            ;;
        torrent|t)
            shift; local mid="$1" ep="$2"
            [ -z "$mid" ] && print_error "Usage: ani-cli torrent <media_id> <ep>" && exit 1
            [ -z "$ep" ] && ep=$(input_text "Episode")
            [[ "$ep" =~ ^[0-9]+$ ]] || { print_error "Episode must be a number"; exit 1; }
            ep=$((10#$ep))
            local json=$(anilist_media_details "$mid")
            local title=$(echo "$json" | sed -n 's/.*"userPreferred":"\([^"]*\)".*/\1/p' | head -1)
            [ -z "$title" ] && title="Anime #$mid"
            local total=$(echo "$json" | sed -n 's/.*"episodes":\([0-9][0-9]*\).*/\1/p' | head -1) || true
            [ -z "$total" ] && total="?"
            # Prime media entry cache for skip prefetch (status, progress, idMal)
            local details=$(parse_media_details "$json")
            if [ -n "$details" ]; then
                local e_st e_pr mal_id
                IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ mal_id e_st e_pr <<< "$details"
                [ -n "$e_st" ] && media_entry_prime "$mid" "$e_st" "$e_pr" "$mal_id"
            fi
            AUTOPLAYING=false
            play_loop "$mid" "$title" "$ep" "$total" "torrent"
            ;;
        auth) rm -f "$TOKEN_FILE" "$USERID_FILE"; anilist_auth; print_success "Authenticated!" ;;
        help|h|--help)
            echo "Usage: ani-cli [command] [args]"
            echo ""
            echo "Commands (no command = interactive menu):"
            echo "  search|s <query>      Search anime"
            echo "  continue|c            Continue watching"
            echo "  popular               All time popular"
            echo "  seasonal              Popular this season"
            echo "  stream <id> <ep>      Stream episode"
            echo "  torrent <id> <ep>     Torrent-stream episode"
            echo "  auth                  Re-authenticate"
            echo "  help                  Show this"
            echo ""
            echo "Config: ~/.config/ani-cli/config"
            echo "Data:   ~/.local/share/ani-cli/"
            ;;
        *) print_error "Unknown: $1"; exit 1 ;;
    esac
}
