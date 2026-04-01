#!/bin/sh
# ==========================================
# IPTV Manager for OpenWrt v3.2
# ==========================================

IPTV_MANAGER_VERSION="3.2"
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

mkdir -p "$IPTV_DIR"

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
    if [ -f "$SCHEDULE_FILE" ]; then . "$SCHEDULE_FILE"; else PLAYLIST_INTERVAL="0"; EPG_INTERVAL="0"; PLAYLIST_LAST_UPDATE=""; EPG_LAST_UPDATE=""; fi
}
save_sched() { printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' "$1" "$2" "$3" "$4" > "$SCHEDULE_FILE"; }
get_ch() { [ -f "$PLAYLIST_FILE" ] && grep -c "^#EXTINF" "$PLAYLIST_FILE" 2>/dev/null || echo "0"; }
file_size() {
    [ -f "$1" ] || { echo "0 B"; return; }
    local s=$(wc -c < "$1" 2>/dev/null)
    if [ "$s" -gt 1048576 ] 2>/dev/null; then echo "$((s/1048576)) MB"
    elif [ "$s" -gt 1024 ] 2>/dev/null; then echo "$((s/1024)) KB"
    else echo "${s} B"; fi
}
int_text() { case "$1" in 0) echo "Выкл";; 1) echo "Каждый час";; 6) echo "Каждые 6ч";; 12) echo "Каждые 12ч";; 24) echo "Раз в сутки";; *) echo "Выкл";; esac; }
detect_builtin_epg() {
    [ -f "$PLAYLIST_FILE" ] || return
    local epg=""
    epg=$(head -5 "$PLAYLIST_FILE" | grep -o 'url-tvg="[^"]*"' | head -1 | sed 's/url-tvg="//;s/"//')
    [ -z "$epg" ] && epg=$(head -5 "$PLAYLIST_FILE" | grep -o "url-tvg='[^']*'" | head -1 | sed "s/url-tvg='//;s/'//")
    echo "$epg"
}
wget_opt() { local o="-q --timeout=15"; wget --help 2>&1 | grep -q "no-check-certificate" && o="$o --no-check-certificate"; echo "$o"; }

# ==========================================
# CGI Generation
# ==========================================
generate_cgi() {
    load_config; load_epg; load_sched
    local ch=$(get_ch)
    local psz=$(file_size "$PLAYLIST_FILE")
    local esz=$(file_size "$EPG_FILE")
    local purl=""; [ "$PLAYLIST_TYPE" = "url" ] && purl="$PLAYLIST_URL"
    local eurl=""; [ -n "$EPG_URL" ] && eurl="$EPG_URL"
    local pi="${PLAYLIST_INTERVAL:-0}"
    local ei="${EPG_INTERVAL:-0}"
    local plu="${PLAYLIST_LAST_UPDATE:----}"
    local elu="${EPG_LAST_UPDATE:----}"

    local groups=""
    [ -f "$PLAYLIST_FILE" ] && groups=$(grep -o 'group-title="[^"]*"' "$PLAYLIST_FILE" | sed 's/group-title="//;s/"//' | sort -u)

    # EPG now-playing map
    local now_epg="/tmp/iptv-now-epg.txt"
    > "$now_epg"
    if [ -f "$EPG_FILE" ]; then
        local now_ts=$(date '+%Y%m%d%H%M%S')
        awk -v now="$now_ts" '
            /<programme / { start=""; stop=""; ch=""
                if (match($0,/start="[0-9]+/)) start=substr($0,RSTART+7,RLENGTH-7)
                if (match($0,/stop="[0-9]+/)) stop=substr($0,RSTART+6,RLENGTH-6)
                if (match($0,/channel="[^"]+"/)) ch=substr($0,RSTART+9,RLENGTH-9)
            }
            /<title[^>]*>/ { t=$0; if(match(t,/<title[^>]*>[^<]*<\/title>/)){t=substr(t,RSTART,RLENGTH);gsub(/<[^>]*>/,"",t);title=t} }
            /<\/programme>/ { if(start!=""&&stop!=""&&start<=now&&stop>=now&&ch!=""&&title!="") print ch"\t"title; title="" }
        ' "$EPG_FILE" > "$now_epg" 2>/dev/null
    fi

    local channels="" group_opts=""
    if [ -f "$PLAYLIST_FILE" ]; then
        # Generate channels.json via awk (reliable for any size)
        mkdir -p /www/iptv
        awk 'BEGIN{printf "["}
            /#EXTINF:/ {
                name=""; group=""; tvgid=""; logo=""
                n=$0
                if(match(n,/,/)) name=substr(n,RSTART+1)
                gsub(/^ +| +$/,"",name)
                if(match(n,/group-title="[^"]*"/)) { group=substr(n,RSTART+12,RLENGTH-13) }
                if(match(n,/tvg-id="[^"]*"/)) { tvgid=substr(n,RSTART+9,RLENGTH-10) }
                if(match(n,/tvg-logo="[^"]*"/)) { logo=substr(n,RSTART+11,RLENGTH-12) }
                if(name=="") name="Unknown"
                if(group=="") group="Общее"
            }
            /^http|^https|^rtsp|^rtmp|^udp|^rtp/ {
                url=$0
                gsub(/\\/,"\\\\",name); gsub(/"/,"\\\"",name)
                gsub(/\\/,"\\\\",group); gsub(/"/,"\\\"",group)
                gsub(/\\/,"\\\\",url); gsub(/"/,"\\\"",url)
                gsub(/\\/,"\\\\",logo); gsub(/"/,"\\\"",logo)
                gsub(/\\/,"\\\\",tvgid); gsub(/"/,"\\\"",tvgid)
                if(idx>0) printf ","
                printf "{\"i\":%d,\"n\":\"%s\",\"g\":\"%s\",\"u\":\"%s\",\"t\":\"%s\",\"l\":\"%s\"}", idx++, name, group, url, tvgid, logo
                if(idx>=5000) exit
            }
            END{printf "]"}
        ' "$PLAYLIST_FILE" > /www/iptv/channels.json 2>/dev/null

        echo "$groups" | while IFS= read -r g; do [ -n "$g" ] && echo "<option value=\"$g\">$g</option>"; done > /tmp/iptv-go.txt
        group_opts=$(cat /tmp/iptv-go.txt 2>/dev/null)
        rm -f /tmp/iptv-go.txt
    fi
    rm -f "$now_epg"

    # EPG rows
    local epg_rows=""
    [ -f "$EPG_FILE" ] && epg_rows=$(awk '/<programme /{s=$0;if(match(s,/start="[0-9]+/)){st=substr(s,RSTART+7,RLENGTH-7);if(match(s,/channel="[^"]+"/)){ch=substr(s,RSTART+9,RLENGTH-9)}}}/<title/{t=$0;if(match(t,/<title[^>]*>[^<]*<\/title>/)){t=substr(t,RSTART,RLENGTH);gsub(/<[^>]*>/,"",t);ti=t}}/<\/programme>/{if(ti!=""&&ch!=""&&st!=""){printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n",substr(st,9,2)":"substr(st,11,2),ch,ti;c++;if(c>=30)exit}ti=""}' "$EPG_FILE" 2>/dev/null)

    cat > /www/iptv/cgi-bin/admin.cgi << 'CGIEOF'
#!/bin/sh
PL="/etc/iptv/playlist.m3u"
EC="/etc/iptv/iptv.conf"
EF="/etc/iptv/epg.xml"
EXC="/etc/iptv/epg.conf"
SC="/etc/iptv/schedule.conf"
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"
hdr() { printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'; }
json_hdr() { printf 'Content-Type: application/json\r\n\r\n'; }
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
    json_hdr
    case "$ACTION" in
        check_channel)
            URL=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            case "$URL" in
                http*|https*)
                    wget --spider --timeout=4 --tries=1 --header="User-Agent: VLC/3.0" "$URL" 2>/dev/null && printf '{"status":"ok","online":true}' || printf '{"status":"ok","online":false}' ;;
                udp*|rtp*) printf '{"status":"ok","online":true}' ;;
                *) printf '{"status":"ok","online":false}' ;;
            esac ;;
        update_channel)
            IDX=$(echo "$POST_DATA" | sed -n 's/.*idx=\([^&]*\).*/\1/p')
            NURL=$(echo "$POST_DATA" | sed -n 's/.*new_url=\([^&]*\).*/\1/p')
            NGRP=$(echo "$POST_DATA" | sed -n 's/.*new_group=\([^&]*\).*/\1/p')
            if [ -n "$IDX" ] && [ -n "$NURL" ]; then
                TMP="/tmp/iptv-edit.m3u"; echo "#EXTM3U" > "$TMP"; I=0
                while IFS= read -r L; do
                    case "$L" in
                        "#EXTINF:"*) [ "$I" -eq "$IDX" ] 2>/dev/null && [ -n "$NGRP" ] && L=$(echo "$L" | sed "s/group-title=\"[^\"]*\"/group-title=\"$NGRP\"/"); echo "$L" >> "$TMP" ;;
                        http*|https*|rtsp*|rtmp*|udp*|rtp*) [ "$I" -eq "$IDX" ] 2>/dev/null && echo "$NURL" >> "$TMP" || echo "$L" >> "$TMP"; I=$((I+1)) ;;
                        *) echo "$L" >> "$TMP" ;;
                    esac
                done < "$PL"
                cp "$TMP" "$PL"; mkdir -p /www/iptv; cp "$PL" /www/iptv/playlist.m3u
                printf '{"status":"ok","message":"Канал обновлён"}'
            else printf '{"status":"error","message":"Неверные данные"}'; fi ;;
        refresh_playlist)
            . "$EC" 2>/dev/null
            case "$PLAYLIST_TYPE" in
                url) wget $(wget_opt) -O "$PL" "$PLAYLIST_URL" 2>/dev/null && [ -s "$PL" ] && { CH=$(grep -c "^#EXTINF" "$PL"); mkdir -p /www/iptv; cp "$PL" /www/iptv/playlist.m3u; printf '{"status":"ok","message":"Плейлист обновлён! Каналов: %s"}' "$CH"; } || printf '{"status":"error","message":"Ошибка загрузки"}' ;;
                *) printf '{"status":"error","message":"Невозможно обновить"}' ;;
            esac ;;
        refresh_epg)
            . "$EXC" 2>/dev/null
            if [ -n "$EPG_URL" ]; then
                wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EF" "$EPG_URL" 2>/dev/null && [ -s "$EF" ] && {
                    M=$(hexdump -n 2 -e '2/1 "%02x"' "$EF" 2>/dev/null)
                    [ "$M" = "1f8b" ] && { gunzip -f "$EF" 2>/dev/null; mv "${EF%.gz}" "$EF" 2>/dev/null; }
                    case "$EPG_URL" in *.gz) gunzip -f "$EF" 2>/dev/null; mv "${EF%.gz}" "$EF" 2>/dev/null ;; esac
                    SZ=$(wc -c < "$EF"); mkdir -p /www/iptv; cp "$EF" /www/iptv/epg.xml
                    printf '{"status":"ok","message":"EPG обновлён! Размер: %s KB"}' "$((SZ/1024))"
                } || printf '{"status":"error","message":"Ошибка загрузки EPG"}'
            else printf '{"status":"error","message":"EPG URL не задан"}'; fi ;;
        set_playlist_url)
            NU=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            NU=$(echo "$NU" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            if [ -n "$NU" ]; then
                printf 'PLAYLIST_TYPE="url"\nPLAYLIST_URL="%s"\nPLAYLIST_SOURCE=""\n' "$NU" > "$EC"
                wget $(wget_opt) -O "$PL" "$NU" 2>/dev/null && [ -s "$PL" ] && {
                    CH=$(grep -c "^#EXTINF" "$PL"); mkdir -p /www/iptv; cp "$PL" /www/iptv/playlist.m3u
                    printf '{"status":"ok","message":"Плейлист загружен! Каналов: %s"}' "$CH"
                } || printf '{"status":"error","message":"Ошибка загрузки"}'
            else printf '{"status":"error","message":"Укажите URL"}'; fi ;;
        set_epg_url)
            NU=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            NU=$(echo "$NU" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            if [ -n "$NU" ]; then
                printf 'EPG_URL="%s"\n' "$NU" > "$EXC"
                wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EF" "$NU" 2>/dev/null && [ -s "$EF" ] && {
                    M=$(hexdump -n 2 -e '2/1 "%02x"' "$EF" 2>/dev/null)
                    [ "$M" = "1f8b" ] && { gunzip -f "$EF" 2>/dev/null; mv "${EF%.gz}" "$EF" 2>/dev/null; }
                    case "$NU" in *.gz) gunzip -f "$EF" 2>/dev/null; mv "${EF%.gz}" "$EF" 2>/dev/null ;; esac
                    SZ=$(wc -c < "$EF"); mkdir -p /www/iptv; cp "$EF" /www/iptv/epg.xml
                    printf '{"status":"ok","message":"EPG загружен! Размер: %s KB"}' "$((SZ/1024))"
                } || printf '{"status":"error","message":"Ошибка загрузки EPG"}'
            else printf '{"status":"error","message":"Укажите URL"}'; fi ;;
        set_schedule)
            PI=$(echo "$POST_DATA" | sed -n 's/.*playlist_interval=\([^&]*\).*/\1/p')
            EI=$(echo "$POST_DATA" | sed -n 's/.*epg_interval=\([^&]*\).*/\1/p')
            [ -z "$PI" ] && PI=0; [ -z "$EI" ] && EI=0
            printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\n' "$PI" "$EI" > "$SC"
            printf '{"status":"ok","message":"Расписание сохранено"}' ;;
        *) printf '{"status":"error","message":"Неизвестное действие"}' ;;
    esac
    exit 0
fi

hdr
load_config; load_epg; load_sched
CH=$(grep -c "^#EXTINF" "$PL" 2>/dev/null || echo 0)
PSZ=$(file_size "$PL"); ESZ=$(file_size "$EF")
PURL=""; [ "$PLAYLIST_TYPE" = "url" ] && PURL="$PLAYLIST_URL"
EURL=""; [ -n "$EPG_URL" ] && EURL="$EPG_URL"
PI="${PLAYLIST_INTERVAL:-0}"; EI="${EPG_INTERVAL:-0}"
PLU="${PLAYLIST_LAST_UPDATE:----}"; ELU="${EPG_LAST_UPDATE:----}"
BUILTIN_EPG=$(head -5 "$PL" 2>/dev/null | grep -o 'url-tvg="[^"]*"' | head -1 | sed 's/url-tvg="//;s/"//')
EPG_NOTICE=""; [ -n "$BUILTIN_EPG" ] && [ -z "$EURL" ] && EPG_NOTICE="<div class=\"banner\">💡 В плейлисте найдена встроенная ссылка EPG: <code>$BUILTIN_EPG</code> — укажите её в поле выше для загрузки.</div>"
GROUPS=""; [ -f "$PL" ] && GROUPS=$(grep -o 'group-title="[^"]*"' "$PL" | sed 's/group-title="//;s/"//' | sort -u)
GOPTS=""; echo "$GROUPS" | while IFS= read -r g; do [ -n "$g" ] && echo "<option value=\"$g\">$g</option>"; done > /tmp/iptv-go2.txt
GOPTS=$(cat /tmp/iptv-go2.txt 2>/dev/null); rm -f /tmp/iptv-go2.txt
NOW_EPG="/tmp/iptv-ne.txt"; > "$NOW_EPG"
[ -f "$EF" ] && { NT=$(date '+%Y%m%d%H%M%S'); awk -v n="$NT" '/<programme /{s=$0;if(match(s,/start="[0-9]+/))st=substr(s,RSTART+7,RLENGTH-7);if(match(s,/channel="[^"]+"/))ch=substr(s,RSTART+9,RLENGTH-9)}/<title/{t=$0;if(match(t,/<title[^>]*>[^<]*<\/title>/)){t=substr(t,RSTART,RLENGTH);gsub(/<[^>]*>/,"",t);ti=t}}/<\/programme>/{if(st!=""&&ch!=""&&ti!="")print st"\t"ch"\t"ti;ti=""}' "$EF" | sort -t'	' -k1 -r | awk -F'\t' '!seen[$2]++{print $2"\t"$3}' > "$NOW_EPG" 2>/dev/null; }
CHROWS=""; IDX=0; NM=""; GR=""; TG=""; LG=""; UL=""
[ -f "$PL" ] && while IFS= read -r L; do
    case "$L" in
        "#EXTINF:"*) NM=$(echo "$L"|sed 's/.*,\(.*\)/\1/'|sed 's/ *$//'); GR=$(echo "$L"|grep -o 'group-title="[^"]*"'|sed 's/group-title="//;s/"//'); TG=$(echo "$L"|grep -o 'tvg-id="[^"]*"'|sed 's/tvg-id="//;s/"//'); LG=$(echo "$L"|grep -o 'tvg-logo="[^"]*"'|sed 's/tvg-logo="//;s/"//'); [ -z "$NM" ] && NM="Unknown"; [ -z "$GR" ] && GR="Общее" ;;
        http*|https*|rtsp*|rtmp*|udp*|rtp*)
            UL="$L"; PR="—"; [ -n "$TG" ] && [ -s "$NOW_EPG" ] && PR=$(grep "^${TG}	" "$NOW_EPG" | head -1 | cut -f2); [ -z "$PR" ] && PR="—"
            LI=""; [ -n "$LG" ] && LI="<img src=\"$LG\" style=\"width:20px;height:20px;border-radius:3px;object-fit:contain;vertical-align:middle;margin-right:4px\" onerror=\"this.style.display='none'\">"
            CHROWS="$CHROWS<tr data-group=\"$GR\" data-name=\"$NM\" data-idx=\"$IDX\" data-url=\"$UL\"><td><span class=\"ch-st unknown\" id=\"st-$IDX\"></span></td><td class=\"ch-n\">${LI}${NM}</td><td class=\"ch-g\">$GR</td><td class=\"ch-p\" title=\"$PR\">$PR</td><td><button class=\"b bsm bp\" onclick=\"checkCh($IDX,'$UL')\">Пинг</button></td><td><button class=\"b bsm bo\" onclick=\"editCh($IDX)\">Изм.</button></td></tr>
"
            IDX=$((IDX+1)); [ "$IDX" -ge 1000 ] && break; NM=""; GR=""; TG=""; LG=""; UL="" ;;
    esac
done < "$PL"
rm -f "$NOW_EPG"
EPGROWS=""; [ -f "$EF" ] && EPGROWS=$(awk '/<programme /{s=$0;if(match(s,/start="[0-9]+/)){st=substr(s,RSTART+7,RLENGTH-7);if(match(s,/channel="[^"]+"/)){ch=substr(s,RSTART+9,RLENGTH-9)}}}/<title/{t=$0;if(match(t,/<title[^>]*>[^<]*<\/title>/)){t=substr(t,RSTART,RLENGTH);gsub(/<[^>]*>/,"",t);ti=t}}/<\/programme>/{if(ti!=""&&ch!=""&&st!=""){printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n",substr(st,9,2)":"substr(st,11,2),ch,ti;c++;if(c>=30)exit}ti=""}' "$EF" 2>/dev/null)

cat << HTMLEND
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>IPTV Manager</title>
<style>
:root{--bg:#f0f2f5;--card:#fff;--text:#1a1a2e;--text2:#666;--text3:#888;--border:#e0e0e0;--input-bg:#fafafa;--hover-bg:#f8f9fa;--primary:#1a73e8;--primary-hover:#1557b0;--success:#1e8e3e;--danger:#d93025;--shadow:0 1px 3px rgba(0,0,0,.06);--shadow-lg:0 8px 32px rgba(0,0,0,.15);--modal-bg:rgba(0,0,0,.4)}
[data-theme="dark"]{--bg:#0a0e1a;--card:#1e293b;--text:#e2e8f0;--text2:#94a3b8;--text3:#64748b;--border:#334155;--input-bg:#0f172a;--hover-bg:#334155;--primary:#3b82f6;--primary-hover:#2563eb;--success:#22c55e;--danger:#ef4444;--shadow:0 1px 3px rgba(0,0,0,.2);--shadow-lg:0 8px 32px rgba(0,0,0,.4);--modal-bg:rgba(0,0,0,.6)}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--text);min-height:100vh;transition:background .2s,color .2s}
.c{max-width:1200px;margin:0 auto;padding:16px}
.h{display:flex;align-items:center;justify-content:space-between;padding:16px 20px;border-bottom:2px solid var(--border);margin-bottom:16px;background:var(--card);border-radius:8px;box-shadow:var(--shadow)}
.h h1{font-size:20px;color:var(--primary)}.h p{color:var(--text3);font-size:11px;margin-top:2px}
.tt{background:var(--input-bg);border:1px solid var(--border);border-radius:20px;padding:6px 14px;cursor:pointer;font-size:13px;color:var(--text);display:flex;align-items:center;gap:6px;transition:all .2s;user-select:none}
.tt:hover{border-color:var(--primary)}
.st{display:grid;grid-template-columns:repeat(auto-fit,minmax(110px,1fr));gap:8px;margin-bottom:16px}
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
@media(max-width:700px){.st{grid-template-columns:1fr 1fr}.sg{grid-template-columns:1fr}.h{flex-direction:column;gap:10px}.fb{flex-direction:column}}
</style>
</head>
<body>
<div class="c">
<div class="h"><div><h1>IPTV Manager</h1><p>OpenWrt</p></div><button class="tt" id="ttb" onclick="toggleTheme()">🌙 Тема</button></div>
<div class="st"><div class="s"><div class="sv">$CH</div><div class="sl">Каналов</div></div><div class="s"><div class="sv">$PSZ</div><div class="sl">Плейлист</div></div><div class="s"><div class="sv">$ESZ</div><div class="sl">EPG</div></div></div>
<div class="ub"><code>http://$LAN_IP:$IPTV_PORT/playlist.m3u</code><button onclick="cp(this)">Копировать</button></div>
<div class="ub"><code>http://$LAN_IP:$IPTV_PORT/epg.xml</code><button onclick="cp(this)">Копировать</button></div>
<div class="tb"><button class="t a" onclick="st('status',this)">Каналы</button><button class="t" onclick="st('playlist',this)">Плейлист</button><button class="t" onclick="st('epg',this)">Телепрограмма</button><button class="t" onclick="st('settings',this)">Настройки</button></div>
<div class="pn a" id="p-status"><h2>Список каналов</h2>
<div class="fb"><select id="f-g" onchange="filterCh()"><option value="">Все группы</option>$GOPTS</select><input type="text" id="f-s" placeholder="Поиск..." oninput="filterCh()"><button class="b bp bsm" onclick="checkAll()">Проверить все</button></div>
<div id="ch-loading" style="text-align:center;padding:40px;color:var(--text3)">Загрузка каналов...</div>
<div style="overflow-x:auto;display:none" id="ch-wrap"><table class="ch-t"><thead><tr><th style="width:20px"></th><th>Название</th><th>Группа</th><th>Сейчас играет</th><th style="width:80px">Пинг</th><th>Действия</th></tr></thead><tbody id="ch-tb"></tbody></table></div>
<div id="pager" style="display:none;justify-content:center;align-items:center;gap:6px;margin-top:12px;flex-wrap:wrap"></div>
</div>
<div class="pn" id="p-playlist"><h2>Плейлист</h2>
<div class="fg"><label>Ссылка на плейлист</label><input type="url" id="pl-u" placeholder="http://example.com/playlist.m3u" value="$PURL"><div class="hint">Вставьте ссылку на M3U/M3U8 плейлист</div></div>
<div class="bg"><button class="b bp" onclick="setPlUrl()">Применить</button><button class="b bs" onclick="act('refresh_playlist','')">Обновить</button></div><hr>
<h3>Исходный M3U</h3><div class="fg"><textarea id="pl-r" readonly style="min-height:200px"></textarea></div></div>
<div class="pn" id="p-epg"><h2>Телепрограмма (EPG)</h2>$EPG_NOTICE
<div class="fg"><label>Ссылка на EPG (XMLTV)</label><input type="url" id="epg-u" placeholder="https://iptvx.one/EPG.XML" value="$EURL"><div class="hint">Поддерживаются XML и XML.gz. Распаковка автоматическая.</div></div>
<div class="bg"><button class="b bp" onclick="setEpgUrl()">Применить</button><button class="b bs" onclick="act('refresh_epg','')">Обновить</button></div><hr>
<h3>Передачи</h3><div style="overflow-x:auto"><table class="epg-t"><thead><tr><th>Время</th><th>Канал</th><th>Передача</th></tr></thead><tbody>$EPGROWS</tbody></table></div></div>
<div class="pn" id="p-settings"><h2>Настройки</h2>
<div class="sg"><div class="sc"><h3>Расписание плейлиста</h3><select id="s-pl"><option value="0"$([ "$PI" = "0" ] && echo " selected")>Выкл</option><option value="1"$([ "$PI" = "1" ] && echo " selected")>Каждый час</option><option value="6"$([ "$PI" = "6" ] && echo " selected")>Каждые 6ч</option><option value="12"$([ "$PI" = "12" ] && echo " selected")>Каждые 12ч</option><option value="24"$([ "$PI" = "24" ] && echo " selected")>Раз в сутки</option></select><div class="si">Последнее: <span>$PLU</span></div></div>
<div class="sc"><h3>Расписание EPG</h3><select id="s-epg"><option value="0"$([ "$EI" = "0" ] && echo " selected")>Выкл</option><option value="1"$([ "$EI" = "1" ] && echo " selected")>Каждый час</option><option value="6"$([ "$EI" = "6" ] && echo " selected")>Каждые 6ч</option><option value="12"$([ "$EI" = "12" ] && echo " selected")>Каждые 12ч</option><option value="24"$([ "$EI" = "24" ] && echo " selected")>Раз в сутки</option></select><div class="si">Последнее: <span>$ELU</span></div></div></div>
<div class="bg"><button class="b bp bsm" onclick="saveSched()">Сохранить</button></div></div>
<div class="modal" id="em"><div class="modal-box"><h3>Редактировать канал</h3>
<div class="fg"><label>Название</label><input type="text" id="e-n" readonly></div>
<div class="fg"><label>Ссылка</label><input type="text" id="e-u"></div>
<div class="fg"><label>Группа</label><input type="text" id="e-g"></div>
<div class="bg"><button class="b bp bsm" onclick="saveEdit()">Сохранить</button><button class="b bd bsm" onclick="closeModal()">Отмена</button></div></div></div>
<div class="ft">IPTV Manager v3.2 — OpenWrt</div>
</div>
<script>
var API='/cgi-bin/admin.cgi';
function toggleTheme(){var d=document.documentElement,t=d.getAttribute('data-theme')==='dark'?'light':'dark';d.setAttribute('data-theme',t);document.getElementById('ttb').innerHTML=t==='dark'?'☀️ Тема':'🌙 Тема';try{localStorage.setItem('iptv-theme',t)}catch(e){}}
(function(){try{var t=localStorage.getItem('iptv-theme');if(t==='dark'){document.documentElement.setAttribute('data-theme','dark');document.getElementById('ttb').innerHTML='☀️ Тема'}}catch(e){}})();
function st(t,e){document.querySelectorAll('.t').forEach(function(x){x.classList.remove('a')});document.querySelectorAll('.pn').forEach(function(x){x.classList.remove('a')});document.getElementById('p-'+t).classList.add('a');e.classList.add('a');if(t==='playlist')loadRaw()}
function cp(b){var c=b.previousElementSibling,r=document.createRange();r.selectNodeContents(c);var s=window.getSelection();s.removeAllRanges();s.addRange(r);document.execCommand('copy');s.removeAllRanges();b.textContent='OK';setTimeout(function(){b.textContent='Копировать'},1500)}
function toast(m,t){var d=document.createElement('div');d.className='toast '+(t==='ok'?'to':'te');d.textContent=m;document.body.appendChild(d);setTimeout(function(){d.remove()},4000)}
function act(a,p){var x=new XMLHttpRequest();x.open('POST',API,true);x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');x.onload=function(){try{var r=JSON.parse(x.responseText);if(r.status==='ok'){toast(r.message,'ok');setTimeout(function(){location.reload()},1500)}else toast(r.message,'err')}catch(e){toast('Ошибка','err')}};x.onerror=function(){toast('Ошибка сети','err')};x.send('action='+a+'&'+p)}
function checkCh(i,u){var el=document.getElementById('st-'+i);el.className='ch-st unknown';var x=new XMLHttpRequest();x.open('POST',API,true);x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');x.onload=function(){try{var r=JSON.parse(x.responseText);el.className=r.online?'ch-st online':'ch-st offline'}catch(e){el.className='ch-st offline'}};x.send('action=check_channel&url='+encodeURIComponent(u))}
function checkAll(){var vis=getVisible();vis.forEach(function(r){var i=r.getAttribute('data-idx'),u=r.getAttribute('data-url');if(u)checkCh(i,u)})}
var PS=150,CP=0,allRows=[],allCh=[];
function esc(s){if(!s)return'';return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function renderRows(chs){
    var tb=document.getElementById('ch-tb'),h='';
    chs.forEach(function(c){
        var li=c.l?'<img src="'+esc(c.l)+'" style="width:20px;height:20px;border-radius:3px;object-fit:contain;vertical-align:middle;margin-right:4px" onerror="this.style.display=\'none\'">':'';
        h+='<tr data-group="'+esc(c.g)+'" data-name="'+esc(c.n)+'" data-idx="'+c.i+'" data-url="'+esc(c.u)+'"><td><span class="ch-st unknown" id="st-'+c.i+'"></span></td><td class="ch-n">'+li+esc(c.n)+'</td><td class="ch-g">'+esc(c.g)+'</td><td class="ch-p">—</td><td><button class="b bsm bp" onclick="checkCh('+c.i+',\''+esc(c.u).replace(/'/g,"\\'")+'\')">Пинг</button></td><td><button class="b bsm bo" onclick="editCh('+c.i+')">Изм.</button></td></tr>'
    });
    tb.innerHTML=h;
    allRows=[];tb.querySelectorAll('tr').forEach(function(r){allRows.push(r)});
    document.getElementById('ch-loading').style.display='none';
    document.getElementById('ch-wrap').style.display='block';
    document.getElementById('pager').style.display='flex';
    goPage(0)
}
function getVisible(){var g=document.getElementById('f-g').value,s=document.getElementById('f-s').value.toLowerCase();return allRows.filter(function(r){var rg=r.getAttribute('data-group'),rn=r.getAttribute('data-name').toLowerCase();return(!g||rg===g)&&(!s||rn.indexOf(s)>=0)})}
function renderPager(){
    var vis=getVisible(),total=vis.length,pages=Math.ceil(total/PS);
    var pg=document.getElementById('pager');
    if(pages<=1){pg.innerHTML='<span class="pg-info">'+total+' каналов</span>';return}
    var h='<button class="pg" onclick="goPage(CP-1)"'+(CP===0?' disabled':'')+'>‹</button>';
    for(var i=0;i<pages;i++){
        if(pages>15&&Math.abs(i-CP)>3&&i!==0&&i!==pages-1){if(i===1||i===pages-2)h+='<span class="pg-info">…</span>';continue}
        h+='<button class="pg'+(i===CP?' a':'')+'" onclick="goPage('+i+')">'+(i+1)+'</button>'
    }
    h+='<button class="pg" onclick="goPage(CP+1)"'+(CP===pages-1?' disabled':'')+'>›</button>';
    h+='<span class="pg-info">'+(CP*PS+1)+'–'+Math.min((CP+1)*PS,total)+' из '+total+'</span>';
    pg.innerHTML=h
}
function goPage(n){
    var vis=getVisible(),pages=Math.ceil(vis.length/PS);
    if(n<0||n>=pages)return;CP=n;
    allRows.forEach(function(r){r.style.display='none'});
    vis.forEach(function(r,i){if(i>=CP*PS&&i<(CP+1)*PS)r.style.display=''})
    renderPager()
}
function filterCh(){CP=0;goPage(0)}
function editCh(i){
    var c=allCh.find(function(x){return x.i===i});if(!c)return;
    document.getElementById('e-n').value=c.n;document.getElementById('e-u').value=c.u;document.getElementById('e-g').value=c.g;
    document.getElementById('em').classList.add('open');document.getElementById('em').setAttribute('data-idx',i)
}
function closeModal(){document.getElementById('em').classList.remove('open')}
function saveEdit(){var i=document.getElementById('em').getAttribute('data-idx'),u=document.getElementById('e-u').value,g=document.getElementById('e-g').value,x=new XMLHttpRequest();x.open('POST',API,true);x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');x.onload=function(){try{var r=JSON.parse(x.responseText);if(r.status==='ok'){toast('Сохранено','ok');closeModal();setTimeout(function(){location.reload()},1000)}else toast(r.message,'err')}catch(e){toast('Ошибка','err')}};x.send('action=update_channel&idx='+i+'&new_url='+encodeURIComponent(u)+'&new_group='+encodeURIComponent(g))}
function setPlUrl(){var u=document.getElementById('pl-u').value;if(!u){toast('Введите ссылку','err');return}act('set_playlist_url','url='+encodeURIComponent(u))}
function setEpgUrl(){var u=document.getElementById('epg-u').value;if(!u){toast('Введите ссылку','err');return}act('set_epg_url','url='+encodeURIComponent(u))}
function saveSched(){var p=document.getElementById('s-pl').value,e=document.getElementById('s-epg').value;act('set_schedule','playlist_interval='+p+'&epg_interval='+e)}
function loadRaw(){var x=new XMLHttpRequest();x.open('GET','/playlist.m3u',true);x.onload=function(){document.getElementById('pl-r').value=x.responseText};x.send()}
// Load channels from JSON
(function(){
    var x=new XMLHttpRequest();x.open('GET','/channels.json',true);
    x.onload=function(){
        try{allCh=JSON.parse(x.responseText);renderRows(allCh)}
        catch(e){document.getElementById('ch-loading').innerHTML='Ошибка загрузки каналов'}
    };
    x.onerror=function(){document.getElementById('ch-loading').innerHTML='Ошибка сети'};
    x.send()
})();
function editCh(i){var r=document.querySelector('#ch-tb tr[data-idx="'+i+'"]');document.getElementById('e-n').value=r.getAttribute('data-name');document.getElementById('e-u').value=r.getAttribute('data-url');document.getElementById('e-g').value=r.getAttribute('data-group');document.getElementById('em').classList.add('open');document.getElementById('em').setAttribute('data-idx',i)}
function closeModal(){document.getElementById('em').classList.remove('open')}
function saveEdit(){var i=document.getElementById('em').getAttribute('data-idx'),u=document.getElementById('e-u').value,g=document.getElementById('e-g').value,x=new XMLHttpRequest();x.open('POST',API,true);x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');x.onload=function(){try{var r=JSON.parse(x.responseText);if(r.status==='ok'){toast('Сохранено','ok');closeModal();setTimeout(function(){location.reload()},1000)}else toast(r.message,'err')}catch(e){toast('Ошибка','err')}};x.send('action=update_channel&idx='+i+'&new_url='+encodeURIComponent(u)+'&new_group='+encodeURIComponent(g))}
function setPlUrl(){var u=document.getElementById('pl-u').value;if(!u){toast('Введите ссылку','err');return}act('set_playlist_url','url='+encodeURIComponent(u))}
function setEpgUrl(){var u=document.getElementById('epg-u').value;if(!u){toast('Введите ссылку','err');return}act('set_epg_url','url='+encodeURIComponent(u))}
function saveSched(){var p=document.getElementById('s-pl').value,e=document.getElementById('s-epg').value;act('set_schedule','playlist_interval='+p+'&epg_interval='+e)}
function loadRaw(){var x=new XMLHttpRequest();x.open('GET','/playlist.m3u',true);x.onload=function(){document.getElementById('pl-r').value=x.responseText};x.send()}
</script>
</body>
</html>
HTMLEND
CGIEOF
    chmod +x /www/iptv/cgi-bin/admin.cgi
}

# ==========================================
# Scheduler
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
                url) wget -q --timeout=15 --no-check-certificate -O "$D/playlist.m3u" "$PLAYLIST_URL" 2>/dev/null;;
                file) [ -f "$PLAYLIST_SOURCE" ] && cp "$PLAYLIST_SOURCE" "$D/playlist.m3u";;
            esac
            NT=$(date '+%d.%m.%Y %H:%M')
            printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$NT" "$EPG_LAST_UPDATE" > "$D/schedule.conf"
            mkdir -p /www/iptv; [ -f "$D/playlist.m3u" ] && cp "$D/playlist.m3u" /www/iptv/playlist.m3u
        }
    fi
    if [ "${EPG_INTERVAL:-0}" -gt 0 ] 2>/dev/null; then
        L=$(date -d "$EPG_LAST_UPDATE" +%s 2>/dev/null || echo 0)
        [ "$(( (N-L)/3600 ))" -ge "$EPG_INTERVAL" ] && {
            . "$D/epg.conf" 2>/dev/null
            [ -n "$EPG_URL" ] && wget -q --timeout=30 --no-check-certificate -O "$D/epg.xml" "$EPG_URL" 2>/dev/null && [ -s "$D/epg.xml" ] && {
                NT=$(date '+%d.%m.%Y %H:%M')
                printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$NT" > "$D/schedule.conf"
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
stop_scheduler() { kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null; rm -f /var/run/iptv-scheduler.pid /tmp/iptv-scheduler.sh; }

# ==========================================
# HTTP Server
# ==========================================
start_http_server() {
    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then echo_success "Сервер уже запущен: http://$LAN_IP:$IPTV_PORT/"; return; fi
    if [ ! -f "$PLAYLIST_FILE" ]; then echo_error "Плейлист не найден!"; PAUSE; return 1; fi
    mkdir -p /www/iptv/cgi-bin
    cp "$PLAYLIST_FILE" /www/iptv/playlist.m3u
    [ -f "$EPG_FILE" ] && cp "$EPG_FILE" /www/iptv/epg.xml
    generate_cgi
    kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null; sleep 1
    uhttpd -f -p "0.0.0.0:$IPTV_PORT" -h /www/iptv -x /cgi-bin -i ".cgi=/bin/sh" &
    echo $! > "$HTTPD_PID"
    echo_success "Сервер запущен!"
    echo_info "Админка: http://$LAN_IP:$IPTV_PORT/cgi-bin/admin.cgi"
    echo_info "Плейлист: http://$LAN_IP:$IPTV_PORT/playlist.m3u"
    echo_info "EPG: http://$LAN_IP:$IPTV_PORT/epg.xml"
}
stop_http_server() { kill $(cat "$HTTPD_PID" 2>/dev/null) 2>/dev/null; kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null; rm -f "$HTTPD_PID"; echo_success "Сервер остановлен"; }

# ==========================================
# SSH Actions
# ==========================================
load_playlist_url() {
    echo_color "Загрузка плейлиста"
    echo -ne "${YELLOW}URL: ${NC}"; read PLAYLIST_URL </dev/tty
    [ -z "$PLAYLIST_URL" ] && { echo_error "URL пуст!"; PAUSE; return 1; }
    echo_info "Скачиваем..."
    if wget $(wget_opt) -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null && [ -s "$PLAYLIST_FILE" ]; then
        local ch=$(get_ch); echo_success "Загружен! Каналов: $ch"
        save_config "url" "$PLAYLIST_URL" ""
        local now=$(get_ts); load_sched; save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
        start_http_server
    else echo_error "Не удалось скачать!"; PAUSE; return 1; fi
}
load_playlist_file() {
    echo_color "Загрузка из файла"
    echo -ne "${YELLOW}Путь: ${NC}"; read FP </dev/tty
    [ -z "$FP" ] && { echo_error "Путь пуст!"; PAUSE; return 1; }
    [ ! -f "$FP" ] && { echo_error "Файл не найден: $FP"; PAUSE; return 1; }
    cp "$FP" "$PLAYLIST_FILE"; local ch=$(get_ch); echo_success "Загружен! Каналов: $ch"
    save_config "file" "" "$FP"
    local now=$(get_ts); load_sched; save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
    start_http_server
}
setup_provider() {
    echo_color "Настройка провайдера"
    echo -ne "${YELLOW}Название: ${NC}"; read PN </dev/tty
    echo -ne "${YELLOW}Логин: ${NC}"; read PL2 </dev/tty
    echo -ne "${YELLOW}Пароль: ${NC}"; stty -echo; read PP </dev/tty; stty echo; echo ""
    [ -z "$PN" ] || [ -z "$PL2" ] || [ -z "$PP" ] && { echo_error "Все поля обязательны!"; PAUSE; return 1; }
    printf 'PROVIDER_NAME=%s\nPROVIDER_LOGIN=%s\nPROVIDER_PASS=%s\nPROVIDER_SERVER=http://%s\n' "$PN" "$PL2" "$PP" "$PN" > "$PROVIDER_CONFIG"
    local pu="http://$PN/get.php?username=$PL2&password=$PP&type=m3u_plus&output=ts"
    echo_info "Получаем плейлист..."
    if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$pu" 2>/dev/null && [ -s "$PLAYLIST_FILE" ]; then
        local ch=$(get_ch); echo_success "Загружен! Провайдер: $PN, Каналов: $ch"
        save_config "provider" "$pu" "$PN"
        local now=$(get_ts); load_sched; save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
        start_http_server
    else echo_error "Ошибка!"; PAUSE; return 1; fi
}
do_update_playlist() {
    load_config
    case "$PLAYLIST_TYPE" in
        url) wget $(wget_opt) -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null && { local ch=$(get_ch); local now=$(get_ts); load_sched; save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"; echo_success "Обновлён! Каналов: $ch"; } || echo_error "Ошибка!" ;;
        provider) [ -f "$PROVIDER_CONFIG" ] && { . "$PROVIDER_CONFIG"; local pu="http://${PROVIDER_SERVER:-$PROVIDER_NAME}/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"; wget -q --timeout=15 -O "$PLAYLIST_FILE" "$pu" 2>/dev/null && { local ch=$(get_ch); local now=$(get_ts); load_sched; save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"; echo_success "Обновлён! Каналов: $ch"; } || echo_error "Ошибка!"; } ;;
    esac
}
setup_epg() {
    echo_color "Настройка EPG"; load_epg
    [ -n "$EPG_URL" ] && echo_info "Текущий EPG: $EPG_URL"
    # Проверяем встроенный EPG из плейлиста
    local builtin=$(detect_builtin_epg)
    if [ -n "$builtin" ]; then
        echo -e "${CYAN}В плейлисте найден встроенный EPG:${NC} $builtin"
        echo -e "${YELLOW}1) ${GREEN}Скачать встроенный EPG${NC}"
        echo -e "${YELLOW}2) ${GREEN}Указать свою ссылку${NC}"
        echo -e "${YELLOW}Enter) ${GREEN}Пропустить${NC}"
        echo -ne "${YELLOW}> ${NC}"; read choice </dev/tty
        case "$choice" in
            1)
                echo_info "Скачиваем $builtin ..."
                if wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EPG_FILE" "$builtin" 2>/dev/null && [ -s "$EPG_FILE" ]; then
                    local sz=$(file_size "$EPG_FILE")
                    echo_success "Загружен! Размер: $sz"
                    printf 'EPG_URL="%s"\n' "$builtin" > "$EPG_CONFIG"
                    local now=$(get_ts); load_sched; save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
                    start_http_server
                else echo_error "Не удалось скачать!"; PAUSE; return 1; fi
                ;;
            2)
                echo -ne "${YELLOW}EPG URL: ${NC}"; read EPG_URL </dev/tty
                [ -z "$EPG_URL" ] && { echo_info "Отмена"; return 1; }
                echo_info "Скачиваем..."
                if wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EPG_FILE" "$EPG_URL" 2>/dev/null && [ -s "$EPG_FILE" ]; then
                    local sz=$(file_size "$EPG_FILE"); echo_success "Загружен! Размер: $sz"
                    printf 'EPG_URL="%s"\n' "$EPG_URL" > "$EPG_CONFIG"
                    local now=$(get_ts); load_sched; save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
                    start_http_server
                else echo_error "Не удалось скачать!"; PAUSE; return 1; fi
                ;;
            *) echo_info "Пропущено"; return 1 ;;
        esac
    else
        echo -ne "${YELLOW}EPG URL: ${NC}"; read EPG_URL </dev/tty
        [ -z "$EPG_URL" ] && { echo_info "Отмена"; return 1; }
        echo_info "Скачиваем..."
        if wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EPG_FILE" "$EPG_URL" 2>/dev/null && [ -s "$EPG_FILE" ]; then
            local sz=$(file_size "$EPG_FILE"); echo_success "Загружен! Размер: $sz"
            printf 'EPG_URL="%s"\n' "$EPG_URL" > "$EPG_CONFIG"
            local now=$(get_ts); load_sched; save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
            start_http_server
        else echo_error "Не удалось скачать!"; PAUSE; return 1; fi
    fi
}
do_update_epg() {
    load_epg; [ -z "$EPG_URL" ] && { echo_error "EPG не настроен!"; return 1; }
    if wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EPG_FILE" "$EPG_URL" 2>/dev/null && [ -s "$EPG_FILE" ]; then
        local sz=$(file_size "$EPG_FILE"); local now=$(get_ts); load_sched; save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
        echo_success "Обновлён! Размер: $sz"
    else echo_error "Ошибка!"; return 1; fi
}
remove_epg() { rm -f "$EPG_FILE" "$EPG_CONFIG"; echo_success "EPG удалён"; }
setup_schedule() {
    load_sched; echo_color "Расписание"
    echo_info "Плейлист: $(int_text $PLAYLIST_INTERVAL) | EPG: $(int_text $EPG_INTERVAL)"
    echo -e "  ${CYAN}0) Выкл  1) Каждый час  2) Каждые 6ч  3) Каждые 12ч  4) Раз в сутки${NC}"
    echo -ne "${YELLOW}Плейлист (0-4): ${NC}"; read pi </dev/tty
    case "$pi" in 0|1) PLAYLIST_INTERVAL=$pi;; 2) PLAYLIST_INTERVAL=6;; 3) PLAYLIST_INTERVAL=12;; 4) PLAYLIST_INTERVAL=24;; *) PLAYLIST_INTERVAL=0;; esac
    echo -ne "${YELLOW}EPG (0-4): ${NC}"; read ei </dev/tty
    case "$ei" in 0|1) EPG_INTERVAL=$ei;; 2) EPG_INTERVAL=6;; 3) EPG_INTERVAL=12;; 4) EPG_INTERVAL=24;; *) EPG_INTERVAL=0;; esac
    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$EPG_LAST_UPDATE"
    if [ "$PLAYLIST_INTERVAL" -gt 0 ] || [ "$EPG_INTERVAL" -gt 0 ]; then start_scheduler; echo_success "Планировщик запущен"
    else stop_scheduler; echo_success "Расписание отключено"; fi
}
remove_playlist() { rm -f "$PLAYLIST_FILE" "$CONFIG_FILE" "$PROVIDER_CONFIG"; stop_http_server; echo_success "Удалено"; }
setup_autostart() {
    if [ -f /etc/init.d/iptv-manager ]; then /etc/init.d/iptv-manager disable 2>/dev/null; rm -f /etc/init.d/iptv-manager; echo_success "Автозапуск отключён"
    else
        cat > /etc/init.d/iptv-manager <<'INITEOF'
#!/bin/sh /etc/rc.common
START=99
start() {
    mkdir -p /www/iptv/cgi-bin
    [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u
    [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml
    [ -f /etc/iptv/IPTV-Manager.sh ] && . /etc/iptv/IPTV-Manager.sh 2>/dev/null
    uhttpd -f -p 0.0.0.0:8082 -h /www/iptv -x /cgi-bin -i ".cgi=/bin/sh" &
    [ -f /etc/iptv/schedule.conf ] && { . /etc/iptv/schedule.conf; [ "${PLAYLIST_INTERVAL:-0}" -gt 0 ] || [ "${EPG_INTERVAL:-0}" -gt 0 ] && /bin/sh /tmp/iptv-scheduler.sh &; }
}
stop() { kill $(pgrep -f "uhttpd.*8082" 2>/dev/null) 2>/dev/null; kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null; }
INITEOF
        chmod +x /etc/init.d/iptv-manager; /etc/init.d/iptv-manager enable 2>/dev/null; echo_success "Автозапуск включён"
    fi
}
uninstall() {
    echo_color "Полное удаление IPTV Manager"
    echo -ne "${YELLOW}Вы уверены? Все данные будут удалены! (y/N): ${NC}"; read ans </dev/tty
    case "$ans" in y|Y|yes|Yes) ;; *) echo_info "Отмена"; return 1;; esac
    echo_info "Останавливаем сервисы..."; stop_http_server; stop_scheduler
    echo_info "Удаляем файлы..."
    rm -rf /etc/iptv /www/iptv
    rm -f /var/run/iptv-httpd.pid /var/run/iptv-scheduler.pid /tmp/iptv-scheduler.sh /tmp/iptv-edit.m3u /tmp/iptv-group-opts.txt
    [ -f /etc/init.d/iptv-manager ] && { /etc/init.d/iptv-manager disable 2>/dev/null; rm -f /etc/init.d/iptv-manager; }
    echo_success "IPTV Manager полностью удалён"; echo_info "Для выхода введите Enter"
}

# ==========================================
# Menu
# ==========================================
show_menu() {
    clear; load_sched
    echo -e "${MAGENTA}╔══════════════════════════════════════════╗"
    echo -e "║     IPTV Manager v$IPTV_MANAGER_VERSION                  ║"
    echo -e "╠══════════════════════════════════════════╣"
    echo -e "║${NC} IP: ${CYAN}$LAN_IP  Port: ${CYAN}$IPTV_PORT                    ${MAGENTA}║"
    echo -e "╚══════════════════════════════════════════╝${NC}"
    echo ""
    load_config
    echo -e "${CYAN}Плейлист:${NC} $([ "$PLAYLIST_TYPE" = "url" ] && echo "$PLAYLIST_URL" || echo "$PLAYLIST_TYPE")"
    load_epg
    local display_epg="не настроен"
    [ -n "$EPG_URL" ] && display_epg=$(echo "$EPG_URL" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
    echo -e "${CYAN}EPG:${NC} $display_epg"
    echo -e "${CYAN}Расписание:${NC} Плейлист=$(int_text $PLAYLIST_INTERVAL) | EPG=$(int_text $EPG_INTERVAL)"
    [ -n "$PLAYLIST_LAST_UPDATE" ] && echo -e "${CYAN}Обновлён:${NC} $PLAYLIST_LAST_UPDATE"
    echo ""
    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then echo_success "Сервер: http://$LAN_IP:$IPTV_PORT/cgi-bin/admin.cgi"
    else echo_error "Сервер: остановлен"; fi
    echo ""
    echo -e "${YELLOW}── Плейлист ──────────────────────────${NC}"
    echo -e "${CYAN} 1) ${GREEN}Загрузить по ссылке${NC}"
    echo -e "${CYAN} 2) ${GREEN}Загрузить из файла${NC}"
    echo -e "${CYAN} 3) ${GREEN}Настроить провайдера${NC}"
    echo -e "${CYAN} 4) ${GREEN}Обновить плейлист${NC}"
    echo ""
    echo -e "${YELLOW}── Телепрограмма ─────────────────────${NC}"
    echo -e "${CYAN} 5) ${GREEN}Настроить EPG${NC}"
    echo -e "${CYAN} 6) ${GREEN}Обновить EPG${NC}"
    echo -e "${CYAN} 7) ${GREEN}Удалить EPG${NC}"
    echo ""
    echo -e "${YELLOW}── Сервер ────────────────────────────${NC}"
    echo -e "${CYAN} 8) ${GREEN}Запустить${NC}"
    echo -e "${CYAN} 9) ${GREEN}Остановить${NC}"
    echo ""
    echo -e "${YELLOW}── Настройки ─────────────────────────${NC}"
    echo -e "${CYAN}10) ${GREEN}Расписание обновлений${NC}"
    echo -e "${CYAN}11) ${GREEN}Автозапуск${NC}"
    echo ""
    echo -e "${YELLOW}── Удаление ──────────────────────────${NC}"
    echo -e "${CYAN}12) ${GREEN}Удалить плейлист${NC}"
    echo -e "${RED} 13) ${RED}Удалить IPTV Manager${NC}"
    echo ""
    echo -e "${CYAN}Enter) ${GREEN}Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"; read c </dev/tty
    case "$c" in
        1) load_playlist_url;; 2) load_playlist_file;; 3) setup_provider;;
        4) do_update_playlist;; 5) setup_epg;; 6) do_update_epg;; 7) remove_epg;;
        8) start_http_server;; 9) stop_http_server;;
        10) setup_schedule;; 11) setup_autostart;;
        12) remove_playlist;; 13) uninstall;; *) echo_info "Выход"; exit 0;;
    esac
    PAUSE
}

while true; do show_menu; done
