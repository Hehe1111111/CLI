# ── Provider Loader ───────────────────────────────────────────────
# Discovers and loads site (stream) and torrent providers.
# Each provider lives in its own folder:
#   providers/sites/<name>/<name>.sh      (+ optional <name>_serve.py, assets)
#   providers/torrent/<name>/<name>.sh    (+ optional engine/scripts)
# See providers/sites/_template.sh and providers/torrent/_template.sh.

if [ -z "${SCRIPT_DIR:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    export SCRIPT_DIR
fi
PROVIDERS_DIR="$SCRIPT_DIR/providers"

# Shared portable helpers (providers/common.sh) — also used by core.
[ -f "$PROVIDERS_DIR/common.sh" ] && source "$PROVIDERS_DIR/common.sh"

# ── Discovery ─────────────────────────────────────────────────────

load_site_providers() {
    SITE_PROVIDERS=()
    SITE_PROVIDER_NAMES=()
    local d f name
    for d in "$PROVIDERS_DIR/sites/"*/; do
        [ ! -d "$d" ] && continue
        name=$(basename "$d")
        [[ "$name" == _* ]] && continue
        f="$d${name}.sh"
        [ ! -f "$f" ] && continue
        if ! ( source "$f" && \
               declare -f provider_search >/dev/null && \
               declare -f provider_get_stream >/dev/null ) 2>/dev/null; then
            command -v print_warning >/dev/null && print_warning "Skipping invalid site provider: $name (missing interface functions)" \
                || echo "warning: skipping invalid site provider: $name" >&2
            continue
        fi
        PROVIDER_NAME=""   # reset — a provider that forgets it must not inherit the previous one
        source "$f"
        [ -z "${PROVIDER_NAME:-}" ] && PROVIDER_NAME="$name"
        SITE_PROVIDERS+=("$name")
        SITE_PROVIDER_NAMES+=("$PROVIDER_NAME")
    done
}

load_torrent_providers() {
    TORRENT_PROVIDERS=()
    TORRENT_PROVIDER_NAMES=()
    local d f name
    for d in "$PROVIDERS_DIR/torrent/"*/; do
        [ ! -d "$d" ] && continue
        name=$(basename "$d")
        [[ "$name" == _* ]] && continue
        f="$d${name}.sh"
        [ ! -f "$f" ] && continue
        if ! ( source "$f" && \
               declare -f provider_search >/dev/null && \
               declare -f provider_download >/dev/null ) 2>/dev/null; then
            command -v print_warning >/dev/null && print_warning "Skipping invalid torrent provider: $name (missing interface functions)" \
                || echo "warning: skipping invalid torrent provider: $name" >&2
            continue
        fi
        PROVIDER_NAME=""
        source "$f"
        [ -z "${PROVIDER_NAME:-}" ] && PROVIDER_NAME="$name"
        TORRENT_PROVIDERS+=("$name")
        TORRENT_PROVIDER_NAMES+=("$PROVIDER_NAME")
    done
}

# Path of a provider's folder (empty if not found)
provider_dir() {
    local kind="$1" name="$2"
    local d="$PROVIDERS_DIR/$kind/$name"
    [ -d "$d" ] && echo "$d"
}

# ── Dispatch ──────────────────────────────────────────────────────

# 90s: slow-backend providers (uniquestream) can exceed 45s on a fully cold
# chain (5 sequential calls at 10-23s each) and were killed mid-resolve.
# Esc cancels any wait interactively, so a generous ceiling costs nothing.
PROVIDER_TIMEOUT="${PROVIDER_TIMEOUT:-90}"

call_site_provider() {
    local provider_id="$1"; shift
    local func="provider_search"
    [ $# -ge 1 ] && func="$1" && shift
    local file="$PROVIDERS_DIR/sites/${provider_id}/${provider_id}.sh"
    [ ! -f "$file" ] && return 1
    case "$func" in
        search)       _with_timeout "$PROVIDER_TIMEOUT" bash -c "source '$PROVIDERS_DIR/common.sh' 2>/dev/null; source '$file' && provider_search \"\$@\"" _ "$@" ;;
        get_stream)   _with_timeout "$PROVIDER_TIMEOUT" bash -c "source '$PROVIDERS_DIR/common.sh' 2>/dev/null; source '$file' && provider_get_stream \"\$@\"" _ "$@" ;;
        # optional hook: remove the provider's temp artifacts after playback
        cleanup)      _with_timeout 10 bash -c "source '$file' && declare -f provider_cleanup >/dev/null 2>&1 && provider_cleanup" 2>/dev/null ;;
        # optional hook: wipe the provider's own caches (Settings → Clear Cache)
        cache_clear)  _with_timeout 15 bash -c "source '$file' && declare -f provider_cache_clear >/dev/null 2>&1 && provider_cache_clear" 2>/dev/null ;;
        *) return 1 ;;   # unknown function must error, never no-op silently
    esac
}

call_torrent_provider() {
    local provider_id="$1"; shift
    local func="$1"; shift
    local file="$PROVIDERS_DIR/torrent/${provider_id}/${provider_id}.sh"
    [ ! -f "$file" ] && return 1
    case "$func" in
        search)      _with_timeout "$PROVIDER_TIMEOUT" bash -c "source '$PROVIDERS_DIR/common.sh' 2>/dev/null; source '$file' && provider_search \"\$@\"" _ "$@" ;;
        download)    _with_timeout "$PROVIDER_TIMEOUT" bash -c "source '$PROVIDERS_DIR/common.sh' 2>/dev/null; source '$file' && provider_download \"\$@\"" _ "$@" ;;
        cache_clear) _with_timeout 15 bash -c "source '$file' && declare -f provider_cache_clear >/dev/null 2>&1 && provider_cache_clear" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

# ── Select menu ───────────────────────────────────────────────────

choose_site_provider() {
    if [ ${#SITE_PROVIDERS[@]} -eq 0 ]; then
        print_warning "No site providers found in providers/sites/"
        return 1
    fi
    local items="" i
    for i in "${!SITE_PROVIDERS[@]}"; do
        local mark=""
        [ "${SITE_PROVIDERS[$i]}" = "$provider" ] && mark=" (current)"
        items+="${SITE_PROVIDERS[$i]}\t${SITE_PROVIDER_NAMES[$i]}${mark}\n"
    done
    echo -e "$items" | menu_choice "${STYLE_MENU_NUM}Preferred source${R}:" --delimiter=$'\t' --with-nth=2..
}

choose_torrent_provider() {
    if [ ${#TORRENT_PROVIDERS[@]} -eq 0 ]; then
        print_warning "No torrent providers found in providers/torrent/"
        return 1
    fi
    local items="" i
    for i in "${!TORRENT_PROVIDERS[@]}"; do
        local mark=""
        [ "${TORRENT_PROVIDERS[$i]}" = "$torrent_provider" ] && mark=" (current)"
        items+="${TORRENT_PROVIDERS[$i]}\t${TORRENT_PROVIDER_NAMES[$i]}${mark}\n"
    done
    echo -e "$items" | menu_choice "${STYLE_MENU_NUM}Torrent provider${R}:" --delimiter=$'\t' --with-nth=2..
}
