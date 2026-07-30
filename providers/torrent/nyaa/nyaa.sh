# Nyaa.si Torrent Provider
# Uses nyaa_provider.py for RSS search + ranking + filtering

PROVIDER_NAME="Nyaa.si"

NYAA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NYAA_PY="${NYAA_PY:-$NYAA_DIR/nyaa_provider.py}"

provider_search() {
    local name="$1" episode="$2" quality="$3"
    local preferred_group="${4:-}"
    local preferred_res="${5:-}"

    # stderr goes to a debug log (truncated each call), NOT /dev/null —
    # invisible tracebacks cost days when ranking/parsing breaks.
    python3 "$NYAA_PY" search "$name" "$episode" "$quality" "$preferred_group" "$preferred_res" \
        2>/tmp/ani-cli_nyaa_err.log || echo "[]"
}

provider_download() {
    # nyaa emits magnets only — they are streamed via torrent_stream.py,
    # never downloaded as .torrent files. Refuse everything.
    echo "nyaa: magnets are streamed directly, not downloaded" >&2
    return 1
}

# Hook (generic dispatch, Settings → Clear Cache): wipe nyaa search caches.
provider_cache_clear() {
    rm -f /tmp/ani-cli_nyaa_search_* /tmp/ani-cli_nyaa_err.log 2>/dev/null
    return 0
}
