# Site Provider Template
# Each provider lives in its own folder:
#   providers/sites/<name>/<name>.sh
# Copy this file to providers/sites/<name>/<name>.sh (drop the _ prefix),
# implement the two required functions, and the app picks it up
# automatically (validated at load time). Companion scripts (e.g. a
# <name>_serve.py proxy) live in the same folder.
#
# A site provider resolves an anime title + episode number to a
# playable video URL (m3u8 or mp4) that mpv can open.

# ── Metadata ──────────────────────────────────────────────────────
PROVIDER_NAME="My Site Provider"

# ── Optional playback metadata (consumed generically by core.sh) ──
# HTTP headers mpv should send for THIS provider's URLs:
# PROVIDER_HEADERS=("Referer: https://example.com/" "Origin: https://example.com")
# Extra mpv demuxer options:
# PROVIDER_LAVF_OPTS="--demuxer-lavf-o=allowed_segment_extensions=jpg"
#
# ── Optional local proxy convention ──────────────────────────────
# If provider_get_stream prints "serve:/path/to/file", the app runs:
#   python3 providers/sites/<name>/<name>_serve.py /path/to/file
# The script must print one line "http://127.0.0.1:PORT/..." to stdout,
# then serve forever. mpv plays that local URL.

# ── Required functions ────────────────────────────────────────────

# Search anime by title.
# Input:  $1 = search query
# Output: TSV lines to stdout: "id\ttitle\tyear\tepisodes"
# Return: 0 on success
provider_search() {
    local query="$1"
    : # TODO: curl/fetch the site's search API and print results
}

# Get a playable stream URL.
# Input:  $1 = AniList media id, $2 = episode number, $3 = quality, $4 = title
# Output: first line = video URL, or "serve:/path" (proxy convention above);
#         optional second line = "sub:/path/or/url" (subtitle file/URL)
provider_get_stream() {
    local id="$1" episode="$2" quality="$3" title="$4"
    : # TODO: scrape/extract the video URL and print it
}

# ── Optional hook ─────────────────────────────────────────────────
# Called by the app after playback ends. Remove one-shot temp artifacts
# (serve handoff files etc.). Keep caches — they make replays instant.
provider_cleanup() {
    : # TODO: rm -f your provider's /tmp artifacts
    return 0
}

# ── Optional hook: cache clearing ─────────────────────────────────
# Called by Settings → Clear Cache (generic dispatch). Wipe ALL of your
# provider's /tmp caches and handoff files here so a cache clear actually
# clears everything. Keeps nothing — user data lives outside /tmp.
provider_cache_clear() {
    : # TODO: rm -rf your provider's cache files/dirs
    return 0
}
