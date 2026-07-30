#!/usr/bin/env bash
set -uo pipefail

VERSION="2.0.0"
APP="ani-cli"

# ── Paths ─────────────────────────────────────────────────────────
SCRIPT_SRC="$0"
if command -v readlink &>/dev/null && readlink -f "$0" &>/dev/null; then
    SCRIPT_SRC="$(readlink -f "$0")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
export SCRIPT_DIR
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/${APP}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/${APP}"
CONFIG_FILE="$CONFIG_DIR/config"
PROGRESS_DIR="$DATA_DIR/progress"
LAST_WATCHED_DIR="$DATA_DIR/last_watched"
CACHE_DIR="/tmp/${APP}-images"

# ── Migrate from the old "otaku" name ─────────────────────────────
OLD_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/otaku"
OLD_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/otaku"
[ ! -d "$CONFIG_DIR" ] && [ -d "$OLD_CONFIG_DIR" ] && mv "$OLD_CONFIG_DIR" "$CONFIG_DIR" 2>/dev/null
[ ! -d "$DATA_DIR" ] && [ -d "$OLD_DATA_DIR" ] && mv "$OLD_DATA_DIR" "$DATA_DIR" 2>/dev/null

mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$PROGRESS_DIR" "$LAST_WATCHED_DIR" "$CACHE_DIR"

# ── Defaults (never empty) ────────────────────────────────────────
# Providers are plugins: defaults come from discovery below, not names.
player="${player:-mpv}"
quality="${quality:-1080}"
provider="${provider:-}"
torrent_provider="${torrent_provider:-}"
subs_language="${subs_language:-english}"
use_external_menu="${use_external_menu:-false}"
image_preview="${image_preview:-false}"
sub_or_dub="${sub_or_dub:-sub}"
torrent_buffer="${torrent_buffer:-50}"
anilist_sync="${anilist_sync:-true}"
skip_opening="${skip_opening:-true}"
resume_min_seconds="${resume_min_seconds:-15}"

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Re-assert defaults in case the config file has empty values
: "${player:=mpv}" "${quality:=1080}" "${provider:=}" "${torrent_provider:=}"
: "${subs_language:=english}" "${sub_or_dub:=sub}" "${torrent_buffer:=50}" "${anilist_sync:=true}"

# Providers are dispatched via `bash -c`, which only inherits EXPORTED
# variables — without this the subtitle-language and sub/dub settings
# silently never reached the providers.
export quality subs_language sub_or_dub torrent_buffer skip_opening player resume_min_seconds

# ── Source modules ────────────────────────────────────────────────
for f in "$SCRIPT_DIR/src/"*.sh; do
    [ -f "$f" ] && source "$f"
done

# ── Provider discovery ────────────────────────────────────────────
load_site_providers
load_torrent_providers

# Default provider = first discovered; fall back if the configured one
# is no longer installed.
if [ ${#SITE_PROVIDERS[@]} -gt 0 ]; then
    case " ${SITE_PROVIDERS[*]} " in
        *" $provider "*) : ;;
        *) provider="${SITE_PROVIDERS[0]}" ;;
    esac
fi
if [ ${#TORRENT_PROVIDERS[@]} -gt 0 ]; then
    case " ${TORRENT_PROVIDERS[*]} " in
        *" $torrent_provider "*) : ;;
        *) torrent_provider="${TORRENT_PROVIDERS[0]}" ;;
    esac
fi

# ── Cleanup on Ctrl+C / kill ──────────────────────────────────────
# Kill a pidfile's process only when it still looks like ours — after a
# SIGKILL'd run the pidfile can hold a recycled PID of an unrelated process.
_cleanup_pidfile() { # $1=pidfile $2=process-name substring
    local f="$1" pat="$2" p comm i
    [ -f "$f" ] || return 0
    p=$(cat "$f" 2>/dev/null)
    rm -f "$f"
    [[ "$p" =~ ^[0-9]+$ ]] || return 0
    comm=$(ps -p "$p" -o comm= 2>/dev/null)
    case "$comm" in
        *"$pat"*)
            kill "$p" 2>/dev/null
            # stuck processes can ignore SIGTERM — escalate to SIGKILL
            for i in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$p" 2>/dev/null || break
                sleep 0.1 2>/dev/null || sleep 1
            done
            kill -9 "$p" 2>/dev/null
            ;;
    esac
    return 0
}

cleanup_exit() {
    trap - HUP INT TERM
    # kill the player first — mpv must never outlive the CLI
    _cleanup_pidfile /tmp/ani-cli_mpv.pid "mpv"
    _cleanup_pidfile /tmp/ani-cli_torrent_engine.pid "python"
    local pf
    for pf in /tmp/ani-cli_prep_*.state; do
        [ -f "$pf" ] && _cleanup_pidfile "$pf" "python"
    done
    kill $(jobs -p) 2>/dev/null
    stty sane 2>/dev/null
    printf '\033[?25h' 2>/dev/null
    clear_screen 2>/dev/null || clear
    print_logo 2>/dev/null
    print_info "Goodbye!"
    sleep 1
    clear
    exit 130
}
trap cleanup_exit HUP INT TERM

# Sweep stale pidfiles from crashed runs (SIGKILL skips the trap above):
# mpv, the torrent engine, and autoplay prep state files. A "searching"
# or dead-pid entry would otherwise confuse adoption in this run.
_cleanup_pidfile /tmp/ani-cli_mpv.pid "mpv"
_cleanup_pidfile /tmp/ani-cli_torrent_engine.pid "python"
for _stale in /tmp/ani-cli_prep_*.state; do
    [ -f "$_stale" ] && _cleanup_pidfile "$_stale" "python"
done
unset _stale 2>/dev/null || true

# ── Install self ──────────────────────────────────────────────────
install_self() {
    local target="${1:-$HOME/.local/bin/$APP}"
    mkdir -p "$(dirname "$target")"
    if [ ! -L "$target" ]; then
        ln -s "$SCRIPT_DIR/run.sh" "$target"
        echo -e " ${STYLE_SUCCESS}✓${R} Installed → $target"
        if [[ ":$PATH:" != *":$(dirname "$target"):"* ]]; then
            echo -e " ${STYLE_WARNING}⚠${R} Add to PATH: export PATH=\"\$PATH:$(dirname "$target")\""
        fi
        echo -e " ${STYLE_INFO}i${R} Run: $APP"
    fi
}

# Only auto-install in interactive mode (no args)
if [ $# -eq 0 ]; then
    install_self
fi

# ── Entry ─────────────────────────────────────────────────────────
check_deps

if [ $# -gt 0 ]; then
    access_token=""; user_id=""
    [ -f "$TOKEN_FILE" ] && access_token=$(cat "$TOKEN_FILE")
    [ -f "$USERID_FILE" ] && user_id=$(cat "$USERID_FILE")
    [ -f "$USERNAME_FILE" ] && user_name=$(cat "$USERNAME_FILE")
    case "$1" in help|h|--help|-h) cli_direct "$@"; exit 0 ;; esac
    [ -z "$user_id" ] && anilist_auth
    cli_direct "$@"
else
    access_token=""; user_id=""
    anilist_auth
    [ -f "$USERNAME_FILE" ] && user_name=$(cat "$USERNAME_FILE")
    save_config
    anilist_prefetch_home
    main_menu
fi
