# Torrent Provider Template
# Each provider lives in its own folder:
#   providers/torrent/<name>/<name>.sh
# Copy this file to providers/torrent/<name>/<name>.sh (drop the _
# prefix) and implement the two required functions. If the provider
# supports streaming, place the engine at
#   providers/torrent/<name>/torrent_stream.py
#
# A torrent provider searches a torrent index for anime episodes and
# returns downloadable .torrent file URLs or magnet links.

# ── Metadata ──────────────────────────────────────────────────────
PROVIDER_NAME="My Torrent Provider"

# ── Required functions ────────────────────────────────────────────

# Search for a torrent.
# Input:  $1 = anime name
#         $2 = episode number (zero-padded to 2 digits)
#         $3 = quality filter (e.g. "720", "1080")
# Output: JSON array to stdout, best-first. Each object:
#   { "name", "magnet", "group", "resolution", "size", "seeds",
#     "is_batch", "trusted", "target_season" }
# Required: name, seeds, magnet. target_season = season number parsed from
# the query (null when none) — the app passes it to the engine for batch
# file picking. Empty "[]" if none. Stderr must stay clean (app parses
# stdout as JSON).
provider_search() {
    local name="$1" episode="$2" quality="$3"
    : # TODO: search the index, output JSON
    echo "[]"
}

# Download a torrent file.
# Input:  $1 = torrent URL or magnet
#         $2 = output file path
# Return: 0 on success
provider_download() {
    local url="$1" output="$2"
    : # TODO: download the file
    return 1
}

# ── Optional hook: cache clearing ─────────────────────────────────
# Called by Settings → Clear Cache (generic dispatch). Wipe ALL of your
# provider's /tmp caches here.
provider_cache_clear() {
    : # TODO: rm -f your provider's cache files
    return 0
}
