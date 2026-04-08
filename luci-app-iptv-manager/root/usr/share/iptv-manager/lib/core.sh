#!/bin/sh
# ==========================================
# IPTV Manager — Core module
# Конфигурация, утилиты, инициализация
# ==========================================

IPTV_MANAGER_VERSION="3.21"

# Цвета
GREEN="\033[1;32m"; RED="\033[1;31m"; CYAN="\033[1;36m"
YELLOW="\033[1;33m"; MAGENTA="\033[1;35m"; NC="\033[0m"

# --- Загрузка defaults.conf ---
_CORE_DIR="$(cd "$(dirname "$0")" && pwd)"
_DEFAULTS_CONF="${IPTV_DEFAULTS_CONF:-/etc/iptv/defaults.conf}"
if [ -f "$_DEFAULTS_CONF" ]; then
    . "$_DEFAULTS_CONF"
fi

# --- Значения по умолчанию ---
IPTV_PORT="${IPTV_PORT:-8082}"
IPTV_BIND_ADDR="${IPTV_BIND_ADDR:-0.0.0.0}"
IPTV_DIR="${IPTV_DIR:-/etc/iptv}"
WWW_DIR="${WWW_DIR:-/www/iptv}"
CGI_DIR="${CGI_DIR:-/www/iptv/cgi-bin}"
RATE_LIMIT="${RATE_LIMIT:-60}"
BLOCK_DURATION="${BLOCK_DURATION:-300}"
GITHUB_REPO="${GITHUB_REPO:-whatuneeed/IPTV-Manager}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}}"
WGET_TIMEOUT="${WGET_TIMEOUT:-15}"
WGET_CONNECT_TIMEOUT="${WGET_CONNECT_TIMEOUT:-10}"
SERVER_START_TRIES="${SERVER_START_TRIES:-15}"

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"

# --- Файловые пути ---
PLAYLIST_FILE="${PLAYLIST_FILE:-$IPTV_DIR/playlist.m3u}"
CONFIG_FILE="${CONFIG_FILE:-$IPTV_DIR/iptv.conf}"
PROVIDER_CONFIG="${PROVIDER_CONFIG:-$IPTV_DIR/provider.conf}"
EPG_GZ="${EPG_GZ:-/tmp/iptv-epg.xml.gz}"
EPG_TD="${EPG_TD:-/tmp/iptv-epg-dl.xml}"
EPG_CONFIG="${EPG_CONFIG:-$IPTV_DIR/epg.conf}"
SCHEDULE_FILE="${SCHEDULE_FILE:-$IPTV_DIR/schedule.conf}"
FAVORITES_FILE="${FAVORITES_FILE:-$IPTV_DIR/favorites.json}"
SECURITY_FILE="${SECURITY_FILE:-$IPTV_DIR/security.conf}"
HTTPD_PID="${HTTPD_PID:-/var/run/iptv-httpd.pid}"
STARTUP_TIME="${STARTUP_TIME:-/tmp/iptv-start.ts}"
RATE_FILE="${RATE_FILE:-/var/run/iptv-ratelimit}"
MERGED_PL="${MERGED_PL:-/tmp/iptv-merged.m3u}"
WHITELIST_FILE="${WHITELIST_FILE:-$IPTV_DIR/ip_whitelist.txt}"

# --- Создание директорий ---
core_init() {
    mkdir -p "$IPTV_DIR" || return 1

    # Install defaults.conf if not present
    if [ ! -f "$IPTV_DIR/defaults.conf" ] && [ -f "$_CORE_DIR/defaults.conf" ]; then
        cp "$_CORE_DIR/defaults.conf" "$IPTV_DIR/defaults.conf"
    fi

    # Создаём конфиги если не существуют
    [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"
    [ -f "$EPG_CONFIG" ] || touch "$EPG_CONFIG"
    [ -f "$SCHEDULE_FILE" ] || touch "$SCHEDULE_FILE"
    [ -f "$FAVORITES_FILE" ] || echo "[]" > "$FAVORITES_FILE"
    [ -f "$SECURITY_FILE" ] || printf 'ADMIN_USER=""\nADMIN_PASS=""\nAPI_TOKEN=""\n' > "$SECURITY_FILE"
    [ -f "$WHITELIST_FILE" ] || touch "$WHITELIST_FILE"

    # LuCI UCI config
    if ! grep -q 'config iptv' /etc/config/iptv 2>/dev/null; then
        mkdir -p /etc/config
        printf 'config iptv main\n\toption enabled "1"\n' > /etc/config/iptv
    fi

    # Symlink
    local real_script="$IPTV_DIR/IPTV-Manager.sh"
    [ -f "$real_script" ] && ln -sf "$real_script" /usr/bin/iptv 2>/dev/null
}

# --- Вывод ---
echo_color() { echo -e "${MAGENTA}$1${NC}"; }
echo_success() { echo -e "${GREEN}$1${NC}"; }
echo_error() { echo -e "${RED}$1${NC}"; }
echo_info() { echo -e "${CYAN}$1${NC}"; }
PAUSE() { echo -ne "${YELLOW}Нажмите Enter...${NC}"; read dummy </dev/tty; }
get_ts() { date '+%d.%m.%Y %H:%M' 2>/dev/null || echo "—"; }

# --- Конфиги: save/load ---
save_config() { printf 'PLAYLIST_TYPE="%s"\nPLAYLIST_URL="%s"\nPLAYLIST_SOURCE="%s"\n' "$1" "$2" "$3" > "${CONFIG_FILE:-$IPTV_DIR/iptv.conf}"; }
load_config() { [ -f "${CONFIG_FILE:-$IPTV_DIR/iptv.conf}" ] && . "${CONFIG_FILE:-$IPTV_DIR/iptv.conf}"; }
load_epg() { [ -f "${EPG_CONFIG:-$IPTV_DIR/epg.conf}" ] && . "${EPG_CONFIG:-$IPTV_DIR/epg.conf}"; }
load_sched() {
    if [ -f "${SCHEDULE_FILE:-$IPTV_DIR/schedule.conf}" ]; then
        . "${SCHEDULE_FILE:-$IPTV_DIR/schedule.conf}"
    fi
    [ -z "$PLAYLIST_INTERVAL" ] && PLAYLIST_INTERVAL="0"
    [ -z "$EPG_INTERVAL" ] && EPG_INTERVAL="0"
    [ -z "$PLAYLIST_LAST_UPDATE" ] && PLAYLIST_LAST_UPDATE="--"
    [ -z "$EPG_LAST_UPDATE" ] && EPG_LAST_UPDATE="--"
}
save_sched() { printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' "$1" "$2" "$3" "$4" > "${SCHEDULE_FILE:-$IPTV_DIR/schedule.conf}"; }

# --- Утилиты ---
get_ch() {
    local n
    n=$(grep -c "^#EXTINF" "$PLAYLIST_FILE" 2>/dev/null || true)
    echo "${n:-0}"
}

file_size() {
    [ -f "$1" ] || { echo "0 B"; return; }
    local s
    s=$(wc -c < "$1" 2>/dev/null)
    s=$((s + 0))  # ensure numeric
    if [ "$s" -eq 0 ] 2>/dev/null; then echo "0 B"
    elif [ "$s" -gt 1048576 ] 2>/dev/null; then echo "$((s/1048576)) MB"
    elif [ "$s" -gt 1024 ] 2>/dev/null; then echo "$((s/1024)) KB"
    else echo "${s} B"; fi
}

int_text() { case "${1:-0}" in 0) echo "Выкл";; 1) echo "Каждый час";; 6) echo "Каждые 6ч";; 12) echo "Каждые 12ч";; 24) echo "Раз в сутки";; *) echo "Выкл";; esac; }

detect_builtin_epg() {
    [ -f "$PLAYLIST_FILE" ] || return 0
    local epg=""
    epg=$(head -5 "$PLAYLIST_FILE" | grep -o 'url-tvg="[^"]*"' | head -1 | sed 's/url-tvg="//;s/"//' || true)
    if [ -z "$epg" ]; then
        epg=$(head -5 "$PLAYLIST_FILE" | grep -o "url-tvg='[^']*'" | head -1 | sed "s/url-tvg='//;s/'//" || true)
    fi
    echo "$epg"
}

wget_opt() {
    local o="-q --timeout=${WGET_TIMEOUT}"
    wget --help 2>&1 | grep -q "no-check-certificate" && o="$o --no-check-certificate"
    echo "$o"
}

# --- Валидация ---
_validate_url() {
    case "$1" in
        http://*|https://*|rtsp://*|rtmp://*|udp://*|rtp://*) return 0 ;;
        *) return 1 ;;
    esac
}

_sanitize_str() { printf '%s' "$1" | tr -cd '[:print:]' | head -c 500; }
_sanitize_filename() { printf '%s' "$1" | tr -cd '[:alnum:]._-/'; }
_sanitize_cgi_idx() { case "$1" in ''|*[!0-9]*) echo "0";;*) echo "$1";;esac; }

_is_number() {
    case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;;
    esac
}
