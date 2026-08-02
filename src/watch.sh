# ── Watch tracking: resume points, completion, OP/ED skip ─────────
# Local episode-time tracking lives in $PROGRESS_DIR (one file per
# episode: "<media_id>_<ep>" containing "pos_seconds duration_seconds").
# AniList handles anime/episode completion and statuses; this module
# only handles in-episode positions locally.

WATCH_COMPLETE_PCT=80   # an episode is "finished" at 80% watched
: "${RESUME_MIN_SECONDS:=15}"   # minimum position to save resume point (UX-1)

# ── AniList list-entry session cache ─────────────────────────────
# anilist_media_entry hits the network (~1s); everything on the play
# path needs it (status transitions, skip-times idMal, ep list), so
# cache it for the session and invalidate on writes.

declare -gA MEDIA_ENTRY_CACHE=()

media_entry() { # $1=mid → "status<TAB>progress<TAB>idMal" (cached)
    local mid="$1"
    [[ "$mid" =~ ^[0-9]+$ ]] || return 1
    [ "$mid" = "0" ] && return 1
    if [ -z "${MEDIA_ENTRY_CACHE[$mid]+x}" ]; then
        local e; e=$(anilist_media_entry "$mid")
        [ -z "$e" ] && return 1
        MEDIA_ENTRY_CACHE[$mid]="$e"
    fi
    echo "${MEDIA_ENTRY_CACHE[$mid]}"
}

# Seed the cache from an already-fetched details response.
media_entry_prime() { # $1=mid $2=status $3=progress $4=idMal
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" != "0" ] || return 0
    MEDIA_ENTRY_CACHE[$1]="${2}	${3:-0}	${4}"
}

media_entry_invalidate() { unset "MEDIA_ENTRY_CACHE[$1]" 2>/dev/null || :; }

# ── Resume point store ────────────────────────────────────────────

_resume_file() { echo "$PROGRESS_DIR/${1}_${2}"; }

resume_get() {  # → "<pos> <dur>" or nothing
    local f; f=$(_resume_file "$1" "$2")
    [ -f "$f" ] && cat "$f"
}

resume_save() { # $1=mid $2=ep $3=pos $4=dur
    local pos="${3%.*}" dur="${4%.*}"
    [[ "$pos" =~ ^[0-9]+$ ]] || return 1
    [ "$pos" -lt "$RESUME_MIN_SECONDS" ] && return 1   # ignore accidental early quits
    echo "$pos $dur" > "$(_resume_file "$1" "$2")"
}

resume_clear() { local f; f=$(_resume_file "$1" "$2"); rm -f "$f"; }

# Drop resume points for every episode before $2 (a later episode was
# completed, so earlier ones count as watched).
resume_clear_before() {
    local mid="$1" ep="$2" f n
    for f in "$PROGRESS_DIR/${mid}_"*; do
        [ -f "$f" ] || continue
        n="${f##*_}"
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -lt "$ep" ] && rm -f "$f"
    done
}

# ── mpv IPC position watcher ──────────────────────────────────────
# Starts a background python process that polls mpv's IPC socket and
# keeps the last known "pos duration" in an output file.

mpv_watch_start() { # $1=sock $2=outfile → prints watcher pid
    command -v python3 &>/dev/null || return 1
    # NOTE: the watcher's fds MUST be detached from this function's stdout.
    # Callers use $(mpv_watch_start ...) — if the background python kept the
    # pipe open, the command substitution would block until the watcher exits
    # (20s connect deadline), stalling every playback start and leaving the
    # watcher dead before mpv even launches (no resume points, ever).
    ANI_CLI_IPC="$1" python3 - "$2" >/dev/null 2>&1 <<'EOF' &
import json, os, socket, sys, time

# Cross-platform: POSIX gets a unix-socket path, Windows gets tcp://HOST:PORT
# (Git Bash/MSYS translate AF_UNIX differently per distribution, and mpv
# itself needs a tcp:// URL on native Windows).
ipc, out = os.environ["ANI_CLI_IPC"], sys.argv[1]
if ipc.startswith("tcp://"):
    host, port = ipc[6:].split(":", 1)
    connect_target = ("tcp", host, int(port))
else:
    connect_target = ("unix", ipc, None)

def connect():
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            if connect_target[0] == "tcp":
                s = socket.create_connection((connect_target[1], connect_target[2]), timeout=3)
            else:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(3)
                s.connect(connect_target[1])
            return s
        except OSError:
            time.sleep(0.3)
    return None

def get(s, prop):
    s.sendall((json.dumps({"command": ["get_property", prop]}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise OSError("closed")
        buf += chunk
    for line in buf.splitlines():
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if "data" in msg:
            return msg["data"]
    return None

s = connect()
if not s:
    sys.exit(0)
pos, dur = 0.0, 0.0
last_pos = 0.0
while True:
    try:
        p = get(s, "time-pos")
        d = get(s, "duration")
        if p is not None:
            pos = float(p)
        if d:
            dur = float(d)
        # Sanity filter: on a still-downloading torrent file mpv seeks to
        # EOF to read the mkv index — time-pos then reports the PROBE
        # position (pos == dur == file end) and duration fluctuates as the
        # file grows. Those samples must never become resume points or
        # false 80% completions. Natural end-of-file exits kill us anyway,
        # so discarding pos>=end samples costs nothing.
        # Relaxed: allow dur > 1 (was 10) to track position before full
        # duration is known; still require pos < dur - 0.5 to filter probes.
        sane = dur > 1 and 0 <= pos <= dur and pos < dur - 0.5
        if sane:
            with open(out, "w") as f:
                f.write(f"{pos:.0f} {dur:.0f}")
            last_pos = pos
        else:
            # Still update last_pos for seek detection even if filtered
            last_pos = pos
    except (OSError, ValueError):
        break
    # Poll every 1s (was 2s) for more responsive seek/end detection.
    # Also write immediately on large seeks (>5s jump) so quick skip-to-end
    # is captured even if user quits before next poll.
    if 'last_pos' in locals() and abs(pos - last_pos) > 5:
        if sane:
            with open(out, "w") as f:
                f.write(f"{pos:.0f} {dur:.0f}")
    time.sleep(1)
sys.exit(0)
EOF
    echo $!
}

# Launch mpv with IPC + optional resume/skip; blocks until mpv exits.
# $1=media_id $2=ep $3=display title $4=url $5=subfile(or "") $6=skip_lua(or "")
# remaining mpv args come from global MPV_EXTRA_ARGS array
play_mpv() {
    local mid="$1" ep="$2" title="$3" url="$4" sub="${5:-}" skip_lua="${6:-}"
    local posfile="/tmp/ani-cli_mpvpos_$$.txt"
    local mpv_log="/tmp/ani-cli_mpv_err.log"
    # mpv IPC: unix sockets on POSIX; tcp:// on Windows/MSYS where AF_UNIX
    # semantics diverge per runtime (MSYS2 vs Git Bash vs Cygwin). The
    # watcher connects through whichever scheme we set.
    local sock ipc_addr
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
            # Pick a random free port via bash's /dev/tcp trick is unreliable;
            # let the OS choose by binding 0 — python does this for us below.
            # Simpler: random high port; collision odds are tiny.
            sock="tcp://127.0.0.1:$((20000 + RANDOM % 20000))"
            ipc_addr="$sock"
            ;;
        *)
            sock="/tmp/ani-cli_mpv_$$.sock"
            ipc_addr="$sock"
            rm -f "$sock"
            ;;
    esac
    rm -f "$posfile"
    : > "$mpv_log"

    # --quiet (not --really-quiet): no status line spam, but errors still
    # land in $mpv_log — invisible diagnostics cost us a bug once already.
    # --ytdl=no: everything we play is a direct URL (HLS/file/bridge); the
    # youtube-dl hook would otherwise interrogate every http:// URL and add
    # a multi-second stall (or outright failure) before playback starts.
    local -a args=("$url" "--input-ipc-server=$ipc_addr" "--force-media-title=$title" "--quiet" "--ytdl=no")
    local start_pos=0
    local resume; resume=$(resume_get "$mid" "$ep")
    if [ -n "$resume" ]; then
        local rp="${resume%% *}"
        if [[ "$rp" =~ ^[0-9]+$ ]] && [ "$rp" -ge "$RESUME_MIN_SECONDS" ]; then
            args+=("--start=$rp")
            start_pos=$rp
        fi
    fi
    [ -n "$sub" ] && args+=("--sub-file=$sub")
    if [ -n "$skip_lua" ] && [ -f "$skip_lua" ]; then
        args+=("--script=$skip_lua")
        # OP/ED chapter markings on the mpv timeline
        local chaps="${skip_lua%.lua}.ffmetadata"
        [ -f "$chaps" ] && args+=("--chapters-file=$chaps")
    fi
    [ ${#MPV_EXTRA_ARGS[@]} -gt 0 ] && args+=("${MPV_EXTRA_ARGS[@]}")

    local watcher_pid=""
    watcher_pid=$(mpv_watch_start "$ipc_addr" "$posfile")
    local t0=$SECONDS user_killed=0
    # stdout → /dev/null: mpv's track list/AO/VO and ffmpeg keepalive spam
    # must never reach the terminal. stderr → log: real errors stay
    # diagnosable (surfaced as a tail on playback failure below).
    "$player" "${args[@]}" >/dev/null 2>"$mpv_log" &
    local mpv_pid=$!
    # pidfile lets cleanup_exit kill the player even if the CLI dies first
    echo "$mpv_pid" > /tmp/ani-cli_mpv.pid
    # esc in the terminal also closes the player
    while kill -0 "$mpv_pid" 2>/dev/null; do
        if _read_key 0.3 && _key_is_esc; then
            user_killed=1
            # mpv stuck on network I/O can ignore SIGTERM — escalate to
            # SIGKILL so the player never outlives the app.
            kill "$mpv_pid" 2>/dev/null
            local i
            for i in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$mpv_pid" 2>/dev/null || break
                sleep 0.1 2>/dev/null || sleep 1
            done
            kill -9 "$mpv_pid" 2>/dev/null
            break
        fi
    done
    wait "$mpv_pid" 2>/dev/null
    rm -f /tmp/ani-cli_mpv.pid
    local runtime=$((SECONDS - t0))

    # Final position: read poller file first (last known good position),
    # then try IPC query as supplement (handles skip-to-end where poller
    # may miss the final seek). IPC must not overwrite poller data on failure.
    local pos=0 dur=0
    [ -f "$posfile" ] && read -r pos dur < "$posfile"
    # IPC final-position query — skip on tcp:// (the socket test `-S` is
    # unix-only; on Windows we rely on the poller file the watcher already
    # wrote).
    if [ "${ipc_addr#tcp://}" = "$ipc_addr" ] && [ -S "$sock" ] && command -v python3 &>/dev/null; then
        local ipc_posfile="/tmp/ani-cli_mpvpos_$$_ipc.txt"
        local attempt=0
        while [ $attempt -lt 3 ]; do
            python3 - "$sock" <<'EOF' > "$ipc_posfile" 2>/dev/null || true
import socket, json, sys
sock = sys.argv[1]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1)
    s.connect(sock)
    for prop in ("time-pos", "duration"):
        s.sendall((json.dumps({"command": ["get_property", prop]}) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        for line in buf.splitlines():
            try:
                msg = json.loads(line)
                if "data" in msg:
                    if prop == "time-pos":
                        print(f"{float(msg['data']):.0f}", end=" ")
                    else:
                        print(f"{float(msg['data']):.0f}")
            except:
                pass
except:
    pass
EOF
            if [ -f "$ipc_posfile" ]; then
                local ipc_pos ipc_dur
                read -r ipc_pos ipc_dur < "$ipc_posfile"
                if [[ "$ipc_pos" =~ ^[0-9]+$ ]] && [[ "$ipc_dur" =~ ^[0-9]+$ ]]; then
                    pos="$ipc_pos"
                    dur="$ipc_dur"
                    rm -f "$ipc_posfile"
                    break
                fi
                rm -f "$ipc_posfile"
            fi
            attempt=$((attempt + 1))
            [ $attempt -lt 3 ] && sleep 0.5
        done
    fi

    [ -n "$watcher_pid" ] && kill "$watcher_pid" 2>/dev/null
    [ "${ipc_addr#tcp://}" = "$ipc_addr" ] && rm -f "$sock"
    rm -f "$posfile"

    # mpv died almost immediately without playing anything (and the user
    # didn't kill it): playback failed — surface the error and stop
    # instead of silently auto-advancing to the next episode.
    if [ "$user_killed" -eq 0 ] && [ "$runtime" -lt 4 ] && [ "${pos%.*}" = "0" ] && [ "${dur%.*}" = "0" ]; then
        echo -ne "\r\033[K" >&2   # don't append to a live status/bar line
        print_error "Playback failed to start"
        local eline
        grep -vE '^\s*$' "$mpv_log" 2>/dev/null | tail -3 | while IFS= read -r eline; do
            print_muted "  mpv: $eline"
        done
        return 1
    fi

    watch_record_result "$mid" "$ep" "$pos" "$dur" "$start_pos"
}

# Decide completed vs mid-watch; update AniList accordingly.
# $5 = position playback started at this session (resume point or 0).
watch_record_result() {
    local mid="$1" ep="$2" pos="${3%.*}" dur="${4%.*}" start="${5%.*}"
    [[ "$pos" =~ ^[0-9]+$ ]] || pos=0
    [[ "$dur" =~ ^[0-9]+$ ]] || dur=0
    [[ "$start" =~ ^[0-9]+$ ]] || start=0
    
    local crossed_threshold=0
    if [ "$dur" -gt 0 ]; then
        local threshold=$((dur * WATCH_COMPLETE_PCT / 100))
        # Complete only when the 80% point was crossed DURING this
        # session. Opening at a resume point already past 80% and
        # closing right away must not mark the episode complete.
        # Also treat skipping to the end (within 30s of duration) as completion.
        if [ "$start" -lt "$threshold" ] && [ "$pos" -ge "$threshold" ]; then
            crossed_threshold=1
        fi
        if [ "$pos" -ge $((dur - 30)) ] && [ "$dur" -gt 30 ]; then
            crossed_threshold=1
        fi
        # Also mark complete if watched >90% in this session regardless of start
        local session_watched=$((pos - start))
        if [ "$session_watched" -gt $((dur * 90 / 100)) ]; then
            crossed_threshold=1
        fi
    else
        # No duration known (watcher failed) - infer completion if
        # position is reasonably high and we watched a meaningful amount
        # this session (e.g. watched >5min in session and pos > 300s)
        local session_watched=$((pos - start))
        if [ "$pos" -ge 300 ] && [ "$session_watched" -ge 300 ]; then
            crossed_threshold=1
        fi
    fi
    
    if [ "$crossed_threshold" -eq 1 ]; then
        # Mark complete
        resume_clear "$mid" "$ep"
        resume_clear_before "$mid" "$ep"
        watch_mark_completed "$mid" "$ep"
        return
    fi
    
    # Save resume if meaningful progress
    if [ "$pos" -ge "$RESUME_MIN_SECONDS" ] && { [ "$dur" -eq 0 ] || [ "$pos" -lt "$dur" ]; }; then
        resume_save "$mid" "$ep" "$pos" "$dur"
    fi
    return 0   # an early esc quit is not a playback failure
}

# AniList: progress + status transitions on episode completion.
# Runs with retry (3 attempts, backoff) and logs failures.
watch_mark_completed() {
    [ "$anilist_sync" != "true" ] && return 0
    local mid="$1" ep="$2"
    local entry status progress
    entry=$(media_entry "$mid")
    status=$(echo "$entry" | cut -f1)
    progress=$(echo "$entry" | cut -f2)
    [[ "$progress" =~ ^[0-9]+$ ]] || progress=0
    local total="${ANIME_TOTAL_EPS:-0}"
    local st="$status"
    case "$status" in
        COMPLETED) st="REPEATING" ;;
        CURRENT|REPEATING) : ;;
        *) st="CURRENT" ;;   # unwatched/planning/paused/dropped -> watching
    esac
    [ "$ep" -lt "$progress" ] 2>/dev/null && [ "$st" != "REPEATING" ] && return 0
    if [ "$total" -gt 0 ] 2>/dev/null && [ "$ep" -ge "$total" ]; then
        st="COMPLETED"
    fi
    media_entry_invalidate "$mid"

    local attempt=1 max_attempts=3 delay=2
    while [ $attempt -le $max_attempts ]; do
        if anilist_update_progress "$mid" "$ep" "$st" >/dev/null 2>&1; then
            return 0
        fi
        local err_log="/tmp/ani-cli_anilist_err.log"
        echo "$(date '+%Y-%m-%d %H:%M:%S') watch_mark_completed mid=$mid ep=$ep attempt=$attempt failed" >> "$err_log"
        sleep $delay
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
    return 1
}

# AniList: mark "watching"/"rewatching" as soon as playback starts.
watch_mark_started() {
    [ "$anilist_sync" != "true" ] && return 0
    local mid="$1"
    local flag="/tmp/ani-cli_started_${mid}"
    [ -f "$flag" ] && return 0
    touch "$flag"
    local entry status
    entry=$(media_entry "$mid")
    status=$(echo "$entry" | cut -f1)
    case "$status" in
        CURRENT|REPEATING) : ;;
        COMPLETED) media_entry_invalidate "$mid"; anilist_set_status "$mid" "REPEATING" &>/dev/null || true ;;
        *)         media_entry_invalidate "$mid"; anilist_set_status "$mid" "CURRENT" &>/dev/null || true ;;
    esac
}

# ── OP/ED skip (AniSkip) ──────────────────────────────────────────
# Fetches skip intervals and writes a generated mpv lua script.
# Echoes the lua path, or nothing when unavailable.

aniskip_lua() { # $1=media_id $2=ep
    [ "$skip_opening" != "true" ] && return 1
    command -v python3 &>/dev/null || return 1
    local mid="$1" ep="$2"
    local mal_id
    # Route diagnostics to a stable log — the old code swallowed everything
    # with 2>/dev/null, which is why "aniskip doesn't work" was undiagnosable.
    local dbg="${ANISKIP_DEBUG:-/dev/null}"
    [ "$dbg" = "1" ] && dbg="/tmp/ani-cli_aniskip_err.log"
    mal_id=$(media_entry "$mid" | cut -f3)
    # Validate MAL ID: must be a positive integer (BUG-5 fix)
    if [[ ! "$mal_id" =~ ^[0-9]+$ ]] || [ "$mal_id" -eq 0 ] 2>/dev/null; then
        # Fallback: fetch mal_id directly from AniList details
        mal_id=$(anilist_media_details "$mid" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    m = d.get('data', {}).get('Media', {}) or {}
    print(m.get('idMal', '') or '')
except: pass
" 2>/dev/null)
        [ -n "$mal_id" ] && media_entry_prime "$mid" "" "0" "$mal_id"
    fi
    [[ "$mal_id" =~ ^[0-9]+$ ]] && [ "$mal_id" -gt 0 ] || return 1
    local cache="/tmp/ani-cli_skip_${mal_id}_${ep}.lua"
    if [ -f "$cache" ] && [ -n "$(find "$cache" -mtime -1 2>/dev/null)" ]; then
        if [ -s "$cache" ]; then
            echo "$cache"
            return 0
        fi
        # Cache exists but is empty (0 bytes) = previously confirmed no skip data.
        # Return without refetching to avoid redundant API calls.
        return 1
    fi
    local json
    json=$(curl -s --connect-timeout 5 --max-time 15 -H "User-Agent: ani-cli/1.0" "https://api.aniskip.com/v1/skip-times/${mal_id}/${ep}?types[]=op&types[]=ed" 2>"$dbg")
    [ -z "$json" ] && return 1
    # Generation lives in a standalone script (same pattern as uniquestream's
    # companion .py): the old inline heredoc broke silently when the nested
    # Lua quotes collided with bash's double-quoted -c body, producing rc=1
    # with empty stderr ("AniSkip doesn't work").
    local gen="${SCRIPT_DIR}/src/aniskip_gen.py"
    [ -f "$gen" ] || return 1
    echo "$json" | python3 "$gen" "$cache" 2>"$dbg"
    local rc=$?
    [ $rc -eq 2 ] && return 1
    if [ $rc -ne 0 ]; then
        rm -f "$cache" "${cache%.lua}.ffmetadata"
        return 1
    fi
    [ -s "$cache" ] && echo "$cache"
}
