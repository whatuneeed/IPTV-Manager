#!/bin/sh
# ==========================================
# IPTV Manager for OpenWrt v1.2
# ==========================================
# uhttpd-based, no CGI issues
# ==========================================

IPTV_MANAGER_VERSION="1.2"
GREEN="\033[1;32m"; RED="\033[1;31m"; CYAN="\033[1;36m"; YELLOW="\033[1;33m"; MAGENTA="\033[1;35m"; BLUE="\033[0;34m"; NC="\033[0m"
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"
IPTV_PORT="8082"
API_PORT="8083"
IPTV_DIR="/etc/iptv"
PLAYLIST_FILE="$IPTV_DIR/playlist.m3u"
CONFIG_FILE="$IPTV_DIR/iptv.conf"
PROVIDER_CONFIG="$IPTV_DIR/provider.conf"
EPG_FILE="$IPTV_DIR/epg.xml"
EPG_CONFIG="$IPTV_DIR/epg.conf"
SCHEDULE_FILE="$IPTV_DIR/schedule.conf"
HTTPD_PID="/var/run/iptv-httpd.pid"
API_PID="/var/run/iptv-api.pid"
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
    printf 'PLAYLIST_TYPE=%s\nPLAYLIST_URL=%s\nPLAYLIST_SOURCE=%s\n' "$1" "$2" "$3" > "$CONFIG_FILE"
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
    case "$1" in
        0) echo "Выкл";; 1) echo "Каждый час";; 6) echo "Каждые 6ч";;
        12) echo "Каждые 12ч";; 24) echo "Раз в сутки";; *) echo "Выкл";;
    esac
}

# ==========================================
# Действия
# ==========================================
do_update_playlist() {
    load_config
    case "$PLAYLIST_TYPE" in
        url)
            if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null; then
                local ch=$(get_ch)
                local now=$(get_ts)
                load_sched
                save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                echo_success "Плейлист обновлён! Каналов: $ch"
                return 0
            fi ;;
        provider)
            if [ -f "$PROVIDER_CONFIG" ]; then
                . "$PROVIDER_CONFIG"
                local purl="http://${PROVIDER_SERVER:-$PROVIDER_NAME}/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"
                if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$purl" 2>/dev/null; then
                    local ch=$(get_ch)
                    local now=$(get_ts); load_sched
                    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                    echo_success "Плейлист обновлён! Каналов: $ch"
                    return 0
                fi
            fi ;;
        file)
            if [ -f "$PLAYLIST_SOURCE" ]; then
                cp "$PLAYLIST_SOURCE" "$PLAYLIST_FILE"
                local ch=$(get_ch); local now=$(get_ts); load_sched
                save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                echo_success "Плейлист обновлён! Каналов: $ch"
                return 0
            fi ;;
    esac
    echo_error "Ошибка обновления плейлиста!"; return 1
}

do_update_epg() {
    load_epg
    [ -z "$EPG_URL" ] && { echo_error "EPG не настроен!"; return 1; }
    echo_info "Скачиваем EPG..."
    if wget -q --timeout=30 -O "$EPG_FILE" "$EPG_URL" 2>/dev/null && [ -s "$EPG_FILE" ]; then
        local sz=$(file_size "$EPG_FILE")
        local now=$(get_ts); load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
        echo_success "EPG обновлён! Размер: $sz"
        return 0
    fi
    echo_error "Не удалось скачать EPG!"; return 1
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
# Генерация HTML админки (на роутере, без CRLF)
# ==========================================
gen_html() {
    load_config; load_epg; load_sched
    local ch=$(get_ch)
    local psz=$(file_size "$PLAYLIST_FILE")
    local esz=$(file_size "$EPG_FILE")
    local purl=""; [ "$PLAYLIST_TYPE" = "url" ] && purl="$PLAYLIST_URL"
    local eurl=""; [ -n "$EPG_URL" ] && eurl="$EPG_URL"
    local pi="${PLAYLIST_INTERVAL:-0}"
    local ei="${EPG_INTERVAL:-0}"

    cat > /www/iptv/index.html <<HTMLHEAD
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>IPTV Manager</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#0f172a;color:#e2e8f0;min-height:100vh}
.c{max-width:900px;margin:0 auto;padding:20px}
.h{text-align:center;padding:24px 0 16px;border-bottom:1px solid #1e293b;margin-bottom:20px}
.h h1{font-size:24px;background:linear-gradient(135deg,#3b82f6,#8b5cf6);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.h p{color:#64748b;font-size:13px;margin-top:4px}
.st{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:10px;margin-bottom:20px}
.s{background:#1e293b;border-radius:10px;padding:14px;text-align:center;border:1px solid #334155}
.sv{font-size:20px;font-weight:700;color:#3b82f6}
.sl{font-size:11px;color:#64748b;text-transform:uppercase;margin-top:2px}
.ub{background:#0f172a;border:1px solid #334155;border-radius:8px;padding:10px;margin:8px 0;display:flex;align-items:center;gap:8px}
.ub code{flex:1;font-size:13px;color:#3b82f6;word-break:break-all}
.ub button{padding:6px 10px;background:#334155;border:none;border-radius:6px;color:#e2e8f0;cursor:pointer;font-size:12px}
.ub button:hover{background:#475569}
.tb{display:flex;gap:4px;margin-bottom:16px;background:#1e293b;border-radius:10px;padding:4px;overflow-x:auto}
.t{flex:1;padding:10px 12px;border:none;background:transparent;color:#94a3b8;border-radius:8px;cursor:pointer;font-size:13px;font-weight:500;white-space:nowrap}
.t:hover{color:#e2e8f0}.t.a{background:#3b82f6;color:#fff}
.pn{display:none;background:#1e293b;border-radius:14px;padding:20px;border:1px solid #334155;margin-bottom:12px}
.pn.a{display:block}
.pn h2{font-size:16px;margin-bottom:14px;color:#f1f5f9}
.fg{margin-bottom:12px}
.fg label{display:block;font-size:12px;color:#94a3b8;margin-bottom:4px}
.fg input,.fg textarea{width:100%;padding:10px 12px;background:#0f172a;border:1px solid #334155;border-radius:8px;color:#e2e8f0;font-size:14px}
.fg input:focus,.fg textarea:focus{outline:none;border-color:#3b82f6}
.fg textarea{min-height:70px;font-family:monospace;font-size:12px;resize:vertical}
.b{padding:9px 16px;border:none;border-radius:8px;font-size:13px;font-weight:600;cursor:pointer;display:inline-block}
.bp{background:#3b82f6;color:#fff}.bp:hover{background:#2563eb}
.bd{background:#ef4444;color:#fff}.bd:hover{background:#dc2626}
.bs{background:#22c55e;color:#fff}.bs:hover{background:#16a34a}
.bsm{padding:7px 12px;font-size:12px}
.bg{display:flex;gap:8px;margin-top:14px;flex-wrap:wrap}
hr{border:none;border-top:1px solid #334155;margin:16px 0}
.sg{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.sc{background:#0f172a;border-radius:10px;padding:14px;border:1px solid #334155}
.sc h3{font-size:13px;color:#f1f5f9;margin-bottom:10px}
.sc select{width:100%;padding:9px;background:#1e293b;border:1px solid #334155;border-radius:8px;color:#e2e8f0;font-size:13px}
.si{margin-top:10px;font-size:11px;color:#64748b}
.si span{color:#94a3b8}
.cl{max-height:350px;overflow-y:auto}
.ci{display:flex;align-items:center;gap:8px;padding:8px;border-bottom:1px solid #334155}
.ci:hover{background:#334155}
.ci:last-child{border-bottom:none}
.cn{font-size:13px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cg{font-size:11px;color:#64748b}
.toast{position:fixed;top:16px;right:16px;padding:12px 16px;border-radius:8px;font-size:13px;z-index:9999;box-shadow:0 8px 30px rgba(0,0,0,.3)}
.to{background:#064e3b;border:1px solid #10b981;color:#6ee7b7}
.te{background:#7f1d1d;border:1px solid #ef4444;color:#fca5a5}
.ti{background:#1e3a5f;border:1px solid #3b82f6;color:#93c5fd}
.empty{text-align:center;padding:24px;color:#64748b}
.ft{text-align:center;padding:20px 0;color:#475569;font-size:11px}
@media(max-width:600px){.st{grid-template-columns:repeat(2,1fr)}.sg{grid-template-columns:1fr}.bg{flex-direction:column}}
</style>
</head>
<body>
<div class="c">
<div class="h"><h1>IPTV Manager</h1><p>OpenWrt</p></div>
<div class="st">
<div class="s"><div class="sv">$ch</div><div class="sl">Channels</div></div>
<div class="s"><div class="sv">$psz</div><div class="sl">Playlist</div></div>
<div class="s"><div class="sv">$esz</div><div class="sl">EPG</div></div>
</div>
<div class="ub"><code>http://$LAN_IP:$IPTV_PORT/playlist.m3u</code><button onclick="cp(this)">Copy</button></div>
<div class="ub"><code>http://$LAN_IP:$IPTV_PORT/epg.xml</code><button onclick="cp(this)">Copy</button></div>
<div class="tb">
<button class="t a" onclick="st('pl',this)">Playlist</button>
<button class="t" onclick="st('epg',this)">EPG</button>
<button class="t" onclick="st('sch',this)">Schedule</button>
<button class="t" onclick="st('ch',this)">Channels</button>
</div>
<div class="pn a" id="p-pl">
<h2>Playlist Source</h2>
<div class="fg"><label>Load from URL</label>
<input type="url" id="i-url" placeholder="http://example.com/playlist.m3u" value="$purl"></div>
<button class="b bp bsm" onclick="act('load_url','url='+encodeURIComponent(document.getElementById('i-url').value))">Load URL</button>
<hr>
<div class="fg"><label>Paste M3U</label>
<textarea id="i-m3u" placeholder="#EXTM3U\n#EXTINF:-1,Channel\nhttp://..."></textarea></div>
<button class="b bp bsm" onclick="act('load_file','content='+encodeURIComponent(document.getElementById('i-m3u').value))">Load text</button>
<hr>
<div class="fg"><label>Provider</label>
<input type="text" id="i-pn" placeholder="Provider name"></div>
<div class="fg"><label>Server</label>
<input type="text" id="i-ps" placeholder="example.com"></div>
<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
<div class="fg"><label>Login</label><input type="text" id="i-pl" placeholder="login"></div>
<div class="fg"><label>Password</label><input type="password" id="i-pp" placeholder="password"></div>
</div>
<button class="b bp bsm" onclick="act('setup_provider','name='+encodeURIComponent(document.getElementById('i-pn').value)+'&server='+encodeURIComponent(document.getElementById('i-ps').value)+'&login='+encodeURIComponent(document.getElementById('i-pl').value)+'&password='+encodeURIComponent(document.getElementById('i-pp').value))">Connect</button>
<hr>
<div class="bg"><button class="b bs bsm" onclick="act('update_playlist','')">Refresh playlist</button></div>
</div>
<div class="pn" id="p-epg">
<h2>EPG TV Guide</h2>
<div class="fg"><label>EPG URL (XMLTV)</label>
<input type="url" id="i-epg" placeholder="http://epg.example.com/epg.xml" value="$eurl"></div>
<div class="bg">
<button class="b bp bsm" onclick="act('setup_epg','epg_url='+encodeURIComponent(document.getElementById('i-epg').value))">Load EPG</button>
<button class="b bs bsm" onclick="act('update_epg','')">Refresh EPG</button>
<button class="b bd bsm" onclick="act('delete_epg','')">Delete EPG</button>
</div>
</div>
<div class="pn" id="p-sch">
<h2>Update Schedule</h2>
<div class="sg">
<div class="sc"><h3>Playlist</h3>
<select id="s-pl">
<option value="0"$([ "$pi" = "0" ] && echo " selected")>Off</option>
<option value="1"$([ "$pi" = "1" ] && echo " selected")>Every hour</option>
<option value="6"$([ "$pi" = "6" ] && echo " selected")>Every 6h</option>
<option value="12"$([ "$pi" = "12" ] && echo " selected")>Every 12h</option>
<option value="24"$([ "$pi" = "24" ] && echo " selected")>Every 24h</option>
</select>
<div class="si">Last: <span>${PLAYLIST_LAST_UPDATE:----}</span></div></div>
<div class="sc"><h3>EPG</h3>
<select id="s-epg">
<option value="0"$([ "$ei" = "0" ] && echo " selected")>Off</option>
<option value="1"$([ "$ei" = "1" ] && echo " selected")>Every hour</option>
<option value="6"$([ "$ei" = "6" ] && echo " selected")>Every 6h</option>
<option value="12"$([ "$ei" = "12" ] && echo " selected")>Every 12h</option>
<option value="24"$([ "$ei" = "24" ] && echo " selected")>Every 24h</option>
</select>
<div class="si">Last: <span>${EPG_LAST_UPDATE:----}</span></div></div>
</div>
<div class="bg"><button class="b bp bsm" onclick="act('set_schedule','playlist_interval='+document.getElementById('s-pl').value+'&epg_interval='+document.getElementById('s-epg').value)">Save</button></div>
</div>
<div class="pn" id="p-ch">
<h2>Channels ($ch)</h2>
<div class="cl">
HTMLHEAD

    if [ "$ch" -gt 0 ] 2>/dev/null; then
        grep "^#EXTINF" "$PLAYLIST_FILE" | head -80 | while IFS= read -r line; do
            local name=$(echo "$line" | sed 's/.*,\(.*\)/\1/')
            local group=$(echo "$line" | grep -o 'group-title="[^"]*"' | sed 's/group-title="//;s/"//')
            [ -z "$name" ] && name="Unknown"
            [ -z "$group" ] && group="General"
            printf '<div class="ci"><div><div class="cn">%s</div><div class="cg">%s</div></div></div>\n' "$name" "$group"
        done >> /www/iptv/index.html
        [ "$ch" -gt 80 ] 2>/dev/null && echo '<div class="empty">Showing 80 of '"$ch"' channels</div>' >> /www/iptv/index.html
    else
        echo '<div class="empty">No playlist</div>' >> /www/iptv/index.html
    fi

    cat >> /www/iptv/index.html <<HTMLFOOT
</div></div>
<div class="ft">IPTV Manager v1.2 — OpenWrt</div>
</div>
<script>
function st(t,e){document.querySelectorAll('.t').forEach(function(x){x.classList.remove('a')});document.querySelectorAll('.pn').forEach(function(x){x.classList.remove('a')});document.getElementById('p-'+t).classList.add('a');e.classList.add('a')}
function cp(b){var c=b.previousElementSibling;var r=document.createRange();r.selectNodeContents(c);var s=window.getSelection();s.removeAllRanges();s.addRange(r);document.execCommand('copy');s.removeAllRanges();b.textContent='OK';setTimeout(function(){b.textContent='Copy'},1500)}
function toast(m,t){var d=document.createElement('div');d.className='toast '+(t==='ok'?'to':'te');d.textContent=m;document.body.appendChild(d);setTimeout(function(){d.remove()},4000)}
function act(a,p){
var x=new XMLHttpRequest();
x.open('POST','http://$LAN_IP:$API_PORT/',true);
x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
x.onload=function(){try{var r=JSON.parse(x.responseText);if(r.status==='ok'){toast(r.message,'ok');setTimeout(function(){location.reload()},1500)}else toast(r.message,'err')}catch(e){toast('Error','err')}};
x.onerror=function(){toast('Network error','err')};
x.send('action='+a+'&'+p);
}
</script>
</body>
</html>
HTMLFOOT
}

# ==========================================
# HTTP сервер (uhttpd — статика)
# ==========================================
start_http_server() {
    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then
        echo_success "Сервер уже запущен: http://$LAN_IP:$IPTV_PORT/"
        return
    fi
    if [ ! -f "$PLAYLIST_FILE" ]; then
        echo_error "Плейлист не найден!"; PAUSE; return 1
    fi

    mkdir -p /www/iptv
    cp "$PLAYLIST_FILE" /www/iptv/playlist.m3u
    [ -f "$EPG_FILE" ] && cp "$EPG_FILE" /www/iptv/epg.xml
    gen_html

    kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null
    sleep 1
    uhttpd -f -p "0.0.0.0:$IPTV_PORT" -h /www/iptv &
    echo $! > "$HTTPD_PID"

    start_api
    echo_success "Сервер запущен!"
    echo_info "Админка: http://$LAN_IP:$IPTV_PORT/"
    echo_info "Плейлист: http://$LAN_IP:$IPTV_PORT/playlist.m3u"
    echo_info "EPG: http://$LAN_IP:$IPTV_PORT/epg.xml"
}

stop_http_server() {
    kill $(cat "$HTTPD_PID" 2>/dev/null) 2>/dev/null
    kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null
    rm -f "$HTTPD_PID"
    stop_api
    echo_success "Сервер остановлен"
}

# ==========================================
# API сервер (uhttpd + CGI-скрипт, генерируемый на роутере)
# ==========================================
gen_api_cgi() {
    cat > /www/iptv-api/cgi-bin/api <<'CGIEOF'
#!/bin/sh
D=/etc/iptv
PL=$D/playlist.m3u; EC=$D/iptv.conf; PC=$D/provider.conf
EF=$D/epg.xml; EXC=$D/epg.conf; SC=$D/schedule.conf

readln() { read -r line; echo "$line"; }
# Skip headers
while readln; do [ -z "$line" ] && break; done
# Read POST data
CL=$(echo "$line" | grep -i content-length | grep -o '[0-9]*')
[ -z "$CL" ] && CL=0
if [ "$CL" -gt 0 ] 2>/dev/null; then
    dd bs=1 count=$CL 2>/dev/null > /tmp/iptv-post.txt
fi

ACT=$(grep -o 'action=[^&]*' /tmp/iptv-post.txt 2>/dev/null | sed 's/action=//')
gch() { [ -f "$PL" ] && grep -c "^#EXTINF" "$PL" 2>/dev/null || echo "0"; }

restart() {
    mkdir -p /www/iptv
    [ -f "$PL" ] && cp "$PL" /www/iptv/playlist.m3u
    [ -f "$EF" ] && cp "$EF" /www/iptv/epg.xml
    # Regenerate HTML
    if [ -f "$D/IPTV-Manager.sh" ]; then
        . "$D/IPTV-Manager.sh" 2>/dev/null
    fi
    kill $(cat /var/run/iptv-httpd.pid 2>/dev/null) 2>/dev/null
    kill $(pgrep -f "uhttpd.*:8082" 2>/dev/null) 2>/dev/null
    sleep 1
    uhttpd -f -p "0.0.0.0:8082" -h /www/iptv &
    echo $! > /var/run/iptv-httpd.pid
}

j() { printf 'Content-Type: application/json\r\n\r\n%s' "$1"; }

case "$ACT" in
load_url)
    U=$(grep -o 'url=[^&]*' /tmp/iptv-post.txt | sed 's/url=//')
    if wget -q --timeout=15 -O "$PL" "$U" 2>/dev/null && [ -s "$PL" ]; then
        CH=$(gch)
        printf 'PLAYLIST_TYPE=url\nPLAYLIST_URL=%s\nPLAYLIST_SOURCE=\n' "$U" > "$EC"
        restart
        j '{"status":"ok","message":"Playlist loaded! Channels: '"$CH"'"}'
    else j '{"status":"error","message":"Download failed"}'; fi;;
load_file)
    C=$(sed 's/.*content=//' /tmp/iptv-post.txt)
    printf '%b\n' "$C" > "$PL"
    CH=$(gch)
    printf 'PLAYLIST_TYPE=file\nPLAYLIST_URL=\nPLAYLIST_SOURCE=manual\n' > "$EC"
    restart
    j '{"status":"ok","message":"Playlist loaded! Channels: '"$CH"'"}';;
setup_provider)
    PN=$(grep -o 'name=[^&]*' /tmp/iptv-post.txt | sed 's/name=//')
    PS=$(grep -o 'server=[^&]*' /tmp/iptv-post.txt | sed 's/server=//')
    PL2=$(grep -o 'login=[^&]*' /tmp/iptv-post.txt | sed 's/login=//')
    PP=$(grep -o 'password=[^&]*' /tmp/iptv-post.txt | sed 's/password=//')
    [ -z "$PS" ] && PS="http://$PN"
    PU="$PS/get.php?username=$PL2&password=$PP&type=m3u_plus&output=ts"
    if wget -q --timeout=15 -O "$PL" "$PU" 2>/dev/null && [ -s "$PL" ]; then
        CH=$(gch)
        printf 'PROVIDER_NAME=%s\nPROVIDER_LOGIN=%s\nPROVIDER_PASS=%s\nPROVIDER_SERVER=%s\n' "$PN" "$PL2" "$PP" "$PS" > "$PC"
        printf 'PLAYLIST_TYPE=provider\nPLAYLIST_URL=%s\nPLAYLIST_SOURCE=%s\n' "$PU" "$PN" > "$EC"
        restart
        j '{"status":"ok","message":"Provider connected! Channels: '"$CH"'"}'
    else j '{"status":"error","message":"Provider connection failed"}'; fi;;
update_playlist)
    . "$EC" 2>/dev/null
    case "$PLAYLIST_TYPE" in
        url) wget -q --timeout=15 -O "$PL" "$PLAYLIST_URL" 2>/dev/null;;
        provider)
            . "$PC" 2>/dev/null
            pu="http://${PROVIDER_SERVER:-$PROVIDER_NAME}/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"
            wget -q --timeout=15 -O "$PL" "$pu" 2>/dev/null;;
    esac
    CH=$(gch); NT=$(date '+%d.%m.%Y %H:%M')
    . "$SC" 2>/dev/null
    printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' \
        "${PLAYLIST_INTERVAL:-0}" "${EPG_INTERVAL:-0}" "$NT" "${EPG_LAST_UPDATE:-}" > "$SC"
    restart
    j '{"status":"ok","message":"Playlist updated! Channels: '"$CH"'"}';;
setup_epg)
    EU=$(grep -o 'epg_url=[^&]*' /tmp/iptv-post.txt | sed 's/epg_url=//')
    if wget -q --timeout=30 -O "$EF" "$EU" 2>/dev/null && [ -s "$EF" ]; then
        SZ=$(wc -c < "$EF" 2>/dev/null)
        printf 'EPG_URL=%s\n' "$EU" > "$EXC"
        NT=$(date '+%d.%m.%Y %H:%M')
        . "$SC" 2>/dev/null
        printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' \
            "${PLAYLIST_INTERVAL:-0}" "${EPG_INTERVAL:-0}" "${PLAYLIST_LAST_UPDATE:-}" "$NT" > "$SC"
        restart
        j '{"status":"ok","message":"EPG loaded! Size: '"$((SZ/1024))' KB"}'
    else j '{"status":"error","message":"EPG download failed"}'; fi;;
update_epg)
    . "$EXC" 2>/dev/null
    if [ -n "$EPG_URL" ] && wget -q --timeout=30 -O "$EF" "$EPG_URL" 2>/dev/null && [ -s "$EF" ]; then
        SZ=$(wc -c < "$EF" 2>/dev/null); NT=$(date '+%d.%m.%Y %H:%M')
        . "$SC" 2>/dev/null
        printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' \
            "${PLAYLIST_INTERVAL:-0}" "${EPG_INTERVAL:-0}" "${PLAYLIST_LAST_UPDATE:-}" "$NT" > "$SC"
        restart
        j '{"status":"ok","message":"EPG updated! Size: '"$((SZ/1024))' KB"}'
    else j '{"status":"error","message":"EPG update failed"}'; fi;;
delete_epg)
    rm -f "$EF" "$EXC"; j '{"status":"ok","message":"EPG deleted"}';;
set_schedule)
    PI=$(grep -o 'playlist_interval=[^&]*' /tmp/iptv-post.txt | sed 's/playlist_interval=//')
    EI=$(grep -o 'epg_interval=[^&]*' /tmp/iptv-post.txt | sed 's/epg_interval=//')
    [ -z "$PI" ] && PI=0; [ -z "$EI" ] && EI=0
    . "$SC" 2>/dev/null
    printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' \
        "$PI" "$EI" "${PLAYLIST_LAST_UPDATE:-}" "${EPG_LAST_UPDATE:-}" > "$SC"
    if [ "$PI" -gt 0 ] || [ "$EI" -gt 0 ]; then
        kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null
        /bin/sh /tmp/iptv-scheduler.sh &
        j '{"status":"ok","message":"Schedule saved, scheduler started"}'
    else
        kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null
        rm -f /var/run/iptv-scheduler.pid /tmp/iptv-scheduler.sh
        j '{"status":"ok","message":"Schedule disabled"}'
    fi;;
*) j '{"status":"error","message":"Unknown action"}';;
esac
rm -f /tmp/iptv-post.txt
CGIEOF
    chmod +x /www/iptv-api/cgi-bin/api
}

start_api() {
    kill $(pgrep -f "uhttpd.*:$API_PORT" 2>/dev/null) 2>/dev/null
    sleep 1
    mkdir -p /www/iptv-api/cgi-bin
    gen_api_cgi
    uhttpd -f -p "0.0.0.0:$API_PORT" -h /www/iptv-api -x /cgi-bin -i ".cgi=/bin/sh" &
    echo $! > "$API_PID"
    echo_success "API сервер: http://$LAN_IP:$API_PORT/"
}

stop_api() {
    kill $(cat "$API_PID" 2>/dev/null) 2>/dev/null
    kill $(pgrep -f "uhttpd.*:$API_PORT" 2>/dev/null) 2>/dev/null
    rm -f "$API_PID"
    rm -rf /www/iptv-api
}

# ==========================================
# Загрузка плейлиста (SSH)
# ==========================================
load_playlist_url() {
    echo_color "Загрузка плейлиста по ссылке"
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
        printf 'EPG_URL=%s\n' "$EPG_URL" > "$EPG_CONFIG"
        local now=$(get_ts); load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
        start_http_server
    else
        echo_error "Не удалось скачать!"; PAUSE; return 1
    fi
}

remove_epg() { rm -f "$EPG_FILE" "$EPG_CONFIG"; echo_success "EPG удалён"; }

setup_schedule() {
    load_sched
    echo_color "Расписание обновлений"
    echo_info "Плейлист: $(int_text $PLAYLIST_INTERVAL) | EPG: $(int_text $EPG_INTERVAL)"
    echo ""
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
    mkdir -p /www/iptv /www/iptv-api/cgi-bin
    [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u
    [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml
    uhttpd -f -p 0.0.0.0:8082 -h /www/iptv &
    [ -f /etc/iptv/iptv-admin.cgi ] && {
        cp /etc/iptv/iptv-admin.cgi /www/iptv-api/cgi-bin/api
        chmod +x /www/iptv-api/cgi-bin/api
        uhttpd -f -p 0.0.0.0:8083 -h /www/iptv-api -x /cgi-bin -i ".cgi=/bin/sh" &
    }
    if [ -f /etc/iptv/schedule.conf ]; then
        . /etc/iptv/schedule.conf
        [ "${PLAYLIST_INTERVAL:-0}" -gt 0 ] || [ "${EPG_INTERVAL:-0}" -gt 0 ] && /bin/sh /tmp/iptv-scheduler.sh &
    fi
}
stop() {
    kill $(pgrep -f "uhttpd.*8082" 2>/dev/null) 2>/dev/null
    kill $(pgrep -f "uhttpd.*8083" 2>/dev/null) 2>/dev/null
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
    load_config; get_ch > /dev/null
    echo -e "${CYAN}Плейлист:${NC} $([ "$PLAYLIST_TYPE" = "url" ] && echo "$PLAYLIST_URL" || echo "$PLAYLIST_TYPE")"
    load_epg; echo -e "${CYAN}EPG:${NC} $([ -n "$EPG_URL" ] && echo "$EPG_URL" || echo "не настроен")"
    echo -e "${CYAN}Расписание:${NC} Плейлист=$(int_text $PLAYLIST_INTERVAL) | EPG=$(int_text $EPG_INTERVAL)"
    [ -n "$PLAYLIST_LAST_UPDATE" ] && echo -e "${CYAN}Обновлён:${NC} $PLAYLIST_LAST_UPDATE"
    echo ""
    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then
        echo_success "Сервер: запущен — http://$LAN_IP:$IPTV_PORT/"
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
