#!/usr/bin/env bash
# ani-cli installer
#
# One-line install:
#   bash <(curl -sL https://raw.githubusercontent.com/Hehe1111111/CLI/main/install.sh)
#
# Works on Linux, macOS, and Windows (Git Bash / WSL).
set -e

REPO="${ANI_CLI_REPO:-https://github.com/Hehe1111111/CLI}"
APP="ani-cli"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP/app"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/$APP"

info() { printf '\033[0;36mi\033[0m %s\n' "$1"; }
ok()   { printf '\033[0;32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33m⚠\033[0m %s\n' "$1"; }

OS="$(uname -s)"
case "$OS" in
    Linux*)   PLATFORM=linux ;;
    Darwin*)  PLATFORM=mac ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
    *)        PLATFORM=unknown ;;
esac
info "Platform: $PLATFORM"

# ── Dependencies ──────────────────────────────────────────────────
# required: curl jq fzf mpv python3 | optional: python libtorrent (torrents)

install_deps_linux() {
    if command -v apt &>/dev/null; then
        sudo apt update && sudo apt install -y curl jq fzf mpv python3 git python3-libtorrent 2>/dev/null \
            || sudo apt install -y curl jq fzf mpv python3 git
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y curl jq fzf mpv python3 git rb_libtorrent-python3 2>/dev/null \
            || sudo dnf install -y curl jq fzf mpv python3 git
    elif command -v pacman &>/dev/null; then
        sudo pacman -Sy --noconfirm curl jq fzf mpv python git libtorrent-rasterbar 2>/dev/null \
            || sudo pacman -Sy --noconfirm curl jq fzf mpv python git
    elif command -v zypper &>/dev/null; then
        sudo zypper install -y curl jq fzf mpv python3 git python3-libtorrent-rasterbar 2>/dev/null \
            || sudo zypper install -y curl jq fzf mpv python3 git
    else
        warn "Unknown package manager — install manually: curl jq fzf mpv python3 git"
    fi
}

install_deps_mac() {
    if ! command -v brew &>/dev/null; then
        warn "Homebrew not found. Install from https://brew.sh first, then re-run."
        exit 1
    fi
    # bash: macOS ships bash 3.2, but the app uses fractional `read -t`
    # timeouts — brew bash (>=4) is required.
    brew install bash curl jq fzf mpv python git
    brew install libtorrent-rasterbar 2>/dev/null || warn "libtorrent not installed — torrent streaming unavailable (site streaming still works)"
    if [ "$(bash -c 'echo ${BASH_VERSINFO[0]}')" -lt 4 ] 2>/dev/null; then
        warn "System bash is <4 — run the app with: /opt/homebrew/bin/bash $(command -v ani-cli 2>/dev/null || echo ani-cli)"
    fi
}

install_deps_windows() {
    info "Windows detected (Git Bash/MSYS)."
    if command -v pacman &>/dev/null || [ -x "/usr/bin/pacman" ] || [ -x "/mingw64/bin/pacman" ]; then
        info "Installing via pacman (Git Bash built-in)..."
        (pacman -Sy --noconfirm curl jq fzf mpv python git 2>/dev/null) || \
        (/usr/bin/pacman -Sy --noconfirm curl jq fzf mpv python git 2>/dev/null) || \
        (/mingw64/bin/pacman -Sy --noconfirm curl jq fzf mpv python git 2>/dev/null) || true
    elif command -v scoop &>/dev/null; then
        scoop install curl jq fzf mpv python git
    elif command -v choco &>/dev/null; then
        choco install -y curl jq fzf mpv python git
    else
        warn "No package manager found. Run in Git Bash terminal (includes pacman) or install scoop/choco."
    fi
    warn "Torrent streaming needs Python libtorrent; on Windows use WSL for best results."
}

case "$PLATFORM" in
    linux)   install_deps_linux ;;
    mac)     install_deps_mac ;;
    windows) install_deps_windows ;;
    *)       warn "Unknown OS — install manually: curl jq fzf mpv python3 git" ;;
esac

# The app invokes `python3` everywhere — that name must resolve. A bare
# `python` is not enough (`python` is often Python 2 or missing entirely).
for cmd in curl jq fzf mpv python3; do
    command -v "$cmd" &>/dev/null || warn "missing: $cmd"
done

# Optionally: libtorrent for torrent streaming (site streaming works without).
if ! python3 -c "import libtorrent" 2>/dev/null; then
    case "$PLATFORM" in
        mac)      warn "libtorrent unavailable — torrent mode disabled (brew install libtorrent-rasterbar).";;
        windows)  warn "libtorrent unavailable — torrent mode disabled (pip install libtorrent).";;
        *)        warn "libtorrent unavailable — torrent mode disabled (install python3-libtorrent / libtorrent-rasterbar).";;
    esac
fi

# ── Install / update the app ──────────────────────────────────────
if [ -d "$APP_DIR/.git" ]; then
    info "Updating existing install..."
    git -C "$APP_DIR" fetch --depth 1 origin main
    git -C "$APP_DIR" reset --hard FETCH_HEAD
else
    mkdir -p "$(dirname "$APP_DIR")"
    git clone --depth 1 "$REPO" "$APP_DIR"
fi
chmod +x "$APP_DIR/run.sh"

mkdir -p "$BIN_DIR"
ln -sf "$APP_DIR/run.sh" "$BIN"
ok "Installed → $BIN"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "Add to PATH: export PATH=\"\$PATH:$BIN_DIR\"" ;;
esac

ok "Done. Run: $APP"
