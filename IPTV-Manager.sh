#!/bin/sh
# ==========================================
# IPTV Manager для OpenWrt v3.6
# ==========================================

IPTV_MANAGER_VERSION="3.6"
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
[ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"
[ -f "$EPG_CONFIG" ] || touch "$EPG_CONFIG"
[ -f "$SCHEDULE_FILE" ] || touch "$SCHEDULE_FILE"

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
# Генерация CGI
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
    local grp_count=$(echo "$groups" | grep -c . 2>/dev/null || echo 0)
    local hd_count=$(grep -ci "hd\|1080\|4k\|2160\|uhd" "$PLAYLIST_FILE" 2>/dev/null || echo 0)
    local sd_count=$((ch - hd_count))

    # Генерация JSON каналов через awk
    mkdir -p /www/iptv
    if [ -f "$PLAYLIST_FILE" ]; then
        awk '
        BEGIN {
            printf "["
            first = 1
            idx = 0
        }
        /#EXTINF:/ {
            name = ""
            grp = ""
            logo = ""
            tvgid = ""
            n = $0
            if (match(n, /,/)) {
                name = substr(n, RSTART + 1)
                gsub(/^[ \t]+/, "", name)
                gsub(/[ \t]+$/, "", name)
            }
            if (match(n, /group-title="[^"]*"/)) {
                grp = substr(n, RSTART + 12, RLENGTH - 13)
            }
            if (match(n, /tvg-id="[^"]*"/)) {
                tvgid = substr(n, RSTART + 9, RLENGTH - 10)
            }
            if (match(n, /tvg-logo="[^"]*"/)) {
                logo = substr(n, RSTART + 11, RLENGTH - 12)
            }
            if (name == "") name = "Неизвестный"
            if (grp == "") grp = "Общее"
            next
        }
        /^http/ {
            url = $0
            _out()
        }
        /^https/ {
            url = $0
            _out()
        }
        /^rtsp/ {
            url = $0
            _out()
        }
        /^rtmp/ {
            url = $0
            _out()
        }
        /^udp/ {
            url = $0
            _out()
        }
        /^rtp/ {
            url = $0
            _out()
        }
        function _out() {
            gsub(/\\/, "\\\\", name)
            gsub(/"/, "\\\"", name)
            gsub(/\\/, "\\\\", grp)
            gsub(/"/, "\\\"", grp)
            gsub(/\\/, "\\\\", logo)
            gsub(/"/, "\\\"", logo)
            gsub(/\\/, "\\\\", tvgid)
            gsub(/"/, "\\\"", tvgid)
            gsub(/\\/, "\\\\", url)
            gsub(/"/, "\\\"", url)
            if (!first) printf ","
            first = 0
            printf "{\"n\":\"%s\",\"g\":\"%s\",\"l\":\"%s\",\"i\":\"%s\",\"u\":\"%s\"}", name, grp, logo, tvgid, url
            idx++
            if (idx >= 5000) exit
        }
        END {
            printf "]"
        }
        ' "$PLAYLIST_FILE" > /www/iptv/channels.json 2>/dev/null
    else
        echo "[]" > /www/iptv/channels.json
    fi

    # Опции групп для HTML
    local group_opts=""
    if [ -n "$groups" ]; then
        group_opts=$(echo "$groups" | while IFS= read -r g; do [ -n "$g" ] && echo "<option value=\"$g\">$g</option>"; done)
    fi

    # EPG сейчас-играет
    local now_ts=$(date '+%Y%m%d%H%M%S' 2>/dev/null)
    local epg_rows=""
    if [ -f "$EPG_FILE" ]; then
        epg_rows=$(awk -v now="$now_ts" '
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
        ' "$EPG_FILE" 2>/dev/null)
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
IPTV_MANAGER_VERSION="3.6"
PL="/etc/iptv/playlist.m3u"
EC="/etc/iptv/iptv.conf"
EF="/etc/iptv/epg.xml"
EXC="/etc/iptv/epg.conf"
SC="/etc/iptv/schedule.conf"
wget_opt() { local o="-q --timeout=15"; wget --help 2>&1 | grep -q "no-check-certificate" && o="$o --no-check-certificate"; echo "$o"; }
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
                mkdir -p /www/iptv
                cp "$PL" /www/iptv/playlist.m3u
                printf '{"status":"ok","message":"Канал обновлён"}'
            else
                printf '{"status":"error","message":"Неверные данные"}'
            fi ;;
        refresh_playlist)
            . "$EC" 2>/dev/null
            case "$PLAYLIST_TYPE" in
                url)
                    wget $(wget_opt) -O "$PL" "$PLAYLIST_URL" 2>/dev/null && [ -s "$PL" ] && {
                        CH=$(grep -c "^#EXTINF" "$PL")
                        mkdir -p /www/iptv
                        cp "$PL" /www/iptv/playlist.m3u
                        printf '{"status":"ok","message":"Плейлист обновлён! Каналов: %s"}' "$CH"
                    } || printf '{"status":"error","message":"Ошибка загрузки"}' ;;
                *) printf '{"status":"error","message":"Невозможно обновить"}' ;;
            esac ;;
        refresh_epg)
            . "$EXC" 2>/dev/null
            if [ -n "$EPG_URL" ]; then
                wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EF" "$EPG_URL" 2>/dev/null && [ -s "$EF" ] && {
                    M=$(hexdump -n 2 -e '2/1 "%02x"' "$EF" 2>/dev/null)
                    [ "$M" = "1f8b" ] && { gunzip -f "$EF" 2>/dev/null; mv "${EF%.gz}" "$EF" 2>/dev/null; }
                    case "$EPG_URL" in *.gz) gunzip -f "$EF" 2>/dev/null; mv "${EF%.gz}" "$EF" 2>/dev/null ;; esac
                    SZ=$(wc -c < "$EF")
                    mkdir -p /www/iptv
                    cp "$EF" /www/iptv/epg.xml
                    printf '{"status":"ok","message":"EPG обновлён! Размер: %s KB"}' "$((SZ / 1024))"
                } || printf '{"status":"error","message":"Ошибка загрузки EPG"}'
            else
                printf '{"status":"error","message":"EPG URL не задан"}'
            fi ;;
        set_playlist_url)
            NU=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            NU=$(echo "$NU" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            if [ -n "$NU" ]; then
                printf 'PLAYLIST_TYPE="url"\nPLAYLIST_URL="%s"\nPLAYLIST_SOURCE=""\n' "$NU" > "$EC"
                wget $(wget_opt) -O "$PL" "$NU" 2>/dev/null && [ -s "$PL" ] && {
                    CH=$(grep -c "^#EXTINF" "$PL")
                    mkdir -p /www/iptv
                    cp "$PL" /www/iptv/playlist.m3u
                    printf '{"status":"ok","message":"Плейлист загружен! Каналов: %s"}' "$CH"
                } || printf '{"status":"error","message":"Ошибка загрузки"}'
            else
                printf '{"status":"error","message":"Укажите URL"}'
            fi ;;
        set_epg_url)
            NU=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            NU=$(echo "$NU" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            if [ -n "$NU" ]; then
                printf 'EPG_URL="%s"\n' "$NU" > "$EXC"
                wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EF" "$NU" 2>/dev/null && [ -s "$EF" ] && {
                    M=$(hexdump -n 2 -e '2/1 "%02x"' "$EF" 2>/dev/null)
                    [ "$M" = "1f8b" ] && { gunzip -f "$EF" 2>/dev/null; mv "${EF%.gz}" "$EF" 2>/dev/null; }
                    case "$NU" in *.gz) gunzip -f "$EF" 2>/dev/null; mv "${EF%.gz}" "$EF" 2>/dev/null ;; esac
                    SZ=$(wc -c < "$EF")
                    mkdir -p /www/iptv
                    cp "$EF" /www/iptv/epg.xml
                    printf '{"status":"ok","message":"EPG загружен! Размер: %s KB"}' "$((SZ / 1024))"
                } || printf '{"status":"error","message":"Ошибка загрузки EPG"}'
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
        *) printf '{"status":"error","message":"Неизвестное действие"}' ;;
    esac
    exit 0
fi

hdr
CH=$(grep -c "^#EXTINF" "$PL" 2>/dev/null || echo 0)
PSZ="---"
ESZ="---"
if [ -f "$PL" ]; then PSZ=$(cat "$PL" | wc -c); PSZ="$((PSZ/1024)) KB"; fi
if [ -f "$EF" ]; then ESZ=$(cat "$EF" | wc -c); ESZ="$((ESZ/1024)) KB"; fi
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
echo "$GROUPS" | while IFS= read -r g; do [ -n "$g" ] && echo "<option value=\"$g\">$g</option>"; done > /tmp/iptv-go2.txt
GOPTS=$(cat /tmp/iptv-go2.txt 2>/dev/null)
rm -f /tmp/iptv-go2.txt
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"
EPGROWS=""
[ -f "$EF" ] && EPGROWS=$(awk '/<programme /{s=$0;if(match(s,/start="[0-9]+/)){st=substr(s,RSTART+7,RLENGTH-7);if(match(s,/channel="[^"]+"/)){ch=substr(s,RSTART+9,RLENGTH-9)}}}/<title/{t=$0;if(match(t,/<title[^>]*>[^<]*<\/title>/)){t=substr(t,RSTART,RLENGTH);gsub(/<[^>]*>/,"",t);ti=t}}/<\/programme>/{if(ti!=""&&ch!=""&&st!=""){printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n",substr(st,9,2)":"substr(st,11,2),ch,ti;c++;if(c>=30)exit}ti=""}' "$EF" 2>/dev/null)

mkdir -p /www/iptv
if [ -f "$PL" ]; then
    awk '
    BEGIN { printf "["; first=1; idx=0 }
    /#EXTINF:/ {
        name=""; grp=""; logo=""; tvgid=""; n=$0
        if(match(n,/,/)){name=substr(n,RSTART+1);gsub(/^[ \t]+/,"",name);gsub(/[ \t]+$/,"",name)}
            if(match(n,/group-title="[^"]*"/)){grp=substr(n,RSTART+13,RLENGTH-14)}
            if(match(n,/tvg-id="[^"]*"/)){tvgid=substr(n,RSTART+9,RLENGTH-10)}
            if(match(n,/tvg-logo="[^"]*"/)){logo=substr(n,RSTART+11,RLENGTH-12)}
        if(name=="")name="Неизвестный"; if(grp=="")grp="Общее"; next
    }
    /^http/||/^https/||/^rtsp/||/^rtmp/||/^udp/||/^rtp/{
        url=$0; gsub(/\\/,"\\\\",name); gsub(/"/,"\\\"",name); gsub(/\\/,"\\\\",grp); gsub(/"/,"\\\"",grp)
        gsub(/\\/,"\\\\",logo); gsub(/"/,"\\\"",logo); gsub(/\\/,"\\\\",tvgid); gsub(/"/,"\\\"",tvgid)
        gsub(/\\/,"\\\\",url); gsub(/"/,"\\\"",url)
        if(!first)printf ","; first=0
        printf "{\"n\":\"%s\",\"g\":\"%s\",\"l\":\"%s\",\"i\":\"%s\",\"u\":\"%s\"}",name,grp,logo,tvgid,url
        idx++; if(idx>=5000)exit
    }
    END { printf "]" }
    ' "$PL" > /www/iptv/channels.json 2>/dev/null
else
    echo "[]" > /www/iptv/channels.json
fi

groups=""
[ -f "$PL" ] && groups=$(grep -o 'group-title="[^"]*"' "$PL" | sed 's/group-title="//;s/"//' | sort -u)
grp_count=$(echo "$groups" | grep -c . 2>/dev/null || echo 0)
hd_count=$(grep -ci "hd\|1080\|4k\|2160\|uhd" "$PL" 2>/dev/null || echo 0)
sd_count=$((CH - hd_count))

group_opts=""
if [ -n "$groups" ]; then
    group_opts=$(echo "$groups" | while IFS= read -r g; do [ -n "$g" ] && echo "<option value=\"$g\">$g</option>"; done)
fi

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
@media(max-width:700px){.st{grid-template-columns:1fr 1fr}.sg{grid-template-columns:1fr}.h{flex-direction:column;gap:10px}.fb{flex-direction:column}}
</style>
</head>
<body>
<div class="c">
<div class="h"><div><h1>IPTV Manager</h1><p>OpenWrt v$IPTV_MANAGER_VERSION</p></div><button class="tt" id="ttb" onclick="toggleTheme()">🌙 Тема</button></div>
<div class="st">
<div class="s"><div class="sv">$CH</div><div class="sl">Каналов</div></div>
<div class="s"><div class="sv">$psz</div><div class="sl">Плейлист</div></div>
<div class="s"><div class="sv">$esz</div><div class="sl">EPG</div></div>
<div class="s"><div class="sv">$grp_count</div><div class="sl">Групп</div></div>
<div class="s"><div class="sv">$hd_count</div><div class="sl">HD</div></div>
<div class="s"><div class="sv">$sd_count</div><div class="sl">SD</div></div>
</div>
<div class="ub"><code>http://$LAN_IP:$IPTV_PORT/playlist.m3u</code><button onclick="cp(this)">Копировать</button></div>
<div class="ub"><code>http://$LAN_IP:$IPTV_PORT/epg.xml</code><button onclick="cp(this)">Копировать</button></div>
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
<button class="b bp bsm" onclick="checkAll()">Проверить все</button>
<button class="b bs bsm" onclick="watchAll()">▶ Смотреть всё</button>
</div>
<div style="overflow-x:auto">
<table class="ch-t">
<thead><tr><th style="width:20px"></th><th>Название</th><th>Группа</th><th>Сейчас играет</th><th style="width:70px">Пинг</th><th style="width:40px"></th><th>Действия</th></tr></thead>
<tbody id="ch-tb"><tr><td colspan="7" class="loading">Загрузка каналов...</td></tbody>
</table>
</div>
<div id="pager" style="display:flex;justify-content:center;align-items:center;gap:6px;margin-top:12px;flex-wrap:wrap"></div>
</div>
<div class="pn" id="p-playlist">
<h2>Плейлист</h2>
<div class="fg"><label>Ссылка на плейлист</label><input type="url" id="pl-u" placeholder="http://example.com/playlist.m3u" value="$purl"><div class="hint">Вставьте ссылку на M3U/M3U8 плейлист</div></div>
<div class="bg"><button class="b bp" onclick="setPlUrl()">Применить</button><button class="b bs" onclick="act('refresh_playlist','')">Обновить</button></div>
<hr>
<h3>Исходный M3U</h3>
<div class="fg"><textarea id="pl-r" readonly style="min-height:200px"></textarea></div>
</div>
<div class="pn" id="p-epg">
<h2>Телепрограмма (EPG)</h2>
$epg_notice
<div class="fg"><label>Ссылка на EPG (XMLTV)</label><input type="url" id="epg-u" placeholder="https://iptvx.one/EPG.XML" value="$eurl"><div class="hint">Поддерживаются XML и XML.gz. Распаковка автоматическая.</div></div>
<div class="bg"><button class="b bp" onclick="setEpgUrl()">Применить</button><button class="b bs" onclick="act('refresh_epg','')">Обновить</button></div>
<hr>
<h3>Передачи</h3>
<div style="overflow-x:auto">
<table class="epg-t">
<thead><tr><th>Время</th><th>Канал</th><th>Передача</th></tr></thead>
<tbody>$epg_rows</tbody>
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
<div class="si">Последнее: <span>$plu</span></div>
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
<div class="si">Последнее: <span>$elu</span></div>
</div>
</div>
<div class="bg"><button class="b bp bsm" onclick="saveSched()">Сохранить</button></div>
<hr>
<h3>Бэкап и восстановление</h3>
<div class="sg">
<div class="sc">
<h3>Экспорт</h3>
<div class="si">Скачать архив со всеми настройками, плейлистом и EPG</div>
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
var PS=150,CP=0,filteredRows=[];

function toggleTheme(){
    var d=document.documentElement,t=d.getAttribute('data-theme')==='dark'?'light':'dark';
    d.setAttribute('data-theme',t);
    document.getElementById('ttb').innerHTML=t==='dark'?'☀️ Тема':'🌙 Тема';
    try{localStorage.setItem('iptv-theme',t)}catch(e){}
}
(function(){
    try{
        var t=localStorage.getItem('iptv-theme');
        if(t==='dark'){document.documentElement.setAttribute('data-theme','dark');document.getElementById('ttb').innerHTML='☀️ Тема'}
    }catch(e){}
})();

function st(t,e){
    document.querySelectorAll('.t').forEach(function(x){x.classList.remove('a')});
    document.querySelectorAll('.pn').forEach(function(x){x.classList.remove('a')});
    document.getElementById('p-'+t).classList.add('a');
    e.classList.add('a');
    if(t==='playlist')loadRaw();
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

function act(a,p){
    var x=new XMLHttpRequest();
    x.open('POST',API,true);
    x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
    x.onload=function(){
        try{
            var r=JSON.parse(x.responseText);
            if(r.status==='ok'){toast(r.message,'ok');setTimeout(function(){location.reload()},1500)}
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
    act('set_epg_url','url='+encodeURIComponent(u));
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
        tb.innerHTML='<tr><td colspan="7" class="loading">Нет каналов</td></tr>';
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
        html+='<tr>';
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
        if(show){ch._idx=i;filteredRows.push(ch)}
    }
    CP=0;
    renderRows();
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
    x.open('GET','/epg.xml',true);
    x.onload=function(){
        try{
            var xml=x.responseXML;
            if(!xml)return;
            var now=new Date();
            var nowStr=now.getFullYear()+('0'+(now.getMonth()+1)).slice(-2)+('0'+now.getDate()).slice(-2)+('0'+now.getHours()).slice(-2)+('0'+now.getMinutes()).slice(-2)+('0'+now.getSeconds()).slice(-2);
            var progs=xml.getElementsByTagName('programme');
            for(var i=0;i<progs.length;i++){
                var p=progs[i];
                var start=p.getAttribute('start');
                var stop=p.getAttribute('stop');
                var ch=p.getAttribute('channel');
                var titleEl=p.getElementsByTagName('title')[0];
                var title=titleEl?titleEl.textContent:'';
                if(start&&stop&&start<=nowStr&&stop>=nowStr&&ch&&title){
                    epgMap[ch]=title;
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
</script>
</body>
</html>
HTMLEND
CGIEOF
    chmod +x /www/iptv/cgi-bin/admin.cgi
    generate_player
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
:root{--bg:#0f172a;--panel:#1e293b;--border:#334155;--text:#e2e8f0;--text2:#94a3b8;--text3:#64748b;--accent:#3b82f6;--accent2:#2563eb;--hover:#334155;--active:#1e3a5f;--green:#22c55e;--red:#ef4444}
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
#video-wrap{flex:1;display:flex;align-items:center;justify-content:center;background:#000;position:relative}
video{width:100%;height:100%;background:#000}
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
#sb-search{padding:6px 12px;border-bottom:1px solid var(--border)}
#sb-search input{width:100%;padding:7px 10px;background:var(--bg);border:1px solid var(--border);border-radius:5px;color:var(--text);font-size:12px}
#sb-search input:focus{outline:none;border-color:var(--accent)}
#sb-group{padding:4px 12px 6px;border-bottom:1px solid var(--border)}
#sb-group select{width:100%;padding:5px 8px;background:var(--bg);border:1px solid var(--border);border-radius:5px;color:var(--text);font-size:12px}
#sb-pl{padding:8px 12px;border-bottom:1px solid var(--border);display:none}
#sb-pl input{width:100%;padding:7px 10px;background:var(--bg);border:1px solid var(--border);border-radius:5px;color:var(--text);font-size:12px;margin-bottom:6px}
#sb-pl button{width:100%;padding:6px;background:var(--green);border:none;border-radius:5px;color:#fff;font-weight:600;cursor:pointer;font-size:12px}
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
var hls=null,channels=[],filtered=[],curIdx=-1,epgData={},curMode='ch';

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
        h+='<div class="ch'+(ch._r===curIdx?' on':'')+'" onclick="play(\''+esc(ch.u).replace(/'/g,"\\'")+'\','+ch._r+')">';
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
        if((!g||ch.g===g)&&(!q||ch.n.toLowerCase().indexOf(q)>=0)){
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
    document.getElementById('sb-search').style.display=m==='ch'?'':'none';
    document.getElementById('sb-group').style.display=m==='ch'?'':'none';
    document.getElementById('sb-pl').style.display=m==='pl'?'':'none';
    if(m==='ch')filter();
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

var params=new URLSearchParams(window.location.search);
var sUrl=params.get('url'),sIdx=params.get('idx'),pUrl=params.get('pl');
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
            mkdir -p /www/iptv
            [ -f "$D/playlist.m3u" ] && cp "$D/playlist.m3u" /www/iptv/playlist.m3u
        }
    fi
    if [ "${EPG_INTERVAL:-0}" -gt 0 ] 2>/dev/null; then
        L=$(date -d "$EPG_LAST_UPDATE" +%s 2>/dev/null || echo 0)
        [ "$(( (N-L)/3600 ))" -ge "$EPG_INTERVAL" ] && {
            . "$D/epg.conf" 2>/dev/null
            [ -n "$EPG_URL" ] && wget -q --timeout=30 --no-check-certificate -O "$D/epg.xml" "$EPG_URL" 2>/dev/null && [ -s "$D/epg.xml" ] && {
                NT=$(date '+%d.%m.%Y %H:%M')
                printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$NT" > "$D/schedule.conf"
                mkdir -p /www/iptv
                cp "$D/epg.xml" /www/iptv/epg.xml 2>/dev/null
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
    cp "$PLAYLIST_FILE" /www/iptv/playlist.m3u
    [ -f "$EPG_FILE" ] && cp "$EPG_FILE" /www/iptv/epg.xml
    generate_cgi
    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then
        echo_success "Сервер обновлён: http://$LAN_IP:$IPTV_PORT/"
        return
    fi
    if [ ! -f "$PLAYLIST_FILE" ]; then
        echo_error "Плейлист не найден!"
        PAUSE
        return 1
    fi
    kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null
    sleep 1
    uhttpd -f -p "0.0.0.0:$IPTV_PORT" -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" &
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
                if wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EPG_FILE" "$builtin" 2>/dev/null && [ -s "$EPG_FILE" ]; then
                    local sz=$(file_size "$EPG_FILE")
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
                if wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EPG_FILE" "$EPG_URL" 2>/dev/null && [ -s "$EPG_FILE" ]; then
                    local sz=$(file_size "$EPG_FILE")
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
        if wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EPG_FILE" "$EPG_URL" 2>/dev/null && [ -s "$EPG_FILE" ]; then
            local sz=$(file_size "$EPG_FILE")
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
    if wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$EPG_FILE" "$EPG_URL" 2>/dev/null && [ -s "$EPG_FILE" ]; then
        local sz=$(file_size "$EPG_FILE")
        local now=$(get_ts)
        load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
        echo_success "Обновлён! Размер: $sz"
    else
        echo_error "Ошибка!"
        return 1
    fi
}

remove_epg() { rm -f "$EPG_FILE" "$EPG_CONFIG"; echo_success "EPG удалён"; }

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
        cat > /etc/init.d/iptv-manager <<'INITEOF'
#!/bin/sh /etc/rc.common
START=99
start() {
    mkdir -p /www/iptv/cgi-bin
    [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u
    [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml
    [ -f /etc/iptv/IPTV-Manager.sh ] && . /etc/iptv/IPTV-Manager.sh 2>/dev/null
    uhttpd -f -p 0.0.0.0:8082 -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" &
    [ -f /etc/iptv/schedule.conf ] && { . /etc/iptv/schedule.conf; [ "${PLAYLIST_INTERVAL:-0}" -gt 0 ] || [ "${EPG_INTERVAL:-0}" -gt 0 ] && /bin/sh /tmp/iptv-scheduler.sh &; }
}
stop() { kill $(pgrep -f "uhttpd.*8082" 2>/dev/null) 2>/dev/null; kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null; }
INITEOF
        chmod +x /etc/init.d/iptv-manager
        /etc/init.d/iptv-manager enable 2>/dev/null
        echo_success "Автозапуск включён"
    fi
}

uninstall() {
    echo_color "Полное удаление IPTV Manager"
    echo -ne "${YELLOW}Вы уверены? Все данные будут удалены! (y/N): ${NC}"
    read ans </dev/tty
    case "$ans" in y|Y|yes|Yes) ;; *) echo_info "Отмена"; return 1 ;; esac
    echo_info "Останавливаем сервисы..."
    stop_http_server
    stop_scheduler
    echo_info "Удаляем файлы..."
    rm -rf /etc/iptv /www/iptv
    rm -f /var/run/iptv-httpd.pid /var/run/iptv-scheduler.pid /tmp/iptv-scheduler.sh /tmp/iptv-edit.m3u /tmp/iptv-group-opts.txt
    [ -f /etc/init.d/iptv-manager ] && { /etc/init.d/iptv-manager disable 2>/dev/null; rm -f /etc/init.d/iptv-manager; }
    echo_success "IPTV Manager полностью удалён"
    echo_info "Для выхода введите Enter"
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
    local display_epg="не настроен"
    [ -n "$EPG_URL" ] && display_epg=$(echo "$EPG_URL" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
    echo -e "${CYAN}EPG:${NC} $display_epg"
    echo -e "${CYAN}Расписание:${NC} Плейлист=$(int_text $PLAYLIST_INTERVAL) | EPG=$(int_text $EPG_INTERVAL)"
    [ -n "$PLAYLIST_LAST_UPDATE" ] && echo -e "${CYAN}Обновлён:${NC} $PLAYLIST_LAST_UPDATE"
    echo ""
    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then
        echo_success "Сервер: http://$LAN_IP:$IPTV_PORT/cgi-bin/admin.cgi"
    else
        echo_error "Сервер: остановлен"
    fi
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
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) load_playlist_url ;; 2) load_playlist_file ;; 3) setup_provider ;;
        4) do_update_playlist ;; 5) setup_epg ;; 6) do_update_epg ;; 7) remove_epg ;;
        8) start_http_server ;; 9) stop_http_server ;;
        10) setup_schedule ;; 11) setup_autostart ;;
        12) remove_playlist ;; 13) uninstall ;; *) echo_info "Выход"; exit 0 ;;
    esac
    PAUSE
}

while true; do show_menu; done
