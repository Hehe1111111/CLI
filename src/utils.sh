# ── Utilities ─────────────────────────────────────────────────────

# Open a URL in the user's default browser, best-effort across platforms.
# Linux: xdg-open. macOS: open. Windows (Git Bash / MSYS): cmd start.
_open_url() {
    local url="$1"
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)  cmd /c start "" "$url" ;;
        Darwin*)                open "$url" ;;
        *)                      xdg-open "$url" ;;
    esac
}

check_deps() {
    local missing=()
    local cmd
    for cmd in curl jq fzf mpv python3; do
        if ! command -v "$cmd" &>/dev/null && ! command -v "$cmd.exe" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    [ ${#missing[@]} -eq 0 ] && return 0

    local hint
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
            if command -v choco &>/dev/null; then
                hint="choco install -y ${missing[*]/python3/python}"
            else
                hint="scoop install ${missing[*]/python3/python}   (or: choco install -y ${missing[*]/python3/python})"
            fi
            ;;
        Darwin*)
            hint="brew install ${missing[*]/python3/python}"
            ;;
        *)
            hint="sudo apt install ${missing[*]}   (or the dnf/pacman equivalents)"
            ;;
    esac
    print_error "Missing dependencies: ${missing[*]}"
    print_info "Install them with: $hint"
    print_info "Then re-run ani-cli. Site streaming needs all of: curl jq fzf mpv python3"
    exit 1
}

# Wipe every /tmp cache the app and its providers create. Keeps config,
# auth tokens, resume points, and last-watched stamps (those are data).
# Provider-owned caches are cleared through each provider's own
# provider_cache_clear hook — new providers integrate with zero src changes.
clear_all_caches() {
    rm -f /tmp/ani-cli_alcache_* \
          /tmp/ani-cli_pop_season /tmp/ani-cli_pop_alltime \
          /tmp/ani-cli_offset_* \
          /tmp/ani-cli_skip_*.lua /tmp/ani-cli_skip_*.ffmetadata \
          /tmp/ani-cli_prefetch_* \
          /tmp/ani-cli_started_* \
          /tmp/ani-cli_skiplua_* \
          /tmp/ani-cli_torrent_prefs.txt \
          /tmp/ani-cli_race_* \
          /tmp/ani-cli_torsearch_* \
          /tmp/ani-cli_nyaa_err.log \
          2>/dev/null
    local p
    for p in ${SITE_PROVIDERS[@]+"${SITE_PROVIDERS[@]}"}; do
        call_site_provider "$p" cache_clear
    done
    for p in ${TORRENT_PROVIDERS[@]+"${TORRENT_PROVIDERS[@]}"}; do
        call_torrent_provider "$p" cache_clear
    done
    return 0
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
player="$player"
quality="$quality"
provider="$provider"
torrent_provider="$torrent_provider"
subs_language="$subs_language"
use_external_menu="$use_external_menu"
image_preview="$image_preview"
sub_or_dub="$sub_or_dub"
torrent_buffer="$torrent_buffer"
anilist_sync="$anilist_sync"
skip_opening="$skip_opening"
EOF
}
