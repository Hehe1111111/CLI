# ── UI: 1:1 translation of u.py theme ─────────────────────────────

R=$'\033[0m'
STYLE_BOLD=$'\033[1m'
STYLE_INFO=$'\033[0;36m'
STYLE_WARNING=$'\033[0;33m'
STYLE_ERROR=$'\033[0;31m'
STYLE_SUCCESS=$'\033[0;32m'
STYLE_MUTED=$'\033[1;90m'
STYLE_MENU_NUM=$'\033[1;37m'
STYLE_MENU_TEXT=$'\033[0;37m'
STYLE_ANIME_TITLE=$'\033[1;37m'
STYLE_ANIME_INFO=$'\033[1;90m'
STYLE_LOGO=$'\033[1;37m'

LOGO="
██▀██ ███▄██ ▀██▀     ██▀██ ██    ▀██▀
██▄██ ██ ▀██  ██  ██  ██    ██     ██
██░█▓ █▓░ █▓  █▓░     █▓░▄▄ █▓░▄▄  █▓░
▀▀ ▀▀ ▀▀  ▀▀ ▀▀▀▀     ▀▀▀▀▀ ▀▀▀▀▀ ▀▀▀▀
"

# fzf feature detection: `accept-or-print-query` lets enter accept the typed
# query when nothing matches — this powers "type an episode number into any
# episode menu to jump straight to it". Detected once at startup (rc=2 on an
# unknown bind action); older fzf/rofi keep the classic "Go to episode" item.
FZF_QUERY_JUMP=0
if [ "${use_external_menu:-false}" != "true" ] && command -v fzf >/dev/null 2>&1; then
    if printf 'x\n' | fzf -f x --bind 'enter:accept-or-print-query' >/dev/null 2>&1; then
        FZF_QUERY_JUMP=1
    fi
fi

# ── Core print functions ──────────────────────────────────────────

pe() { echo -e "$@"; }
c()  { echo -e "${1}${2}${R}"; }
cs() { echo -e "${1}${2}${R}" >&2; }

clear_screen() { printf "\033[2J\033[3J\033[H"; }

print_logo() {
    while IFS= read -r line; do
        echo -e "${STYLE_LOGO}${line}${R}"
    done <<< "$LOGO"
}

print_title_online()  {
    local name="${1:-$user_name}" style="$STYLE_BOLD"
    [ "${anilist_sync:-true}" != "true" ] && style="$STYLE_ERROR"
    echo -e "${style}󰀉 ${name}${R}"
}

print_error()   { cs "$STYLE_ERROR"   "$1"; }
print_success() { cs "$STYLE_SUCCESS" "$1"; }
print_warning() { cs "$STYLE_WARNING" "$1"; }
print_info()    { cs "$STYLE_INFO"    "$1"; }
print_muted()   { cs "$STYLE_MUTED"   "$1"; }

print_anime_title() { c "$STYLE_ANIME_TITLE" "$1"; }
print_anime_info()  { c "$STYLE_ANIME_INFO"  "$1"; }

get_quality_style() {
    # All qualities shown in muted grey — no per-resolution color.
    echo "$STYLE_MUTED"
}

# ── Formatters ────────────────────────────────────────────────────

format_timestamp() {
    local s=$1
    [ "$s" -le 0 ] 2>/dev/null && echo "" && return
    local h=$((s/3600)) m=$(((s%3600)/60)) sec=$((s%60))
    if [ "$h" -gt 0 ]; then printf "%02d:%02d:%02d" "$h" "$m" "$sec"
    else printf "%02d:%02d" "$m" "$sec"; fi
}

# ── Menu helpers (fzf-based, shows styled list) ───────────────────

# Prints the selection; returns fzf's exit code (130 on esc/abort) so
# callers can tell "accepted an empty/odd result" from "user went back".
menu_choice() {
    local prompt="$1"; shift 2>/dev/null || true
    if [ "$use_external_menu" = "true" ]; then
        rofi -dmenu -i -sort -p "$prompt" -mesg "$prompt"
    else
        local rc=0
        printf '\033[?25l' >&2
        fzf --cycle --reverse --ansi --info=hidden --no-border --pointer='' --bind 'esc:abort' --prompt "$prompt " --height='~40%' "$@" || rc=$?
        printf '\033[?25h' >&2
        return $rc
    fi
}

# Free-text input with proper esc/backspace handling.
# esc = cancel (prints nothing, returns 1); enter = accept.
input_text() {
    local prompt="$1"
    if [ "$use_external_menu" = "true" ]; then
        echo "" | rofi -dmenu -p "$prompt" -mesg "$prompt"
        return
    fi
    echo -n "${STYLE_MENU_NUM}${prompt}${R}: " >&2
    local val="" ch rest
    while true; do
        IFS= read -rs -n 1 ch || { echo "" >&2; return 1; }
        if [ "$ch" = $'\e' ]; then
            # drain escape sequence (arrows etc.) — only a lone esc cancels
            rest=""
            IFS= read -rs -t 0.05 -n 2 rest 2>/dev/null || true
            if [ -z "$rest" ]; then
                echo "" >&2
                return 1
            fi
            continue
        fi
        case "$ch" in
            ""|$'\n')
                echo "" >&2
                echo "$val"
                return 0
                ;;
            $'\x7f'|$'\b')
                if [ -n "$val" ]; then
                    val="${val%?}"
                    printf '\b \b' >&2
                fi
                ;;
            *)
                val+="$ch"
                printf '%s' "$ch" >&2
                ;;
        esac
    done
}

press_any_key() {
    echo -n "${STYLE_MUTED}Press any key to continue...${R}"
    read -s -n 1 || true
    echo ""
}