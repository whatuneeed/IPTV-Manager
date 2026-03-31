#!/bin/sh
# ==========================================
# IPTV Manager for OpenWrt v2.0
# ==========================================
# Полноценная веб-админка: Статус, Плейлист, EPG
# ==========================================

IPTV_MANAGER_VERSION="2.0"
GREEN="\033[1;32m"; RED="\033[1;31m"; CYAN="\033[1;36m"; YELLOW="\033[1;33m"; MAGENTA="\033[1;35m"; NC="\033[0m"
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"
IPTV_PORT="8082"
IPTV_DIR="/etc/iptv"
PLAYLIST_FILE="$IPTV_DIR/playlist.m3u"
CONFIG_FILE="$IPTV_DIR/iptv.conf"
PROVIDER_CONFIG="$IPTV_DIR/provider.conf"
EPG_FILE="$IPTV_DIR/epg.xml"
EPG_CONFIG="$IPTV_DIR/epg.conf"
SCHEDULE_FILE="$IPTV_DIR/schedule.conf"
HTTPD_PID="/var/run/iptv-httpd.pid"
SCHEDULER_PID="/var/run/iptv-scheduler.pid"

mkdir -p "$IPTV_DIR"

# ==========================================
# Утилиты
# ==========================================
echo_color() { echo -e "${MAGENTA}$1${NC}"; }
echo_success() { echo -e "${GREEN}$1${NC}"; }
echo_error() { echo -e "${RED}$1${NC}"; }
echo_info() { echo -e "${CYAN}$1${NC}"; }
PAUSE() { echo -ne "${YELLOW}Нажмите Enter...${NC}"; read dummy </dev/tty; }

get_ts() { date '+%d.%m.%Y %H:%M' 2>/dev/null || echo "—"; }

save_config() {
    printf 'PLAYLIST_TYPE="%s"\nPLAYLIST_URL="%s"\nPLAYLIST_SOURCE="%s"\n' "$1" "$2" "$3" > "$CONFIG_FILE"
}
load_config() { [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"; }
load_epg() { [ -f "$EPG_CONFIG" ] && . "$EPG_CONFIG"; }
load_sched() {
    if [ -f "$SCHEDULE_FILE" ]; then
        . "$SCHEDULE_FILE"
    else
        PLAYLIST_INTERVAL="0"; EPG_INTERVAL="0"
        PLAYLIST_LAST_UPDATE=""; EPG_LAST_UPDATE=""
    fi
}
save_sched() {
    printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' \
        "$1" "$2" "$3" "$4" > "$SCHEDULE_FILE"
}

get_ch() { [ -f "$PLAYLIST_FILE" ] && grep -c "^#EXTINF" "$PLAYLIST_FILE" 2>/dev/null || echo "0"; }

file_size() {
    [ -f "$1" ] || { echo "0 B"; return; }
    local s=$(wc -c < "$1" 2>/dev/null)
    if [ "$s" -gt 1048576 ] 2>/dev/null; then echo "$((s/1048576)) MB"
    elif [ "$s" -gt 1024 ] 2>/dev/null; then echo "$((s/1024)) KB"
    else echo "${s} B"; fi
}

int_text() {
    case "$1" in 0) echo "Выкл";; 1) echo "Каждый час";; 6) echo "Каждые 6ч";;
        12) echo "Каждые 12ч";; 24) echo "Раз в сутки";; *) echo "Выкл";; esac
}

# ==========================================
# Генерация CGI-админки НА РОУТЕРЕ (без CRLF проблем)
# ==========================================
generate_cgi() {
    cat > /www/iptv/cgi-bin/admin.cgi << 'CGIEND'
#!/bin/sh
# IPTV Manager CGI - generated on router
IPTV_DIR="/etc/iptv"
PL="$IPTV_DIR/playlist.m3u"
EC="$IPTV_DIR/iptv.conf"
PC="$IPTV_DIR/provider.conf"
EF="$IPTV_DIR/epg.xml"
EXC="$IPTV_DIR/epg.conf"
SC="$IPTV_DIR/schedule.conf"
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"
PORT="8082"

hdr() { printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'; }
json_hdr() { printf 'Content-Type: application/json\r\n\r\n'; }

# Parse M3U into channel list
# Output: name|url|group|logo|tvg-id
parse_m3u() {
    [ -f "$PL" ] || return
    local name="" url="" group="" logo="" tvgid=""
    while IFS= read -r line; do
        case "$line" in
            "#EXTINF:"*)
                name=$(echo "$line" | sed 's/.*,\(.*\)/\1/' | sed 's/ *$//')
                group=$(echo "$line" | grep -o 'group-title="[^"]*"' | sed 's/group-title="//;s/"//')
                logo=$(echo "$line" | grep -o 'tvg-logo="[^"]*"' | sed 's/tvg-logo="//;s/"//')
                tvgid=$(echo "$line" | grep -o 'tvg-id="[^"]*"' | sed 's/tvg-id="//;s/"//')
                [ -z "$name" ] && name="Unknown"
                [ -z "$group" ] && group="General"
                ;;
            "#EXTVLCOPT:"*) ;;
            "#EXTM3U"*) ;;
            "#EXTGRP:"*) group=$(echo "$line" | sed 's/#EXTGRP://') ;;
            "#KODIPROP:"*) ;;
            http*|https*|rtsp*|rtmp*|udp*|rtp*)
                url="$line"
                printf '%s|%s|%s|%s|%s\n' "$name" "$url" "$group" "$logo" "$tvgid"
                name=""; url=""; group=""; logo=""; tvgid=""
                ;;
        esac
    done < "$PL"
}

# Get current program from EPG for a channel
get_current_program() {
    local tvgid="$1"
    [ -z "$tvgid" ] && { echo "—"; return; }
    [ -f "$EF" ] || { echo "—"; return; }
    # Simple XMLTV parsing - find current program
    local now=$(date -u '+%Y%m%d%H%M%S' 2>/dev/null)
    if [ -n "$now" ]; then
        # Find programme for this channel that is currently airing
        local prog=$(awk -v ch="$tvgid" -v now="$now" '
            /<programme channel="/ { in_prog=1; channel=$0; gsub(/.*channel="([^"]+)".*/, "\\1", channel) }
            in_prog && /start="/ { start=$0; gsub(/.*start="([0-9]+).*/, "\\1", start) }
            in_prog && /stop="/ { stop=$0; gsub(/.*stop="([0-9]+).*/, "\\1", stop) }
            in_prog && /<title/ { title=$0; gsub(/.*<title[^>]*>([^<]+)<.*/, "\\1", title) }
            in_prog && /<\/programme>/ {
                if (channel == ch && start <= now && stop >= now) {
                    print title; exit
                }
                in_prog=0
            }
        ' "$EF" 2>/dev/null)
        [ -n "$prog" ] && echo "$prog" || echo "—"
    else
        echo "—"
    fi
}

# Get all groups from playlist
get_groups() {
    parse_m3u | awk -F'|' '{print $3}' | sort -u
}

# ==========================================
# Request handling
# ==========================================
METHOD="${REQUEST_METHOD:-GET}"
QUERY="${QUERY_STRING:-}"
CONTENT_LEN="${CONTENT_LENGTH:-0}"

# Read POST data
POST_DATA=""
if [ "$METHOD" = "POST" ] && [ "$CONTENT_LEN" -gt 0 ] 2>/dev/null; then
    POST_DATA=$(dd bs=1 count="$CONTENT_LEN" 2>/dev/null)
fi

# Determine action
ACTION=""
case "$METHOD" in
    GET)
        # Parse query string
        ACTION=$(echo "$QUERY" | sed -n 's/.*action=\([^&]*\).*/\1/p')
        ;;
    POST)
        ACTION=$(echo "$POST_DATA" | sed -n 's/.*action=\([^&]*\).*/\1/p')
        ;;
esac

# ==========================================
# API endpoints
# ==========================================
if [ -n "$ACTION" ]; then
    json_hdr
    case "$ACTION" in
        check_channel)
            URL=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            # Try to fetch first 1KB with 3s timeout
            if wget -q --timeout=3 --spider "$URL" 2>/dev/null || wget -q --timeout=3 -O /dev/null "$URL" 2>/dev/null; then
                printf '{"status":"ok","online":true}'
            else
                printf '{"status":"ok","online":false}'
            fi
            ;;
        update_channel)
            IDX=$(echo "$POST_DATA" | sed -n 's/.*idx=\([^&]*\).*/\1/p')
            NEW_URL=$(echo "$POST_DATA" | sed -n 's/.*new_url=\([^&]*\).*/\1/p')
            NEW_GROUP=$(echo "$POST_DATA" | sed -n 's/.*new_group=\([^&]*\).*/\1/p')
            if [ -n "$IDX" ] && [ -n "$NEW_URL" ]; then
                # Rebuild playlist with updated channel
                local tmp="/tmp/iptv-edit.m3u"
                echo "#EXTM3U" > "$tmp"
                local i=0
                while IFS= read -r line; do
                    case "$line" in
                        "#EXTINF:"*)
                            if [ "$i" -eq "$IDX" ] 2>/dev/null && [ -n "$NEW_GROUP" ]; then
                                line=$(echo "$line" | sed "s/group-title=\"[^\"]*\"/group-title=\"$NEW_GROUP\"/")
                            fi
                            echo "$line" >> "$tmp"
                            ;;
                        http*|https*|rtsp*|rtmp*|udp*|rtp*)
                            if [ "$i" -eq "$IDX" ] 2>/dev/null; then
                                echo "$NEW_URL" >> "$tmp"
                            else
                                echo "$line" >> "$tmp"
                            fi
                            i=$((i+1))
                            ;;
                        *) echo "$line" >> "$tmp" ;;
                    esac
                done < "$PL"
                cp "$tmp" "$PL"
                cp "$PL" /www/iptv/playlist.m3u
                printf '{"status":"ok","message":"Channel updated"}'
            else
                printf '{"status":"error","message":"Invalid data"}'
            fi
            ;;
        refresh_playlist)
            . "$EC" 2>/dev/null
            case "$PLAYLIST_TYPE" in
                url)
                    if wget -q --timeout=15 -O "$PL" "$PLAYLIST_URL" 2>/dev/null && [ -s "$PL" ]; then
                        cp "$PL" /www/iptv/playlist.m3u
                        CH=$(get_ch)
                        NT=$(get_ts)
                        load_sched
                        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$NT" "$EPG_LAST_UPDATE"
                        printf '{"status":"ok","message":"Playlist updated! Channels: '"$CH"'"}'
                    else
                        printf '{"status":"error","message":"Download failed"}'
                    fi;;
                provider)
                    . "$PC" 2>/dev/null
                    PU="http://${PROVIDER_SERVER:-$PROVIDER_NAME}/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"
                    if wget -q --timeout=15 -O "$PL" "$PU" 2>/dev/null && [ -s "$PL" ]; then
                        cp "$PL" /www/iptv/playlist.m3u
                        CH=$(get_ch)
                        NT=$(get_ts)
                        load_sched
                        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$NT" "$EPG_LAST_UPDATE"
                        printf '{"status":"ok","message":"Playlist updated! Channels: '"$CH"'"}'
                    else
                        printf '{"status":"error","message":"Download failed"}'
                    fi;;
                *) printf '{"status":"error","message":"Cannot refresh"}' ;;
            esac
            ;;
        refresh_epg)
            . "$EXC" 2>/dev/null
            if [ -n "$EPG_URL" ] && wget -q --timeout=30 -O "$EF" "$EPG_URL" 2>/dev/null && [ -s "$EF" ]; then
                cp "$EF" /www/iptv/epg.xml 2>/dev/null
                SZ=$(file_size "$EF")
                NT=$(get_ts); load_sched
                save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$NT"
                printf '{"status":"ok","message":"EPG updated! Size: '"$SZ"'"}'
            else
                printf '{"status":"error","message":"EPG download failed"}'
            fi
            ;;
        set_playlist_url)
            NEW_URL=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            if [ -n "$NEW_URL" ]; then
                printf 'PLAYLIST_TYPE="url"\nPLAYLIST_URL="%s"\nPLAYLIST_SOURCE=""\n' "$NEW_URL" > "$EC"
                if wget -q --timeout=15 -O "$PL" "$NEW_URL" 2>/dev/null && [ -s "$PL" ]; then
                    cp "$PL" /www/iptv/playlist.m3u
                    CH=$(get_ch)
                    NT=$(get_ts); load_sched
                    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$NT" "$EPG_LAST_UPDATE"
                    printf '{"status":"ok","message":"New playlist loaded! Channels: '"$CH"'"}'
                else
                    printf '{"status":"error","message":"Download failed"}'
                fi
            else
                printf '{"status":"error","message":"URL required"}'
            fi
            ;;
        set_epg_url)
            NEW_URL=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            if [ -n "$NEW_URL" ]; then
                printf 'EPG_URL="%s"\n' "$NEW_URL" > "$EXC"
                if wget -q --timeout=30 -O "$EF" "$NEW_URL" 2>/dev/null && [ -s "$EF" ]; then
                    cp "$EF" /www/iptv/epg.xml 2>/dev/null
                    SZ=$(file_size "$EF")
                    NT=$(get_ts); load_sched
                    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$NT"
                    printf '{"status":"ok","message":"EPG loaded! Size: '"$SZ"'"}'
                else
                    printf '{"status":"error","message":"EPG download failed"}'
                fi
            else
                printf '{"status":"error","message":"URL required"}'
            fi
            ;;
        set_schedule)
            PI=$(echo "$POST_DATA" | sed -n 's/.*playlist_interval=\([^&]*\).*/\1/p')
            EI=$(echo "$POST_DATA" | sed -n 's/.*epg_interval=\([^&]*\).*/\1/p')
            [ -z "$PI" ] && PI=0; [ -z "$EI" ] && EI=0
            load_sched
            save_sched "$PI" "$EI" "$PLAYLIST_LAST_UPDATE" "$EPG_LAST_UPDATE"
            if [ "$PI" -gt 0 ] || [ "$EI" -gt 0 ]; then
                kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null
                /bin/sh /tmp/iptv-scheduler.sh &
                printf '{"status":"ok","message":"Schedule saved"}'
            else
                kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null
                rm -f /var/run/iptv-scheduler.pid /tmp/iptv-scheduler.sh
                printf '{"status":"ok","message":"Schedule disabled"}'
            fi
            ;;
        *) printf '{"status":"error","message":"Unknown action"}' ;;
    esac
    exit 0
fi

# ==========================================
# HTML page generation
# ==========================================
hdr

. "$EC" 2>/dev/null
load_epg
load_sched

CH=$(get_ch)
PLSZ=$(file_size "$PL")
EPSZ=$(file_size "$EF")
PLURL=""; [ "$PLAYLIST_TYPE" = "url" ] && PLURL="$PLAYLIST_URL"
EPGURL=""; [ -n "$EPG_URL" ] && EPGURL="$EPG_URL"
PI="${PLAYLIST_INTERVAL:-0}"
EI="${EPG_INTERVAL:-0}"

# Get groups
GROUPS=$(get_groups)

cat << HTMLHEAD
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>IPTV Manager</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#0a0e1a;color:#e2e8f0;min-height:100vh}
.c{max-width:1200px;margin:0 auto;padding:16px}
.h{text-align:center;padding:20px 0 16px;border-bottom:1px solid #1e293b;margin-bottom:16px}
.h h1{font-size:22px;background:linear-gradient(135deg,#3b82f6,#8b5cf6);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.h p{color:#64748b;font-size:12px;margin-top:4px}
.st{display:grid;grid-template-columns:repeat(auto-fit,minmax(110px,1fr));gap:8px;margin-bottom:16px}
.s{background:#1e293b;border-radius:8px;padding:12px;text-align:center;border:1px solid #334155}
.sv{font-size:18px;font-weight:700;color:#3b82f6}
.sl{font-size:10px;color:#64748b;text-transform:uppercase;margin-top:2px}
.ub{background:#0f172a;border:1px solid #334155;border-radius:6px;padding:8px;margin:6px 0;display:flex;align-items:center;gap:6px}
.ub code{flex:1;font-size:12px;color:#3b82f6;word-break:break-all}
.ub button{padding:4px 8px;background:#334155;border:none;border-radius:4px;color:#e2e8f0;cursor:pointer;font-size:11px}
.tb{display:flex;gap:4px;margin-bottom:14px;background:#1e293b;border-radius:8px;padding:4px;overflow-x:auto}
.t{flex:1;padding:9px 10px;border:none;background:transparent;color:#94a3b8;border-radius:6px;cursor:pointer;font-size:12px;font-weight:500;white-space:nowrap}
.t:hover{color:#e2e8f0}.t.a{background:#3b82f6;color:#fff}
.pn{display:none;background:#1e293b;border-radius:12px;padding:16px;border:1px solid #334155;margin-bottom:10px}
.pn.a{display:block}
.pn h2{font-size:15px;margin-bottom:12px;color:#f1f5f9}
.fg{margin-bottom:10px}
.fg label{display:block;font-size:11px;color:#94a3b8;margin-bottom:3px}
.fg input,.fg textarea,.fg select{width:100%;padding:8px 10px;background:#0a0e1a;border:1px solid #334155;border-radius:6px;color:#e2e8f0;font-size:13px}
.fg input:focus,.fg textarea:focus{outline:none;border-color:#3b82f6}
.fg textarea{min-height:60px;font-family:monospace;font-size:11px;resize:vertical}
.b{padding:7px 14px;border:none;border-radius:6px;font-size:12px;font-weight:600;cursor:pointer;display:inline-block}
.bp{background:#3b82f6;color:#fff}.bp:hover{background:#2563eb}
.bd{background:#ef4444;color:#fff}.bd:hover{background:#dc2626}
.bs{background:#22c55e;color:#fff}.bs:hover{background:#16a34a}
.bsm{padding:5px 10px;font-size:11px}
.bg{display:flex;gap:6px;margin-top:10px;flex-wrap:wrap}
hr{border:none;border-top:1px solid #334155;margin:12px 0}

/* Channel list */
.ch-table{width:100%;border-collapse:collapse}
.ch-table th{text-align:left;padding:8px 10px;font-size:11px;color:#64748b;border-bottom:1px solid #334155;font-weight:500}
.ch-table td{padding:8px 10px;font-size:12px;border-bottom:1px solid #1e293b;vertical-align:middle}
.ch-table tr:hover{background:#334155}
.ch-status{width:10px;height:10px;border-radius:50%;display:inline-block}
.ch-status.online{background:#22c55e;box-shadow:0 0 6px #22c55e}
.ch-status.offline{background:#ef4444;box-shadow:0 0 6px #ef4444}
.ch-status.unknown{background:#64748b}
.ch-name{font-weight:500;max-width:200px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ch-group{color:#64748b;font-size:11px}
.ch-url{max-width:250px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#94a3b8;font-size:11px;font-family:monospace}
.ch-prog{color:#94a3b8;font-size:11px;max-width:200px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ch-actions{display:flex;gap:4px}

/* EPG table */
.epg-table{width:100%;border-collapse:collapse}
.epg-table th{text-align:left;padding:8px 10px;font-size:11px;color:#64748b;border-bottom:1px solid #334155}
.epg-table td{padding:8px 10px;font-size:12px;border-bottom:1px solid #1e293b}
.epg-table tr:hover{background:#334155}

/* Filter */
.filter-bar{display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap;align-items:center}
.filter-bar select{padding:6px 10px;background:#0a0e1a;border:1px solid #334155;border-radius:6px;color:#e2e8f0;font-size:12px}
.filter-bar input{padding:6px 10px;background:#0a0e1a;border:1px solid #334155;border-radius:6px;color:#e2e8f0;font-size:12px;flex:1;min-width:150px}

/* Modal */
.modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:100;align-items:center;justify-content:center}
.modal.open{display:flex}
.modal-box{background:#1e293b;border-radius:12px;padding:20px;border:1px solid #334155;max-width:500px;width:90%}
.modal-box h3{font-size:15px;margin-bottom:12px}

.toast{position:fixed;top:12px;right:12px;padding:10px 14px;border-radius:6px;font-size:12px;z-index:200;box-shadow:0 6px 20px rgba(0,0,0,.3)}
.to{background:#064e3b;border:1px solid #10b981;color:#6ee7b7}
.te{background:#7f1d1d;border:1px solid #ef4444;color:#fca5a5}
.ti{background:#1e3a5f;border:1px solid #3b82f6;color:#93c5fd}

.sg{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.sc{background:#0a0e1a;border-radius:8px;padding:12px;border:1px solid #334155}
.sc h3{font-size:12px;color:#f1f5f9;margin-bottom:8px}
.sc select{width:100%;padding:8px;background:#1e293b;border:1px solid #334155;border-radius:6px;color:#e2e8f0;font-size:12px}
.si{margin-top:8px;font-size:10px;color:#64748b}
.si span{color:#94a3b8}

.empty{text-align:center;padding:20px;color:#64748b}
.ft{text-align:center;padding:16px 0;color:#475569;font-size:10px}
@media(max-width:700px){.st{grid-template-columns:repeat(2,1fr)}.sg{grid-template-columns:1fr}.bg{flex-direction:column}.ch-table{font-size:11px}}
</style>
</head>
<body>
<div class="c">
<div class="h"><h1>IPTV Manager</h1><p>OpenWrt</p></div>
<div class="st">
<div class="s"><div class="sv">$CH</div><div class="sl">Channels</div></div>
<div class="s"><div class="sv">$PLSZ</div><div class="sl">Playlist</div></div>
<div class="s"><div class="sv">$EPSZ</div><div class="sl">EPG</div></div>
</div>
<div class="ub"><code>http://$LAN_IP:$PORT/playlist.m3u</code><button onclick="cp(this)">Copy</button></div>
<div class="ub"><code>http://$LAN_IP:$PORT/epg.xml</code><button onclick="cp(this)">Copy</button></div>
<div class="tb">
<button class="t a" onclick="st('status',this)">Status</button>
<button class="t" onclick="st('playlist',this)">Playlist</button>
<button class="t" onclick="st('epg',this)">EPG</button>
<button class="t" onclick="st('settings',this)">Settings</button>
</div>

<!-- STATUS TAB -->
<div class="pn a" id="p-status">
<h2>Channels Status</h2>
<div class="filter-bar">
<select id="f-group" onchange="filterCh()"><option value="">All groups</option>
HTMLHEAD

get_groups | while IFS= read -r g; do
    [ -n "$g" ] && echo "<option value=\"$g\">$g</option>"
done >> /www/iptv/cgi-bin/admin.cgi

cat >> /www/iptv/cgi-bin/admin.cgi << 'HTMLMID'
</select>
<input type="text" id="f-search" placeholder="Search channels..." oninput="filterCh()">
<button class="b bp bsm" onclick="checkAll()">Check All</button>
</div>
<div style="overflow-x:auto">
<table class="ch-table">
<thead><tr>
<th style="width:20px"></th>
<th>Name</th>
<th>Group</th>
<th>Now Playing</th>
<th style="width:80px">Status</th>
<th>Actions</th>
</tr></thead>
<tbody id="ch-tbody">
HTMLMID

# Generate channel rows
IDX=0
parse_m3u | while IFS='|' read -r name url group logo tvgid; do
    prog=$(get_current_program "$tvgid")
    cat << CHROW
<tr data-group="$group" data-name="$name" data-idx="$IDX" data-url="$url">
<td><span class="ch-status unknown" id="st-$IDX"></span></td>
<td class="ch-name" title="$name">$name</td>
<td class="ch-group">$group</td>
<td class="ch-prog" title="$prog">$prog</td>
<td><button class="b bsm bp" onclick="checkCh($IDX,'$url')">Ping</button></td>
<td class="ch-actions">
<button class="b bsm bp" onclick="editCh($IDX)" title="Edit">Edit</button>
</td>
</tr>
CHROW
    IDX=$((IDX+1))
done >> /www/iptv/cgi-bin/admin.cgi

cat >> /www/iptv/cgi-bin/admin.cgi << 'HTMLEND'
</tbody></table></div>
</div>

<!-- PLAYLIST TAB -->
<div class="pn" id="p-playlist">
<h2>Playlist Editor</h2>
<div class="fg">
<label>Playlist URL</label>
<div style="display:flex;gap:6px">
<input type="url" id="pl-url" placeholder="http://example.com/playlist.m3u" value="">
<button class="b bp bsm" onclick="setPlUrl()">Apply</button>
<button class="b bs bsm" onclick="act('refresh_playlist','')">Refresh</button>
</div>
</div>
<hr>
<div class="fg">
<label>Raw M3U Content</label>
<textarea id="pl-raw" readonly style="min-height:200px"></textarea>
</div>
</div>

<!-- EPG TAB -->
<div class="pn" id="p-epg">
<h2>EPG TV Guide</h2>
<div class="fg">
<label>EPG URL</label>
<div style="display:flex;gap:6px">
<input type="url" id="epg-url" placeholder="http://epg.example.com/epg.xml" value="">
<button class="b bp bsm" onclick="setEpgUrl()">Apply</button>
<button class="b bs bsm" onclick="act('refresh_epg','')">Refresh</button>
</div>
</div>
<hr>
<h3>Programs</h3>
<div style="overflow-x:auto">
<table class="epg-table">
<thead><tr><th>Time</th><th>Channel</th><th>Program</th></tr></thead>
<tbody id="epg-tbody">
HTMLEND

# Parse EPG programs (first 50)
if [ -f "$EF" ]; then
    awk '
        /<programme / {
            start=""; stop=""; channel=""; title=""
            match($0, /start="([0-9]+)/, a); start=a[1]
            match($0, /stop="([0-9]+)/, a); stop=a[1]
            match($0, /channel="([^"]+)"/, a); channel=a[1]
        }
        /<title[^>]*>/ {
            match($0, /<title[^>]*>([^<]+)<\/title>/, a); title=a[1]
        }
        /<\/programme>/ {
            if (title != "" && channel != "") {
                # Format time
                t = substr(start, 9, 2) ":" substr(start, 11, 2)
                printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n", t, channel, title
                count++
                if (count >= 50) exit
            }
        }
    ' "$EF" 2>/dev/null >> /www/iptv/cgi-bin/admin.cgi
fi

cat >> /www/iptv/cgi-bin/admin.cgi << 'HTMLEND2'
</tbody></table></div>
</div>

<!-- SETTINGS TAB -->
<div class="pn" id="p-settings">
<h2>Settings</h2>
<div class="sg">
<div class="sc"><h3>Playlist Schedule</h3>
<select id="s-pl">
<option value="0">Off</option>
<option value="1">Every hour</option>
<option value="6">Every 6h</option>
<option value="12">Every 12h</option>
<option value="24">Every 24h</option>
</select>
<div class="si">Last: <span id="pl-last">—</span></div></div>
<div class="sc"><h3>EPG Schedule</h3>
<select id="s-epg">
<option value="0">Off</option>
<option value="1">Every hour</option>
<option value="6">Every 6h</option>
<option value="12">Every 12h</option>
<option value="24">Every 24h</option>
</select>
<div class="si">Last: <span id="epg-last">—</span></div></div>
</div>
<div class="bg"><button class="b bp bsm" onclick="saveSched()">Save Schedule</button></div>
</div>

<!-- Edit Modal -->
<div class="modal" id="edit-modal">
<div class="modal-box">
<h3>Edit Channel</h3>
<div class="fg"><label>Name</label><input type="text" id="e-name" readonly></div>
<div class="fg"><label>URL</label><input type="text" id="e-url"></div>
<div class="fg"><label>Group</label><input type="text" id="e-group"></div>
<div class="bg">
<button class="b bp bsm" onclick="saveEdit()">Save</button>
<button class="b bd bsm" onclick="closeModal()">Cancel</button>
</div>
</div>
</div>

<div class="ft">IPTV Manager v2.0 — OpenWrt</div>
</div>

<script>
var API='http://$LAN_IP:8082/cgi-bin/admin.cgi';
var TOTAL_CH=$CH;
function st(t,e){document.querySelectorAll('.t').forEach(function(x){x.classList.remove('a')});document.querySelectorAll('.pn').forEach(function(x){x.classList.remove('a')});document.getElementById('p-'+t).classList.add('a');e.classList.add('a');if(t==='playlist')loadRaw()}
function cp(b){var c=b.previousElementSibling;var r=document.createRange();r.selectNodeContents(c);var s=window.getSelection();s.removeAllRanges();s.addRange(r);document.execCommand('copy');s.removeAllRanges();b.textContent='OK';setTimeout(function(){b.textContent='Copy'},1500)}
function toast(m,t){var d=document.createElement('div');d.className='toast '+(t==='ok'?'to':'te');d.textContent=m;document.body.appendChild(d);setTimeout(function(){d.remove()},4000)}
function act(a,p){
var x=new XMLHttpRequest();x.open('POST',API,true);
x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
x.onload=function(){try{var r=JSON.parse(x.responseText);if(r.status==='ok'){toast(r.message,'ok');setTimeout(function(){location.reload()},1500)}else toast(r.message,'err')}catch(e){toast('Error','err')}};
x.onerror=function(){toast('Network error','err')};
x.send('action='+a+'&'+p);
}
function checkCh(idx,url){
var el=document.getElementById('st-'+idx);
el.className='ch-status unknown';
var x=new XMLHttpRequest();x.open('POST',API,true);
x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
x.onload=function(){try{var r=JSON.parse(x.responseText);el.className=r.online?'ch-status online':'ch-status offline'}catch(e){el.className='ch-status offline'}};
x.send('action=check_channel&url='+encodeURIComponent(url));
}
function checkAll(){
var rows=document.querySelectorAll('#ch-tbody tr');
rows.forEach(function(row){
var idx=row.getAttribute('data-idx');
var url=row.getAttribute('data-url');
if(url)checkCh(idx,url);
});
}
function filterCh(){
var g=document.getElementById('f-group').value;
var s=document.getElementById('f-search').value.toLowerCase();
var rows=document.querySelectorAll('#ch-tbody tr');
rows.forEach(function(row){
var rg=row.getAttribute('data-group');
var rn=row.getAttribute('data-name').toLowerCase();
var show=(!g||rg===g)&&(!s||rn.indexOf(s)>=0);
row.style.display=show?'':'none';
});
}
function editCh(idx){
var row=document.querySelector('#ch-tbody tr[data-idx="'+idx+'"]');
document.getElementById('e-name').value=row.getAttribute('data-name');
document.getElementById('e-url').value=row.getAttribute('data-url');
document.getElementById('e-group').value=row.getAttribute('data-group');
document.getElementById('edit-modal').classList.add('open');
document.getElementById('edit-modal').setAttribute('data-idx',idx);
}
function closeModal(){document.getElementById('edit-modal').classList.remove('open')}
function saveEdit(){
var idx=document.getElementById('edit-modal').getAttribute('data-idx');
var url=document.getElementById('e-url').value;
var group=document.getElementById('e-group').value;
var x=new XMLHttpRequest();x.open('POST',API,true);
x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
x.onload=function(){try{var r=JSON.parse(x.responseText);if(r.status==='ok'){toast('Saved','ok');closeModal();setTimeout(function(){location.reload()},1000)}else toast(r.message,'err')}catch(e){toast('Error','err')}};
x.send('action=update_channel&idx='+idx+'&new_url='+encodeURIComponent(url)+'&new_group='+encodeURIComponent(group));
}
function setPlUrl(){
var u=document.getElementById('pl-url').value;
if(!u){toast('URL required','err');return}
act('set_playlist_url','url='+encodeURIComponent(u));
}
function setEpgUrl(){
var u=document.getElementById('epg-url').value;
if(!u){toast('URL required','err');return}
act('set_epg_url','url='+encodeURIComponent(u));
}
function saveSched(){
var pi=document.getElementById('s-pl').value;
var ei=document.getElementById('s-epg').value;
act('set_schedule','playlist_interval='+pi+'&epg_interval='+ei);
}
function loadRaw(){
var x=new XMLHttpRequest();x.open('GET','/playlist.m3u',true);
x.onload=function(){document.getElementById('pl-raw').value=x.responseText};
x.send();
}
// Init
document.getElementById('pl-url').value='$PLURL';
document.getElementById('epg-url').value='$EPGURL';
document.getElementById('s-pl').value='$PI';
document.getElementById('s-epg').value='$EI';
document.getElementById('pl-last').textContent='${PLAYLIST_LAST_UPDATE:----}';
document.getElementById('epg-last').textContent='${EPG_LAST_UPDATE:----}';
</script>
</body>
</html>
HTMLEND2
CGIEND
    chmod +x /www/iptv/cgi-bin/admin.cgi
}

# ==========================================
# Планировщик
# ==========================================
start_scheduler() {
    stop_scheduler
    cat > /tmp/iptv-scheduler.sh <<'SCEOF'
#!/bin/sh
D=/etc/iptv; echo $$ > /var/run/iptv-scheduler.pid
while true; do
    sleep 60
    [ ! -f "$D/schedule.conf" ] && continue
    . "$D/schedule.conf"
    N=$(date +%s 2>/dev/null || echo 0)
    if [ "${PLAYLIST_INTERVAL:-0}" -gt 0 ] 2>/dev/null; then
        L=$(date -d "$PLAYLIST_LAST_UPDATE" +%s 2>/dev/null || echo 0)
        [ "$(( (N-L)/3600 ))" -ge "$PLAYLIST_INTERVAL" ] && {
            . "$D/iptv.conf" 2>/dev/null
            case "$PLAYLIST_TYPE" in
                url) wget -q --timeout=15 -O "$D/playlist.m3u" "$PLAYLIST_URL" 2>/dev/null;;
                provider)
                    if [ -f "$D/provider.conf" ]; then
                        . "$D/provider.conf"
                        wget -q --timeout=15 -O "$D/playlist.m3u" "http://${PROVIDER_SERVER:-$PROVIDER_NAME}/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts" 2>/dev/null
                    fi;;
                file) [ -f "$PLAYLIST_SOURCE" ] && cp "$PLAYLIST_SOURCE" "$D/playlist.m3u";;
            esac
            NT=$(date '+%d.%m.%Y %H:%M')
            printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' \
                "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$NT" "$EPG_LAST_UPDATE" > "$D/schedule.conf"
            mkdir -p /www/iptv; [ -f "$D/playlist.m3u" ] && cp "$D/playlist.m3u" /www/iptv/playlist.m3u
        }
    fi
    if [ "${EPG_INTERVAL:-0}" -gt 0 ] 2>/dev/null; then
        L=$(date -d "$EPG_LAST_UPDATE" +%s 2>/dev/null || echo 0)
        [ "$(( (N-L)/3600 ))" -ge "$EPG_INTERVAL" ] && {
            . "$D/epg.conf" 2>/dev/null
            [ -n "$EPG_URL" ] && wget -q --timeout=30 -O "$D/epg.xml" "$EPG_URL" 2>/dev/null && [ -s "$D/epg.xml" ] && {
                NT=$(date '+%d.%m.%Y %H:%M')
                printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' \
                    "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$NT" > "$D/schedule.conf"
                mkdir -p /www/iptv; cp "$D/epg.xml" /www/iptv/epg.xml 2>/dev/null
            }
        }
    fi
done
SCEOF
    chmod +x /tmp/iptv-scheduler.sh
    /bin/sh /tmp/iptv-scheduler.sh &
    echo_success "Планировщик запущен"
}

stop_scheduler() {
    kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null
    rm -f /var/run/iptv-scheduler.pid /tmp/iptv-scheduler.sh
}

# ==========================================
# HTTP сервер
# ==========================================
start_http_server() {
    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then
        echo_success "Сервер уже запущен: http://$LAN_IP:$IPTV_PORT/"
        return
    fi
    if [ ! -f "$PLAYLIST_FILE" ]; then
        echo_error "Плейлист не найден!"; PAUSE; return 1
    fi

    mkdir -p /www/iptv/cgi-bin
    cp "$PLAYLIST_FILE" /www/iptv/playlist.m3u
    [ -f "$EPG_FILE" ] && cp "$EPG_FILE" /www/iptv/epg.xml

    generate_cgi

    kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null
    sleep 1
    uhttpd -f -p "0.0.0.0:$IPTV_PORT" -h /www/iptv -x /cgi-bin -i ".cgi=/bin/sh" &
    echo $! > "$HTTPD_PID"

    echo_success "Сервер запущен!"
    echo_info "Админка: http://$LAN_IP:$IPTV_PORT/cgi-bin/admin.cgi"
    echo_info "Плейлист: http://$LAN_IP:$IPTV_PORT/playlist.m3u"
    echo_info "EPG: http://$LAN_IP:$IPTV_PORT/epg.xml"
}

stop_http_server() {
    kill $(cat "$HTTPD_PID" 2>/dev/null) 2>/dev/null
    kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null
    rm -f "$HTTPD_PID"
    echo_success "Сервер остановлен"
}

# ==========================================
# SSH действия
# ==========================================
load_playlist_url() {
    echo_color "Загрузка плейлиста"
    echo -ne "${YELLOW}URL: ${NC}"; read PLAYLIST_URL </dev/tty
    [ -z "$PLAYLIST_URL" ] && { echo_error "URL пуст!"; PAUSE; return 1; }
    echo_info "Скачиваем..."
    if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null && [ -s "$PLAYLIST_FILE" ]; then
        local ch=$(get_ch)
        echo_success "Загружен! Каналов: $ch"
        save_config "url" "$PLAYLIST_URL" ""
        local now=$(get_ts); load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
        start_http_server
    else
        echo_error "Не удалось скачать!"; PAUSE; return 1
    fi
}

load_playlist_file() {
    echo_color "Загрузка из файла"
    echo -ne "${YELLOW}Путь: ${NC}"; read FP </dev/tty
    [ -z "$FP" ] && { echo_error "Путь пуст!"; PAUSE; return 1; }
    [ ! -f "$FP" ] && { echo_error "Файл не найден: $FP"; PAUSE; return 1; }
    cp "$FP" "$PLAYLIST_FILE"
    local ch=$(get_ch)
    echo_success "Загружен! Каналов: $ch"
    save_config "file" "" "$FP"
    local now=$(get_ts); load_sched
    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
    start_http_server
}

setup_provider() {
    echo_color "Настройка провайдера"
    echo -ne "${YELLOW}Название: ${NC}"; read PN </dev/tty
    echo -ne "${YELLOW}Логин: ${NC}"; read PL2 </dev/tty
    echo -ne "${YELLOW}Пароль: ${NC}"; stty -echo; read PP </dev/tty; stty echo; echo ""
    [ -z "$PN" ] || [ -z "$PL2" ] || [ -z "$PP" ] && { echo_error "Все поля обязательны!"; PAUSE; return 1; }
    cat > "$PROVIDER_CONFIG" <<EOF
PROVIDER_NAME=$PN
PROVIDER_LOGIN=$PL2
PROVIDER_PASS=$PP
PROVIDER_SERVER=http://$PN
EOF
    local pu="http://$PN/get.php?username=$PL2&password=$PP&type=m3u_plus&output=ts"
    echo_info "Получаем плейлист..."
    if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$pu" 2>/dev/null && [ -s "$PLAYLIST_FILE" ]; then
        local ch=$(get_ch)
        echo_success "Загружен! Провайдер: $PN, Каналов: $ch"
        save_config "provider" "$pu" "$PN"
        local now=$(get_ts); load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
        start_http_server
    else
        echo_error "Ошибка!"; PAUSE; return 1
    fi
}

do_update_playlist() {
    load_config
    case "$PLAYLIST_TYPE" in
        url)
            if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null; then
                local ch=$(get_ch); local now=$(get_ts); load_sched
                save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                echo_success "Обновлён! Каналов: $ch"
            else echo_error "Ошибка!"; fi ;;
        provider)
            if [ -f "$PROVIDER_CONFIG" ]; then
                . "$PROVIDER_CONFIG"
                local pu="http://${PROVIDER_SERVER:-$PROVIDER_NAME}/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"
                if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$pu" 2>/dev/null; then
                    local ch=$(get_ch); local now=$(get_ts); load_sched
                    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                    echo_success "Обновлён! Каналов: $ch"
                else echo_error "Ошибка!"; fi
            fi ;;
    esac
}

setup_epg() {
    echo_color "Настройка EPG"
    load_epg
    [ -n "$EPG_URL" ] && echo_info "Текущий: $EPG_URL"
    echo -ne "${YELLOW}EPG URL: ${NC}"; read EPG_URL </dev/tty
    [ -z "$EPG_URL" ] && { echo_error "URL пуст!"; PAUSE; return 1; }
    echo_info "Скачиваем..."
    if wget -q --timeout=30 -O "$EPG_FILE" "$EPG_URL" 2>/dev/null && [ -s "$EPG_FILE" ]; then
        local sz=$(file_size "$EPG_FILE")
        echo_success "Загружен! Размер: $sz"
        printf 'EPG_URL="%s"\n' "$EPG_URL" > "$EPG_CONFIG"
        local now=$(get_ts); load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
        start_http_server
    else
        echo_error "Не удалось скачать!"; PAUSE; return 1
    fi
}

do_update_epg() {
    load_epg
    [ -z "$EPG_URL" ] && { echo_error "EPG не настроен!"; return 1; }
    if wget -q --timeout=30 -O "$EPG_FILE" "$EPG_URL" 2>/dev/null && [ -s "$EPG_FILE" ]; then
        local sz=$(file_size "$EPG_FILE"); local now=$(get_ts); load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
        echo_success "Обновлён! Размер: $sz"
    else
        echo_error "Ошибка!"; return 1
    fi
}

remove_epg() { rm -f "$EPG_FILE" "$EPG_CONFIG"; echo_success "EPG удалён"; }

setup_schedule() {
    load_sched
    echo_color "Расписание"
    echo_info "Плейлист: $(int_text $PLAYLIST_INTERVAL) | EPG: $(int_text $EPG_INTERVAL)"
    echo -e "  ${CYAN}0) Выкл  1) Каждый час  2) Каждые 6ч  3) Каждые 12ч  4) Раз в сутки${NC}"
    echo -ne "${YELLOW}Плейлист (0-4): ${NC}"; read pi </dev/tty
    case "$pi" in 0|1) PLAYLIST_INTERVAL=$pi;; 2) PLAYLIST_INTERVAL=6;; 3) PLAYLIST_INTERVAL=12;; 4) PLAYLIST_INTERVAL=24;; *) PLAYLIST_INTERVAL=0;; esac
    echo -ne "${YELLOW}EPG (0-4): ${NC}"; read ei </dev/tty
    case "$ei" in 0|1) EPG_INTERVAL=$ei;; 2) EPG_INTERVAL=6;; 3) EPG_INTERVAL=12;; 4) EPG_INTERVAL=24;; *) EPG_INTERVAL=0;; esac
    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$EPG_LAST_UPDATE"
    if [ "$PLAYLIST_INTERVAL" -gt 0 ] || [ "$EPG_INTERVAL" -gt 0 ]; then
        start_scheduler; echo_success "Планировщик запущен"
    else
        stop_scheduler; echo_success "Расписание отключено"
    fi
}

remove_playlist() {
    rm -f "$PLAYLIST_FILE" "$CONFIG_FILE" "$PROVIDER_CONFIG"
    stop_http_server; echo_success "Удалено"
}

setup_autostart() {
    if [ -f /etc/init.d/iptv-manager ]; then
        /etc/init.d/iptv-manager disable 2>/dev/null; rm -f /etc/init.d/iptv-manager
        echo_success "Автозапуск отключён"
    else
        cat > /etc/init.d/iptv-manager <<'INITEOF'
#!/bin/sh /etc/rc.common
START=99
start() {
    mkdir -p /www/iptv/cgi-bin
    [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u
    [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml
    # Generate CGI
    if [ -f /etc/iptv/IPTV-Manager.sh ]; then
        . /etc/iptv/IPTV-Manager.sh 2>/dev/null
    fi
    uhttpd -f -p 0.0.0.0:8082 -h /www/iptv -x /cgi-bin -i ".cgi=/bin/sh" &
    if [ -f /etc/iptv/schedule.conf ]; then
        . /etc/iptv/schedule.conf
        [ "${PLAYLIST_INTERVAL:-0}" -gt 0 ] || [ "${EPG_INTERVAL:-0}" -gt 0 ] && /bin/sh /tmp/iptv-scheduler.sh &
    fi
}
stop() {
    kill $(pgrep -f "uhttpd.*8082" 2>/dev/null) 2>/dev/null
    kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null
}
INITEOF
        chmod +x /etc/init.d/iptv-manager
        /etc/init.d/iptv-manager enable 2>/dev/null
        echo_success "Автозапуск включён"
    fi
}

# ==========================================
# Меню
# ==========================================
show_menu() {
    clear
    load_sched
    echo -e "${MAGENTA}╔══════════════════════════════════════════╗"
    echo -e "║     IPTV Manager v$IPTV_MANAGER_VERSION                  ║"
    echo -e "╠══════════════════════════════════════════╣"
    echo -e "║${NC} IP: ${CYAN}$LAN_IP  Port: ${CYAN}$IPTV_PORT                    ${MAGENTA}║"
    echo -e "╚══════════════════════════════════════════╝${NC}"
    echo ""
    load_config
    echo -e "${CYAN}Плейлист:${NC} $([ "$PLAYLIST_TYPE" = "url" ] && echo "$PLAYLIST_URL" || echo "$PLAYLIST_TYPE")"
    load_epg
    echo -e "${CYAN}EPG:${NC} $([ -n "$EPG_URL" ] && echo "$EPG_URL" || echo "не настроен")"
    echo -e "${CYAN}Расписание:${NC} Плейлист=$(int_text $PLAYLIST_INTERVAL) | EPG=$(int_text $EPG_INTERVAL)"
    [ -n "$PLAYLIST_LAST_UPDATE" ] && echo -e "${CYAN}Обновлён:${NC} $PLAYLIST_LAST_UPDATE"
    echo ""
    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then
        echo_success "Сервер: http://$LAN_IP:$IPTV_PORT/cgi-bin/admin.cgi"
    else
        echo_error "Сервер: остановлен"
    fi
    echo ""
    echo -e "${CYAN}1) ${GREEN}Загрузить по ссылке${NC}"
    echo -e "${CYAN}2) ${GREEN}Загрузить из файла${NC}"
    echo -e "${CYAN}3) ${GREEN}Настроить провайдера${NC}"
    echo -e "${CYAN}4) ${GREEN}Обновить плейлист${NC}"
    echo -e "${CYAN}5) ${GREEN}Настроить EPG${NC}"
    echo -e "${CYAN}6) ${GREEN}Обновить EPG${NC}"
    echo -e "${CYAN}7) ${GREEN}Удалить EPG${NC}"
    echo -e "${CYAN}8) ${GREEN}Расписание${NC}"
    echo -e "${CYAN}9) ${GREEN}Запустить сервер${NC}"
    echo -e "${CYAN}10) ${GREEN}Остановить сервер${NC}"
    echo -e "${CYAN}11) ${GREEN}Автозапуск${NC}"
    echo -e "${CYAN}12) ${GREEN}Удалить плейлист${NC}"
    echo -e "${CYAN}Enter) ${GREEN}Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"; read c </dev/tty
    case "$c" in
        1) load_playlist_url;; 2) load_playlist_file;; 3) setup_provider;;
        4) do_update_playlist;; 5) setup_epg;; 6) do_update_epg;; 7) remove_epg;;
        8) setup_schedule;; 9) start_http_server;; 10) stop_http_server;;
        11) setup_autostart;; 12) remove_playlist;; *) echo_info "Выход"; exit 0;;
    esac
    PAUSE
}

while true; do show_menu; done
