#!/bin/sh
# ==========================================
# IPTV Manager — CGI module
# Генерация admin.cgi (API only, HTML из файла)
# ==========================================

cgi_generate_admin() {
    local output="${1:-/www/iptv/cgi-bin/admin.cgi}"
    mkdir -p "$(dirname "$output")" || { log_error "Failed to create CGI dir"; return 1; }

    cat > "$output" << 'ADMINCGI'
#!/bin/sh
# IPTV Manager Admin CGI — v3.21 (API only)
PL="/etc/iptv/playlist.m3u"
EC="/etc/iptv/iptv.conf"
EGZ="/tmp/iptv-epg.xml.gz"
EXC="/etc/iptv/epg.conf"
SC="/etc/iptv/schedule.conf"
FAV="/etc/iptv/favorites.json"
SEC="/etc/iptv/security.conf"
IPTV_PORT="${IPTV_PORT:-8082}"
GITHUB_REPO="${GITHUB_REPO:-whatuneeed/IPTV-Manager}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

wget_opt() { local o="-q --timeout=15"; wget --help 2>&1 | grep -q "no-check-certificate" && o="$o --no-check-certificate"; echo "$o"; }
hdr() { printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'; }
json_hdr() { printf 'Content-Type: application/json\r\n\r\n'; }

_validate_cgi_url() { case "$1" in http://*|https://*|rtsp://*|rtmp://*|udp://*|rtp://*) return 0;;*) return 1;;esac; }
_sanitize_cgi_str() { printf '%s' "$1" | tr -cd '[:print:]' | head -c 500; }
_sanitize_cgi_idx() { case "$1" in ''|*[!0-9]*) echo "0";;*) echo "$1";;esac; }

auth_fail() { printf 'HTTP/1.0 401 Unauthorized\r\nWWW-Authenticate: Basic realm="IPTV Manager"\r\nContent-Type: text/html\r\n\r\n<html><body><h1>401</h1></body></html>\r\n'; exit 0; }

check_auth() {
    [ -f "$SEC" ] || return
    . "$SEC" 2>/dev/null
    [ -z "$ADMIN_USER" ] && [ -z "$ADMIN_PASS" ] && return
    AUTH="${HTTP_AUTHORIZATION:-}"
    case "$AUTH" in
        Basic\ *)
            _b64=$(echo "$AUTH" | sed 's/Basic //')
            CREDS=$(echo "$_b64" | busybox base64 -d 2>/dev/null) || \
            CREDS=$(echo "$_b64" | openssl enc -base64 -d 2>/dev/null) || \
            CREDS=$(echo "$_b64" | base64 -d 2>/dev/null) || \
            CREDS=""
            U=$(echo "$CREDS" | cut -d: -f1); P=$(echo "$CREDS" | cut -d: -f2-)
            [ "$U" = "$ADMIN_USER" ] && [ "$P" = "$ADMIN_PASS" ] && return ;;
    esac
    auth_fail
}

check_api_token() {
    [ -f "$SEC" ] || return
    . "$SEC" 2>/dev/null
    [ -z "$API_TOKEN" ] && return
    [ "${HTTP_X_API_TOKEN:-}" = "$API_TOKEN" ] && return
    auth_fail
}

# Source catchup module if available
[ -f /etc/iptv/lib/catchup.sh ] && . /etc/iptv/lib/catchup.sh 2>/dev/null

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
            URL=$(_sanitize_cgi_str "$URL")
            if ! _validate_cgi_url "$URL"; then
                printf '{"status":"error","message":"Неверный формат URL"}'
            else
                case "$URL" in
                    http*|https*) wget -q --timeout=8 -O - --header="User-Agent: VLC/3.0" "$URL" 2>/dev/null | grep -q "EXTM3U" && printf '{"status":"ok","online":true}' || printf '{"status":"ok","online":false}';;
                    udp*|rtp*) printf '{"status":"ok","online":true}';;
                    *) printf '{"status":"ok","online":false}';;
                esac
            fi ;;

        update_channel)
            IDX=$(echo "$POST_DATA" | sed -n 's/.*idx=\([^&]*\).*/\1/p')
            IDX=$(_sanitize_cgi_idx "$IDX")
            NURL=$(echo "$POST_DATA" | sed -n 's/.*new_url=\([^&]*\).*/\1/p')
            NGRP=$(echo "$POST_DATA" | sed -n 's/.*new_group=\([^&]*\).*/\1/p')
            NURL=$(echo "$NURL" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            NURL=$(_sanitize_cgi_str "$NURL")
            NGRP=$(_sanitize_cgi_str "$NGRP")
            if [ -n "$IDX" ] && [ -n "$NURL" ] && _validate_cgi_url "$NURL"; then
                TMP="/tmp/iptv-edit.m3u"; echo "#EXTM3U" > "$TMP"; I=0
                while IFS= read -r L; do
                    case "$L" in
                        "#EXTINF:"*) [ "$I" -eq "$IDX" ] 2>/dev/null && [ -n "$NGRP" ] && L=$(echo "$L" | sed "s/group-title=\"[^\"]*\"/group-title=\"$NGRP\"/"); echo "$L" >> "$TMP" ;;
                        http*|https*|rtsp*|rtmp*|udp*|rtp*) [ "$I" -eq "$IDX" ] 2>/dev/null && echo "$NURL" >> "$TMP" || echo "$L" >> "$TMP"; I=$((I + 1)) ;;
                        *) echo "$L" >> "$TMP" ;;
                    esac
                done < "$PL"
                cp "$TMP" "$PL" && cp "$PL" /www/iptv/playlist.m3u
                printf '{"status":"ok","message":"Канал обновлён"}'
            else
                printf '{"status":"error","message":"Неверные данные"}'
            fi ;;

        refresh_playlist)
            . "$EC" 2>/dev/null
            case "$PLAYLIST_TYPE" in
                url) wget $(wget_opt) -O "$PL" "$PLAYLIST_URL" 2>/dev/null && [ -s "$PL" ] && {
                    CH=$(grep -c "^#EXTINF" "$PL" 2>/dev/null || true)
                    cp "$PL" /www/iptv/playlist.m3u
                    [ -f /etc/iptv/lib/catchup.sh ] && . /etc/iptv/lib/catchup.sh 2>/dev/null
                    catchup_enrich_channels_json "$PL" /www/iptv/channels.json 2>/dev/null || true
                    printf '{"status":"ok","message":"Плейлист обновлён! Каналов: %s"}' "$CH"
                } || printf '{"status":"error","message":"Ошибка загрузки"}' ;;
                *) printf '{"status":"error","message":"Невозможно обновить"}' ;;
            esac ;;

        refresh_epg)
            . "$EXC" 2>/dev/null
            if [ -n "$EPG_URL" ]; then
                TD="/tmp/epg-dl.tmp"; _ok=false; _trials=0
                while [ "$_trials" -lt 3 ] && [ "$_ok" = "false" ]; do
                    wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$TD" "$EPG_URL" 2>/dev/null && [ -s "$TD" ] && {
                        M=$(hexdump -n 2 -e '2/1 "%02x"' "$TD" 2>/dev/null)
                        [ "$M" = "1f8b" ] && cp "$TD" "$EGZ" || gzip -c "$TD" > "$EGZ" 2>/dev/null
                        rm -f "$TD"; _ok=true
                    }
                    _trials=$((_trials + 1)); [ "$_ok" = "false" ] && sleep 5
                done
                [ "$_ok" = "true" ] && [ -f "$EGZ" ] && [ -s "$EGZ" ] && {
                    SZ=$(wc -c < "$EGZ"); SZKB=$((SZ / 1024))
                    printf '{"status":"ok","message":"EPG обновлён! gz: %s KB"}' "$SZKB"
                } || printf '{"status":"error","message":"Ошибка EPG"}'
            else printf '{"status":"error","message":"EPG URL не задан"}'; fi ;;

        set_playlist_url)
            NU=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            NU=$(echo "$NU" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            NU=$(_sanitize_cgi_str "$NU")
            if [ -n "$NU" ] && _validate_cgi_url "$NU"; then
                printf 'PLAYLIST_TYPE="url"\nPLAYLIST_URL="%s"\nPLAYLIST_SOURCE=""\n' "$NU" > "$EC"
                wget $(wget_opt) -O "$PL" "$NU" 2>/dev/null && [ -s "$PL" ] && {
                    CH=$(grep -c "^#EXTINF" "$PL" 2>/dev/null || true)
                    cp "$PL" /www/iptv/playlist.m3u
                    printf '{"status":"ok","message":"Плейлист загружен! Каналов: %s"}' "$CH"
                } || printf '{"status":"error","message":"Ошибка загрузки"}'
            else printf '{"status":"error","message":"Укажите корректный URL"}'; fi ;;

        set_epg_url)
            NU=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            NU=$(echo "$NU" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
            NU=$(_sanitize_cgi_str "$NU")
            if [ -n "$NU" ] && _validate_cgi_url "$NU"; then
                printf 'EPG_URL="%s"\n' "$NU" > "$EXC"
                TD="/tmp/epg-dl.tmp"
                wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$TD" "$NU" 2>/dev/null && [ -s "$TD" ] && {
                    M=$(hexdump -n 2 -e '2/1 "%02x"' "$TD" 2>/dev/null)
                    [ "$M" = "1f8b" ] && cp "$TD" "$EGZ" || gzip -c "$TD" > "$EGZ" 2>/dev/null
                    rm -f "$TD"; printf '{"status":"ok","message":"EPG загружен"}'
                } || { rm -f "$TD"; printf '{"status":"error","message":"Ошибка загрузки EPG"}'; }
            else printf '{"status":"error","message":"Укажите корректный URL"}'; fi ;;

        set_schedule)
            PI=$(echo "$POST_DATA" | sed -n 's/.*playlist_interval=\([^&]*\).*/\1/p')
            EI=$(echo "$POST_DATA" | sed -n 's/.*epg_interval=\([^&]*\).*/\1/p')
            [ -z "$PI" ] && PI=0; [ -z "$EI" ] && EI=0
            printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\n' "$PI" "$EI" > "$SC"
            printf '{"status":"ok","message":"Расписание сохранено"}' ;;

        set_playlist_name)
            NM=$(echo "$POST_DATA" | sed -n 's/.*name=\([^&]*\).*/\1/p')
            NM=$(_sanitize_cgi_str "$NM")
            if [ -n "$NM" ]; then
                printf 'PLAYLIST_NAME="%s"\n' "$NM" >> "$EC"
                printf '{"status":"ok","message":"Название сохранено"}'
            else printf '{"status":"error","message":"Укажите название"}'; fi ;;

        get_epg)
            if [ -f "$EGZ" ]; then
                now_ts=$(date '+%Y%m%d%H%M%S' 2>/dev/null)
                rows=$(gunzip -c "$EGZ" 2>/dev/null | awk -v now="$now_ts" 'BEGIN{printf "[";f=1;c=0}/<programme /{s=$0;st="";ch="";if(match(s,/start="[0-9]+/))st=substr(s,RSTART+7,RLENGTH-7);if(match(s,/channel="[^"]+"/))ch=substr(s,RSTART+9,RLENGTH-9)}/<title/{t=$0;if(match(t,/<title[^>]*>[^<]*<\/title>/)){t=substr(t,RSTART,RLENGTH);gsub(/<[^>]*>/,"",t);ti=t}}/<\/programme>/{if(ti!=""&&ch!=""&&st!=""){if(!f)printf ",";f=0;gsub(/"/,"\\\"",ti);gsub(/"/,"\\\"",ch);printf "{\"t\":\"%s:%s\",\"c\":\"%s\",\"p\":\"%s\"}",substr(st,9,2),substr(st,11,2),ch,ti;c++;if(c>=50)exit}ti=""}END{printf "]"}' 2>/dev/null)
                printf '{"status":"ok","rows":%s}' "$rows"
            else printf '{"status":"ok","rows":[]}'; fi ;;

        toggle_favorite)
            IDX=$(echo "$POST_DATA" | sed -n 's/.*idx=\([^&]*\).*/\1/p')
            IDX=$(_sanitize_cgi_idx "$IDX")
            [ -f "$FAV" ] || echo "[]" > "$FAV"
            if grep -q "\"$IDX\"" "$FAV" 2>/dev/null; then
                awk -v idx="$IDX" 'BEGIN{RS=",";ORS=""}{gsub(/[\[\]]/,"");gsub(/"/,"");if($0!=idx)print (NR>1?",":"")$0}' "$FAV" > /tmp/fav_tmp.json
                printf '[%s]' "$(cat /tmp/fav_tmp.json)" > "$FAV"
                printf '{"status":"ok","fav":false}'
            else
                if [ "$(cat "$FAV")" = "[]" ]; then printf '["%s"]' "$IDX" > "$FAV"
                else sed -i "s/\]/,\"$IDX\"\]/" "$FAV"; fi
                printf '{"status":"ok","fav":true}'
            fi ;;

        get_favorites)
            [ -f "$FAV" ] || echo "[]" > "$FAV"
            printf '{"status":"ok","favorites":%s}' "$(cat "$FAV")" ;;

        set_security)
            U=$(echo "$POST_DATA" | sed -n 's/.*user=\([^&]*\).*/\1/p')
            P=$(echo "$POST_DATA" | sed -n 's/.*pass=\([^&]*\).*/\1/p')
            U=$(_sanitize_cgi_str "$U"); P=$(_sanitize_cgi_str "$P")
            cur_token=$(grep API_TOKEN "$SEC" 2>/dev/null | sed 's/.*="//;s/"//' || true)
            if [ -n "$U" ] && [ -n "$P" ]; then
                printf 'ADMIN_USER="%s"\nADMIN_PASS="%s"\nAPI_TOKEN="%s"\n' "$U" "$P" "$cur_token" > "$SEC"
                printf '{"status":"ok","message":"Пароль установлен"}'
            else
                printf 'ADMIN_USER=""\nADMIN_PASS=""\nAPI_TOKEN="%s"\n' "$cur_token" > "$SEC"
                printf '{"status":"ok","message":"Авторизация отключена"}'
            fi ;;

        set_token)
            T=$(echo "$POST_DATA" | sed -n 's/.*token=\([^&]*\).*/\1/p')
            T=$(_sanitize_cgi_str "$T")
            cur_user=$(grep ADMIN_USER "$SEC" 2>/dev/null | sed 's/.*="//;s/"//' || true)
            cur_pass=$(grep ADMIN_PASS "$SEC" 2>/dev/null | sed 's/.*="//;s/"//' || true)
            printf 'ADMIN_USER="%s"\nADMIN_PASS="%s"\nAPI_TOKEN="%s"\n' "$cur_user" "$cur_pass" "$T" > "$SEC"
            printf '{"status":"ok","message":"Токен сохранён"}' ;;

        check_update)
            CUR="${IPTV_MANAGER_VERSION:-3.21}"
            LATEST=$(wget -q --timeout=5 -O - "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/main/IPTV-Manager.sh" 2>/dev/null | head -10 | grep -o 'IPTV_MANAGER_VERSION="[^"]*"' | sed 's/IPTV_MANAGER_VERSION="//;s/"//')
            [ -n "$LATEST" ] && [ "$LATEST" != "$CUR" ] && _upd=true || _upd=false
            printf '{"status":"ok","update":%s,"current":"%s","latest":"%s"}' "$_upd" "$CUR" "${LATEST:-$CUR}" ;;

        system_info)
            _up=$(cat /proc/uptime 2>/dev/null | cut -d. -f1)
            _d=$((_up / 86400)); _h=$(((_up % 86400) / 3600)); _m=$(((_up % 3600) / 60))
            _uptxt=""; [ "$_d" -gt 0 ] && _uptxt="${_d}д "; _uptxt="${_uptxt}${_h}ч ${_m}м"
            _mem_total=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null)
            _mem_free=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null)
            [ -z "$_mem_free" ] && _mem_free=$(awk '/MemFree/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null)
            _mem_used=$((_mem_total - _mem_free))
            _disk_total=$(df / 2>/dev/null | awk 'NR==2{print $2}')
            _disk_used=$(df / 2>/dev/null | awk 'NR==2{print $3}')
            _disk_pct=$(df / 2>/dev/null | awk 'NR==2{print $5}')
            printf '{"status":"ok","uptime":"%s","mem_total":"%sMB","mem_used":"%sMB","disk_total":"%s","disk_used":"%s","disk_pct":"%s"}' "$_uptxt" "$_mem_total" "$_mem_used" "$_disk_total" "$_disk_used" "$_disk_pct"
            ;;

        server_start) printf '{"status":"ok"}'; (sleep 1; /etc/iptv/IPTV-Manager.sh start >/dev/null 2>&1) & ;;
        server_stop) printf '{"status":"ok"}'; (sleep 3; kill "$(pgrep -f "uhttpd.*8082")" 2>/dev/null || true; rm -f /var/run/iptv-httpd.pid) & ;;
        server_status)
            if [ -f /var/run/iptv-httpd.pid ] && kill -0 "$(cat /var/run/iptv-httpd.pid 2>/dev/null)" 2>/dev/null; then
                printf '{"status":"ok","output":"running"}'
            else printf '{"status":"ok","output":"stopped"}'; fi ;;

        backup)
            BF="/tmp/iptv-backup-$(date +%Y%m%d%H%M%S).tar.gz"
            tar czf "$BF" -C /etc iptv 2>/dev/null
            if [ -f "$BF" ]; then
                SZ=$(wc -c < "$BF")
                printf 'Content-Type: application/gzip\r\nContent-Disposition: attachment; filename="iptv-backup.tar.gz"\r\nContent-Length: %s\r\n\r\n' "$SZ"
                cat "$BF"; rm -f "$BF"
            else printf '{"status":"error","message":"Ошибка бэкапа"}'; fi ;;

        import)
            TF="/tmp/iptv-restore.tar.gz"
            if [ "$CL" -gt 0 ] 2>/dev/null; then
                dd bs=1 count="$CL" 2>/dev/null > "$TF"
                tar xzf "$TF" -C / 2>/dev/null && {
                    mkdir -p /www/iptv/cgi-bin
                    [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u
                    printf '{"status":"ok","message":"Бэкап восстановлен"}'
                } || printf '{"status":"error","message":"Ошибка восстановления"}'
                rm -f "$TF"
            else printf '{"status":"error","message":"Нет данных"}'; fi ;;

        validate_playlist)
            VU=$(echo "$POST_DATA" | sed -n 's/.*url=\([^&]*\).*/\1/p')
            VU=$(_sanitize_cgi_str "$VU")
            if [ -n "$VU" ] && _validate_cgi_url "$VU"; then
                if wget -q --spider --timeout=10 --no-check-certificate "$VU" 2>/dev/null; then
                    VCH=$(wget -q --timeout=10 --no-check-certificate -O - "$VU" 2>/dev/null | grep -c "^#EXTINF" || true)
                    printf '{"status":"ok","valid":true,"channels":"%s"}' "$VCH"
                else printf '{"status":"ok","valid":false}'; fi
            else printf '{"status":"error","message":"Укажите URL"}'; fi ;;

        merge_playlists)
            MP=$(echo "$POST_DATA" | sed -n 's/.*urls=\([^&]*\).*/\1/p')
            MP=$(echo "$MP" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g;s/+/ /g')
            echo "#EXTM3U" > /tmp/iptv-merged.m3u
            for _u in $MP; do
                _u=$(echo "$_u" | sed 's/%2F/\//g;s/%3A/:/g')
                wget -q --timeout=15 --no-check-certificate -O /tmp/_ipl.m3u "$_u" 2>/dev/null && grep "^#\|^http" /tmp/_ipl.m3u >> /tmp/iptv-merged.m3u 2>/dev/null
            done
            _mc=$(grep -c "^#EXTINF" /tmp/iptv-merged.m3u 2>/dev/null || true)
            cp /tmp/iptv-merged.m3u "$PL" 2>/dev/null && cp "$PL" /www/iptv/playlist.m3u 2>/dev/null
            printf '{"status":"ok","merged_channels":"%s"}' "${_mc:-0}" ;;

        set_whitelist)
            WL=$(echo "$POST_DATA" | sed -n 's/.*ips=\([^&]*\).*/\1/p')
            WL=$(echo "$WL" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g;s/+/ /g')
            if [ -n "$WL" ]; then echo "$WL" | tr ' ' '\n' | grep -v '^$' > "/etc/iptv/ip_whitelist.txt"
            else > "/etc/iptv/ip_whitelist.txt"; fi
            printf '{"status":"ok","message":"Список IP обновлён"}' ;;

        get_catchup_url)
            [ -f /etc/iptv/lib/catchup.sh ] && . /etc/iptv/lib/catchup.sh 2>/dev/null
            catchup_get_url "$POST_DATA" 2>/dev/null || printf '{"status":"error","message":"Catchup not available"}' ;;

        auto_update_keep)
            printf 'Content-Type: application/json\r\n\r\n{"status":"ok","message":"Обновление..."}'
            ( sleep 1; TMPN="/tmp/IPTV-Manager-new.sh"
              wget -q --timeout=30 --no-check-certificate -O "$TMPN" "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/main/IPTV-Manager.sh" 2>/dev/null
              [ -s "$TMPN" ] && {
                  kill "$(pgrep -f "uhttpd.*8082")" 2>/dev/null || true; sleep 1
                  for _cf in iptv.conf epg.conf schedule.conf security.conf favorites.json playlist.m3u; do cp "/etc/iptv/$_cf" "/tmp/_save_$_cf" 2>/dev/null; done
                  cp "$TMPN" /etc/iptv/IPTV-Manager.sh && chmod +x /etc/iptv/IPTV-Manager.sh && rm -f "$TMPN"
                  for _cf in iptv.conf epg.conf schedule.conf security.conf favorites.json playlist.m3u; do [ -f "/tmp/_save_$_cf" ] && cp "/tmp/_save_$_cf" "/etc/iptv/$_cf"; done
                  rm -f /tmp/_save_*
                  /etc/iptv/IPTV-Manager.sh start >/dev/null 2>&1 &
              }
            ) </dev/null >/dev/null 2>&1 &
            sleep 1; exit 0 ;;

        factory_reset)
            printf 'Content-Type: application/json\r\n\r\n{"status":"ok","message":"Сброс..."}'
            ( sleep 2
              kill "$(pgrep -f "uhttpd.*8082")" 2>/dev/null || true
              rm -f /etc/iptv/iptv.conf /etc/iptv/epg.conf /etc/iptv/schedule.conf /etc/iptv/security.conf /etc/iptv/favorites.json /etc/iptv/provider.conf /etc/iptv/playlist.m3u
              wget -q --timeout=30 --no-check-certificate -O /tmp/iptv-reset-new.sh "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/main/IPTV-Manager.sh" 2>/dev/null && [ -s /tmp/iptv-reset-new.sh ] && { cp /tmp/iptv-reset-new.sh /etc/iptv/IPTV-Manager.sh; chmod +x /etc/iptv/IPTV-Manager.sh; }
              rm -f /tmp/iptv-reset-new.sh /tmp/iptv-started
              /etc/iptv/IPTV-Manager.sh start >/dev/null 2>&1 &
            ) </dev/null >/dev/null 2>&1 &
            sleep 1; exit 0 ;;

        *) printf '{"status":"error","message":"Unknown action: %s"}' "$ACTION" ;;
    esac
    exit 0
fi

# Health check — без авторизации
case "$ACTION" in
    health)
        json_hdr
        _srv="stopped"; wget -q --timeout=2 -O /dev/null "http://127.0.0.1:${IPTV_PORT:-8082}/" 2>/dev/null && _srv="ok"
        _pl="missing"; [ -f /etc/iptv/playlist.m3u ] && [ -s /etc/iptv/playlist.m3u ] && _pl="ok"
        _epg="missing"; [ -f /tmp/iptv-epg.xml.gz ] && [ -s /tmp/iptv-epg.xml.gz ] && _epg="ok"
        _uptxt="--"
        if [ -f /tmp/iptv-start.ts ]; then
            _sn=$(cat /tmp/iptv-start.ts 2>/dev/null); _now=$(date +%s)
            [ -n "$_sn" ] && [ "$_sn" -lt "$_now" ] 2>/dev/null && {
                _diff=$((_now - _sn)); _id=$((_diff / 86400)); _ih=$(((_diff % 86400) / 3600)); _im=$(((_diff % 3600) / 60))
                _uptxt=""; [ "$_id" -gt 0 ] && _uptxt="${_id}d "; _uptxt="${_uptxt}${_ih}h ${_im}m"
            }
        fi
        printf '{"status":"ok","server":"%s","playlist":"%s","epg":"%s","uptime":"%s"}' "$_srv" "$_pl" "$_epg" "$_uptxt"
        exit 0 ;;
esac

# Serve admin.html (with config variable substitution)
hdr
if [ -f /www/iptv/admin.html ]; then
    # Load config for template substitution
    . /etc/iptv/iptv.conf 2>/dev/null || true
    . /etc/iptv/epg.conf 2>/dev/null || true
    . /etc/iptv/schedule.conf 2>/dev/null || true
    _pi="${PLAYLIST_INTERVAL:-0}"
    _ei="${EPG_INTERVAL:-0}"
    _plu="${PLAYLIST_LAST_UPDATE:----}"
    _elu="${EPG_LAST_UPDATE:----}"
    _pname="${PLAYLIST_NAME:-}"
    _purl="${PLAYLIST_URL:-}"
    _eurl="${EPG_URL:-}"
    _ver="$IPTV_MANAGER_VERSION"
    sed -e "s|__PI__|$_pi|g" \
        -e "s|__EI__|$_ei|g" \
        -e "s|__PLU__|$_plu|g" \
        -e "s|__ELU__|$_elu|g" \
        -e "s|__PNAME__|$_pname|g" \
        -e "s|__PURL__|$_purl|g" \
        -e "s|__EURL__|$_eurl|g" \
        -e "s|__VER__|$_ver|g" \
        /www/iptv/admin.html
else
    echo "<h1>IPTV Manager</h1><p>admin.html not found.</p>"
fi
ADMINCGI

    chmod +x "$output" || log_error "Failed to chmod admin.cgi"
    log_info "Admin CGI generated: $output (API only, HTML from file)"
}

# Сгенерировать epg.cgi
cgi_generate_epg() {
    local output="${1:-/www/iptv/cgi-bin/epg.cgi}"
    mkdir -p "$(dirname "$output")" || return 1

    cat > "$output" << 'EPGCGI'
#!/bin/sh
EGZ="/tmp/iptv-epg.xml.gz"
if [ -f "$EGZ" ]; then
    printf 'Content-Type: text/xml; charset=utf-8\r\n\r\n'
    gunzip -c "$EGZ" 2>/dev/null
else
    printf 'Content-Type: text/xml\r\n\r\n<?xml version="1.0"?><tv></tv>'
fi
EPGCGI
    chmod +x "$output"
}
