#!/bin/sh
# Strip BOM and CRLF (fix for Windows edits / GitHub downloads)
SELF="$0"
if [ -f "$SELF" ]; then sed -i '1s/^\xef\xbb\xbf//;s/\r$//' "$SELF" 2>/dev/null; fi
# ==========================================
# IPTV Manager для OpenWrt v3.20
# ==========================================

IPTV_MANAGER_VERSION="3.20"
GREEN="\033[1;32m"; RED="\033[1;31m"; CYAN="\033[1;36m"; YELLOW="\033[1;33m"; MAGENTA="\033[1;35m"; NC="\033[0m"
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"
IPTV_PORT="8082"
IPTV_DIR="/etc/iptv"
PLAYLIST_FILE="$IPTV_DIR/playlist.m3u"
CONFIG_FILE="$IPTV_DIR/iptv.conf"
PROVIDER_CONFIG="$IPTV_DIR/provider.conf"
EPG_GZ="/tmp/iptv-epg.xml.gz"
EPG_TD="/tmp/iptv-epg-dl.xml"
EPG_CONFIG="$IPTV_DIR/epg.conf"
SCHEDULE_FILE="$IPTV_DIR/schedule.conf"
FAVORITES_FILE="$IPTV_DIR/favorites.json"
SECURITY_FILE="$IPTV_DIR/security.conf"
HTTPD_PID="/var/run/iptv-httpd.pid"
STARTUP_TIME="/tmp/iptv-start.ts"
RATE_FILE="/var/run/iptv-ratelimit"
MERGED_PL="/tmp/iptv-merged.m3u"

# Rate limiting config
RATE_LIMIT=60 # max requests per minute
BLOCK_DURATION=300 # seconds to ban

# IP whitelist (empty = all allowed, add IPs one per line)
WHITELIST_FILE="$IPTV_DIR/ip_whitelist.txt"

mkdir -p "$IPTV_DIR"
# If not saved at expected location, download and save self first
real_script="/etc/iptv/IPTV-Manager.sh"
if [ ! -f "$real_script" ]; then
    if wget -q --timeout=30 -O "$real_script" "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null; then
        chmod +x "$real_script"
        exec sh "$real_script"
    fi
fi
ln -sf "$real_script" /usr/bin/iptv 2>/dev/null
[ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"
[ -f "$EPG_CONFIG" ] || touch "$EPG_CONFIG"
[ -f "$SCHEDULE_FILE" ] || touch "$SCHEDULE_FILE"
[ -f "$FAVORITES_FILE" ] || echo "[]" > "$FAVORITES_FILE"
[ -f "$SECURITY_FILE" ] || printf 'ADMIN_USER=""\nADMIN_PASS=""\nAPI_TOKEN=""\n' > "$SECURITY_FILE"
[ -f "$WHITELIST_FILE" ] || touch "$WHITELIST_FILE"

# LuCI UCI config (required for LuCI plugin to work)
if ! grep -q 'config iptv' /etc/config/iptv 2>/dev/null; then
    mkdir -p /etc/config
    printf 'config iptv main\n\toption enabled "1"\n' > /etc/config/iptv
fi

# Auto-update on startup
_auto_update() {
    local latest=$(wget -q --timeout=10 --no-check-certificate -O - "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null | head -10 | grep -o 'IPTV_MANAGER_VERSION="[^"]*"' | sed 's/IPTV_MANAGER_VERSION="//;s/"//')
    if [ -n "$latest" ] && [ "$latest" != "$IPTV_MANAGER_VERSION" ]; then
        echo -e "${CYAN}Доступна версия v$latest (у вас v$IPTV_MANAGER_VERSION). Обновляю...${NC}"
        local tmp="/tmp/IPTV-Manager-new.sh"
        if wget -q --timeout=15 --no-check-certificate -O "$tmp" "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null && [ -s "$tmp" ]; then
            cp "$tmp" "/etc/iptv/IPTV-Manager.sh"
            chmod +x "/etc/iptv/IPTV-Manager.sh"
            rm -f "$tmp"
            exec sh "/etc/iptv/IPTV-Manager.sh"
        fi
    fi
}
# Always auto-update on startup
_auto_update

# Rate limiter
_rate_limit() {
    local ip=${REMOTE_ADDR:-unknown}
    local now=$(date +%s)
    local block_file="/tmp/iptv-blocked-$ip"
    [ -f "$block_file" ] && [ "$(cat "$block_file")" -gt "$now" ] 2>/dev/null && return 1
    [ -f "$RATE_FILE" ] || echo "" > "$RATE_FILE"
    local recent=$(awk -v n=$now 'BEGIN{c=0}{if($1>n-60)c++}END{print c}' "$RATE_FILE")
    echo "$now" >> "$RATE_FILE"
    awk -v n=$now '{if($1>n-60)print}' "$RATE_FILE" > /tmp/rf_tmp && mv /tmp/rf_tmp "$RATE_FILE"
    [ "$recent" -ge "$RATE_LIMIT" ] 2>/dev/null && { echo $((now + BLOCK_DURATION)) > "$block_file"; return 1; }
    return 0
}

# IP whitelist check
_ip_whitelist() {
    [ -s "$WHITELIST_FILE" ] || return 0
    local ip="${REMOTE_ADDR%:*}"
    grep -q "^${ip}$" "$WHITELIST_FILE" 2>/dev/null
}

# Download EPG from URL → /tmp/iptv-epg.xml.gz
# Usage: _dl_epg "https://..."  (returns 0 on success, sets $EPG_GZ_SZ to human-readable size)
_dl_epg() {
    local _url="$1"
    if wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EPG_TD" "$_url" 2>/dev/null && [ -s "$EPG_TD" ]; then
        local _m=$(hexdump -n 2 -e '2/1 "%02x"' "$EPG_TD" 2>/dev/null)
        if [ "$_m" = "1f8b" ]; then
            cp "$EPG_TD" "$EPG_GZ"
        else
            gzip -c "$EPG_TD" > "$EPG_GZ" 2>/dev/null
        fi
        rm -f "$EPG_TD"
        return 0
    fi
    return 1
}

echo_color() { echo -e "${MAGENTA}$1${NC}"; }
echo_success() { echo -e "${GREEN}$1${NC}"; }
echo_error() { echo -e "${RED}$1${NC}"; }
echo_info() { echo -e "${CYAN}$1${NC}"; }
PAUSE() { echo -ne "${YELLOW}Нажмите Enter...${NC}"; read dummy </dev/tty; }
get_ts() { date '+%d.%m.%Y %H:%M' 2>/dev/null || echo "—"; }
save_config() { printf 'PLAYLIST_TYPE="%s"\nPLAYLIST_URL="%s"\nPLAYLIST_SOURCE="%s"\n' "$1" "$2" "$3" > "$CONFIG_FILE"; }
load_config() { [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"; }
load_epg() { [ -f "$EPG_CONFIG" ] && . "$EPG_CONFIG"; }
load_sched() {
    if [ -f "$SCHEDULE_FILE" ]; then . "$SCHEDULE_FILE"; fi; [ -z "$PLAYLIST_INTERVAL" ] && PLAYLIST_INTERVAL="0"; [ -z "$EPG_INTERVAL" ] && EPG_INTERVAL="0"; [ -z "$PLAYLIST_LAST_UPDATE" ] && PLAYLIST_LAST_UPDATE="--"; [ -z "$EPG_LAST_UPDATE" ] && EPG_LAST_UPDATE="--"
}
save_sched() { printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' "$1" "$2" "$3" "$4" > "$SCHEDULE_FILE"; }
get_ch() {
    local n=$(grep -c "^#EXTINF" "$PLAYLIST_FILE" 2>/dev/null)
    echo "${n:-0}"
}
file_size() {
    [ -f "$1" ] || { echo "0 B"; return; }
    local s=$(wc -c < "$1" 2>/dev/null)
    if [ "$s" -gt 1048576 ] 2>/dev/null; then echo "$((s/1048576)) MB"
    elif [ "$s" -gt 1024 ] 2>/dev/null; then echo "$((s/1024)) KB"
    else echo "${s} B"; fi
}
int_text() { case "${1:-0}" in 0) echo "Выкл";; 1) echo "Каждый час";; 6) echo "Каждые 6ч";; 12) echo "Каждые 12ч";; 24) echo "Раз в сутки";; *) echo "Выкл";; esac; }
detect_builtin_epg() {
    [ -f "$PLAYLIST_FILE" ] || return
    local epg=""
    epg=$(head -5 "$PLAYLIST_FILE" | grep -o 'url-tvg="[^"]*"' | head -1 | sed 's/url-tvg="//;s/"//')
    [ -z "$epg" ] && epg=$(head -5 "$PLAYLIST_FILE" | grep -o "url-tvg='[^']*'" | head -1 | sed "s/url-tvg='//;s/'//")
    echo "$epg"
}
wget_opt() { local o="-q --timeout=15"; wget --help 2>&1 | grep -q "no-check-certificate" && o="$o --no-check-certificate"; echo "$o"; }

# ==========================================
# Генерация server.html
# ==========================================
generate_server_html() {
    mkdir -p /www/iptv
    cat > /www/iptv/server.html << 'SERVEREOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>IPTV Manager — Сервер</title>
<style>
:root{--bg:#f0f2f5;--card:#fff;--text:#1a1a2e;--text2:#666;--border:#e0e0e0;--primary:#1a73e8;--success:#1e8e3e;--danger:#d93025;--btn-bg:#fafafa}
[data-theme="dark"]{--bg:#0a0e1a;--card:#1e293b;--text:#e2e8f0;--text2:#94a3b8;--border:#334155;--primary:#3b82f6;--success:#22c55e;--danger:#ef4444;--btn-bg:#0f172a}
[data-theme="openwrt"]{--bg:#1a1b26;--card:#24283b;--text:#c0caf5;--text2:#9aa5ce;--border:#3b4261;--primary:#7aa2f7;--success:#9ece6a;--danger:#f7768e;--btn-bg:#1e2030}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--text);min-height:100vh;display:flex;align-items:center;justify-content:center;padding:10px}
.c{background:var(--card);border-radius:12px;padding:32px;border:1px solid var(--border);box-shadow:0 1px 3px rgba(0,0,0,.06);text-align:center;max-width:360px;width:90%}
h1{font-size:20px;margin-bottom:8px;color:var(--primary)}
#status{font-size:14px;color:var(--text2);margin:16px 0;padding:12px;background:var(--btn-bg);border-radius:8px;border:1px solid var(--border)}
.btns{display:flex;gap:10px;justify-content:center;margin-top:20px}
.b{padding:10px 24px;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;color:#fff}
.bs{background:var(--success)}.bs:hover{background:#137333}
.bd{background:var(--danger)}.bd:hover{background:#b3261e}
.b:disabled{opacity:.5;cursor:default}
.p{font-size:11px;color:var(--text2);margin-top:16px}
</style>
</head>
<body>
<div class="c">
<h1>Сервер</h1>
<div id="status">Загрузка...</div>
<div class="btns">
<button class="b bs" id="startBtn">Запустить</button>
<button class="b bd" id="stopBtn">Остановить</button>
</div>
<p class="p">Управление IPTV сервером</p>
</div>
<script>
var API='/cgi-bin/srv.cgi';
if(window.parent!==window){document.documentElement.setAttribute('data-theme','openwrt')}
else{try{var t=localStorage.getItem('iptv-theme');if(t==='dark'||t==='openwrt')document.documentElement.setAttribute('data-theme',t)}catch(e){}}
function qs(s){return document.querySelector(s)}
function setStatus(working){
qs('#status').textContent=working?'● Запущен':'○ Остановлен';
qs('#status').style.color=working?'var(--success)':'var(--text2)';
var sb=qs('#startBtn');
sb.disabled=false;
sb.textContent=working?'\u2713 Работает':'Запустить';
var ob=qs('#stopBtn');
ob.disabled=!working;
}
function chk(){
var x=new XMLHttpRequest();
x.open('GET',API+'?action=server_status',true);
x.timeout=5000;
x.onload=function(){try{var r=JSON.parse(x.responseText);setStatus(r.status==='ok'&&r.output.indexOf('running')>-1)}catch(e){setStatus(false)}};
x.onerror=function(){setStatus(false)};
x.ontimeout=function(){setStatus(false)};
x.send();
}
qs('#startBtn').onclick=function(){
this.disabled=true;this.textContent='Запуск...';
qs('#status').textContent='Запуск...';qs('#status').style.color='var(--primary)';
var x=new XMLHttpRequest();
x.open('GET',API+'?action=server_start',true);x.timeout=15000;
x.onload=function(){setTimeout(chk,10000)};
x.onerror=function(){x.ontimeout()};
x.ontimeout=function(){setTimeout(chk,10000)};
x.send();
};
qs('#stopBtn').onclick=function(){
this.disabled=true;this.textContent='Остановка...';
qs('#status').textContent='Остановка...';qs('#status').style.color='var(--danger)';
var x=new XMLHttpRequest();
x.open('GET',API+'?action=server_stop',true);x.timeout=15000;
x.onload=function(){setTimeout(chk,5000)};
x.onerror=function(){x.ontimeout()};
x.ontimeout=function(){setTimeout(chk,5000)};
x.send();
};
chk();
</script>
</body>
</html>
SERVEREOF
}

generate_srv_cgi() {
    mkdir -p /www/cgi-bin
    cat > /www/cgi-bin/srv.cgi << 'SRVEOF'
#!/bin/sh
PID=/var/run/iptv-httpd.pid
HDR() { printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'; }
JSON() { printf 'Content-Type: application/json\r\n\r\n'; }
ACT=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')
case "$ACTION$ACT" in
    *start*)
        JSON
        kill $(pgrep -f "uhttpd.*8082") 2>/dev/null
        sleep 1
        mkdir -p /www/iptv /www/iptv/cgi-bin
        [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u 2>/dev/null
        [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml 2>/dev/null
        uhttpd -p 0.0.0.0:8082 -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" </dev/null >/dev/null 2>&1 &
        printf '{"ok":true}'
        ;;
    *stop*)
        JSON
        kill $(pgrep -f "uhttpd.*8082") 2>/dev/null
        rm -f $PID 2>/dev/null
        printf '{"ok":true}'
        ;;
    *status*)
        JSON
        if wget -q --spider --timeout=2 http://127.0.0.1:8082/ 2>/dev/null; then
            printf '{"ok":true,"running":true}'
        else
            printf '{"ok":true,"running":false}'
        fi
        ;;
    *)
        HDR
        if [ -f /www/luci-static/resources/view/iptv-manager/srv.html ]; then
            cat /www/luci-static/resources/view/iptv-manager/srv.html
        else
            echo "<h3>srv.html not found, please install LuCI plugin</h3>"
        fi
        ;;
esac
SRVEOF
    chmod +x /www/cgi-bin/srv.cgi
    # Also copy srv.html to CGI dir as fallback
    if [ -f /www/luci-static/resources/view/iptv-manager/srv.html ]; then
        cp /www/luci-static/resources/view/iptv-manager/srv.html /www/cgi-bin/srv.html
    fi
}


# ==========================================
# Генерация CGI
# ==========================================
generate_cgi() {
    load_config; load_epg; load_sched
    local ch=$(get_ch)
    local psz=$(file_size "$PLAYLIST_FILE")
    local esz=$(file_size "$EPG_GZ")
    local purl=""; [ "$PLAYLIST_TYPE" = "url" ] && purl="$PLAYLIST_URL"
    local pname="${PLAYLIST_NAME:-}"
    local eurl=""; [ -n "$EPG_URL" ] && eurl="$EPG_URL"
    local pi="${PLAYLIST_INTERVAL:-0}"
    local ei="${EPG_INTERVAL:-0}"
    local plu="${PLAYLIST_LAST_UPDATE:----}"
    local elu="${EPG_LAST_UPDATE:----}"

    local groups=""
    [ -f "$PLAYLIST_FILE" ] && groups=$(grep -o 'group-title="[^"]*"' "$PLAYLIST_FILE" 2>/dev/null | sed 's/group-title="//;s/"//' | sort -u | grep . || true)
    local grp_count=0
    [ -n "$groups" ] && grp_count=$(echo "$groups" | wc -l)
    local hd_count=0
    [ -f "$PLAYLIST_FILE" ] && hd_count=$(grep -ci "hd\|1080\|4k\|2160\|uhd" "$PLAYLIST_FILE" 2>/dev/null || true)
    [ -z "$hd_count" ] && hd_count=0
    local sd_count=$((ch - hd_count))

    # Генерация JSON каналов через awk
    mkdir -p /www/iptv
    if [ -f "$PLAYLIST_FILE" ]; then
        awk 'BEGIN{printf "[";f=1;i=0}/#EXTINF:/{nm="";g="";l="";t="";ii=index($0,",");if(ii>0){nm=substr($0,ii+1);sub(/^[ \t]+/,"",nm)};if(nm=="")nm="Неизвестный";p=index($0,"group-title=\"");if(p>0){s=substr($0,p+13);e=index(s,"\"");g=substr(s,1,e-1)};if(g=="")g="Общее";p=index($0,"tvg-logo=\"");if(p>0){s=substr($0,p+10);e=index(s,"\"");l=substr(s,1,e-1)};p=index($0,"tvg-id=\"");if(p>0){s=substr($0,p+8);e=index(s,"\"");t=substr(s,1,e-1)};next}/^http/{if(!f)printf ",";f=0;gsub(/"/,"\\\"",$0);gsub(/"/,"\\\"",nm);gsub(/"/,"\\\"",g);gsub(/"/,"\\\"",l);gsub(/"/,"\\\"",t);printf "{\"n\":\"%s\",\"g\":\"%s\",\"l\":\"%s\",\"i\":\"%s\",\"u\":\"%s\",\"idx\":%d}",nm,g,l,t,$0,i;i++}END{printf "]"}' "$PLAYLIST_FILE" > /www/iptv/channels.json 2>/dev/null
    else
        echo "[]" > /www/iptv/channels.json
    fi
    # Serve player.html too
    [ -f /www/iptv/player.html ] || true

    # Опции групп для HTML
    local group_opts=""
    if [ -n "$groups" ]; then
        group_opts=$(echo "$groups" | while IFS= read -r g; do [ -n "$g" ] && echo "<option value=\"$g\">$g</option>"; done)
    fi

    # EPG сейчас-играет (стриминг из gz, без распаковки)
    local now_ts=$(date '+%Y%m%d%H%M%S' 2>/dev/null)
    local epg_rows=""
    if [ -f "$EPG_GZ" ]; then
        epg_rows=$(gunzip -c "$EPG_GZ" 2>/dev/null | awk -v now="$now_ts" '
        /<programme / {
            s = $0
            st = ""
            ch = ""
            if (match(s, /start="[0-9]+/)) st = substr(s, RSTART + 7, RLENGTH - 7)
            if (match(s, /channel="[^"]+"/)) ch = substr(s, RSTART + 9, RLENGTH - 9)
        }
        /<title/ {
            t = $0
            if (match(t, /<title[^>]*>[^<]*<\/title>/)) {
                t = substr(t, RSTART, RLENGTH)
                gsub(/<[^>]*>/, "", t)
                ti = t
            }
        }
        /<\/programme>/ {
            if (ti != "" && ch != "" && st != "") {
                printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n", substr(st, 9, 2) ":" substr(st, 11, 2), ch, ti
                c++
                if (c >= 30) exit
            }
            ti = ""
        }
        ' 2>/dev/null)
    fi

    local builtin_epg=$(detect_builtin_epg)
    local epg_notice=""
    if [ -n "$builtin_epg" ] && [ -z "$eurl" ]; then
        epg_notice="<div class=\"banner\">💡 В плейлисте найдена встроенная ссылка EPG: <code>$builtin_epg</code> — укажите её в поле выше для загрузки.</div>"
    fi

    mkdir -p /www/iptv/cgi-bin

    # --- CGI файл (без раскрытия переменных) ---
    cat > /www/iptv/cgi-bin/admin.cgi << 'CGIEOF'
#!/bin/sh
IPTV_MANAGER_VERSION="$IPTV_MANAGER_VERSION"
PL="/etc/iptv/playlist.m3u"
EC="/etc/iptv/iptv.conf"
EGZ="/tmp/iptv-epg.xml.gz"
EXC="/etc/iptv/epg.conf"
SC="/etc/iptv/schedule.conf"
FAV="/etc/iptv/favorites.json"
SEC="/etc/iptv/security.conf"
wget_opt() { local o="-q --timeout=15"; wget --help 2>&1 | grep -q "no-check-certificate" && o="$o --no-check-certificate"; echo "$o"; }
hdr() { printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'; }
json_hdr() { printf 'Content-Type: application/json\r\n\r\n'; }
auth_fail() { printf 'HTTP/1.0 401 Unauthorized\r\nWWW-Authenticate: Basic realm="IPTV Manager"\r\nContent-Type: text/html\r\n\r\n<html><body><h1>401 Unauthorized</h1></body></html>\r\n'; exit 0; }
check_auth() {
    [ -f "$SEC" ] || return
    . "$SEC" 2>/dev/null
    [ -z "$ADMIN_USER" ] && [ -z "$ADMIN_PASS" ] && return
    AUTH="${HTTP_AUTHORIZATION:-}"
    case "$AUTH" in
        Basic\ *)
            CREDS=$(echo "$AUTH" | sed 's/Basic //' | busybox base64 -d 2>/dev/null || echo "$AUTH" | sed 's/Basic //' | openssl enc -base64 -d 2>/dev/null || echo "")
            U=$(echo "$CREDS" | cut -d: -f1)
            P=$(echo "$CREDS" | cut -d: -f2-)
            [ "$U" = "$ADMIN_USER" ] && [ "$P" = "$ADMIN_PASS" ] && return
            ;;
    esac
    auth_fail
}
check_api_token() {
    [ -f "$SEC" ] || return
    . "$SEC" 2>/dev/null
    [ -z "$API_TOKEN" ] && return
    TOK="${HTTP_X_API_TOKEN:-}"
    [ "$TOK" = "$API_TOKEN" ] && return
    auth_fail
}
check_auth
METHOD="${REQUEST_METHOD:-GET}"
QUERY="${QUERY_STRING:-}"
CL="${CONTENT_LENGTH:-0}"
POST_DATA=""
[ "$METHOD" = "POST" ] && [ "$CL" -gt 0 ] 2>/dev/null && POST_DATA=$(dd bs=1 count="$CL" 2>/dev/null)
ACTION=""
case "$METHOD" in
    GET) ACTION=$(echo "$QUERY" | sed -n 's/.*action=\([^&]*\).*/\1/p') ;;
    POST) ACTION=$(echo "$POST_DATA" | sed -n 's/.*action=\([^&]*\).*/\1/p') ;;
esac
if [ -n "$ACTION" ]; then
    check_api_token
    json_hdr
    case "$ACTION" in
        check_channel)
            URL=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            URL=$(echo "$URL" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            case "$URL" in
                http*|https*)
                    wget -q --timeout=8 -O - --header="User-Agent: VLC/3.0" "$URL" 2>/dev/null | grep -q "EXTM3U"
                    [ $? -eq 0 ] && printf '{"status":"ok","online":true}' || printf '{"status":"ok","online":false}' ;;
                udp*|rtp*) printf '{"status":"ok","online":true}' ;;
                *) printf '{"status":"ok","online":false}' ;;
            esac ;;
        update_channel)
            IDX=$(echo "$POST_DATA" | sed -n 's/.*idx=\([^&]*\).*/\1/p')
            NURL=$(echo "$POST_DATA" | sed -n 's/.*new_url=\([^&]*\).*/\1/p')
            NGRP=$(echo "$POST_DATA" | sed -n 's/.*new_group=\([^&]*\).*/\1/p')
            NURL=$(echo "$NURL" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            NGRP=$(echo "$NGRP" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            if [ -n "$IDX" ] && [ -n "$NURL" ]; then
                TMP="/tmp/iptv-edit.m3u"
                echo "#EXTM3U" > "$TMP"
                I=0
                while IFS= read -r L; do
                    case "$L" in
                        "#EXTINF:"*)
                            if [ "$I" -eq "$IDX" ] 2>/dev/null && [ -n "$NGRP" ]; then
                                L=$(echo "$L" | sed "s/group-title=\"[^\"]*\"/group-title=\"$NGRP\"/")
                            fi
                            echo "$L" >> "$TMP" ;;
                        http*|https*|rtsp*|rtmp*|udp*|rtp*)
                            if [ "$I" -eq "$IDX" ] 2>/dev/null; then
                                echo "$NURL" >> "$TMP"
                            else
                                echo "$L" >> "$TMP"
                            fi
                            I=$((I + 1)) ;;
                        *) echo "$L" >> "$TMP" ;;
                    esac
                done < "$PL"
                cp "$TMP" "$PL"
                cp "$PL" /www/iptv/playlist.m3u
                printf '{"status":"ok","message":"Канал обновлён"}'
            else
                printf '{"status":"error","message":"Неверные данные"}'
            fi ;;
        refresh_playlist)
            . "$EC" 2>/dev/null
            case "$PLAYLIST_TYPE" in
                url)
                    # Validate first
                    if ! wget -q --spider --timeout=10 --no-check-certificate "$PLAYLIST_URL" 2>/dev/null; then
                        printf '{"status":"error","message":"URL плейлиста недоступен"}'
                    else
                        wget $(wget_opt) -O "$PL" "$PLAYLIST_URL" 2>/dev/null && [ -s "$PL" ] && {
                            CH=$(grep -c "^#EXTINF" "$PL" 2>/dev/null)
                            [ -z "$CH" ] && CH=0
                            cp "$PL" /www/iptv/playlist.m3u
                            # Regenerate channels.json
                            awk 'BEGIN{printf "[";f=1;i=0}/#EXTINF:/{nm="";g="";l="";t="";ii=index($0,",");if(ii>0){nm=substr($0,ii+1);sub(/^[ \t]+/,"",nm)};if(nm=="")nm="Неизвестный";p=index($0,"group-title=\"");if(p>0){s=substr($0,p+13);e=index(s,"\"");g=substr(s,1,e-1)};if(g=="")g="Общее";p=index($0,"tvg-logo=\"");if(p>0){s=substr($0,p+10);e=index(s,"\"");l=substr(s,1,e-1)};p=index($0,"tvg-id=\"");if(p>0){s=substr($0,p+8);e=index(s,"\"");t=substr(s,1,e-1)};next}/^http/{if(!f)printf ",";f=0;gsub(/"/,"\\\"",$0);gsub(/"/,"\\\"",nm);gsub(/"/,"\\\"",g);gsub(/"/,"\\\"",l);gsub(/"/,"\\\"",t);printf "{\"n\":\"%s\",\"g\":\"%s\",\"l\":\"%s\",\"i\":\"%s\",\"u\":\"%s\",\"idx\":%d}",nm,g,l,t,$0,i;i++}END{printf "]"}' "$PL" > /www/iptv/channels.json 2>/dev/null
                            printf '{"status":"ok","message":"Плейлист обновлён! Каналов: %s"}' "$CH"
                        } || printf '{"status":"error","message":"Ошибка загрузки"}'
                    fi ;;
                *) printf '{"status":"error","message":"Невозможно обновить"}' ;;
            esac ;;
        refresh_epg)
            . "$EXC" 2>/dev/null
            if [ -n "$EPG_URL" ]; then
                TD="/tmp/epg-dl.tmp"
                _epg_ok=false
                _epg_trials=0
                # Auto-retry EPG 3 times
                while [ "$_epg_trials" -lt 3 ] && [ "$_epg_ok" = "false" ]; do
                    wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$TD" "$EPG_URL" 2>/dev/null && [ -s "$TD" ] && {
                        M=$(hexdump -n 2 -e '2/1 "%02x"' "$TD" 2>/dev/null)
                        if [ "$M" = "1f8b" ]; then
                            cp "$TD" "$EPG_GZ"
                        else
                            gzip -c "$TD" > "$EPG_GZ" 2>/dev/null
                        fi
                        rm -f "$TD"
                        _epg_ok=true
                    }
                    _epg_trials=$((_epg_trials + 1))
                    [ "$_epg_ok" = "false" ] && sleep 5
                done
                if [ "$_epg_ok" = "true" ]; then
                    if [ -f "$EPG_GZ" ] && [ -s "$EPG_GZ" ]; then
                        SZ=$(wc -c < "$EPG_GZ")
                        SZKB=$((SZ / 1024))
                        SZMB=$((SZ / 1048576))
                        if [ "$SZMB" -gt 10 ] 2>/dev/null; then
                            printf '{"status":"ok","message":"EPG обновлён! Размер gz: %s MB. Внимание: >10MB","large":true,"trials":%d}' "$SZMB" "$_epg_trials"
                        else
                            printf '{"status":"ok","message":"EPG обновлён! Размер gz: %s KB","large":false,"trials":%d}' "$SZKB" "$_epg_trials"
                        fi
                    else
                        printf '{"status":"error","message":"Ошибка сохранения EPG"}'
                    fi
                else
                    printf '{"status":"error","message":"Ошибка загрузки EPG после %d попыток","trials":%d}' "$_epg_trials" "$_epg_trials"
                fi
            else
                printf '{"status":"error","message":"EPG URL не задан"}'
            fi ;;
        set_playlist_url)
            NU=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            NU=$(echo "$NU" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            if [ -n "$NU" ]; then
                printf 'PLAYLIST_TYPE="url"\nPLAYLIST_URL="%s"\nPLAYLIST_SOURCE=""\n' "$NU" > "$EC"
                # Download playlist
                if wget $(wget_opt) -O "$PL" "$NU" 2>/dev/null && [ -s "$PL" ]; then
                    CH=$(grep -c "^#EXTINF" "$PL" 2>/dev/null)
                    [ -z "$CH" ] && CH=0
                    cp "$PL" /www/iptv/playlist.m3u
                    # Regenerate channels.json
                    awk 'BEGIN{printf "[";f=1;i=0}/#EXTINF:/{nm="";g="";l="";t="";ii=index($0,",");if(ii>0){nm=substr($0,ii+1);sub(/^[ \t]+/,"",nm)};if(nm=="")nm="Неизвестный";p=index($0,"group-title=\"");if(p>0){s=substr($0,p+13);e=index(s,"\"");g=substr(s,1,e-1)};if(g=="")g="Общее";p=index($0,"tvg-logo=\"");if(p>0){s=substr($0,p+10);e=index(s,"\"");l=substr(s,1,e-1)};p=index($0,"tvg-id=\"");if(p>0){s=substr($0,p+8);e=index(s,"\"");t=substr(s,1,e-1)};next}/^http/{if(!f)printf ",";f=0;gsub(/"/,"\\\"",$0);gsub(/"/,"\\\"",nm);gsub(/"/,"\\\"",g);gsub(/"/,"\\\"",l);gsub(/"/,"\\\"",t);printf "{\"n\":\"%s\",\"g\":\"%s\",\"l\":\"%s\",\"i\":\"%s\",\"u\":\"%s\",\"idx\":%d}",nm,g,l,t,$0,i;i++}END{printf "]"}' "$PL" > /www/iptv/channels.json 2>/dev/null
                    printf '{"status":"ok","message":"Плейлист загружен! Каналов: %s"}' "$CH"
                else
                    printf '{"status":"error","message":"Ошибка загрузки плейлиста"}'
                fi
            else
                printf '{"status":"error","message":"Укажите URL"}'
            fi ;;
        set_epg_url)
            NU=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            NU=$(echo "$NU" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            if [ -n "$NU" ]; then
                printf 'EPG_URL="%s"\n' "$NU" > "$EXC"
                TD="/tmp/epg-dl.tmp"
                wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$TD" "$NU" 2>/dev/null && [ -s "$TD" ] && {
                    M=$(hexdump -n 2 -e '2/1 "%02x"' "$TD" 2>/dev/null)
                    if [ "$M" = "1f8b" ]; then
                        cp "$TD" "$EPG_GZ"
                    else
                        gzip -c "$TD" > "$EPG_GZ" 2>/dev/null
                    fi
                    rm -f "$TD"
                    if [ -f "$EPG_GZ" ] && [ -s "$EPG_GZ" ]; then
                        SZ=$(wc -c < "$EPG_GZ")
                        SZKB=$((SZ / 1024))
                        SZMB=$((SZ / 1048576))
                        if [ "$SZMB" -gt 10 ] 2>/dev/null; then
                            printf '{"status":"ok","message":"EPG загружен! Размер gz: %s MB. Внимание: >10MB, рекомендуется lite","large":true}' "$SZMB"
                        else
                            printf '{"status":"ok","message":"EPG загружен! Размер gz: %s KB","large":false}' "$SZKB"
                        fi
                    else
                        printf '{"status":"error","message":"Ошибка сохранения EPG"}'
                    fi
                } || { rm -f "$TD"; printf '{"status":"error","message":"Ошибка загрузки EPG"}'; }
            else
                printf '{"status":"error","message":"Укажите URL"}'
            fi ;;
        set_schedule)
            PI=$(echo "$POST_DATA" | sed -n 's/.*playlist_interval=\([^&]*\).*/\1/p')
            EI=$(echo "$POST_DATA" | sed -n 's/.*epg_interval=\([^&]*\).*/\1/p')
            [ -z "$PI" ] && PI=0
            [ -z "$EI" ] && EI=0
            printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\n' "$PI" "$EI" > "$SC"
            printf '{"status":"ok","message":"Расписание сохранено"}' ;;
        set_playlist_name)
            NM=$(echo "$POST_DATA" | sed -n 's/.*name=\([^&]*\).*/\1/p')
            NM=$(echo "$NM" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            if [ -n "$NM" ]; then
                printf 'PLAYLIST_NAME="%s"\n' "$NM" >> "$EC"
                printf '{"status":"ok","message":"Название сохранено"}'
            else
                printf '{"status":"error","message":"Укажите название"}'
            fi ;;
        get_epg)
            if [ -f "$EPG_GZ" ]; then
                now_ts=$(date '+%Y%m%d%H%M%S' 2>/dev/null)
                rows=$(gunzip -c "$EPG_GZ" 2>/dev/null | awk -v now="$now_ts" '
                BEGIN{printf "[";f=1;c=0}
                /<programme / {
                    s = $0; st = ""; ch = ""
                    if (match(s, /start="[0-9]+/)) st = substr(s, RSTART + 7, RLENGTH - 7)
                    if (match(s, /channel="[^"]+"/)) ch = substr(s, RSTART + 9, RLENGTH - 9)
                }
                /<title/ {
                    t = $0
                    if (match(t, /<title[^>]*>[^<]*<\/title>/)) {
                        t = substr(t, RSTART, RLENGTH)
                        gsub(/<[^>]*>/, "", t)
                        ti = t
                    }
                }
                /<\/programme>/ {
                    if (ti != "" && ch != "" && st != "") {
                        if(!f)printf ","
                        f=0
                        gsub(/"/, "\\\"", ti)
                        gsub(/"/, "\\\"", ch)
                        printf "{\"t\":\"%s:%s\",\"c\":\"%s\",\"p\":\"%s\"}", substr(st,9,2), substr(st,11,2), ch, ti
                        c++
                        if(c>=50)exit
                    }
                    ti = ""
                }
                END{printf "]"}
                ' 2>/dev/null)
                printf '{"status":"ok","rows":%s}' "$rows"
            else
                printf '{"status":"ok","rows":[]}'
            fi ;;
        backup)
            BF="/tmp/iptv-backup-$(date +%Y%m%d%H%M%S).tar.gz"
            tar czf "$BF" -C /etc iptv 2>/dev/null
            if [ -f "$BF" ]; then
                SZ=$(wc -c < "$BF")
                printf 'Content-Type: application/gzip\r\n'
                printf 'Content-Disposition: attachment; filename="iptv-backup.tar.gz"\r\n'
                printf 'Content-Length: %s\r\n\r\n' "$SZ"
                cat "$BF"
                rm -f "$BF"
            else
                printf '{"status":"error","message":"Ошибка создания бэкапа"}'
            fi ;;
        import)
            TF="/tmp/iptv-restore.tar.gz"
            if [ "$CL" -gt 0 ] 2>/dev/null; then
                dd bs=1 count="$CL" 2>/dev/null > "$TF"
                if tar xzf "$TF" -C / 2>/dev/null; then
                    mkdir -p /www/iptv/cgi-bin
                    [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u
                    [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml
                    printf '{"status":"ok","message":"Бэкап восстановлен! Перезапустите сервер."}'
                else
                    printf '{"status":"error","message":"Ошибка восстановления"}'
                fi
                rm -f "$TF"
            else
                printf '{"status":"error","message":"Нет данных"}'
            fi ;;
        toggle_favorite)
            IDX=$(echo "$POST_DATA" | sed -n 's/.*idx=\([^&]*\).*/\1/p')
            [ -f "$FAV" ] || echo "[]" > "$FAV"
            if grep -q "\"$IDX\"" "$FAV" 2>/dev/null; then
                awk -v idx="$IDX" 'BEGIN{RS=",";ORS=""} {gsub(/\[/,"");gsub(/\]/,"");gsub(/"/,"");if($0!=idx)print (NR>1?",":"")$0}' "$FAV" > /tmp/fav_tmp.json
                printf '[%s]' "$(cat /tmp/fav_tmp.json)" > "$FAV"
                printf '{"status":"ok","message":"Удалено из избранного","fav":false}'
            else
                if [ "$(cat "$FAV")" = "[]" ]; then
                    printf '["%s"]' "$IDX" > "$FAV"
                else
                    sed -i "s/\]/,\"$IDX\"\]/" "$FAV"
                fi
                printf '{"status":"ok","message":"Добавлено в избранное","fav":true}'
            fi ;;
        get_favorites)
            [ -f "$FAV" ] || echo "[]" > "$FAV"
            printf '{"status":"ok","favorites":%s}' "$(cat "$FAV")" ;;
        set_security)
            U=$(echo "$POST_DATA" | sed -n 's/.*user=\([^&]*\).*/\1/p')
            P=$(echo "$POST_DATA" | sed -n 's/.*pass=\([^&]*\).*/\1/p')
            U=$(echo "$U" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            P=$(echo "$P" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            if [ -n "$U" ] && [ -n "$P" ]; then
                printf 'ADMIN_USER="%s"\nADMIN_PASS="%s"\nAPI_TOKEN="%s"\n' "$U" "$P" "$(grep API_TOKEN "$SEC" 2>/dev/null | sed 's/.*="//;s/"//' || echo '')" > "$SEC"
                printf '{"status":"ok","message":"Пароль установлен"}'
            else
                printf 'ADMIN_USER=""\nADMIN_PASS=""\nAPI_TOKEN="%s"\n' "$(grep API_TOKEN "$SEC" 2>/dev/null | sed 's/.*="//;s/"//' || echo '')" > "$SEC"
                printf '{"status":"ok","message":"Авторизация отключена"}'
            fi ;;
        set_token)
            T=$(echo "$POST_DATA" | sed -n 's/.*token=\([^&]*\).*/\1/p')
            T=$(echo "$T" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            printf 'ADMIN_USER="%s"\nADMIN_PASS="%s"\nAPI_TOKEN="%s"\n' "$(grep ADMIN_USER "$SEC" 2>/dev/null | sed 's/.*="//;s/"//' || echo '')" "$(grep ADMIN_PASS "$SEC" 2>/dev/null | sed 's/.*="//;s/"//' || echo '')" "$T" > "$SEC"
            if [ -n "$T" ]; then
                printf '{"status":"ok","message":"Токен установлен"}'
            else
                printf '{"status":"ok","message":"API токен отключён"}'
            fi ;;
        check_update)
            CUR="$IPTV_MANAGER_VERSION"
            LATEST=$(wget -q --timeout=5 -O - "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null | head -10 | grep -o 'IPTV_MANAGER_VERSION="[^"]*"' | sed 's/IPTV_MANAGER_VERSION="//;s/"//')
            # Download full remote file and compare with local using md5sum
            REMOTE_FULL=$(wget -q --timeout=30 --no-check-certificate -O - "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null)
            if [ -n "$REMOTE_FULL" ]; then
                REMOTE_SUM=$(echo "$REMOTE_FULL" | md5sum | awk '{print $1}')
                LOCAL_SUM=$(md5sum "$IPTV_DIR/IPTV-Manager.sh" 2>/dev/null | awk '{print $1}')
                if [ -n "$LOCAL_SUM" ] && [ "$LOCAL_SUM" != "$REMOTE_SUM" ]; then
                    echo "$REMOTE_FULL" > "/tmp/IPTV-Manager-new.sh" 2>/dev/null
                    printf '{"status":"ok","update":true,"current":"%s","latest":"%s","reason":"file_changed"}' "$CUR" "${LATEST:-$CUR}"
                else
                    printf '{"status":"ok","update":false,"current":"%s","latest":"%s"}' "$CUR" "${LATEST:-$CUR}"
                fi
            else
                printf '{"status":"ok","update":false,"current":"%s","latest":"%s"}' "$CUR" "${LATEST:-$CUR}"
            fi ;;
        exec_cmd)
            CMD=$(echo "$POST_DATA" | sed -n 's/.*cmd=\([^&]*\).*/\1/p')
            CMD=$(echo "$CMD" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g;s/%20/ /g')
            if [ -n "$CMD" ]; then
                sh -c "$CMD" >/dev/null 2>&1
                printf '{"status":"ok"}'
            else
                printf '{"status":"error","message":"Нет команды"}'
            fi ;;
        server_start)
            printf '{"status":"ok"}'
            (sleep 1; /etc/iptv/IPTV-Manager.sh start >/dev/null 2>&1) &
            ;;
        server_stop)
            # Send response first, then kill uhttpd after 3s (gives CGI time to finish)
            printf '{"status":"ok"}'
            (sleep 3; kill $(pgrep -f "uhttpd.*8082") 2>/dev/null; rm -f /var/run/iptv-httpd.pid) &
            ;;
        server_status)
            if [ -f /var/run/iptv-httpd.pid ] && kill -0 "$(cat /var/run/iptv-httpd.pid 2>/dev/null)" 2>/dev/null; then
                printf '{"status":"ok","output":"running"}'
            else
                printf '{"status":"ok","output":"stopped"}'
            fi ;;
        system_info)
            _up=$(cat /proc/uptime 2>/dev/null | cut -d. -f1)
            _d=$((_up / 86400)); _h=$(((_up % 86400) / 3600)); _m=$(((_up % 3600) / 60))
            _uptxt=""
            [ "$_d" -gt 0 ] && _uptxt="${_d}д "
            _uptxt="${_uptxt}${_h}ч ${_m}м"
            # IPTV server uptime
            _iu="--"
            if [ -f /tmp/iptv-started ]; then
                _sn=$(cat /tmp/iptv-started 2>/dev/null)
                if [ -n "$_sn" ]; then
                    _now=$(date +%s)
                    _diff=$((_now - _sn))
                    if [ "$_diff" -gt 0 ] 2>/dev/null; then
                        _id=$((_diff / 86400)); _ih=$(((_diff % 86400) / 3600)); _im=$(((_diff % 3600) / 60))
                        _iu=""
                        [ "$_id" -gt 0 ] && _iu="${_id}д "
                        _iu="${_iu}${_ih}ч ${_im}м"
                    fi
                fi
            fi
            _mem_total=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null)
            _mem_free=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null)
            [ -z "$_mem_free" ] && _mem_free=$(awk '/MemFree/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null)
            _mem_used=$((_mem_total - _mem_free))
            _disk_total=$(df / 2>/dev/null | awk 'NR==2{print $2}')
            _disk_used=$(df / 2>/dev/null | awk 'NR==2{print $3}')
            _disk_pct=$(df / 2>/dev/null | awk 'NR==2{print $5}')
            printf '{"status":"ok","uptime":"%s","mem_total":"%sMB","mem_used":"%sMB","disk_total":"%s","disk_used":"%s","disk_pct":"%s"}' \
                "$_uptxt" "$_mem_total" "$_mem_used" "$_disk_total" "$_disk_used" "$_disk_pct"
            ;;
        validate_playlist)
            VU=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            VU=$(echo "$VU" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            if [ -n "$VU" ]; then
                VK=$(wget -q --spider --timeout=10 --no-check-certificate "$VU" 2>/dev/null && echo "ok" || echo "fail")
                if [ "$VK" = "ok" ]; then
                    VCH=$(wget -q --timeout=10 --no-check-certificate -O - "$VU" 2>/dev/null | grep -c "^#EXTINF")
                    printf '{"status":"ok","valid":true,"channels":"%s"}' "$VCH"
                else
                    printf '{"status":"ok","valid":false}'
                fi
            else
                printf '{"status":"error","message":"Укажите URL"}'
            fi ;;
        merge_playlists)
            MP=$(echo "$POST_DATA" | sed -n 's/.*urls=\([^&]*\).*/\1/p')
            MP=$(echo "$MP" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g;s/+/ /g')
            echo "#EXTM3U" > "$MERGED_PL"
            _mc=0
            for _u in $MP; do
                _u=$(echo "$_u" | sed 's/%2F/\//g;s/%3A/:/g')
                if wget -q --timeout=15 --no-check-certificate -O /tmp/_ipl.m3u "$_u" 2>/dev/null; then
                    grep "^#\|^http" /tmp/_ipl.m3u >> "$MERGED_PL" 2>/dev/null
                fi
            done
            _mc=$(grep -c "^#EXTINF" "$MERGED_PL" 2>/dev/null)
            cp "$MERGED_PL" "$PL" 2>/dev/null
            cp "$PL" /www/iptv/playlist.m3u 2>/dev/null
            printf '{"status":"ok","merged_channels":"%s"}' "${_mc:-0}"
            ;;
        set_playlist_url2)
            NU2=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            NU2=$(echo "$NU2" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            [ -n "$NU2" ] && {
                printf 'PLAYLIST_URL2="%s"\n' "$NU2" >> "$EC"
                printf '{"status":"ok","message":"Доп. плейлист сохранён"}'
            } || printf '{"status":"error","message":"Укажите URL"}' ;;
        set_whitelist)
            WL=$(echo "$POST_DATA" | sed -n 's/.*ips=\([^&]*\).*/\1/p')
            WL=$(echo "$WL" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g;s/+/ /g')
            if [ -n "$WL" ]; then
                echo "$WL" | tr ' ' '\n' | grep -v '^$' > "$WHITELIST_FILE"
                printf '{"status":"ok","message":"Список IP обновлён"}'
            else
                > "$WHITELIST_FILE"
                printf '{"status":"ok","message":"Список IP очищен (все разрешены)"}'
            fi ;;
        auto_update_keep)
            printf 'Content-Type: application/json\r\n\r\n{"status":"ok","message":"Применяю обновление..."}'
            (
                sleep 1
                TMPN="/tmp/IPTV-Manager-new.sh"
                if [ ! -s "$TMPN" ]; then
                    wget -q --timeout=30 --no-check-certificate -O "$TMPN" "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null
                fi
                if [ -s "$TMPN" ]; then
                    kill $(pgrep -f "uhttpd.*8082") 2>/dev/null
                    sleep 1
                    # Save configs
                    cp /etc/iptv/iptv.conf /tmp/_save_iptv.conf 2>/dev/null
                    cp /etc/iptv/epg.conf /tmp/_save_epg.conf 2>/dev/null
                    cp /etc/iptv/schedule.conf /tmp/_save_sched.conf 2>/dev/null
                    cp /etc/iptv/security.conf /tmp/_save_sec.conf 2>/dev/null
                    cp /etc/iptv/favorites.json /tmp/_save_fav.json 2>/dev/null
                    cp /etc/iptv/playlist.m3u /tmp/_save_pl.m3u 2>/dev/null
                    # Replace script
                    cp "$TMPN" /etc/iptv/IPTV-Manager.sh
                    chmod +x /etc/iptv/IPTV-Manager.sh
                    rm -f "$TMPN"
                    # Restore configs
                    [ -f /tmp/_save_iptv.conf ] && cp /tmp/_save_iptv.conf /etc/iptv/iptv.conf
                    [ -f /tmp/_save_epg.conf ] && cp /tmp/_save_epg.conf /etc/iptv/epg.conf
                    [ -f /tmp/_save_sched.conf ] && cp /tmp/_save_sched.conf /etc/iptv/schedule.conf
                    [ -f /tmp/_save_sec.conf ] && cp /tmp/_save_sec.conf /etc/iptv/security.conf
                    [ -f /tmp/_save_fav.json ] && cp /tmp/_save_fav.json /etc/iptv/favorites.json
                    [ -f /tmp/_save_pl.m3u ] && cp /tmp/_save_pl.m3u /etc/iptv/playlist.m3u
                    rm -f /tmp/_save_*
                    # Start server
                    nohup /etc/iptv/IPTV-Manager.sh start >/dev/null 2>&1 &
                fi
            ) </dev/null >/dev/null 2>&1 &
            sleep 1
            exit 0
            ;;
        factory_reset)
            printf 'Content-Type: application/json\r\n\r\n{"status":"ok","message":"Сброс к заводским..."}'
            (
                sleep 2
                kill $(pgrep -f "uhttpd.*8082") 2>/dev/null
                kill $(cat /var/run/iptv-httpd.pid 2>/dev/null) 2>/dev/null
                sleep 1
                rm -f /etc/iptv/iptv.conf /etc/iptv/epg.conf /etc/iptv/schedule.conf
                rm -f /etc/iptv/security.conf /etc/iptv/favorites.json /etc/iptv/provider.conf
                rm -f /etc/iptv/playlist.m3u /tmp/iptv-started
                rm -f /var/run/iptv-httpd.pid /tmp/iptv-reset-new.sh
                # Download fresh script 
                if wget -q --timeout=30 --no-check-certificate -O /tmp/iptv-reset-new.sh "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null && [ -s /tmp/iptv-reset-new.sh ]; then
                    cp /tmp/iptv-reset-new.sh /etc/iptv/IPTV-Manager.sh
                    chmod +x /etc/iptv/IPTV-Manager.sh
                fi
                # Start server using start_http_server 
                nohup sh -c 'source /etc/iptv/IPTV-Manager.sh 2>/dev/null; start_http_server' >/tmp/iptv-reset.log 2>&1 &
            ) </dev/null >/dev/null 2>&1 &
            sleep 1
            exit 0
            ;;
    esac
    exit 0
fi

hdr
CH=$(grep -c "^#EXTINF" "$PL" 2>/dev/null)
[ -z "$CH" ] && CH=0
PSZ="---"
ESZ="---"
if [ -f "$PL" ]; then PSZ=$(cat "$PL" | wc -c); PSZ="$((PSZ/1024)) KB"; fi
if [ -f "$EGZ" ]; then ESZ=$(cat "$EGZ" | wc -c); ESZ="$((ESZ/1024)) KB"; fi
PURL=""
EURL=""
PI="0"
EI="0"
PLU="----"
ELU="----"
. "$EC" 2>/dev/null
[ "$PLAYLIST_TYPE" = "url" ] && PURL="$PLAYLIST_URL"
. "$EXC" 2>/dev/null
[ -n "$EPG_URL" ] && EURL="$EPG_URL"
. "$SC" 2>/dev/null
PI="${PLAYLIST_INTERVAL:-0}"
EI="${EPG_INTERVAL:-0}"
PLU="${PLAYLIST_LAST_UPDATE:----}"
ELU="${EPG_LAST_UPDATE:----}"
BUILTIN_EPG=$(head -5 "$PL" 2>/dev/null | grep -o 'url-tvg="[^"]*"' | head -1 | sed 's/url-tvg="//;s/"//')
EPG_NOTICE=""
[ -n "$BUILTIN_EPG" ] && [ -z "$EURL" ] && EPG_NOTICE="<div class=\"banner\">💡 В плейлисте найдена встроенная ссылка EPG: <code>$BUILTIN_EPG</code> — укажите её в поле выше для загрузки.</div>"
GROUPS=""
[ -f "$PL" ] && GROUPS=$(grep -o 'group-title="[^"]*"' "$PL" | sed 's/group-title="//;s/"//' | sort -u)
GOPTS=""
GOPTS=$(echo "$GROUPS" | while IFS= read -r g; do [ -n "$g" ] && echo "<option value=\"$g\">$g</option>"; done)
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"
EPGROWS=""
[ -f "$EGZ" ] && EPGROWS=$(gunzip -c "$EGZ" 2>/dev/null | awk '/<programme /{s=$0;if(match(s,/start="[0-9]+/)){st=substr(s,RSTART+7,RLENGTH-7);if(match(s,/channel="[^"]+"/)){ch=substr(s,RSTART+9,RLENGTH-9)}}}/<title/{t=$0;if(match(t,/<title[^>]*>[^<]*<\/title>/)){t=substr(t,RSTART,RLENGTH);gsub(/<[^>]*>/,"",t);ti=t}}/<\/programme>/{if(ti!=""&&ch!=""&&st!=""){printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n",substr(st,9,2)":"substr(st,11,2),ch,ti;c++;if(c>=30)exit}ti=""}' 2>/dev/null)

groups=""
[ -f "$PL" ] && groups=$(grep -o 'group-title="[^"]*"' "$PL" 2>/dev/null | sed 's/group-title="//;s/"//' | sort -u | grep . || true)
grp_count=0
[ -n "$groups" ] && grp_count=$(echo "$groups" | wc -l | tr -d ' ')
hd_count=0
[ -f "$PL" ] && hd_count=$(grep -ci "hd\|1080\|4k\|2160\|uhd" "$PL" 2>/dev/null || true)
[ -z "$hd_count" ] && hd_count=0
sd_count=$((${CH:-0} - ${hd_count:-0}))
# IPTV Manager resource usage only
_iptv_ram=0
[ -f "$PL" ] && _iptv_ram=$((_iptv_ram + $(wc -c < "$PL" 2>/dev/null || echo 0)))
[ -f "$EPG_GZ" ] && _iptv_ram=$((_iptv_ram + $(wc -c < "$EPG_GZ" 2>/dev/null || echo 0)))
[ -f /www/iptv/channels.json ] && _iptv_ram=$((_iptv_ram + $(wc -c < /www/iptv/channels.json 2>/dev/null || echo 0)))
for _f in "$CONFIG_FILE" "$PROVIDER_CONFIG" "$EPG_CONFIG" "$SCHEDULE_FILE" "$FAVORITES_FILE" "$SECURITY_FILE"; do [ -f "$_f" ] && _iptv_ram=$((_iptv_ram + $(wc -c < "$_f" 2>/dev/null || echo 0))); done
_iptv_kB=$((_iptv_ram / 1024))
[ "$_iptv_kB" -lt 1024 ] && _iptv_rt="${_iptv_kB}KB" || _iptv_rt="$((_iptv_kB / 1024))MB"
# Disk usage — IPTV Manager files only
_iptv_disk=0
[ -d /etc/iptv ] && _iptv_disk=$((_iptv_disk + $(du -sb /etc/iptv 2>/dev/null | cut -f1 || echo 0)))
[ -d /www/iptv ] && _iptv_disk=$((_iptv_disk + $(du -sb /www/iptv 2>/dev/null | cut -f1 || echo 0)))
[ -f "$EPG_GZ" ] && _iptv_disk=$((_iptv_disk + $(du -sb "$EPG_GZ" 2>/dev/null | cut -f1 || echo 0)))
_iptv_dkB=$((_iptv_disk / 1024))
[ "$_iptv_dkB" -lt 1024 ] && _iptv_dt="${_iptv_dkB}KB" || _iptv_dt="$((_iptv_dkB / 1024))MB"
# IPTV Server uptime
_iptv_uptime="--"
if [ -f "$STARTUP_TIME" ]; then
    _now=$(date +%s)
    _start=$(cat "$STARTUP_TIME" 2>/dev/null)
    if [ -n "$_start" ] && [ "$_start" -lt "$_now" ] 2>/dev/null; then
        _diff=$((_now - _start))
        _iu_d=$((_diff / 86400)); _iu_h=$(((_diff % 86400) / 3600)); _iu_m=$(((_diff % 3600) / 60))
        _iptv_uptime=""
        [ "$_iu_d" -gt 0 ] && _iptv_uptime="${_iu_d}д "
        _iptv_uptime="${_iptv_uptime}${_iu_h}ч ${_iu_m}м"
    fi
fi
pname="${PLAYLIST_NAME:-$PSZ}"
psz="$PSZ"
esz="$ESZ"
group_opts=""
[ -n "$groups" ] && group_opts=$(echo "$groups" | while IFS= read -r g; do [ -n "$g" ] && echo "<option value=\"$g\">$g</option>"; done)
pi="$PI"
ei="$EI"
plu="$PLU"
elu="$ELU"

cat << HTMLEND
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>IPTV Manager</title>
<style>
:root{--bg:#f0f2f5;--card:#fff;--text:#1a1a2e;--text2:#666;--text3:#888;--border:#e0e0e0;--input-bg:#fafafa;--hover-bg:#f8f9fa;--primary:#1a73e8;--primary-hover:#1557b0;--success:#1e8e3e;--danger:#d93025;--shadow:0 1px 3px rgba(0,0,0,.06);--shadow-lg:0 8px 32px rgba(0,0,0,.15);--modal-bg:rgba(0,0,0,.4)}
[data-theme="dark"]{--bg:#0a0e1a;--card:#1e293b;--text:#e2e8f0;--text2:#94a3b8;--text3:#64748b;--border:#334155;--input-bg:#0f172a;--hover-bg:#334155;--primary:#3b82f6;--primary-hover:#2563eb;--success:#22c55e;--danger:#ef4444;--shadow:0 1px 3px rgba(0,0,0,.2);--shadow-lg:0 8px 32px rgba(0,0,0,.4);--modal-bg:rgba(0,0,0,.6)}
[data-theme="openwrt"]{--bg:#1a1b26;--card:#24283b;--text:#c0caf5;--text2:#9aa5ce;--text3:#565f89;--border:#3b4261;--input-bg:#1e2030;--hover-bg:#292e42;--primary:#7aa2f7;--primary-hover:#6893db;--success:#9ece6a;--danger:#f7768e;--shadow:0 1px 3px rgba(0,0,0,.2);--shadow-lg:0 8px 32px rgba(0,0,0,.4);--modal-bg:rgba(0,0,0,.6)}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--text);min-height:100vh;transition:background .2s,color .2s}
.c{max-width:1200px;margin:0 auto;padding:16px}
.h{display:flex;align-items:center;justify-content:space-between;padding:16px 20px;border-bottom:2px solid var(--border);margin-bottom:16px;background:var(--card);border-radius:8px;box-shadow:var(--shadow)}
.h h1{font-size:20px;color:var(--primary)}.h p{color:var(--text3);font-size:11px;margin-top:2px}
.tt{background:var(--input-bg);border:1px solid var(--border);border-radius:20px;padding:6px 14px;cursor:pointer;font-size:13px;color:var(--text);display:flex;align-items:center;gap:6px;transition:all .2s;user-select:none}
.tt:hover{border-color:var(--primary)}
.st{display:grid;grid-template-columns:repeat(auto-fit,minmax(90px,1fr));gap:6px;margin-bottom:16px}
.s{background:var(--card);border-radius:8px;padding:12px;text-align:center;border:1px solid var(--border);box-shadow:var(--shadow)}
.sv{font-size:18px;font-weight:700;color:var(--primary)}.sl{font-size:10px;color:var(--text3);text-transform:uppercase;margin-top:2px}
.ub{background:var(--card);border:1px solid var(--border);border-radius:6px;padding:8px;margin:6px 0;display:flex;align-items:center;gap:6px}
.ub code{flex:1;font-size:12px;color:var(--primary);word-break:break-all}
.ub button{padding:4px 10px;background:var(--input-bg);border:1px solid var(--primary);border-radius:4px;color:var(--primary);cursor:pointer;font-size:11px}
.ub button:hover{background:var(--primary);color:#fff}
.tb{display:flex;gap:4px;margin-bottom:14px;background:var(--card);border-radius:8px;padding:4px;overflow-x:auto;border:1px solid var(--border)}
.t{flex:1;padding:9px 10px;border:none;background:transparent;color:var(--text2);border-radius:6px;cursor:pointer;font-size:12px;font-weight:500;white-space:nowrap}
.t:hover{color:var(--primary);background:var(--hover-bg)}.t.a{background:var(--primary);color:#fff}
.pn{display:none;background:var(--card);border-radius:0 0 12px 12px;padding:16px;border:1px solid var(--border);border-top:none;margin-bottom:10px;box-shadow:var(--shadow)}
.pn.a{display:block}.pn h2{font-size:15px;margin-bottom:12px;color:var(--text)}
.fg{margin-bottom:10px}.fg label{display:block;font-size:11px;color:var(--text2);margin-bottom:3px}
.fg input,.fg textarea,.fg select{width:100%;padding:8px 10px;background:var(--input-bg);border:1px solid var(--border);border-radius:6px;color:var(--text);font-size:13px}
.fg input:focus,.fg textarea:focus{outline:none;border-color:var(--primary);box-shadow:0 0 0 2px rgba(26,115,232,.15)}
.fg textarea{min-height:80px;font-family:monospace;font-size:11px;resize:vertical}
.fg .hint{font-size:10px;color:var(--text3);margin-top:2px}
.b{padding:7px 14px;border:none;border-radius:6px;font-size:12px;font-weight:600;cursor:pointer;display:inline-block}
.bp{background:var(--primary);color:#fff}.bp:hover{background:var(--primary-hover)}
.bd{background:var(--danger);color:#fff}.bd:hover{background:#b3261e}
.bs{background:var(--success);color:#fff}.bs:hover{background:#137333}
.bo{background:transparent;border:1px solid var(--border);color:var(--text)}.bo:hover{background:var(--hover-bg)}
.bsm{padding:5px 10px;font-size:11px}.bg{display:flex;gap:6px;margin-top:10px;flex-wrap:wrap}
hr{border:none;border-top:1px solid var(--border);margin:12px 0}
.ch-t{width:100%;border-collapse:collapse}
.ch-t th{text-align:left;padding:8px 10px;font-size:11px;color:var(--text3);border-bottom:2px solid var(--border);font-weight:500}
.ch-t td{padding:8px 10px;font-size:12px;border-bottom:1px solid var(--border);vertical-align:middle}
.ch-t tr:hover{background:var(--hover-bg)}
.ch-st{width:10px;height:10px;border-radius:50%;display:inline-block}
.ch-st.online{background:var(--success)}.ch-st.offline{background:var(--danger)}.ch-st.unknown{background:var(--text3)}
.ch-n{font-weight:500;max-width:250px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ch-g{color:var(--text3);font-size:11px}.ch-p{color:var(--text2);font-size:11px;max-width:200px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ch-logo{width:20px;height:20px;border-radius:3px;object-fit:contain;vertical-align:middle;margin-right:4px}
.epg-t{width:100%;border-collapse:collapse}.epg-t th{text-align:left;padding:8px 10px;font-size:11px;color:var(--text3);border-bottom:2px solid var(--border)}
.epg-t td{padding:8px 10px;font-size:12px;border-bottom:1px solid var(--border)}.epg-t tr:hover{background:var(--hover-bg)}
.fb{display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap;align-items:center}
.fb select,.fb input{padding:6px 10px;background:var(--input-bg);border:1px solid var(--border);border-radius:6px;color:var(--text);font-size:12px}
.fb input{flex:1;min-width:150px}.fb input:focus,.fb select:focus{outline:none;border-color:var(--primary)}
.modal{display:none;position:fixed;inset:0;background:var(--modal-bg);z-index:100;align-items:center;justify-content:center}
.modal.open{display:flex}
.modal-box{background:var(--card);border-radius:12px;padding:24px;border:1px solid var(--border);max-width:640px;width:92%;box-shadow:var(--shadow-lg)}
.modal-box h3{font-size:16px;margin-bottom:14px;color:var(--text);padding-bottom:10px;border-bottom:1px solid var(--border)}
.toast{position:fixed;top:12px;right:12px;padding:10px 14px;border-radius:6px;font-size:12px;z-index:200;box-shadow:0 4px 12px rgba(0,0,0,.15);animation:si .2s ease-out}
@keyframes si{from{transform:translateX(100%);opacity:0}to{transform:translateX(0);opacity:1}}
.to{background:#e6f4ea;border:1px solid #1e8e3e;color:#137333}.te{background:#fce8e6;border:1px solid #d93025;color:#c5221f}
.sg{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.sc{background:var(--input-bg);border-radius:8px;padding:12px;border:1px solid var(--border)}
.sc h3{font-size:12px;color:var(--text);margin-bottom:8px}.sc select{width:100%;padding:8px;background:var(--card);border:1px solid var(--border);border-radius:6px;color:var(--text);font-size:12px}
.si{margin-top:8px;font-size:10px;color:var(--text3)}.si span{color:var(--text)}
.banner{background:#e8f0fe;border:1px solid #1a73e8;border-radius:8px;padding:10px 14px;margin-bottom:12px;font-size:12px;color:#1a73e8}
.banner code{background:#fff;padding:2px 6px;border-radius:3px;font-size:11px}
.ft{text-align:center;padding:16px 0;color:var(--text3);font-size:10px}
.pg{padding:6px 12px;border:1px solid var(--border);border-radius:6px;background:var(--card);color:var(--text);cursor:pointer;font-size:12px;transition:all .15s}
.pg:hover{background:var(--hover-bg);border-color:var(--primary)}
.pg.a{background:var(--primary);color:#fff;border-color:var(--primary)}
.pg:disabled{opacity:.4;cursor:default}
.pg-info{font-size:11px;color:var(--text3);margin:0 8px}
.loading{text-align:center;padding:40px;color:var(--text3)}
.fav-btn{background:none;border:none;cursor:pointer;font-size:16px;padding:2px 4px;color:var(--text3);transition:color .15s}
.fav-btn:hover{color:#f59e0b}
@media(max-width:700px){.st{grid-template-columns:1fr 1fr}.sg{grid-template-columns:1fr}.h{flex-direction:column;gap:10px}.fb{flex-direction:column}}
</style>
</head>
<body>
<div class="c">
<div class="h"><div><h1>IPTV Manager</h1><p>OpenWrt v$IPTV_MANAGER_VERSION</p></div><button class="tt" id="ttb" onclick="toggleTheme()">☀️ Light</button></div>
<div class="st">
<div class="s"><div class="sv">$CH</div><div class="sl">Каналов</div></div>
<div class="s"><div class="sv">${pname:-$PSZ}</div><div class="sl">Плейлист</div></div>
<div class="s"><div class="sv">$ESZ</div><div class="sl">EPG</div></div>
<div class="s"><div class="sv">$grp_count</div><div class="sl">Групп</div></div>
<div class="s"><div class="sv">$hd_count</div><div class="sl">HD</div></div>
<div class="s"><div class="sv">$sd_count</div><div class="sl">SD</div></div>
<div class="s"><div class="sv">$_iptv_uptime</div><div class="sl">Сервер</div></div>
<div class="s"><div class="sv">$_uptxt</div><div class="sl">Система</div></div>
<div class="s"><div class="sv">$_iptv_rt</div><div class="sl">RAM*</div></div>
<div class="s"><div class="sv">$_iptv_dt</div><div class="sl">Диск*</div></div>
</div>
<div class="ub"><code>http://$LAN_IP:$IPTV_PORT/playlist.m3u</code><button onclick="cp(this)">Копировать</button></div>
<div class="ub"><code>http://$LAN_IP:$IPTV_PORT/epg.xml</code><button onclick="cp(this)">Копировать</button></div>
<div class="ub" style="font-size:10px;color:var(--text3)">* Только файлы IPTV Manager (конфиги, плейлист, EPG)</div>
<div class="tb">
<button class="t a" onclick="st('status',this)">Каналы</button>
<button class="t" onclick="st('playlist',this)">Плейлист</button>
<button class="t" onclick="st('epg',this)">Телепрограмма</button>
<button class="t" onclick="st('settings',this)">Настройки</button>
</div>
<div class="pn a" id="p-status">
<h2>Список каналов</h2>
<div class="fb">
<select id="f-g" onchange="filterCh()"><option value="">Все группы</option>$group_opts</select>
<input type="text" id="f-s" placeholder="Поиск..." oninput="filterCh()">
<button class="b bsm bo" id="fav-btn" onclick="toggleFavFilter()">☆ Избранное</button>
<button class="b bp bsm" onclick="checkAll()">Проверить все</button>
<button class="b bs bsm" onclick="watchAll()">▶ Смотреть всё</button>
</div>
<div style="overflow-x:auto">
<table class="ch-t">
<thead><tr><th style="width:30px">★</th><th style="width:20px"></th><th>Название</th><th>Группа</th><th>Сейчас играет</th><th style="width:70px">Пинг</th><th style="width:40px"></th><th>Действия</th></tr></thead>
<tbody id="ch-tb"><tr><td colspan="8" class="loading">Загрузка каналов...</td></tbody>
</table>
</div>
<div id="pager" style="display:flex;justify-content:center;align-items:center;gap:6px;margin-top:12px;flex-wrap:wrap"></div>
</div>
<div class="pn" id="p-playlist">
<h2>Плейлист</h2>
<div class="fg"><label>Название плейлиста</label><input type="text" id="pl-name" placeholder="Мой плейлист" value="$pname"><div class="hint">Произвольное имя для отображения в статистике</div></div>
<div class="bg" style="margin-top:6px"><button class="b bp bsm" onclick="setPlName()">Сохранить название</button></div>
<hr>
<div class="fg"><label>Ссылка на плейлист</label><input type="url" id="pl-u" placeholder="http://example.com/playlist.m3u" value="$PURL"><div class="hint">Вставьте ссылку на M3U/M3U8 плейлист</div></div>
<div class="bg"><button class="b bp" onclick="setPlUrl()">Применить</button><button class="b bs" onclick="act('refresh_playlist','')">Обновить</button></div>
<hr>
<h3>Исходный M3U</h3>
<div class="fg"><textarea id="pl-r" readonly style="min-height:200px"></textarea></div>
</div>
<div class="pn" id="p-epg">
<h2>Телепрограмма (EPG)</h2>
$EPG_NOTICE
<div class="fg"><label>Ссылка на EPG (XMLTV)</label><input type="url" id="epg-u" placeholder="https://iptvx.one/EPG_LITE" value="$EURL"><div class="hint">Поддерживаются XML и XML.gz. EPG хранится в RAM (/tmp).</div></div>
<div class="bg"><button class="b bp" onclick="setEpgUrl()">Применить</button><button class="b bs" onclick="act('refresh_epg','');setTimeout(loadEpgTable,1000)">Обновить</button></div>
<hr>
<h3>Передачи <button class="b bsm bo" onclick="loadEpgTable()">🔄 Обновить</button></h3>
<div style="overflow-x:auto">
<table class="epg-t">
<thead><tr><th>Время</th><th>Канал</th><th>Передача</th></tr></thead>
<tbody id="epg-tb">$EPGROWS</tbody>
</table>
</div>
</div>
<div class="pn" id="p-settings">
<h2>Настройки</h2>
<div class="sg">
<div class="sc">
<h3>Расписание плейлиста</h3>
<select id="s-pl">
<option value="0">Выкл</option>
<option value="1">Каждый час</option>
<option value="6">Каждые 6ч</option>
<option value="12">Каждые 12ч</option>
<option value="24">Раз в сутки</option>
</select>
<div class="si">Последнее: <span>$PLU</span></div>
</div>
<div class="sc">
<h3>Расписание EPG</h3>
<select id="s-epg">
<option value="0">Выкл</option>
<option value="1">Каждый час</option>
<option value="6">Каждые 6ч</option>
<option value="12">Каждые 12ч</option>
<option value="24">Раз в сутки</option>
</select>
<div class="si">Последнее: <span>$ELU</span></div>
</div>
</div>
<div class="bg"><button class="b bp bsm" onclick="saveSched()">Сохранить</button></div>
<hr>
<h3>Бэкап и восстановление</h3>
<div class="sg">
<div class="sc">
<h3>Экспорт</h3>
<div class="si">Скачать архив со всеми настройками</div>
<div class="bg" style="margin-top:8px"><button class="b bs bsm" onclick="act('backup','')">Скачать бэкап</button></div>
</div>
<div class="sc">
<h3>Импорт</h3>
<div class="bg" style="margin-top:4px">
<label class="b bs bsm" for="imp-file" style="cursor:pointer">Выберите файл</label>
<input type="file" id="imp-file" accept=".tar.gz" style="display:none">
<button class="b bp bsm" onclick="doImport()">Восстановить</button>
</div>
</div>
</div>
<hr>
<h3>Проверка обновлений</h3>
<div id="up-info" style="font-size:11px;color:var(--text3);margin-bottom:8px"></div>
<div class="bg"><button class="b bsm bo" onclick="checkUpdate()">🔄 Проверить обновления</button></div>
<hr>
<h3>Обновление с GitHub</h3>
<div class="sg">
<div class="sc">
<h3>Обновить с сохранением</h3>
<div class="si">Скачивает последнюю версию, сохраняя плейлист, EPG и настройки</div>
<div class="bg" style="margin-top:8px"><button class="b bp bsm" onclick="doUpdateKeep()">📦 Обновить</button></div>
</div>
<div class="sc">
<h3>Сброс к заводским</h3>
<div class="si">Полный сброс — удаляет настройки и запускает первоначальную настройку заново</div>
<div class="bg" style="margin-top:8px"><button class="b bd bsm" onclick="doUpdateClean()">🗑️ Сбросить</button></div>
</div>
</div>
<hr>
<h3>Белый список IP и лимиты</h3>
<div class="sg">
<div class="sc">
<h3>Пароль на админку</h3>
<div class="fg" style="margin-top:6px"><label>Логин</label><input type="text" id="sec-user" placeholder="Пусто = отключить"></div>
<div class="fg"><label>Пароль</label><input type="password" id="sec-pass" placeholder="Пусто = отключить"></div>
<div class="bg" style="margin-top:8px"><button class="b bp bsm" onclick="saveSecurity()">Сохранить</button></div>
</div>
<div class="sc">
<h3>API токен</h3>
<div class="fg" style="margin-top:6px"><label>Токен</label><input type="text" id="sec-token" placeholder="Пусто = отключить"></div>
<div class="bg" style="margin-top:8px"><button class="b bs bsm" onclick="saveToken()">Сохранить</button></div>
</div>
</div>
<hr>
<h3>Белый список IP и лимиты</h3>
<div class="sg">
<div class="sc">
<h3>Белый список IP</h3>
<div class="fg" style="margin-top:6px"><label>IP адреса (по одному на строку)</label><textarea id="wl-ips" placeholder="192.168.1.100&#10;192.168.1.101"></textarea></div>
<div class="bg" style="margin-top:8px"><button class="b bp bsm" onclick="saveWhitelist()">Сохранить</button></div>
<div class="si">Оставьте пустым — все разрешены</div>
</div>
<div class="sc">
<h3>Rate Limit</h3>
<div class="si">Максимум запросов: <b id="rl-info">60/мин</b></div>
<div class="bg" style="margin-top:8px"><button class="b bp bsm" onclick="act('get_whitelist', ''); toast('Rate limit: 60 запросов/мин','ok')">Проверить</button></div>
</div>
</div>
<hr>
<h3>Дополнительные плейлисты</h3>
<div class="sg">
<div class="sc">
<h3>Объединить плейлисты</h3>
<div class="fg" style="margin-top:6px"><label>URL плейлистов (по одному на строку)</label><textarea id="merge-urls" placeholder="http://...&#10;http://..."></textarea></div>
<div class="bg" style="margin-top:8px"><button class="b bp bsm" onclick="mergePlaylists()">Объединить</button></div>
</div>
<div class="sc">
<h3>Проверить URL</h3>
<div class="fg" style="margin-top:6px"><label>URL для проверки</label><input type="url" id="validate-url" placeholder="http://..."></div>
<div class="bg" style="margin-top:8px"><button class="b bp bsm" onclick="validatePlaylist()">Проверить</button></div>
</div>
</div>
</div>
<div class="modal" id="em">
<div class="modal-box">
<h3>Редактировать канал</h3>
<div class="fg"><label>Название</label><input type="text" id="e-n" readonly></div>
<div class="fg"><label>Ссылка</label><input type="text" id="e-u"></div>
<div class="fg"><label>Группа</label><input type="text" id="e-g"></div>
<div class="bg">
<button class="b bp bsm" onclick="saveEdit()">Сохранить</button>
<button class="b bo bsm" onclick="closeModal()">Отмена</button>
</div>
</div>
</div>
<div class="ft">IPTV Manager v$IPTV_MANAGER_VERSION — OpenWrt</div>
</div>
<script>
var API='/cgi-bin/admin.cgi';
var channels=[];
var epgMap={};
var favorites=[];
var PS=150,CP=0,filteredRows=[];
var showFavOnly=false;

function toggleTheme(){
    var d=document.documentElement,c=d.getAttribute('data-theme')||'light';
    var n=c==='light'?'dark':c==='dark'?'openwrt':'light';
    d.setAttribute('data-theme',n);
    var b=document.getElementById('ttb');
    if(b){
        if(n==='light')b.innerHTML='☀️ Light';
        else if(n==='dark')b.innerHTML='🌙 Dark';
        else b.innerHTML='🟣 OpenWrt';
    }
    try{localStorage.setItem('iptv-theme',n)}catch(e){}
}
(function(){
    try{
        var t=localStorage.getItem('iptv-theme');
        var b=document.getElementById('ttb');
        if(t==='dark'){document.documentElement.setAttribute('data-theme','dark');if(b)b.innerHTML='🌙 Dark'}
        else if(t==='openwrt'){document.documentElement.setAttribute('data-theme','openwrt');if(b)b.innerHTML='🟣 OpenWrt'}
        else if(b)b.innerHTML='☀️ Light';
    }catch(e){}
    if(window.parent!==window){
        document.documentElement.setAttribute('data-theme','openwrt');
        var b=document.getElementById('ttb');
        if(b)b.innerHTML='🟣 OpenWrt';
    }
})();

function st(t,e){
    document.querySelectorAll('.t').forEach(function(x){x.classList.remove('a')});
    document.querySelectorAll('.pn').forEach(function(x){x.classList.remove('a')});
    document.getElementById('p-'+t).classList.add('a');
    e.classList.add('a');
    if(t==='playlist')loadRaw();
    if(t==='epg')loadEpgTable();
}

function cp(b){
    var c=b.previousElementSibling,r=document.createRange();
    r.selectNodeContents(c);
    var s=window.getSelection();s.removeAllRanges();s.addRange(r);
    document.execCommand('copy');s.removeAllRanges();
    b.textContent='OK';setTimeout(function(){b.textContent='Копировать'},1500);
}

function toast(m,t){
    var d=document.createElement('div');
    d.className='toast '+(t==='ok'?'to':'te');
    d.textContent=m;document.body.appendChild(d);
    setTimeout(function(){d.remove()},4000);
}

function act(a,p,cb){
    var x=new XMLHttpRequest();
    x.open('POST',API,true);
    x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            if(cb){cb(r)}
            else if(r.status==='ok'){toast(r.message,'ok');setTimeout(function(){location.reload()},1500)}
            else toast(r.message,'err');
        }catch(e){toast('Ошибка','err')}
    };
    x.onerror=function(){toast('Ошибка сети','err')};
    x.send('action='+a+'&'+p);
}

function checkCh(idx){
    var ch=channels[idx];
    if(!ch)return;
    var el=document.getElementById('st-'+idx);
    if(el)el.className='ch-st unknown';
    var x=new XMLHttpRequest();
    x.open('POST',API,true);
    x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            if(el)el.className=r.online?'ch-st online':'ch-st offline';
        }catch(e){if(el)el.className='ch-st offline'}
    };
    x.send('action=check_channel&url='+encodeURIComponent(ch.u));
}

function checkAll(){
    channels.forEach(function(_,i){checkCh(i)});
}

function watchCh(idx){
    var ch=channels[idx];
    if(!ch)return;
    window.open('/player.html?url='+encodeURIComponent(ch.u)+'&idx='+idx,'_blank');
}

function watchAll(){
    window.open('/player.html','_blank');
}

function editCh(idx){
    var ch=channels[idx];
    if(!ch)return;
    document.getElementById('e-n').value=ch.n;
    document.getElementById('e-u').value=ch.u;
    document.getElementById('e-g').value=ch.g;
    document.getElementById('em').classList.add('open');
    document.getElementById('em').setAttribute('data-idx',idx);
}

function closeModal(){
    document.getElementById('em').classList.remove('open');
}

function saveEdit(){
    var idx=document.getElementById('em').getAttribute('data-idx');
    var u=document.getElementById('e-u').value;
    var g=document.getElementById('e-g').value;
    var x=new XMLHttpRequest();
    x.open('POST',API,true);
    x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            if(r.status==='ok'){toast('Сохранено','ok');closeModal();setTimeout(function(){location.reload()},1000)}
            else toast(r.message,'err');
        }catch(e){toast('Ошибка','err')}
    };
    x.send('action=update_channel&idx='+idx+'&new_url='+encodeURIComponent(u)+'&new_group='+encodeURIComponent(g));
}

function setPlUrl(){
    var u=document.getElementById('pl-u').value;
    if(!u){toast('Введите ссылку','err');return}
    act('set_playlist_url','url='+encodeURIComponent(u));
}

function setEpgUrl(){
    var u=document.getElementById('epg-u').value;
    if(!u){toast('Введите ссылку','err');return}
    act('set_epg_url','url='+encodeURIComponent(u),function(r){
        if(r.status==='ok'){
            toast(r.message,r.large?'err':'ok');
            setTimeout(loadEpgTable,1000);
            setTimeout(loadEpgMap,1000);
        }
    });
}

function setPlName(){
    var n=document.getElementById('pl-name').value;
    if(!n){toast('Введите название','err');return}
    act('set_playlist_name','name='+encodeURIComponent(n));
}

function loadEpgTable(){
    var x=new XMLHttpRequest();
    x.open('GET',API+'?action=get_epg',true);
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            var tb=document.getElementById('epg-tb');
            if(r.status==='ok'&&r.rows&&r.rows.length){
                var h='';
                for(var i=0;i<r.rows.length;i++){
                    var row=r.rows[i];
                    h+='<tr><td>'+escHtml(row.t)+'</td><td>'+escHtml(row.c)+'</td><td>'+escHtml(row.p)+'</td></tr>';
                }
                tb.innerHTML=h;
            }else{
                tb.innerHTML='<tr><td colspan="3" class="loading">Нет данных</td></tr>';
            }
        }catch(e){
            document.getElementById('epg-tb').innerHTML='<tr><td colspan="3" class="loading">Ошибка загрузки</td></tr>';
        }
    };
    x.onerror=function(){
        document.getElementById('epg-tb').innerHTML='<tr><td colspan="3" class="loading">Ошибка загрузки</td></tr>';
    };
    x.send();
}

function saveSched(){
    var p=document.getElementById('s-pl').value;
    var e=document.getElementById('s-epg').value;
    act('set_schedule','playlist_interval='+p+'&epg_interval='+e);
}

function loadRaw(){
    var x=new XMLHttpRequest();
    x.open('GET','/playlist.m3u',true);
    x.onload=function(){document.getElementById('pl-r').value=x.responseText};
    x.send();
}

function doImport(){
    var f=document.getElementById('imp-file');
    if(!f.files[0]){toast('Выберите файл','err');return}
    var fd=new FormData();fd.append('file',f.files[0]);
    var x=new XMLHttpRequest();
    x.open('POST',API);
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            if(r.status==='ok'){toast(r.message,'ok');setTimeout(function(){location.reload()},1500)}
            else toast(r.message,'err');
        }catch(e){toast('Ошибка','err')}
    };
    x.send(fd);
}

function renderRows(){
    var tb=document.getElementById('ch-tb');
    if(!filteredRows.length){
        tb.innerHTML='<tr><td colspan="8" class="loading">Нет каналов</td></tr>';
        document.getElementById('pager').innerHTML='';
        return;
    }
    var total=filteredRows.length;
    var pages=Math.ceil(total/PS);
    if(CP>=pages)CP=pages-1;
    if(CP<0)CP=0;
    var start=CP*PS;
    var end=Math.min(start+PS,total);
    var html='';
    for(var i=start;i<end;i++){
        var ch=filteredRows[i];
        var realIdx=ch._idx;
        var logoHtml='';
        if(ch.l){
            logoHtml='<img class="ch-logo" src="'+escHtml(ch.l)+'" onerror="this.style.display=\'none\'">';
        }
        var prog='—';
        if(ch.i && epgMap[ch.i])prog=escHtml(epgMap[ch.i]);
        var isFav=favorites.indexOf(realIdx)>=0;
        html+='<tr>';
        html+='<td><button class="fav-btn" data-idx="'+realIdx+'" onclick="toggleFav('+realIdx+')" title="'+(isFav?'Удалить из избранного':'Добавить в избранное')+'">'+(isFav?'★':'☆')+'</button></td>';
        html+='<td><span class="ch-st unknown" id="st-'+realIdx+'"></span></td>';
        html+='<td class="ch-n">'+logoHtml+escHtml(ch.n)+'</td>';
        html+='<td class="ch-g">'+escHtml(ch.g)+'</td>';
        html+='<td class="ch-p">'+prog+'</td>';
        html+='<td><button class="b bsm bp" onclick="checkCh('+realIdx+')">Пинг</button></td>';
        html+='<td><button class="b bsm bs" onclick="watchCh('+realIdx+')">▶</button></td>';
        html+='<td><button class="b bsm bo" onclick="editCh('+realIdx+')">Изм.</button></td>';
        html+='</tr>';
    }
    tb.innerHTML=html;
    renderPager(total,pages);
}

function renderPager(total,pages){
    var pg=document.getElementById('pager');
    if(pages<=1){
        pg.innerHTML='<span class="pg-info">'+total+' каналов</span>';
        return;
    }
    var h='<button class="pg" onclick="goPage(CP-1)"'+(CP===0?' disabled':'')+'>‹</button>';
    for(var i=0;i<pages;i++){
        if(pages>15&&Math.abs(i-CP)>3&&i!==0&&i!==pages-1){
            if(i===1||i===pages-2)h+='<span class="pg-info">…</span>';
            continue;
        }
        h+='<button class="pg'+(i===CP?' a':'')+'" onclick="goPage('+i+')">'+(i+1)+'</button>';
    }
    h+='<button class="pg" onclick="goPage(CP+1)"'+(CP===pages-1?' disabled':'')+'>›</button>';
    h+='<span class="pg-info">'+(CP*PS+1)+'–'+Math.min((CP+1)*PS,total)+' из '+total+'</span>';
    pg.innerHTML=h;
}

function goPage(n){
    var pages=Math.ceil(filteredRows.length/PS);
    if(n<0||n>=pages)return;
    CP=n;
    renderRows();
}

function filterCh(){
    var g=document.getElementById('f-g').value;
    var s=document.getElementById('f-s').value.toLowerCase();
    filteredRows=[];
    for(var i=0;i<channels.length;i++){
        var ch=channels[i];
        var show=(!g||ch.g===g)&&(!s||ch.n.toLowerCase().indexOf(s)>=0);
        if(showFavOnly&&favorites.indexOf(i)<0)show=false;
        if(show){ch._idx=i;filteredRows.push(ch)}
    }
    CP=0;
    renderRows();
}

function toggleFavFilter(){
    showFavOnly=!showFavOnly;
    var btn=document.getElementById('fav-btn');
    btn.innerHTML=showFavOnly?'★ Избранное':'☆ Избранное';
    btn.className=showFavOnly?'b bsm bs':'b bsm bo';
    filterCh();
}

function toggleFav(idx){
    var x=new XMLHttpRequest();
    x.open('POST',API,true);
    x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            if(r.status==='ok'){
                if(r.fav){
                    if(favorites.indexOf(idx)<0)favorites.push(idx);
                }else{
                    var fi=favorites.indexOf(idx);
                    if(fi>=0)favorites.splice(fi,1);
                }
                filterCh();
            }
        }catch(e){}
    };
    x.send('action=toggle_favorite&idx='+idx);
}

function loadFavorites(){
    var x=new XMLHttpRequest();
    x.open('GET',API+'?action=get_favorites',true);
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            if(r.status==='ok'&&r.favorites){
                favorites=r.favorites;
            }
        }catch(e){}
    };
    x.send();
}

function saveSecurity(){
    var u=document.getElementById('sec-user').value;
    var p=document.getElementById('sec-pass').value;
    act('set_security','user='+encodeURIComponent(u)+'&pass='+encodeURIComponent(p));
}

function saveToken(){
    var t=document.getElementById('sec-token').value;
    act('set_token','token='+encodeURIComponent(t));
}

function checkUpdate(){
    var x=new XMLHttpRequest();
    x.open('GET',API+'?action=check_update',true);
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            var info=document.getElementById('up-info');
            if(info){
                info.textContent='Установлено: v'+r.current+', доступно: v'+(r.latest||'—');
                if(r.update)info.style.color='var(--success)';
            }
            if(r.status==='ok'){
                if(r.update)toast('Доступно обновление v'+r.latest+'!','ok');
                else toast('У вас последняя версия v'+r.current,'ok');
            }
        }catch(e){toast('Ошибка проверки','err')}
    };
    x.send();
}
function doUpdateKeep(){
    var info=document.getElementById('up-info');
    if(info)info.textContent='Проверка и обновление...';
    var x=new XMLHttpRequest();
    x.open('GET',API+'?action=check_update',true);
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            if(r.status==='ok'&&r.update){
                // Download then update
                var y=new XMLHttpRequest();
                y.open('GET',API+'?action=auto_update_keep',true);
                y.timeout=120000;
                y.onload=function(){
                    // Don't reload immediately - wait for server to come up
                    toast('Обновление запущено! Подождите 15 сек...','ok');
                    var retryCount=0;
                    var retryReload=function(){
                        retryCount++;
                        if(retryCount>15){location.reload();return}
                        var z=new XMLHttpRequest();
                        z.open('GET',API,true);z.timeout=3000;
                        z.onload=function(){location.reload()};
                        z.onerror=z.ontimeout=function(){setTimeout(retryReload,1000)};
                        z.send();
                    };
                    setTimeout(retryReload,10000);
                };
                y.onerror=y.ontimeout=function(){
                    toast('Запущено! Подождите...','ok');
                    setTimeout(function(){location.reload()},15000);
                };
                y.send();
            }else{
                toast('У вас последняя версия v'+(r.current||''),'ok');
                if(info)info.textContent='Установлено: v'+r.current+', доступно: '+(r.latest||'—')+' (нет обновлений)';
            }
        }catch(e){toast('Ошибка','err')}
    };
    x.onerror=function(){toast('Ошибка сети','err')};
    x.send();
}
function doUpdateClean(){
    if(!confirm('Сбросить все настройки к заводским? Сервер перезапустится.'))return;
    var x=new XMLHttpRequest();
    x.open('GET',API+'?action=factory_reset',true);
    x.timeout=120000;
    x.onload=function(){
        toast('Сброс запущен! Подождите 15 сек...','ok');
        setTimeout(function(){location.reload()},15000);
    };
    x.onerror=function(){toast('Запущено! Подождите...','ok');setTimeout(function(){location.reload()},15000)};
    x.ontimeout=function(){toast('Запущено! Подождите...','ok');setTimeout(function(){location.reload()},15000)};
    x.send();
}

function saveWhitelist(){
    var ips=document.getElementById('wl-ips').value.replace(/\n/g,'+');
    act('set_whitelist','ips='+encodeURIComponent(ips));
}

function mergePlaylists(){
    var urls=document.getElementById('merge-urls').value.trim().replace(/\n/g,'+');
    if(!urls){toast('Введите URL','err');return}
    act('merge_playlists','urls='+encodeURIComponent(urls),function(r){
        if(r.status==='ok')toast('Объединено! Каналов: '+(r.merged_channels||''),'ok');
        else toast(r.message||'Ошибка','err');
    });
}

function validatePlaylist(){
    var url=document.getElementById('validate-url').value;
    if(!url){toast('Введите URL','err');return}
    act('validate_playlist','url='+encodeURIComponent(url),function(r){
        if(r.status==='ok'&&!r.valid)toast('URL недоступен','err');
        else if(r.valid)toast('Доступен! Каналов: '+(r.channels||''),'ok');
        else toast(r.message||'Ошибка','err');
    });
}

function escHtml(s){
    if(!s)return'';
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function loadChannels(){
    var x=new XMLHttpRequest();
    x.open('GET','/channels.json',true);
    x.onload=function(){
        try{
            channels=JSON.parse(x.responseText);
            filterCh();
        }catch(e){
            document.getElementById('ch-tb').innerHTML='<tr><td colspan="7" class="loading">Ошибка загрузки каналов</td></tr>';
        }
    };
    x.onerror=function(){
        document.getElementById('ch-tb').innerHTML='<tr><td colspan="7" class="loading">Ошибка загрузки каналов</td></tr>';
    };
    x.send();
}

function loadEpgMap(){
    var x=new XMLHttpRequest();
    x.open('GET',API+'?action=get_epg',true);
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            if(r.status==='ok'&&r.rows){
                var now=new Date();
                var ns=now.getFullYear()+('0'+(now.getMonth()+1)).slice(-2)+('0'+now.getDate()).slice(-2)+('0'+now.getHours()).slice(-2)+('0'+now.getMinutes()).slice(-2)+('0'+now.getSeconds()).slice(-2);
                for(var i=0;i<r.rows.length;i++){
                    var row=r.rows[i];
                    var parts=row.t.split(':');
                    var h=parseInt(parts[0])||0,m=parseInt(parts[1])||0;
                    var progTime=('0'+h).slice(-2)+('0'+m).slice(-2);
                    var nextH=h;var nextM=m+60;if(nextM>=60){nextH++;nextM-=60}
                    var nextTime=('0'+(nextH%24)).slice(-2)+('0'+nextM).slice(-2);
                    if(progTime<=ns.slice(8)&&nextTime>=ns.slice(8)){
                        epgMap[row.c]=row.p;
                    }
                }
            }
        }catch(e){}
    };
    x.send();
}

(function(){
    var si=document.getElementById('s-pl');
    var se=document.getElementById('s-epg');
    if(si)si.value='$pi';
    if(se)se.value='$ei';
})();

loadEpgMap();
loadChannels();
loadFavorites();
</script>
</body>
</html>
HTMLEND
CGIEOF
    chmod +x /www/iptv/cgi-bin/admin.cgi
    sed -i "s/IPTV_MANAGER_VERSION=\"\$IPTV_MANAGER_VERSION\"/IPTV_MANAGER_VERSION=\"$IPTV_MANAGER_VERSION\"/" /www/iptv/cgi-bin/admin.cgi
    sed -i "s/IPTV_MANAGER_VERSION=\"3.16\"/IPTV_MANAGER_VERSION=\"$IPTV_MANAGER_VERSION\"/" /www/iptv/cgi-bin/admin.cgi

    # --- ECG прокси (стримит EPG из gz без распаковки в RAM) ---
    cat > /www/iptv/cgi-bin/epg.cgi << 'EPGEOF'
#!/bin/sh
EGZ="/tmp/iptv-epg.xml.gz"
if [ -f "$EGZ" ]; then
    printf 'Content-Type: text/xml; charset=utf-8\r\n\r\n'
    gunzip -c "$EGZ" 2>/dev/null
else
    printf 'Content-Type: text/xml\r\n\r\n'
    printf '<?xml version="1.0" encoding="UTF-8"?><tv></tv>'
fi
EPGEOF
    chmod +x /www/iptv/cgi-bin/epg.cgi

    # Ссылка /epg.xml → epg.cgi
    cat > /www/iptv/epg.xml << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
XMLEOF

    generate_server_html
}

generate_player() {
    cat > /www/iptv/player.html << 'PLAYEREOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>IPTV Player</title>
<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#f0f2f5;--panel:#fff;--border:#e0e0e0;--text:#1a1a2e;--text2:#666;--text3:#888;--accent:#1a73e8;--accent2:#1557b0;--hover:#f0f2f5;--active:#e8f0fe;--green:#1e8e3e;--red:#d93025}
[data-theme="dark"]{--bg:#0a0e1a;--panel:#1e293b;--border:#334155;--text:#e2e8f0;--text2:#94a3b8;--text3:#64748b;--accent:#3b82f6;--accent2:#2563eb;--hover:#334155;--active:#1e3a5f;--green:#22c55e;--red:#ef4444}
[data-theme="openwrt"]{--bg:#1a1b26;--panel:#24283b;--border:#3b4261;--text:#c0caf5;--text2:#9aa5ce;--text3:#565f89;--accent:#7aa2f7;--accent2:#6893db;--hover:#292e42;--active:#1f2335;--green:#9ece6a;--red:#f7768e}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;height:100vh;overflow:hidden}
#app{display:flex;height:100vh}
#main{flex:1;display:flex;flex-direction:column;min-width:0}
#topbar{display:flex;align-items:center;gap:8px;padding:8px 12px;background:var(--panel);border-bottom:1px solid var(--border)}
#topbar .now{font-size:13px;font-weight:600;color:var(--text2);margin-right:8px;max-width:250px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#topbar input{flex:1;padding:7px 12px;background:var(--bg);border:1px solid var(--border);border-radius:6px;color:var(--text);font-size:13px;min-width:120px}
#topbar input:focus{outline:none;border-color:var(--accent)}
#topbar button{padding:7px 14px;border:none;border-radius:6px;font-weight:600;cursor:pointer;font-size:13px;white-space:nowrap;transition:background .15s}
.btn-play{background:var(--accent);color:#fff}.btn-play:hover{background:var(--accent2)}
.btn-icon{background:var(--hover);color:var(--text2);padding:7px 10px;font-size:16px}.btn-icon:hover{background:var(--border);color:var(--text)}
#video-wrap{flex:1;display:flex;align-items:center;justify-content:center;background:var(--bg);position:relative;min-height:0;overflow:hidden}
video{max-width:100%;max-height:100%;background:var(--bg);display:block}
#epg-overlay{position:absolute;bottom:0;left:0;right:0;background:rgba(15,23,42,.92);padding:12px 16px;max-height:120px;overflow-y:auto;backdrop-filter:blur(8px);display:none}
#epg-overlay.show{display:block}
#epg-overlay .epg-now{font-size:13px;color:var(--green);font-weight:600;margin-bottom:4px}
#epg-overlay .epg-next{font-size:12px;color:var(--text3)}
#error{display:none;position:absolute;text-align:center;padding:40px}
#error h2{margin-bottom:8px;color:var(--red)}
#error p{color:var(--text3);font-size:14px}
#sidebar{width:340px;background:var(--panel);border-left:1px solid var(--border);display:flex;flex-direction:column;overflow:hidden}
#sb-head{padding:10px 14px;border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between}
#sb-head h3{font-size:14px;font-weight:600}
#sb-head .cnt{font-size:12px;color:var(--text3)}
#sb-tabs{display:flex;gap:4px;padding:6px 12px;border-bottom:1px solid var(--border)}
#sb-tabs button{flex:1;padding:5px;background:var(--hover);border:none;border-radius:5px;color:var(--text3);cursor:pointer;font-size:11px;font-weight:600;transition:all .15s}
#sb-tabs button.on{background:var(--accent);color:#fff}
.fav-star{color:#64748b;font-size:14px;cursor:pointer;flex-shrink:0;transition:color .15s}
.fav-star.on{color:#f59e0b}
.fav-star:hover{color:#fbbf24}
#sb-search{padding:6px 12px;border-bottom:1px solid var(--border)}
#sb-search input{width:100%;padding:7px 10px;background:var(--bg);border:1px solid var(--border);border-radius:5px;color:var(--text);font-size:12px}
#sb-search input:focus{outline:none;border-color:var(--accent)}
#sb-group{padding:4px 12px 6px;border-bottom:1px solid var(--border)}
#sb-group select{width:100%;padding:5px 8px;background:var(--bg);border:1px solid var(--border);border-radius:5px;color:var(--text);font-size:12px}
#sb-pl{padding:8px 12px;border-bottom:1px solid var(--border);display:none}
#sb-pl input{width:100%;padding:7px 10px;background:var(--bg);border:1px solid var(--border);border-radius:5px;color:var(--text);font-size:12px;margin-bottom:6px}
#sb-pl button{width:100%;padding:6px;background:var(--green);border:none;border-radius:5px;color:#fff;font-weight:600;cursor:pointer;font-size:12px}
#sb-hist{padding:8px 12px;border-bottom:1px solid var(--border);display:none}
#sb-hist .hist-item{display:flex;align-items:center;gap:8px;padding:6px 0;cursor:pointer;border-bottom:1px solid rgba(51,65,85,.3)}
#sb-hist .hist-item:hover{background:var(--hover);border-radius:4px}
#sb-hist .hist-item:last-child{border-bottom:none}
#sb-hist .hist-name{flex:1;font-size:12px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#sb-hist .hist-time{font-size:10px;color:var(--text3)}
#sleep-badge{position:absolute;top:8px;left:8px;background:rgba(239,68,68,.85);color:#fff;padding:3px 8px;border-radius:4px;font-size:11px;font-weight:600;display:none;z-index:10}
#sleep-badge.show{display:block}
#ch-list{flex:1;overflow-y:auto}
.ch{display:flex;align-items:center;gap:8px;padding:7px 12px;cursor:pointer;border-bottom:1px solid rgba(51,65,85,.4);transition:background .12s}
.ch:hover{background:var(--hover)}
.ch.on{background:var(--active);border-left:3px solid var(--accent)}
.ch-logo{width:32px;height:32px;border-radius:5px;overflow:hidden;flex-shrink:0;background:var(--bg);display:flex;align-items:center;justify-content:center}
.ch-logo img{width:100%;height:100%;object-fit:contain}
.ch-logo .ph{font-size:16px}
.ch-info{flex:1;min-width:0}
.ch-name{font-size:13px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ch-meta{font-size:11px;color:var(--text3);margin-top:1px}
.ch-now{font-size:11px;color:var(--green);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#loading{padding:30px;text-align:center;color:var(--text3)}
#empty{padding:30px;text-align:center;color:var(--text3);font-size:13px}
#toggle-sb{display:none;padding:6px 10px;background:var(--hover);border:none;border-radius:5px;color:var(--text);cursor:pointer;font-size:16px}
@media(max-width:800px){
    #sidebar{position:fixed;right:-340px;top:0;bottom:0;z-index:100;transition:right .25s}
    #sidebar.open{right:0}
    #toggle-sb{display:block}
}
</style>
</head>
<body>
<div id="app">
<div id="main">
<div id="topbar">
<button id="toggle-sb" onclick="toggleSb()">☰</button>
<span class="now" id="now-ch"></span>
<input type="text" id="url-in" placeholder="Поток или URL плейлиста...">
<button class="btn-play" onclick="handleUrl()">▶</button>
<button class="btn-icon" onclick="togglePip()" title="Картинка в картинке">⧉</button>
<button class="btn-icon" onclick="toggleTheme()" id="ttb" title="Тема">🌙</button>
<button class="btn-icon" onclick="toggleFs()" title="Полный экран">⛶</button>
</div>
<div id="video-wrap">
<video id="vid" controls autoplay playsinline></video>
<div id="epg-overlay">
<div class="epg-now" id="epg-now"></div>
<div class="epg-next" id="epg-next"></div>
</div>
<div id="error">
<h2 id="err-title">Ошибка</h2>
<p id="err-text"></p>
</div>
</div>
</div>
<div id="sidebar">
<div id="sb-head">
<h3>📺 Каналы</h3>
<span class="cnt" id="ch-cnt"></span>
</div>
<div id="sb-tabs">
<button class="on" onclick="tab('ch',this)">Каналы</button>
<button onclick="tab('fav',this)">★ Избранное</button>
<button onclick="tab('pl',this)">Плейлист</button>
</div>
<div id="sb-search">
<input type="text" id="sb-q" placeholder="Поиск..." oninput="filter()">
</div>
<div id="sb-group">
<select id="sb-g" onchange="filter()"><option value="">Все группы</option></select>
</div>
<div id="sb-pl">
<input type="text" id="pl-url" placeholder="URL M3U/M3U8 плейлиста...">
<button onclick="loadPl()">Загрузить плейлист</button>
</div>
<div id="ch-list"><div id="loading">Загрузка...</div></div>
</div>
</div>
<script>
var vid=document.getElementById('vid');
var urlIn=document.getElementById('url-in');
var nowCh=document.getElementById('now-ch');
var errDiv=document.getElementById('error');
var errText=document.getElementById('err-text');
var epgOv=document.getElementById('epg-overlay');
var epgNow=document.getElementById('epg-now');
var epgNext=document.getElementById('epg-next');
var chList=document.getElementById('ch-list');
var hls=null,channels=[],filtered=[],curIdx=-1,epgData={},curMode='ch',favorites=[];

function play(url,idx){
    if(!url)return;
    urlIn.value=url;
    errDiv.style.display='none';
    epgOv.classList.remove('show');
    if(hls){hls.destroy();hls=null}
    if(Hls.isSupported()){
        hls=new Hls({enableWorker:true,lowLatencyMode:true,maxBufferLength:30,maxMaxBufferLength:60});
        hls.loadSource(url);
        hls.attachMedia(vid);
        hls.on(Hls.Events.MANIFEST_PARSED,function(){vid.play().catch(function(){})});
        hls.on(Hls.Events.ERROR,function(e,d){
            if(d.fatal){
                if(d.type===Hls.ErrorTypes.NETWORK_ERROR){
                    errText.textContent='Ошибка сети. Поток недоступен.';
                }else if(d.type===Hls.ErrorTypes.MEDIA_ERROR){
                    hls.recoverMediaError();return;
                }else{
                    errText.textContent='Неподдерживаемый формат.';
                }
                errDiv.style.display='block';
            }
        });
    }else if(vid.canPlayType('application/vnd.apple.mpegurl')){
        vid.src=url;
        vid.addEventListener('loadedmetadata',function(){vid.play().catch(function(){})});
    }else{
        errText.textContent='Браузер не поддерживает HLS.';
        errDiv.style.display='block';
    }
    if(idx!==undefined&&idx!==null){
        curIdx=idx;
        var ch=channels[idx];
        if(ch){
            nowCh.textContent=ch.n;
            showEpg(ch.i);
        }
        document.querySelectorAll('.ch').forEach(function(el,i){
            el.classList.toggle('on',i===fIdx(idx));
        });
    }
}

function handleUrl(){
    var u=urlIn.value.trim();
    if(!u)return;
    if(u.indexOf('.m3u')>=0||u.indexOf('playlist')>=0){
        loadPlUrl(u);
    }else{
        play(u);
    }
}

function fIdx(ri){
    for(var i=0;i<filtered.length;i++){if(filtered[i]._r===ri)return i}
    return -1;
}

function render(){
    if(!filtered.length){chList.innerHTML='<div id="empty">Нет каналов</div>';return}
    var h='';
    for(var i=0;i<filtered.length;i++){
        var ch=filtered[i];
        var lh=ch.l?'<img src="'+esc(ch.l)+'" onerror="this.parentElement.innerHTML=\'📺\'">':'<span class="ph">📺</span>';
        var now=ch.i&&epgData[ch.i]?'<div class="ch-now">📡 '+esc(epgData[ch.i])+'</div>':'';
        var isFav=favorites.indexOf(ch._r)>=0;
        h+='<div class="ch'+(ch._r===curIdx?' on':'')+'" onclick="play(\''+esc(ch.u).replace(/'/g,"\\'")+'\','+ch._r+')">';
        h+='<span class="fav-star'+(isFav?' on':'')+'" onclick="event.stopPropagation();toggleFav('+ch._r+')">'+(isFav?'★':'☆')+'</span>';
        h+='<div class="ch-logo">'+lh+'</div>';
        h+='<div class="ch-info"><div class="ch-name">'+esc(ch.n)+'</div>';
        h+='<div class="ch-meta">'+esc(ch.g)+'</div>'+now+'</div></div>';
    }
    chList.innerHTML=h;
}

function filter(){
    var q=document.getElementById('sb-q').value.toLowerCase();
    var g=document.getElementById('sb-g').value;
    filtered=[];
    for(var i=0;i<channels.length;i++){
        var ch=channels[i];
        var matchGroup=!g||ch.g===g;
        var matchQuery=!q||ch.n.toLowerCase().indexOf(q)>=0;
        var matchFav=curMode!=='fav'||favorites.indexOf(i)>=0;
        if(matchGroup&&matchQuery&&matchFav){
            ch._r=i;filtered.push(ch);
        }
    }
    document.getElementById('ch-cnt').textContent=filtered.length+'/'+channels.length;
    render();
}

function esc(s){if(!s)return'';return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}

function toggleSb(){document.getElementById('sidebar').classList.toggle('open')}

function tab(m,btn){
    curMode=m;
    document.querySelectorAll('#sb-tabs button').forEach(function(b){b.classList.remove('on')});
    btn.classList.add('on');
    document.getElementById('sb-search').style.display=(m==='ch'||m==='fav')?'':'none';
    document.getElementById('sb-group').style.display=(m==='ch'||m==='fav')?'':'none';
    document.getElementById('sb-pl').style.display=m==='pl'?'':'none';
    if(m==='ch'||m==='fav')filter();
}

function parseM3U(text){
    var lines=text.split('\n');
    var r=[],name='',group='',logo='',tvgid='';
    for(var i=0;i<lines.length;i++){
        var l=lines[i].replace(/^\s+|\s+$/g,'');
        if(l.indexOf('#EXTINF:')===0){
            name='';group='';logo='';tvgid='';
            var ci=l.indexOf(',');
            if(ci>=0)name=l.substring(ci+1).replace(/^\s+/,'');
            var m;
            m=l.match(/group-title="([^"]*)"/);if(m)group=m[1];
            m=l.match(/tvg-logo="([^"]*)"/);if(m)logo=m[1];
            m=l.match(/tvg-id="([^"]*)"/);if(m)tvgid=m[1];
            if(!name)name='Неизвестный';
            if(!group)group='Общее';
        }else if(/^(https?|rtsp|rtmp|udp|rtp):/i.test(l)){
            r.push({n:name,g:group,l:logo,i:tvgid,u:l});
            name='';group='';logo='';tvgid='';
        }
    }
    return r;
}

function loadPlUrl(url){
    chList.innerHTML='<div id="loading">Загрузка плейлиста...</div>';
    var x=new XMLHttpRequest();
    x.open('GET',url,true);
    x.onload=function(){
        try{
            channels=parseM3U(x.responseText);
            fillGroups();filter();
            document.getElementById('pl-url').value=url;
            tab('ch',document.querySelectorAll('#sb-tabs button')[0]);
        }catch(e){chList.innerHTML='<div id="empty">Ошибка парсинга</div>'}
    };
    x.onerror=function(){chList.innerHTML='<div id="empty">Не удалось загрузить</div>'};
    x.send();
}

function loadPl(){
    var u=document.getElementById('pl-url').value.trim();
    if(!u){alert('Введите URL');return}
    loadPlUrl(u);
}

function fillGroups(){
    var g={};
    for(var i=0;i<channels.length;i++){if(channels[i].g&&!g[channels[i].g])g[channels[i].g]=true}
    var s=document.getElementById('sb-g');
    s.innerHTML='<option value="">Все группы</option>';
    var k=Object.keys(g).sort();
    for(var j=0;j<k.length;j++){var o=document.createElement('option');o.value=k[j];o.textContent=k[j];s.appendChild(o)}
}

function loadChannels(){
    var x=new XMLHttpRequest();
    x.open('GET',window.location.origin+'/channels.json',true);
    x.onload=function(){
        try{
            channels=JSON.parse(x.responseText);
            fillGroups();filter();
        }catch(e){chList.innerHTML='<div id="empty">Ошибка загрузки</div>'}
    };
    x.onerror=function(){chList.innerHTML='<div id="empty">Ошибка загрузки</div>'};
    x.send();
}

function loadEpg(){
    var x=new XMLHttpRequest();
    x.open('GET',window.location.origin+'/epg.xml',true);
    x.onload=function(){
        try{
            var xml=x.responseXML;
            if(!xml)return;
            var now=new Date();
            var ns=now.getFullYear()+p2(now.getMonth()+1)+p2(now.getDate())+p2(now.getHours())+p2(now.getMinutes())+p2(now.getSeconds());
            var progs=xml.getElementsByTagName('programme');
            for(var i=0;i<progs.length;i++){
                var p=progs[i];
                var st=p.getAttribute('start'),sp=p.getAttribute('stop'),ch=p.getAttribute('channel');
                var te=p.getElementsByTagName('title')[0];
                var ti=te?te.textContent:'';
                if(st&&sp&&st<=ns&&sp>=ns&&ch&&ti)epgData[ch]=ti;
            }
            render();
        }catch(e){}
    };
    x.send();
}

function p2(n){return n<10?'0'+n:''+n}

function showEpg(id){
    if(!id||!epgData[id]){epgOv.classList.remove('show');return}
    epgNow.textContent='📡 '+epgData[id];
    epgOv.classList.add('show');
    setTimeout(function(){epgOv.classList.remove('show')},5000);
}

function toggleFs(){
    if(document.fullscreenElement)document.exitFullscreen();
    else document.documentElement.requestFullscreen().catch(function(){});
}

function togglePip(){
    if(!document.pictureInPictureElement){
        if(vid.requestPictureInPicture){
            vid.requestPictureInPicture().catch(function(e){
                alert('PiP не поддерживается: '+e.message);
            });
        }else{
            alert('Ваш браузер не поддерживает PiP');
        }
    }else{
        document.exitPictureInPicture();
    }
}

function toggleFav(idx){
    var fi=favorites.indexOf(idx);
    if(fi>=0){
        favorites.splice(fi,1);
    }else{
        favorites.push(idx);
    }
    try{localStorage.setItem('iptv-favorites',JSON.stringify(favorites))}catch(e){}
    render();
}

function loadFavorites(){
    try{
        var s=localStorage.getItem('iptv-favorites');
        if(s)favorites=JSON.parse(s);
    }catch(e){}
}
function toggleTheme(){
    var d=document.documentElement,c=d.getAttribute('data-theme')||'dark';
    var n=c==='light'?'dark':c==='dark'?'openwrt':'light';
    d.setAttribute('data-theme',n);
    var b=document.getElementById('ttb');
    if(b)b.textContent=n==='light'?'☀️':n==='dark'?'🌙':'🟣';
    try{localStorage.setItem('iptv-theme',n)}catch(e){}
}
(function(){
    try{
        var t=localStorage.getItem('iptv-theme')||'dark';
        if(t==='light'||t==='dark'||t==='openwrt'){
            document.documentElement.setAttribute('data-theme',t);
        }else{
            document.documentElement.setAttribute('data-theme','dark');
        }
        var b=document.getElementById('ttb');
        if(b){
            var tt=document.documentElement.getAttribute('data-theme');
            b.textContent=tt==='light'?'☀️':tt==='dark'?'🌙':'🟣';
        }
    }catch(e){}
})();

var params=new URLSearchParams(window.location.search);
var sUrl=params.get('url'),sIdx=params.get('idx'),pUrl=params.get('pl');
loadFavorites();
if(pUrl){loadPlUrl(pUrl)}
else if(sUrl){play(sUrl,sIdx!==null?parseInt(sIdx):-1);loadChannels()}
else{loadChannels()}
loadEpg();

document.addEventListener('keydown',function(e){
    if(e.target.tagName==='INPUT')return;
    if(e.key==='ArrowUp'||e.key==='ArrowDown'){
        e.preventDefault();
        var d=e.key==='ArrowDown'?1:-1,ni=curIdx+d;
        if(ni>=0&&ni<channels.length){
            play(channels[ni].u,ni);
            var fi=fIdx(ni);
            if(fi>=0){var items=document.querySelectorAll('.ch');if(items[fi])items[fi].scrollIntoView({block:'nearest'})}
        }
    }
    if(e.key===' '){e.preventDefault();vid.paused?vid.play():vid.pause()}
    if(e.key==='f'||e.key==='F'||e.key==='а'||e.key==='А')toggleFs();
});

urlIn.addEventListener('keydown',function(e){if(e.key==='Enter')handleUrl()});
</script>
</body>
</html>
PLAYEREOF
}

# ==========================================
# Планировщик
# ==========================================
start_scheduler() {
    stop_scheduler
    cat > /tmp/iptv-scheduler.sh <<'SCEOF'
#!/bin/sh
D=/etc/iptv
echo $$ > /var/run/iptv-scheduler.pid
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
                url) wget -q --timeout=15 --no-check-certificate -O "$D/playlist.m3u" "$PLAYLIST_URL" 2>/dev/null ;;
                file) [ -f "$PLAYLIST_SOURCE" ] && cp "$PLAYLIST_SOURCE" "$D/playlist.m3u" ;;
            esac
            NT=$(date '+%d.%m.%Y %H:%M')
            printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$NT" "$EPG_LAST_UPDATE" > "$D/schedule.conf"
            [ -f "$D/playlist.m3u" ] && cp "$D/playlist.m3u" /www/iptv/playlist.m3u
        }
    fi
    if [ "${EPG_INTERVAL:-0}" -gt 0 ] 2>/dev/null; then
        L=$(date -d "$EPG_LAST_UPDATE" +%s 2>/dev/null || echo 0)
        [ "$(( (N-L)/3600 ))" -ge "$EPG_INTERVAL" ] && {
            . "$D/epg.conf" 2>/dev/null
            [ -n "$EPG_URL" ] && wget -q --timeout=30 --no-check-certificate -O "$D/epg-dl.tmp" "$EPG_URL" 2>/dev/null && [ -s "$D/epg-dl.tmp" ] && {
                M=$(hexdump -n 2 -e '2/1 "%02x"' "$D/epg-dl.tmp" 2>/dev/null)
                if [ "$M" = "1f8b" ]; then
                    cp "$D/epg-dl.tmp" /tmp/iptv-epg.xml.gz
                else
                    gzip -c "$D/epg-dl.tmp" > /tmp/iptv-epg.xml.gz 2>/dev/null
                fi
                NT=$(date '+%d.%m.%Y %H:%M')
                printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$NT" > "$D/schedule.conf"
                rm -f "$D/epg-dl.tmp"
            }
        }
    fi
done
SCEOF
    chmod +x /tmp/iptv-scheduler.sh
    /bin/sh /tmp/iptv-scheduler.sh &
    echo_success "Планировщик запущен"
}
stop_scheduler() { kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null; rm -f /var/run/iptv-scheduler.pid /tmp/iptv-scheduler.sh; }

# ==========================================
# HTTP-сервер
# ==========================================
start_http_server() {
    mkdir -p /www/iptv/cgi-bin
    cp "$IPTV_DIR/server.html" /www/iptv/server.html 2>/dev/null || true
    [ -f "$PLAYLIST_FILE" ] && cp "$PLAYLIST_FILE" /www/iptv/playlist.m3u || echo "#EXTM3U" > /www/iptv/playlist.m3u
    generate_cgi
    generate_player 2>/dev/null
    generate_srv_cgi
    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then
        echo_success "Сервер обновлён: http://$LAN_IP:$IPTV_PORT/"
        return
    fi
    kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null
    sleep 1
    # Record server start time for uptime tracking
    date +%s > "$STARTUP_TIME"
    uhttpd -f -p "0.0.0.0:$IPTV_PORT" -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" &
    echo $! > "$HTTPD_PID"
    date +%s > /tmp/iptv-started
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
# SSH-действия
# ==========================================
load_playlist_url() {
    echo_color "Загрузка плейлиста"
    echo -ne "${YELLOW}URL: ${NC}"
    read PLAYLIST_URL </dev/tty
    [ -z "$PLAYLIST_URL" ] && { echo_error "URL пуст!"; PAUSE; return 1; }
    echo_info "Скачиваем..."
    if wget $(wget_opt) -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null && [ -s "$PLAYLIST_FILE" ]; then
        local ch=$(get_ch)
        echo_success "Загружен! Каналов: $ch"
        save_config "url" "$PLAYLIST_URL" ""
        local now=$(get_ts)
        load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
        start_http_server
    else
        echo_error "Не удалось скачать!"
        PAUSE
        return 1
    fi
}

load_playlist_file() {
    echo_color "Загрузка из файла"
    echo -ne "${YELLOW}Путь: ${NC}"
    read FP </dev/tty
    [ -z "$FP" ] && { echo_error "Путь пуст!"; PAUSE; return 1; }
    [ ! -f "$FP" ] && { echo_error "Файл не найден: $FP"; PAUSE; return 1; }
    cp "$FP" "$PLAYLIST_FILE"
    local ch=$(get_ch)
    echo_success "Загружен! Каналов: $ch"
    save_config "file" "" "$FP"
    local now=$(get_ts)
    load_sched
    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
    start_http_server
}

setup_provider() {
    echo_color "Настройка провайдера"
    echo -ne "${YELLOW}Название: ${NC}"
    read PN </dev/tty
    echo -ne "${YELLOW}Логин: ${NC}"
    read PL2 </dev/tty
    echo -ne "${YELLOW}Пароль: ${NC}"
    stty -echo
    read PP </dev/tty
    stty echo
    echo ""
    [ -z "$PN" ] || [ -z "$PL2" ] || [ -z "$PP" ] && { echo_error "Все поля обязательны!"; PAUSE; return 1; }
    printf 'PROVIDER_NAME=%s\nPROVIDER_LOGIN=%s\nPROVIDER_PASS=%s\nPROVIDER_SERVER=http://%s\n' "$PN" "$PL2" "$PP" "$PN" > "$PROVIDER_CONFIG"
    local pu="http://$PN/get.php?username=$PL2&password=$PP&type=m3u_plus&output=ts"
    echo_info "Получаем плейлист..."
    if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$pu" 2>/dev/null && [ -s "$PLAYLIST_FILE" ]; then
        local ch=$(get_ch)
        echo_success "Загружен! Провайдер: $PN, Каналов: $ch"
        save_config "provider" "$pu" "$PN"
        local now=$(get_ts)
        load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
        start_http_server
    else
        echo_error "Ошибка!"
        PAUSE
        return 1
    fi
}

do_update_playlist() {
    load_config
    case "$PLAYLIST_TYPE" in
        url)
            wget $(wget_opt) -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null && {
                local ch=$(get_ch)
                local now=$(get_ts)
                load_sched
                save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                echo_success "Обновлён! Каналов: $ch"
            } || echo_error "Ошибка!" ;;
        provider)
            [ -f "$PROVIDER_CONFIG" ] && {
                . "$PROVIDER_CONFIG"
                local pu="http://${PROVIDER_SERVER:-$PROVIDER_NAME}/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"
                wget -q --timeout=15 -O "$PLAYLIST_FILE" "$pu" 2>/dev/null && {
                    local ch=$(get_ch)
                    local now=$(get_ts)
                    load_sched
                    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                    echo_success "Обновлён! Каналов: $ch"
                } || echo_error "Ошибка!"
            } ;;
    esac
}

setup_epg() {
    echo_color "Настройка EPG"
    load_epg
    [ -n "$EPG_URL" ] && echo_info "Текущий EPG: $EPG_URL"
    local builtin=$(detect_builtin_epg)
    if [ -n "$builtin" ]; then
        echo -e "${CYAN}В плейлисте найден встроенный EPG:${NC} $builtin"
        echo -e "${YELLOW}1) ${GREEN}Скачать встроенный EPG${NC}"
        echo -e "${YELLOW}2) ${GREEN}Указать свою ссылку${NC}"
        echo -e "${YELLOW}Enter) ${GREEN}Пропустить${NC}"
        echo -ne "${YELLOW}> ${NC}"
        read choice </dev/tty
        case "$choice" in
            1)
                echo_info "Скачиваем $builtin ..."
                if _dl_epg "$builtin"; then
                    local sz=$(file_size "$EPG_GZ")
                    echo_success "Загружен! Размер: $sz"
                    printf 'EPG_URL="%s"\n' "$builtin" > "$EPG_CONFIG"
                    local now=$(get_ts)
                    load_sched
                    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
                    start_http_server
                else
                    echo_error "Не удалось скачать!"
                    PAUSE
                    return 1
                fi ;;
            2)
                echo -ne "${YELLOW}EPG URL: ${NC}"
                read EPG_URL </dev/tty
                [ -z "$EPG_URL" ] && { echo_info "Отмена"; return 1; }
                echo_info "Скачиваем..."
                if _dl_epg "$EPG_URL"; then
                    local sz=$(file_size "$EPG_GZ")
                    echo_success "Загружен! Размер: $sz"
                    printf 'EPG_URL="%s"\n' "$EPG_URL" > "$EPG_CONFIG"
                    local now=$(get_ts)
                    load_sched
                    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
                    start_http_server
                else
                    echo_error "Не удалось скачать!"
                    PAUSE
                    return 1
                fi ;;
            *) echo_info "Пропущено"; return 1 ;;
        esac
    else
        echo -ne "${YELLOW}EPG URL: ${NC}"
        read EPG_URL </dev/tty
        [ -z "$EPG_URL" ] && { echo_info "Отмена"; return 1; }
        echo_info "Скачиваем..."
        if _dl_epg "$EPG_URL"; then
            local sz=$(file_size "$EPG_GZ")
            echo_success "Загружен! Размер: $sz"
            printf 'EPG_URL="%s"\n' "$EPG_URL" > "$EPG_CONFIG"
            local now=$(get_ts)
            load_sched
            save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
            start_http_server
        else
            echo_error "Не удалось скачать!"
            PAUSE
            return 1
        fi
    fi
}

do_update_epg() {
    load_epg
    [ -z "$EPG_URL" ] && { echo_error "EPG не настроен!"; return 1; }
    if _dl_epg "$EPG_URL"; then
        local sz=$(file_size "$EPG_GZ")
        local now=$(get_ts)
        load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
        echo_success "Обновлён! Размер: $sz"
    else
        echo_error "Ошибка!"
        return 1
    fi
}

remove_epg() { rm -f "$EPG_GZ" "$EPG_CONFIG"; echo_success "EPG удалён"; }

setup_schedule() {
    load_sched
    echo_color "Расписание"
    echo_info "Плейлист: $(int_text $PLAYLIST_INTERVAL) | EPG: $(int_text $EPG_INTERVAL)"
    echo -e "  ${CYAN}0) Выкл  1) Каждый час  2) Каждые 6ч  3) Каждые 12ч  4) Раз в сутки${NC}"
    echo -ne "${YELLOW}Плейлист (0-4): ${NC}"
    read pi </dev/tty
    case "$pi" in 0|1) PLAYLIST_INTERVAL=$pi ;; 2) PLAYLIST_INTERVAL=6 ;; 3) PLAYLIST_INTERVAL=12 ;; 4) PLAYLIST_INTERVAL=24 ;; *) PLAYLIST_INTERVAL=0 ;; esac
    echo -ne "${YELLOW}EPG (0-4): ${NC}"
    read ei </dev/tty
    case "$ei" in 0|1) EPG_INTERVAL=$ei ;; 2) EPG_INTERVAL=6 ;; 3) EPG_INTERVAL=12 ;; 4) EPG_INTERVAL=24 ;; *) EPG_INTERVAL=0 ;; esac
    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$EPG_LAST_UPDATE"
    if [ "$PLAYLIST_INTERVAL" -gt 0 ] || [ "$EPG_INTERVAL" -gt 0 ]; then
        start_scheduler
        echo_success "Планировщик запущен"
    else
        stop_scheduler
        echo_success "Расписание отключено"
    fi
}

remove_playlist() { rm -f "$PLAYLIST_FILE" "$CONFIG_FILE" "$PROVIDER_CONFIG"; stop_http_server; echo_success "Удалено"; }

setup_autostart() {
    if [ -f /etc/init.d/iptv-manager ]; then
        /etc/init.d/iptv-manager disable 2>/dev/null
        rm -f /etc/init.d/iptv-manager
        echo_success "Автозапуск отключён"
    else
        cat > /etc/init.d/iptv-manager << 'INITEOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
    mkdir -p /www/iptv/cgi-bin
    [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u 2>/dev/null
    [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml 2>/dev/null
    # Generate CGI if script exists
    if [ -f /etc/iptv/IPTV-Manager.sh ]; then
        /etc/iptv/IPTV-Manager.sh --server 2>/dev/null
    fi
    procd_open_instance
    procd_set_param command uhttpd -f -p 0.0.0.0:8082 -h /www/iptv -x /www/iptv/cgi-bin -i '.cgi=/bin/sh'
    procd_set_param pidfile /var/run/iptv-httpd.pid
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
    [ -f /etc/iptv/schedule.conf ] && { . /etc/iptv/schedule.conf; [ "${PLAYLIST_INTERVAL:-0}" -gt 0 ] || [ "${EPG_INTERVAL:-0}" -gt 0 ] && /bin/sh /tmp/iptv-scheduler.sh &; }
}
INITEOF
        chmod +x /etc/init.d/iptv-manager
        /etc/init.d/iptv-manager enable 2>/dev/null
        echo_success "Автозапуск включён"
    fi
}

uninstall() {
    echo_color "Полное удаление IPTV Manager"
    echo -ne "${YELLOW}Вы уверены? Абсолютно всё будет удалено! (y/N): ${NC}"
    read ans </dev/tty
    case "$ans" in y|Y|yes|Yes) ;; *) echo_info "Отмена"; return 1 ;; esac
    echo_info "Останавливаем сервисы..."
    stop_http_server
    stop_scheduler
    echo_info "Удаляем все файлы..."
    rm -rf /etc/iptv /www/iptv
    rm -f /var/run/iptv-httpd.pid /var/run/iptv-scheduler.pid
    rm -f /tmp/iptv-scheduler.sh /tmp/iptv-edit.m3u /tmp/iptv-group-opts.txt
    rm -f /tmp/iptv-epg.xml.gz /tmp/iptv-epg-dl.xml
    rm -f /var/run/iptv-ratelimit /tmp/iptv-merged.m3u
    rm -f /etc/iptv/ip_whitelist.txt
    rm -rf /www/cgi-bin/srv.cgi /www/cgi-bin/srv.html
    [ -f /etc/init.d/iptv-manager ] && { /etc/init.d/iptv-manager disable 2>/dev/null; rm -f /etc/init.d/iptv-manager; }
    echo_info "Удаляем LuCI-плагин..."
    rm -rf /www/luci-static/resources/view/iptv-manager
    rm -f /usr/share/luci/menu.d/luci-app-iptv-manager.json
    rm -f /usr/share/rpcd/acl.d/luci-app-iptv-manager.json
    rm -f /etc/uci-defaults/99-luci-iptv-manager
    rm -f /etc/config/iptv
    rm -rf /usr/lib/lua/luci/controller/iptv-manager*
    rm -rf /usr/lib/lua/luci/model/cbi/iptv-manager*
    rm -rf /usr/lib/lua/luci/view/iptv-manager*
    /etc/init.d/rpcd restart 2>/dev/null
    echo_success "IPTV Manager полностью удалён"
    echo_info "Для выхода введите Enter"
}

first_setup() {
    echo_color "Первоначальная настройка"
    echo_info "Пошаговый мастер настроит IPTV Manager на вашем роутере"
    echo ""

    echo -e "${YELLOW}── Шаг 1/5: Установка файлов ─────────────────${NC}"
    echo_info "Создаём необходимые файлы и директории..."
    mkdir -p /etc/iptv /www/iptv/cgi-bin
    [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"
    [ -f "$EPG_CONFIG" ] || touch "$EPG_CONFIG"
    [ -f "$SCHEDULE_FILE" ] || touch "$SCHEDULE_FILE"
    [ -f "$FAVORITES_FILE" ] || echo "[]" > "$FAVORITES_FILE"
    [ -f "$SECURITY_FILE" ] || printf 'ADMIN_USER=""\nADMIN_PASS=""\nAPI_TOKEN=""\n' > "$SECURITY_FILE"
    echo_success "Файлы созданы"
    echo ""

    echo -e "${YELLOW}── Шаг 2/5: Плейлист ─────────────────────────${NC}"
    echo_info "Выберите источник плейлиста:"
    echo -e "  ${CYAN}1) Загрузить по ссылке${NC}"
    echo -e "  ${CYAN}2) Загрузить из файла${NC}"
    echo -e "  ${CYAN}3) Настроить провайдера${NC}"
    echo -e "  ${CYAN}4) Пропустить (настрою позже в админке)${NC}"
    echo -ne "${YELLOW}> ${NC}"
    read pl_choice </dev/tty
    case "$pl_choice" in
        1)
            echo -ne "${YELLOW}URL плейлиста: ${NC}"
            read PLAYLIST_URL </dev/tty
            if [ -n "$PLAYLIST_URL" ]; then
                echo_info "Скачиваем..."
                if wget $(wget_opt) -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null && [ -s "$PLAYLIST_FILE" ]; then
                    local ch=$(get_ch)
                    echo_success "Загружен! Каналов: $ch"
                    save_config "url" "$PLAYLIST_URL" ""
                    local now=$(get_ts)
                    save_sched "0" "0" "$now" ""
                else
                    echo_error "Не удалось скачать! Настроите позже в админке."
                    touch "$PLAYLIST_FILE"
                fi
            else
                echo_info "Пропущено"
                touch "$PLAYLIST_FILE"
            fi ;;
        2)
            echo -ne "${YELLOW}Путь к файлу: ${NC}"
            read FP </dev/tty
            if [ -n "$FP" ] && [ -f "$FP" ]; then
                cp "$FP" "$PLAYLIST_FILE"
                local ch=$(get_ch)
                echo_success "Загружен! Каналов: $ch"
                save_config "file" "" "$FP"
                local now=$(get_ts)
                save_sched "0" "0" "$now" ""
            else
                echo_info "Пропущено"
                touch "$PLAYLIST_FILE"
            fi ;;
        3)
            echo -ne "${YELLOW}Название провайдера: ${NC}"
            read PN </dev/tty
            echo -ne "${YELLOW}Сервер (домен или IP): ${NC}"
            read PSRV </dev/tty
            echo -ne "${YELLOW}Логин: ${NC}"
            read PL2 </dev/tty
            echo -ne "${YELLOW}Пароль: ${NC}"
            stty -echo
            read PP </dev/tty
            stty echo
            echo ""
            if [ -n "$PN" ] && [ -n "$PL2" ] && [ -n "$PP" ]; then
                [ -z "$PSRV" ] && PSRV="$PN"
                local pu="http://$PSRV/get.php?username=$PL2&password=$PP&type=m3u_plus&output=ts"
                echo_info "Получаем плейлист..."
                if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$pu" 2>/dev/null && [ -s "$PLAYLIST_FILE" ]; then
                    local ch=$(get_ch)
                    echo_success "Загружен! Каналов: $ch"
                    save_config "provider" "$pu" "$PN"
                    printf 'PROVIDER_NAME=%s\nPROVIDER_LOGIN=%s\nPROVIDER_PASS=%s\nPROVIDER_SERVER=%s\n' "$PN" "$PL2" "$PP" "$PSRV" > "$PROVIDER_CONFIG"
                    local now=$(get_ts)
                    save_sched "0" "0" "$now" ""
                else
                    echo_error "Не удалось получить! Настроите позже в админке."
                    touch "$PLAYLIST_FILE"
                fi
            else
                echo_info "Пропущено"
                touch "$PLAYLIST_FILE"
            fi ;;
        *)
            echo_info "Пропущено"
            touch "$PLAYLIST_FILE" ;;
    esac
    echo ""

    echo -e "${YELLOW}── Шаг 3/5: Телепрограмма (EPG) ──────────────${NC}"
    local builtin=$(detect_builtin_epg)
    if [ -n "$builtin" ]; then
        echo_info "В плейлисте найден встроенный EPG: $builtin"
        echo -e "  ${CYAN}1) Скачать встроенный EPG${NC}"
        echo -e "  ${CYAN}2) Указать свою ссылку${NC}"
        echo -e "  ${CYAN}3) Пропустить${NC}"
        echo -ne "${YELLOW}> ${NC}"
        read epg_choice </dev/tty
        case "$epg_choice" in
            1)
                echo_info "Скачиваем..."
                if _dl_epg "$builtin"; then
                    echo_success "EPG загружен! Размер: $(file_size "$EPG_GZ")"
                    printf 'EPG_URL="%s"\n' "$builtin" > "$EPG_CONFIG"
                else
                    echo_info "Не удалось скачать"
                fi ;;
            2)
                echo -ne "${YELLOW}EPG URL: ${NC}"
                read EPG_URL </dev/tty
                if [ -n "$EPG_URL" ]; then
                    echo_info "Скачиваем..."
                    if _dl_epg "$EPG_URL"; then
                        echo_success "EPG загружен! Размер: $(file_size "$EPG_GZ")"
                        printf 'EPG_URL="%s"\n' "$EPG_URL" > "$EPG_CONFIG"
                    else
                        echo_info "Не удалось скачать"
                    fi
                fi ;;
        esac
    else
        echo_info "Встроенный EPG не найден"
        echo -e "  ${CYAN}1) Указать ссылку на EPG${NC}"
        echo -e "  ${CYAN}2) Пропустить${NC}"
        echo -ne "${YELLOW}> ${NC}"
        read epg_choice </dev/tty
        case "$epg_choice" in
            1)
                echo -ne "${YELLOW}EPG URL: ${NC}"
                read EPG_URL </dev/tty
                if [ -n "$EPG_URL" ]; then
                    echo_info "Скачиваем..."
                    if _dl_epg "$EPG_URL"; then
                        echo_success "EPG загружен! Размер: $(file_size "$EPG_GZ")"
                        printf 'EPG_URL="%s"\n' "$EPG_URL" > "$EPG_CONFIG"
                    else
                        echo_info "Не удалось скачать"
                    fi
                fi ;;
        esac
    fi
    echo ""

    echo -e "${YELLOW}── Шаг 4/5: Расписание обновлений ────────────${NC}"
    echo_info "Как часто обновлять плейлист и EPG?"
    echo -e "  ${CYAN}0) Выкл  1) Каждый час  2) Каждые 6ч  3) Каждые 12ч  4) Раз в сутки${NC}"
    echo -ne "${YELLOW}Плейлист (0-4) [0]: ${NC}"
    read pi </dev/tty
    case "$pi" in 1) PLAYLIST_INTERVAL=1 ;; 2) PLAYLIST_INTERVAL=6 ;; 3) PLAYLIST_INTERVAL=12 ;; 4) PLAYLIST_INTERVAL=24 ;; *) PLAYLIST_INTERVAL=0 ;; esac
    echo -ne "${YELLOW}EPG (0-4) [0]: ${NC}"
    read ei </dev/tty
    case "$ei" in 1) EPG_INTERVAL=1 ;; 2) EPG_INTERVAL=6 ;; 3) EPG_INTERVAL=12 ;; 4) EPG_INTERVAL=24 ;; *) EPG_INTERVAL=0 ;; esac
    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$(get_ts)" "$(get_ts)"
    if [ "$PLAYLIST_INTERVAL" -gt 0 ] || [ "$EPG_INTERVAL" -gt 0 ]; then
        start_scheduler
        echo_success "Расписание настроено, планировщик запущен"
    else
        echo_success "Расписание отключено"
    fi
    echo ""

    echo -e "${YELLOW}── Шаг 5/5: Автозапуск ───────────────────────${NC}"
    echo_info "Запускать IPTV Manager при старте роутера?"
    echo -e "  ${CYAN}1) Да${NC}"
    echo -e "  ${CYAN}2) Нет${NC}"
    echo -ne "${YELLOW}> ${NC}"
    read as_choice </dev/tty
    if [ "$as_choice" = "1" ]; then
        if [ ! -f /etc/init.d/iptv-manager ]; then
        cat > /etc/init.d/iptv-manager <<'INITEOF'
#!/bin/sh /etc/rc.common
START=99
start() {
    mkdir -p /www/iptv/cgi-bin
    [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u
    [ -f /etc/iptv/IPTV-Manager.sh ] && . /etc/iptv/IPTV-Manager.sh 2>/dev/null
    uhttpd -f -p 0.0.0.0:8082 -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" &
    [ -f /etc/iptv/schedule.conf ] && { . /etc/iptv/schedule.conf; [ "${PLAYLIST_INTERVAL:-0}" -gt 0 ] || [ "${EPG_INTERVAL:-0}" -gt 0 ] && /bin/sh /tmp/iptv-scheduler.sh &; }
}
stop() { kill $(pgrep -f "uhttpd.*8082" 2>/dev/null) 2>/dev/null; kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null; }
INITEOF
            chmod +x /etc/init.d/iptv-manager
            /etc/init.d/iptv-manager enable 2>/dev/null
            echo_success "Автозапуск включён"
        else
            echo_info "Автозапуск уже включён"
        fi
    else
        echo_info "Автозапуск отключён"
    fi
    echo ""

    echo -e "${YELLOW}── Шаг 6/6: Интеграция в LuCI ────────────────${NC}"
    echo_info "Установить плагин в веб-интерфейс OpenWrt?"
    echo_info "Появится раздел Services → IPTV Manager с нативными настройками"
    echo -e "  ${CYAN}1) Да, установить${NC}"
    echo -e "  ${CYAN}2) Нет, пропустить${NC}"
    echo -ne "${YELLOW}> ${NC}"
    read luci_choice </dev/tty
    if [ "$luci_choice" = "1" ]; then
        # Clean old/invalid files BEFORE installing new ones
        rm -rf /www/luci-static/resources/view/iptv-manager
        rm -f /usr/share/luci/menu.d/luci-app-iptv-manager.json
        rm -f /usr/share/rpcd/acl.d/luci-app-iptv-manager.json
        rm -f /etc/uci-defaults/99-luci-iptv-manager
        rm -f /www/cgi-bin/srv.cgi /www/cgi-bin/srv.html
        rm -f /usr/lib/lua/luci/view/iptv-manager/*
        echo_info "Скачиваем LuCI-плагин..."
        rm -f /www/luci-static/resources/view/iptv-manager/playlist.js
        rm -f /www/luci-static/resources/view/iptv-manager/epg.js
        rm -f /www/luci-static/resources/view/iptv-manager/schedule.js
        rm -f /www/luci-static/resources/view/iptv-manager/security.js
        rm -f /www/luci-static/resources/view/iptv-manager/channels.js
        rm -f /usr/share/luci/menu.d/luci-app-iptv-manager.json
        rm -f /usr/share/rpcd/acl.d/luci-app-iptv-manager.json
        local luci_base="https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/luci-app-iptv-manager"
        local luci_files="htdocs/luci-static/resources/view/iptv-manager/iptv.js htdocs/luci-static/resources/view/iptv-manager/player.js htdocs/luci-static/resources/view/iptv-manager/server.js root/usr/share/luci/menu.d/luci-app-iptv-manager.json root/usr/share/rpcd/acl.d/luci-app-iptv-manager.json root/etc/uci-defaults/99-luci-iptv-manager"
        local total=0
        local ok=0
        for f in $luci_files; do
            total=$((total + 1))
            local dest=""
            case "$f" in
                root/*) dest="/${f#root/}" ;;
                htdocs/*) dest="/www/${f#htdocs/}" ;;
                luasrc/*) dest="/usr/lib/lua/luci/${f#luasrc/}" ;;
                *) dest="/$f" ;;
            esac
            mkdir -p "$(dirname "$dest")"
            if wget -q --timeout=10 --no-check-certificate -O "$dest" "$luci_base/$f" 2>/tmp/luci-wget-err; then
                ok=$((ok + 1))
            else
                echo_info "FAIL: $f -> $dest"
                cat /tmp/luci-wget-err 2>/dev/null
            fi
        done
        if [ "$ok" -ge 6 ]; then
            chmod +x /etc/uci-defaults/99-luci-iptv-manager 2>/dev/null
            /etc/uci-defaults/99-luci-iptv-manager 2>/dev/null
            /etc/init.d/rpcd restart 2>/dev/null
            echo_success "LuCI-плагин установлен! ($ok/$total файлов)"
            echo_info "Раздел появится в Services → IPTV Manager"
        else
            echo_error "Установлено $ok/$total файлов. Проверьте интернет-соединение."
        fi
    else
        echo_info "Пропущено"
    fi
    echo ""

    echo_color "Настройка завершена!"
    echo_info "Запускаем сервер..."
    start_http_server
    echo ""
    echo_success "Готово! Откройте: http://$LAN_IP:$IPTV_PORT/cgi-bin/admin.cgi"
}

check_for_updates() {
    echo_color "Проверка обновлений"
    echo_info "Текущая версия: $IPTV_MANAGER_VERSION"
    echo_info "Загружаем последнюю версию с GitHub..."
    local latest=$(wget -q --timeout=10 --no-check-certificate -O - "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null | head -10 | grep -o 'IPTV_MANAGER_VERSION="[^"]*"' | sed 's/IPTV_MANAGER_VERSION="//;s/"//')
    if [ -z "$latest" ]; then
        echo_error "Не удалось получить информацию о версии"
        PAUSE
        return 1
    fi
    if [ "$latest" = "$IPTV_MANAGER_VERSION" ]; then
        echo_success "У вас последняя версия v$IPTV_MANAGER_VERSION"
    else
        echo_success "Доступна новая версия: v$latest (у вас v$IPTV_MANAGER_VERSION)"
        echo -ne "${YELLOW}Обновить? (y/N): ${NC}"
        read ans </dev/tty
        case "$ans" in y|Y|yes|Yes) ;; *) echo_info "Отмена"; return 1 ;; esac
        do_update_script
    fi
}

do_update_script() {
    echo_info "Обновляем скрипт..."
    local tmp="/tmp/IPTV-Manager-new.sh"
    if wget -q --timeout=15 --no-check-certificate -O "$tmp" "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null && [ -s "$tmp" ]; then
        local new_ver=$(grep -o 'IPTV_MANAGER_VERSION="[^"]*"' "$tmp" | head -1 | sed 's/IPTV_MANAGER_VERSION="//;s/"//')
        cp "$0" "/etc/iptv/IPTV-Manager.sh.bak" 2>/dev/null
        cp "$tmp" "/etc/iptv/IPTV-Manager.sh"
        chmod +x "/etc/iptv/IPTV-Manager.sh"
        ln -sf /etc/iptv/IPTV-Manager.sh /usr/bin/iptv 2>/dev/null
        rm -f "$tmp"
        echo_success "Обновлено до v$new_ver!"
        echo_info "Перезапуск..."
        exec sh "/etc/iptv/IPTV-Manager.sh"
    else
        echo_error "Не удалось скачать обновление"
        rm -f "$tmp"
        PAUSE
        return 1
    fi
}

install_iptv() {
    echo_color "Установка IPTV Manager"
    echo_info "Загружаем последнюю версию с GitHub..."
    local tmp="/tmp/IPTV-Manager-install.sh"
    if wget -q --timeout=15 --no-check-certificate -O "$tmp" "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null && [ -s "$tmp" ]; then
        local ver=$(grep -o 'IPTV_MANAGER_VERSION="[^"]*"' "$tmp" | head -1 | sed 's/IPTV_MANAGER_VERSION="//;s/"//')
        echo_info "Устанавливаем v$ver..."
        mkdir -p /etc/iptv
        cp "$tmp" "/etc/iptv/IPTV-Manager.sh"
        chmod +x "/etc/iptv/IPTV-Manager.sh"
        ln -sf /etc/iptv/IPTV-Manager.sh /usr/bin/iptv 2>/dev/null
        rm -f "$tmp"
        echo_success "Установлено! Запуск..."
        exec sh "/etc/iptv/IPTV-Manager.sh"
    else
        echo_error "Не удалось скачать скрипт"
        rm -f "$tmp"
        PAUSE
        return 1
    fi
}

reinstall_iptv() {
    echo_color "Переустановка IPTV Manager"
    echo_info "Текущая версия: $IPTV_MANAGER_VERSION"
    echo_info "Ваши настройки и плейлист будут сохранены"
    echo -ne "${YELLOW}Продолжить? (y/N): ${NC}"
    read ans </dev/tty
    case "$ans" in y|Y|yes|Yes) ;; *) echo_info "Отмена"; return 1 ;; esac
    echo_info "Останавливаем сервер..."
    stop_http_server
    stop_scheduler
    echo_info "Загружаем последнюю версию..."
    local tmp="/tmp/IPTV-Manager-reinstall.sh"
    if wget -q --timeout=15 --no-check-certificate -O "$tmp" "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null && [ -s "$tmp" ]; then
        local ver=$(grep -o 'IPTV_MANAGER_VERSION="[^"]*"' "$tmp" | head -1 | sed 's/IPTV_MANAGER_VERSION="//;s/"//')
        cp /etc/iptv/playlist.m3u /tmp/iptv-pl-backup.m3u 2>/dev/null
        cp /etc/iptv/iptv.conf /tmp/iptv-conf-backup.conf 2>/dev/null
        cp /etc/iptv/epg.conf /tmp/iptv-epg-backup.conf 2>/dev/null
        cp /etc/iptv/schedule.conf /tmp/iptv-sched-backup.conf 2>/dev/null
        cp /etc/iptv/favorites.json /tmp/iptv-fav-backup.json 2>/dev/null
        cp /etc/iptv/security.conf /tmp/iptv-sec-backup.conf 2>/dev/null
        cp "$tmp" "/etc/iptv/IPTV-Manager.sh"
        chmod +x "/etc/iptv/IPTV-Manager.sh"
        cp /tmp/iptv-pl-backup.m3u /etc/iptv/playlist.m3u 2>/dev/null
        cp /tmp/iptv-conf-backup.conf /etc/iptv/iptv.conf 2>/dev/null
        cp /tmp/iptv-epg-backup.conf /etc/iptv/epg.conf 2>/dev/null
        cp /tmp/iptv-sched-backup.conf /etc/iptv/schedule.conf 2>/dev/null
        cp /tmp/iptv-fav-backup.json /etc/iptv/favorites.json 2>/dev/null
        cp /tmp/iptv-sec-backup.conf /etc/iptv/security.conf 2>/dev/null
        rm -f "$tmp" /tmp/iptv-pl-backup.m3u /tmp/iptv-conf-backup.conf /tmp/iptv-epg-backup.conf /tmp/iptv-sched-backup.conf /tmp/iptv-fav-backup.json /tmp/iptv-sec-backup.conf
        echo_success "Переустановлено до v$ver!"
        echo_info "Настройки восстановлены. Запуск..."
        exec sh "/etc/iptv/IPTV-Manager.sh"
    else
        echo_error "Не удалось скачать скрипт"
        rm -f "$tmp"
        PAUSE
        return 1
    fi
}

# ==========================================
# Функции для нового меню
# ==========================================
_set_sched() {
    load_sched
    PLAYLIST_INTERVAL="${1:-0}"
    EPG_INTERVAL="${EPG_INTERVAL:-0}"
    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "${PLAYLIST_LAST_UPDATE:--}" "${EPG_LAST_UPDATE:--}"
    echo_success "Расписание плейлиста: $(int_text $PLAYLIST_INTERVAL)"
}

menu_epg_schedule() {
    print_header
    load_sched
    echo -e "${YELLOW}── 📺 EPG Расписание ─────────────────${NC}"
    echo -e "  EPG: ${CYAN}$(int_text $EPG_INTERVAL)${NC}"
    echo ""
    echo -e "${CYAN} 1) Каждый час${NC}"
    echo -e "${CYAN} 2) Каждые 6ч${NC}"
    echo -e "${CYAN} 3) Каждые 12ч${NC}"
    echo -e "${CYAN} 4) Раз в сутки${NC}"
    echo -e "${CYAN} 5) Выкл${NC}"
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) EPG_INTERVAL=1 ;; 2) EPG_INTERVAL=6 ;; 3) EPG_INTERVAL=12 ;; 4) EPG_INTERVAL=24 ;; *) EPG_INTERVAL=0 ;;
    esac
    load_sched
    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$EPG_LAST_UPDATE"
    echo_success "EPG расписание: $(int_text $EPG_INTERVAL)"
    PAUSE
}

express_setup() {
    echo_color "🚀 Экспресс-настройка IPTV Manager"
    echo ""
    echo -e "${YELLOW}[1/6] Скачиваю последние файлы...${NC}"
    # Already on latest version
    echo_success "✓ Готово"
    
    echo -e "${YELLOW}[2/6] Загружаю плейлист 'TV'...${NC}"
    local default_pl="https://raw.githubusercontent.com/smolnp/IPTVru/refs/heads/gh-pages/IPTVru.m3u"
    if wget -q --timeout=30 --no-check-certificate -O "$PLAYLIST_FILE" "$default_pl" 2>/dev/null && [ -s "$PLAYLIST_FILE" ]; then
        local ch=$(get_ch)
        echo_success "✓ Плейлист 'TV' загружен ($ch каналов)"
        printf 'PLAYLIST_TYPE="url"\nPLAYLIST_URL="%s"\nPLAYLIST_SOURCE=""\nPLAYLIST_NAME="TV"\n' "$default_pl" > "$CONFIG_FILE"
    else
        echo_error "✗ Не удалось скачать плейлист"
    fi
    
    echo -e "${YELLOW}[3/6] EPG: пропущено${NC}"
    echo_success "⊘ EPG настраивается позже через админку"
    
    echo -e "${YELLOW}[4/6] Расписание: каждые 6ч...${NC}"
    save_sched "6" "0" "$(get_ts)" "$(get_ts)"
    start_scheduler
    echo_success "✓ Автообновление настроено"
    
    echo -e "${YELLOW}[5/6] Запускаю сервер...${NC}"
    start_http_server
    echo_success "✓ Сервер запущен"
    
    echo -e "${YELLOW}[6/6] Устанавливаю LuCI плагин...${NC}"
    install_luci_plugin
    echo_success "✓ Плагин установлен"
    
    echo ""
    echo_color "✅ Готово! IPTV Manager настроен."
    echo "   Ссылка на админку: http://$LAN_IP:$IPTV_PORT/cgi-bin/admin.cgi"
}

express_factory_reset() {
    echo_color "🏭 Сброс к заводским"
    echo -ne "${YELLOW}Удалить все настройки и скачать новую версию? (y/N): ${NC}"
    read ans </dev/tty
    case "$ans" in y|Y|yes|Yes) ;; *) echo_info "Отмена"; return 1 ;; esac
    echo_info "Останавливаем сервер..."
    stop_http_server
    stop_scheduler
    echo_info "Удаляем все данные..."
    rm -rf "$IPTV_DIR"/*
    rm -f /tmp/iptv-started /var/run/iptv-httpd.pid
    echo_info "Загружаем свежую версию..."
    if wget -q --timeout=30 --no-check-certificate -O "/tmp/IPTV-Manager-new.sh" "https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/IPTV-Manager.sh" 2>/dev/null && [ -s "/tmp/IPTV-Manager-new.sh" ]; then
        cp "/tmp/IPTV-Manager-new.sh" "$IPTV_DIR/IPTV-Manager.sh"
        chmod +x "$IPTV_DIR/IPTV-Manager.sh"
        rm -f "/tmp/IPTV-Manager-new.sh"
        echo_success "Скрипт обновлён. Автоматический запуск..."
        echo_info "Через 3 секунды..."
        sleep 3
        exec sh "$IPTV_DIR/IPTV-Manager.sh"
    else
        echo_error "Не удалось скачать. Запуск текущей версии..."
        sleep 3
        express_setup
    fi
}

setup_password() {
    print_header
    . "$SECURITY_FILE" 2>/dev/null
    echo -e "${YELLOW}── 🔑 Пароль на админку ────────────────${NC}"
    echo -e "  Текущий: ${CYAN}${ADMIN_USER:--}${NC} / ${CYAN}${ADMIN_PASS:+****}${NC}"
    echo ""
    echo -ne "${YELLOW}Логин (пусто=отключить): ${NC}"
    read u </dev/tty
    if [ -z "$u" ]; then
        printf 'ADMIN_USER=""\nADMIN_PASS=""\nAPI_TOKEN="%s"\n' "$(grep API_TOKEN "$SECURITY_FILE" 2>/dev/null | sed 's/.*="//;s/"//')" > "$SECURITY_FILE"
        echo_success "Пароль отключён"
    else
        echo -ne "${YELLOW}Пароль: ${NC}"
        stty -echo; read p </dev/tty; stty echo; echo ""
        printf 'ADMIN_USER="%s"\nADMIN_PASS="%s"\nAPI_TOKEN="%s"\n' "$u" "$p" "$(grep API_TOKEN "$SECURITY_FILE" 2>/dev/null | sed 's/.*="//;s/"//')" > "$SECURITY_FILE"
        echo_success "Пароль установлен"
    fi
    PAUSE
}

setup_api_token() {
    print_header
    . "$SECURITY_FILE" 2>/dev/null
    echo -e "${YELLOW}── 🎫 API токен ─────────────────────${NC}"
    echo -e "  Текущий: ${CYAN}${API_TOKEN:--}${NC}"
    echo ""
    echo -ne "${YELLOW}Токен (пусто=отключить): ${NC}"
    read t </dev/tty
    printf 'ADMIN_USER="%s"\nADMIN_PASS="%s"\nAPI_TOKEN="%s"\n' "$(grep ADMIN_USER "$SECURITY_FILE" 2>/dev/null | sed 's/.*="//;s/"//')" "$(grep ADMIN_PASS "$SECURITY_FILE" 2>/dev/null | sed 's/.*="//;s/"//')" "$t" > "$SECURITY_FILE"
    echo_success "API токен сохранён"
    PAUSE
}

setup_whitelist() {
    print_header
    echo -e "${YELLOW}── 📋 Белый список IP ─────────────────${NC}"
    if [ -s "$WHITELIST_FILE" ]; then
        echo -e "  Текущие IP:"
        cat "$WHITELIST_FILE" | while read -r ip; do echo "    ${CYAN}$ip${NC}"; done
    else
        echo -e "  ${GREEN}Все IP разрешены${NC}"
    fi
    echo ""
    echo -e "${CYAN}1) Добавить IP${NC}"
    echo -e "${CYAN}2) Очистить (все разрешены)${NC}"
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1)
            echo -ne "${YELLOW}IP адрес: ${NC}"
            read ip </dev/tty
            echo "$ip" >> "$WHITELIST_FILE"
            echo_success "Добавлен $ip"
            ;;
        2)
            > "$WHITELIST_FILE"
            echo_success "Список очищен"
            ;;
        9|0) return ;;
    esac
    PAUSE
}

setup_rate_limit() {
    print_header
    echo -e "${YELLOW}── 🛡️ Rate Limiting ─────────────────${NC}"
    echo -e "  Лимит: ${CYAN}$RATE_LIMIT${NC} запросов/мин"
    echo -e "  Блокировка: ${CYAN}$BLOCK_DURATION${NC} сек"
    echo ""
    echo -e "${CYAN}1) Изменить лимит${NC}"
    echo -e "${CYAN}2) Отключить${NC}"
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1)
            echo -ne "${YELLOW}Запросов в минуту: ${NC}"
            read lim </dev/tty
            [ -n "$lim" ] && RATE_LIMIT="$lim"
            echo_success "Лимит: $RATE_LIMIT/мин"
            ;;
        2)
            RATE_LIMIT=0
            echo_success "Rate limiting отключён"
            ;;
        9|0) return ;;
    esac
    PAUSE
}

install_luci_plugin() {
    rm -rf /www/luci-static/resources/view/iptv-manager
    rm -f /usr/share/luci/menu.d/luci-app-iptv-manager.json
    rm -f /usr/share/rpcd/acl.d/luci-app-iptv-manager.json
    rm -f /etc/uci-defaults/99-luci-iptv-manager
    rm -f /www/cgi-bin/srv.cgi /www/cgi-bin/srv.html
    mkdir -p /www/luci-static/resources/view/iptv-manager
    local luci_base="https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/luci-app-iptv-manager"
    for f in "htdocs/luci-static/resources/view/iptv-manager/iptv.js" "htdocs/luci-static/resources/view/iptv-manager/player.js" "htdocs/luci-static/resources/view/iptv-manager/server.js" "htdocs/luci-static/resources/view/iptv-manager/srv.cgi" "htdocs/luci-static/resources/view/iptv-manager/srv.html" "root/usr/share/luci/menu.d/luci-app-iptv-manager.json" "root/usr/share/rpcd/acl.d/luci-app-iptv-manager.json" "root/etc/uci-defaults/99-luci-iptv-manager"; do
        local dest=""
        case "$f" in
            root/*) dest="/${f#root/}" ;;
            htdocs/*) dest="/www/${f#htdocs/}" ;;
            *) dest="/$f" ;;
        esac
        mkdir -p "$(dirname "$dest")"
        wget -q --timeout=10 --no-check-certificate -O "$dest" "$luci_base/$f" 2>/dev/null
    done
    chmod +x /etc/uci-defaults/99-luci-iptv-manager 2>/dev/null
    /etc/uci-defaults/99-luci-iptv-manager 2>/dev/null
    /etc/init.d/rpcd restart 2>/dev/null
}

# ==========================================
# Меню
# ==========================================
print_header() {
    clear
    load_sched
    [ -z "$PLAYLIST_INTERVAL" ] && PLAYLIST_INTERVAL="0"
    [ -z "$EPG_INTERVAL" ] && EPG_INTERVAL="0"
    [ -z "$PLAYLIST_LAST_UPDATE" ] && PLAYLIST_LAST_UPDATE="—"
    local _c=$(get_ch)
    local ch="${_c:-0}"
    local srv_status="❌ Остановлен"
    local srv_uptime="—"
    if [ -f "$HTTPD_PID" ] && kill -0 "$(cat "$HTTPD_PID" 2>/dev/null)" 2>/dev/null; then
        srv_status="✅ Запущен"
        if [ -f "$STARTUP_TIME" ]; then
            local _sn=$(cat "$STARTUP_TIME" 2>/dev/null)
            if [ -n "$_sn" ]; then
                local _now=$(date +%s)
                local _diff=$(((_now+0) - (_sn+0)))
                if [ "$_diff" -gt 0 ] 2>/dev/null; then
                    local _id=$((_diff / 86400))
                    local _ih=$(((_diff % 86400) / 3600))
                    local _im=$(((_diff % 3600) / 60))
                    srv_uptime=""
                    [ "$_id" -gt 0 ] && srv_uptime="${_id}д "
                    srv_uptime="${srv_uptime}${_ih}ч ${_im}м"
                fi
            fi
        fi
    fi
    load_config
    load_epg
    local display_epg="❌"; [ -n "$EPG_URL" ] && display_epg="✅"
    local display_ram="0K"
    [ -d /etc/iptv ] && display_ram=$(du -sh /etc/iptv 2>/dev/null | cut -f1)
    [ -z "$display_ram" ] && display_ram="0K"
    local display_disk="0K"
    [ -d /www/iptv ] && display_disk=$(du -sh /www/iptv 2>/dev/null | cut -f1)
    [ -z "$display_disk" ] && display_disk="0K"

    local hd_count=0
    [ -f "$PLAYLIST_FILE" ] && hd_count=$(grep -ci "hd\|1080\|4k\|2160\|uhd" "$PLAYLIST_FILE" 2>/dev/null || true)
    [ -z "$hd_count" ] && hd_count=0
    local sd_count=$((ch - hd_count))
    [ "$sd_count" -lt 0 ] 2>/dev/null && sd_count=0
    local groups=""
    [ -f "$PLAYLIST_FILE" ] && groups=$(grep -o 'group-title="[^"]*"' "$PLAYLIST_FILE" 2>/dev/null | sed 's/group-title="//;s/"//' | sort -u | grep . || true)
    local grp_count=0
    [ -n "$groups" ] && grp_count=$(echo "$groups" | wc -l | tr -d ' ')

    echo ""
    echo -e "══════════════════════════════════════════"
    echo -e "     IPTV Manager v${CYAN}$IPTV_MANAGER_VERSION${NC}                   "
    echo -e "══════════════════════════════════════════"

    # Check if NOT configured
    load_config
    local has_pl=false
    [ -n "$PLAYLIST_TYPE" ] && [ -n "$PLAYLIST_URL" ] && has_pl=true
    local srv_running=false
    [ -f "$HTTPD_PID" ] && kill -0 "$(cat "$HTTPD_PID" 2>/dev/null)" 2>/dev/null && srv_running=true

    if [ "$has_pl" = "false" ] && [ "$srv_running" = "false" ]; then
        # NOT configured mode
        local srv_short="Остановлен"
        echo -e "🌐 ${CYAN}$LAN_IP${NC}:${CYAN}$IPTV_PORT${NC}   📺 ${GREEN}${ch}${NC} каналов"
        echo -e "📡 EPG: ${CYAN}${display_epg}${NC}          🖥 Сервер: $srv_short"
        echo -e "══════════════════════════════════════════"
        echo -e " ${YELLOW}💡${NC} IPTV Manager не настроен             "
        echo -e " ${YELLOW}Нажмите 1${NC} для быстрой настройки         "
        echo -e "══════════════════════════════════════════"
    else
        # Configured mode
        echo -e "🌐 ${CYAN}$LAN_IP${NC}:${CYAN}$IPTV_PORT${NC}   "
        echo -e "📺 ${GREEN}${ch}${NC} каналов 🎬 HD:${CYAN}${hd_count}${NC}  SD:${CYAN}${sd_count}${NC} 📂 ${CYAN}${grp_count}${NC} групп"
        echo -e "📡 EPG: ${CYAN}${display_epg}${NC}  💾 ${CYAN}${display_ram}${NC}  🗄 Диск: ${CYAN}${display_disk}${NC}"
        echo -e "🖥 Сервер: ${GREEN}${srv_status}${NC}  ⏱ ${CYAN}${srv_uptime}${NC}"
        echo -e "══════════════════════════════════════════"
    fi
}

show_menu() {
    print_header
    load_config
    local has_pl=false
    [ -n "$PLAYLIST_TYPE" ] && [ -n "$PLAYLIST_URL" ] && has_pl=true
    local srv_running=false
    [ -f "$HTTPD_PID" ] && kill -0 "$(cat "$HTTPD_PID" 2>/dev/null)" 2>/dev/null && srv_running=true
    if [ "$has_pl" = "false" ] && [ "$srv_running" = "false" ]; then
        echo -e "${YELLOW}── 🚀 Экспресс-настройка ──────────────${NC}"
        echo "  Автоматическая установка за 30 секунд"
        echo ""
        echo -e "${CYAN} 1) Запустить настройку${NC}"
        echo ""
        echo -e "${CYAN} 0) Выход${NC}"
        echo ""
        echo -ne "${YELLOW}> ${NC}"
        read c </dev/tty
        case "$c" in
            1) express_setup ;; 0) exit 0 ;; *) echo_info "Выход"; exit 0 ;;
        esac
        PAUSE
        return
    fi
    echo -e "${YELLOW}── 💡 Главное меню ────────────────────────${NC}"
    echo -e "  📌 ${CYAN}Админка:${NC}  http://$LAN_IP:$IPTV_PORT/cgi-bin/admin.cgi"
    echo -e "  📌 ${CYAN}Плейлист:${NC} http://$LAN_IP:$IPTV_PORT/playlist.m3u"
    echo -e "  📌 ${CYAN}EPG:${NC}      http://$LAN_IP:$IPTV_PORT/epg.xml"
    echo ""
    echo -e "  ${CYAN}1)${NC} ${GREEN}📡  Плейлист${NC}"
    echo -e "  ${CYAN}2)${NC} ${GREEN}📺  Телепрограмма${NC}"
    echo -e "  ${CYAN}3)${NC} ${GREEN}🔧  Сервер${NC}"
    echo -e "  ${CYAN}4)${NC} ${GREEN}⏰  Расписание${NC}"
    echo -e "  ${CYAN}5)${NC} ${GREEN}🔒  Безопасность${NC}"
    echo -e "  ${CYAN}6)${NC} ${GREEN}💾  Бэкап${NC}"
    echo -e "  ${CYAN}7)${NC} ${GREEN}🔄  Обновление${NC}"
    echo -e "  ${CYAN}8)${NC} ${GREEN}🗑️   Удалить IPTV Manager${NC}"
    echo ""
    echo -e "${CYAN} 0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) menu_playlist ;; 2) menu_epg ;; 3) menu_server ;;
        4) menu_schedule ;; 5) menu_security ;; 6) menu_backup ;;
        7) menu_update ;; 8) uninstall ;; 0) exit 0 ;; *) echo_info "Отмена"; return ;;
    esac
    PAUSE
}

menu_playlist() {
    print_header
    load_config
    echo -e "${YELLOW}── 📡 Плейлист ──────────────────────────${NC}"
    echo -e "  Название: ${CYAN}${PLAYLIST_NAME:--}${NC}"
    echo -e "  Каналов: ${GREEN}$(get_ch)${NC}"
    echo ""
    echo -e "${CYAN} 1) Загрузить по ссылке${NC}"
    echo -e "${CYAN} 2) Загрузить из файла${NC}"
    echo -e "${CYAN} 3) Настроить провайдера${NC}"
    echo -e "${CYAN} 4) Обновить плейлист${NC}"
    echo -e "${CYAN} 5) Удалить плейлист${NC}"
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) load_playlist_url ;; 2) load_playlist_file ;; 3) setup_provider ;;
        4) do_update_playlist ;; 5) remove_playlist ;;
        9|0) return ;; *) echo_info "Отмена"; return ;;
    esac
    PAUSE
}

menu_epg() {
    print_header
    load_epg
    echo -e "${YELLOW}── 📺 Телепрограмма (EPG) ───────────────${NC}"
    echo ""
    echo -e "${CYAN} 1) Настроить EPG${NC}"
    echo -e "${CYAN} 2) Обновить EPG${NC}"
    echo -e "${CYAN} 3) Удалить EPG${NC}"
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) setup_epg ;; 2) do_update_epg ;; 3) remove_epg ;;
        9|0) return ;; *) echo_info "Отмена"; return ;;
    esac
    PAUSE
}

menu_server() {
    print_header
    local srv_status="❌ Остановлен"
    if [ -f "$HTTPD_PID" ] && kill -0 "$(cat "$HTTPD_PID" 2>/dev/null)" 2>/dev/null; then
        srv_status="✅ Запущен"
    fi
    echo -e "${YELLOW}── 🔧 Сервер ────────────────────────${NC}"
    echo -e "  Статус: ${CYAN}$srv_status${NC}"
    echo -e "  Порт: ${CYAN}$IPTV_PORT${NC}"
    echo ""
    if [ -f "$HTTPD_PID" ] && kill -0 "$(cat "$HTTPD_PID" 2>/dev/null)" 2>/dev/null; then
        echo -e "${CYAN} 1) ⏹  Остановить${NC}"
        echo -e "${CYAN} 2) 🔄 Перезапустить${NC}"
    else
        echo -e "${CYAN} 1) ▶  Запустить${NC}"
    fi
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    local srv_up=false
    [ -f "$HTTPD_PID" ] && kill -0 "$(cat "$HTTPD_PID" 2>/dev/null)" 2>/dev/null && srv_up=true
    case "$c" in
        1) if [ "$srv_up" = "true" ]; then stop_http_server; else start_http_server; fi ;;
        2) if [ "$srv_up" = "true" ]; then stop_http_server; sleep 1; start_http_server; fi ;;
        9|0) return ;; *) echo_info "Отмена"; return ;;
    esac
    PAUSE
}

menu_schedule() {
    print_header
    load_sched
    echo -e "${YELLOW}── ⏰ Расписание ───────────────────────${NC}"
    echo -e "  Плейлист: ${CYAN}$(int_text $PLAYLIST_INTERVAL)${NC}   (обновлён: ${CYAN}${PLAYLIST_LAST_UPDATE:--}${NC})"
    echo -e "  EPG: ${CYAN}$(int_text $EPG_INTERVAL)${NC}"
    echo ""
    echo -e "${CYAN} 1) ⏱️  Каждый час${NC}"
    echo -e "${CYAN} 2) ⏱️  Каждые 6ч${NC}"
    echo -e "${CYAN} 3) ⏱️  Каждые 12ч${NC}"
    echo -e "${CYAN} 4) ⏱️  Раз в сутки${NC}"
    echo -e "${CYAN} 5) ⏱️  Выкл${NC}"
    echo ""
    echo -e "${CYAN} 6) 📺 Настроить EPG расписание${NC}"
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) _set_sched "1" ;; 2) _set_sched "6" ;; 3) _set_sched "12" ;;
        4) _set_sched "24" ;; 5) _set_sched "0" ;;
        6) menu_epg_schedule ;;
        9|0) return ;; *) echo_info "Отмена"; return ;;
    esac
    PAUSE
}

menu_security() {
    print_header
    . "$SECURITY_FILE" 2>/dev/null
    local pw_status="❌ Не установлен"
    [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ] && pw_status="✅ Установлен"
    local api_status="❌ Не задан"
    [ -n "$API_TOKEN" ] && api_status="✅ Задан"
    echo -e "${YELLOW}── 🔒 Безопасность ──────────────────────${NC}"
    echo -e "  Пароль: ${CYAN}$pw_status${NC}"
    echo -e "  API токен: ${CYAN}$api_status${NC}"
    echo ""
    echo -e "${CYAN} 1) 🔑 Пароль на админку${NC}"
    echo -e "${CYAN} 2) 🎫 API токен${NC}"
    echo -e "${CYAN} 3) 📋 Белый список IP${NC}"
    echo -e "${CYAN} 4) 🛡️ Rate Limiting${NC}"
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) setup_password ;; 2) setup_api_token ;;
        3) setup_whitelist ;; 4) setup_rate_limit ;;
        9|0) return ;; *) echo_info "Отмена"; return ;;
    esac
    PAUSE
}

menu_backup() {
    print_header
    echo -e "${YELLOW}── 💾 Бэкап и восстановление ────────────${NC}"
    echo ""
    echo -e "${CYAN} 1) 📦 Создать бэкап${NC}"
    echo -e "${CYAN} 2) 📂 Восстановить из бэкапа${NC}"
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) act 'backup' '' 2>/dev/null | head -1 ; echo_info "Бэкап создан" ;; 2) do_import ;;
        9|0) return ;; *) echo_info "Отмена"; return ;;
    esac
    PAUSE
}

menu_update() {
    print_header
    echo -e "${YELLOW}── 🔄 Обновление ────────────────────────${NC}"
    echo ""
    echo -e "${CYAN} 1) 🔍 Проверить обновления${NC}"
    echo -e "${CYAN} 2) ⬇️  Обновить (с сохранением настроек)${NC}"
    echo -e "${CYAN} 3) 🏭 Сброс к заводским${NC}"
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) check_for_updates ;; 2) do_update_script ;;
        3) express_factory_reset ;; 9|0) return ;;
        *) echo_info "Отмена"; return ;;
    esac
    PAUSE
}

show_uninstall() {
    print_header
    echo -e "${YELLOW}── ❌ Полное удаление ──────────────────${NC}"
    echo -e "  Будет удалено:"
    echo -e "  • Все конфиги, настройки, плейлист и EPG"
    echo -e "  • Временные файлы"
    echo -e "  • LuCI плагин"
    echo -e "  • Init-скрипт"
    echo ""
    echo -e "${RED} 1) Удалить IPTV Manager${NC}"
    echo ""
    echo -e "${CYAN} 9) Назад    0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) uninstall ;;
        9|0) return ;; *) echo_info "Отмена"; return ;;
    esac
    PAUSE
}

menu_uninstall() {
    print_header
    uninstall
}

# Handle start/stop commands (for LuCI init script and manual calls)
case "$1" in
    start)
        echo "=== Запуск IPTV-сервера ==="
        # Kill any existing uhttpd on port 8082
        kill -9 $(pgrep -f "uhttpd.*8082") 2>/dev/null; sleep 1
        # Generate CGI and prepare dirs
        generate_cgi
        generate_srv_cgi
        mkdir -p /www/iptv/cgi-bin
        [ -f "$PLAYLIST_FILE" ] && cp "$PLAYLIST_FILE" /www/iptv/playlist.m3u || echo "#EXTM3U" > /www/iptv/playlist.m3u
        # Start in background with nohup
        nohup uhttpd -p "0.0.0.0:$IPTV_PORT" -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" </dev/null >/dev/null 2>&1 &
        echo $! > /var/run/iptv-httpd.pid
        sleep 3
        echo "Сервер запущен (PID: $(cat /var/run/iptv-httpd.pid 2>/dev/null))"
        exit 0
        ;;
    stop)
        echo "=== Остановка IPTV-сервера ==="
        kill -9 $(pgrep -f "uhttpd.*8082") 2>/dev/null
        rm -f /var/run/iptv-httpd.pid
        echo "Сервер остановлен"
        exit 0
        ;;
    status)
        # Check by PID first
        if [ -f /var/run/iptv-httpd.pid ] && kill -0 "$(cat /var/run/iptv-httpd.pid 2>/dev/null)" 2>/dev/null; then
            echo "running"
        else
            # Fallback: check if port 8082 responds
            if wget -q -O /dev/null --timeout=2 "http://127.0.0.1:8082/" 2>/dev/null; then
                echo "running"
            else
                echo "stopped"
            fi
        fi
        exit 0
        ;;
    restart)
        "$0" stop; sleep 1; "$0" start; exit 0 ;;
    --server)
        # Called by init script without interactive menu - for procd compatibility
        stop_http_server 2>/dev/null; sleep 1; generate_cgi; exit 0
        ;;
esac


while true; do show_menu; done
