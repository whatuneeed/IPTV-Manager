#!/bin/sh
# ==========================================
# IPTV Manager - Web Admin CGI v1.1
# ==========================================
# Веб-админ панель с EPG и расписанием
# ==========================================

IPTV_DIR="/etc/iptv"
PLAYLIST_FILE="$IPTV_DIR/playlist.m3u"
CONFIG_FILE="$IPTV_DIR/iptv.conf"
PROVIDER_CONFIG="$IPTV_DIR/provider.conf"
EPG_FILE="$IPTV_DIR/epg.xml"
EPG_CONFIG="$IPTV_DIR/epg.conf"
SCHEDULE_FILE="$IPTV_DIR/schedule.conf"
IPTV_PORT="8082"
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"

mkdir -p "$IPTV_DIR"

load_config() { [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"; }
load_epg_config() { [ -f "$EPG_CONFIG" ] && . "$EPG_CONFIG"; }
load_schedule() {
    if [ -f "$SCHEDULE_FILE" ]; then
        . "$SCHEDULE_FILE"
    else
        PLAYLIST_INTERVAL="0"; EPG_INTERVAL="0"
        PLAYLIST_LAST_UPDATE=""; EPG_LAST_UPDATE=""
    fi
}

get_channel_count() { [ -f "$PLAYLIST_FILE" ] && grep -c "^#EXTINF" "$PLAYLIST_FILE" 2>/dev/null || echo "0"; }
get_file_size() {
    [ -f "$1" ] || { echo "0 B"; return; }
    local s=$(wc -c < "$1" 2>/dev/null)
    if [ "$s" -gt 1048576 ]; then echo "$((s/1048576)) MB"
    elif [ "$s" -gt 1024 ]; then echo "$((s/1024)) KB"
    else echo "${s} B"; fi
}

interval_label() {
    case "$1" in
        0) echo "Выключено";; 1) echo "Каждый час";;
        6) echo "Каждые 6ч";; 12) echo "Каждые 12ч";; 24) echo "Раз в сутки";; *) echo "Выключено";;
    esac
}

httpd_running() {
    [ -f /var/run/iptv-httpd.pid ] && kill -0 $(cat /var/run/iptv-httpd.pid 2>/dev/null) 2>/dev/null
}

scheduler_running() {
    [ -f /var/run/iptv-scheduler.pid ] && kill -0 $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null
}

restart_httpd() {
    mkdir -p /www/iptv/cgi-bin
    cp "$PLAYLIST_FILE" /www/iptv/playlist.m3u 2>/dev/null
    [ -f "$EPG_FILE" ] && cp "$EPG_FILE" /www/iptv/epg.xml 2>/dev/null
    kill $(cat /var/run/iptv-httpd.pid 2>/dev/null) 2>/dev/null
    busybox httpd -p "$IPTV_PORT" -h /www/iptv -c '/cgi-bin/*.cgi' &
    echo $! > /var/run/iptv-httpd.pid
}

stop_httpd() { kill $(cat /var/run/iptv-httpd.pid 2>/dev/null) 2>/dev/null; rm -f /var/run/iptv-httpd.pid; }

start_scheduler() {
    stop_scheduler
    cat > /tmp/iptv-scheduler.sh <<'SCHEDEOF'
#!/bin/sh
IPTV_DIR="/etc/iptv"; PID_FILE="/var/run/iptv-scheduler.pid"
echo $$ > "$PID_FILE"
get_ts() { date '+%d.%m.%Y %H:%M' 2>/dev/null || echo ""; }
while true; do
    sleep 60
    [ ! -f "$IPTV_DIR/schedule.conf" ] && continue
    . "$IPTV_DIR/schedule.conf"
    now_epoch=$(date +%s 2>/dev/null || echo 0)
    if [ "$PLAYLIST_INTERVAL" -gt 0 ] 2>/dev/null; then
        last_epoch=$(date -d "$PLAYLIST_LAST_UPDATE" +%s 2>/dev/null || echo 0)
        diff_h=$(( (now_epoch - last_epoch) / 3600 ))
        if [ "$diff_h" -ge "$PLAYLIST_INTERVAL" ]; then
            . "$IPTV_DIR/iptv.conf" 2>/dev/null
            case "$PLAYLIST_TYPE" in
                url) wget -q --timeout=15 -O "$IPTV_DIR/playlist.m3u" "$PLAYLIST_URL" 2>/dev/null;;
                provider)
                    if [ -f "$IPTV_DIR/provider.conf" ]; then
                        . "$IPTV_DIR/provider.conf"
                        wget -q --timeout=15 -O "$IPTV_DIR/playlist.m3u" "http://$PROVIDER_NAME/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts" 2>/dev/null
                    fi;;
                file) [ -f "$PLAYLIST_SOURCE" ] && cp "$PLAYLIST_SOURCE" "$IPTV_DIR/playlist.m3u";;
            esac
            nt=$(get_ts)
            printf 'PLAYLIST_INTERVAL=%s\nEPG_INTERVAL=%s\nPLAYLIST_LAST_UPDATE=%s\nEPG_LAST_UPDATE=%s\n' \
                "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$nt" "$EPG_LAST_UPDATE" > "$IPTV_DIR/schedule.conf"
            mkdir -p /www/iptv; [ -f "$IPTV_DIR/playlist.m3u" ] && cp "$IPTV_DIR/playlist.m3u" /www/iptv/playlist.m3u
        fi
    fi
    if [ "$EPG_INTERVAL" -gt 0 ] 2>/dev/null; then
        last_epoch=$(date -d "$EPG_LAST_UPDATE" +%s 2>/dev/null || echo 0)
        diff_h=$(( (now_epoch - last_epoch) / 3600 ))
        if [ "$diff_h" -ge "$EPG_INTERVAL" ]; then
            . "$IPTV_DIR/epg.conf" 2>/dev/null
            if [ -n "$EPG_URL" ]; then
                wget -q --timeout=30 -O "$IPTV_DIR/epg.xml" "$EPG_URL" 2>/dev/null
                if [ -s "$IPTV_DIR/epg.xml" ]; then
                    nt=$(get_ts)
                    printf 'PLAYLIST_INTERVAL=%s\nEPG_INTERVAL=%s\nPLAYLIST_LAST_UPDATE=%s\nEPG_LAST_UPDATE=%s\n' \
                        "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$nt" > "$IPTV_DIR/schedule.conf"
                    mkdir -p /www/iptv; cp "$IPTV_DIR/epg.xml" /www/iptv/epg.xml 2>/dev/null
                fi
            fi
        fi
    fi
done
SCHEDEOF
    chmod +x /tmp/iptv-scheduler.sh; /bin/sh /tmp/iptv-scheduler.sh &
}

stop_scheduler() { kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null; rm -f /var/run/iptv-scheduler.pid /tmp/iptv-scheduler.sh; }

url_decode() {
    local encoded="$1"
    printf '%b' "$(echo "$encoded" | sed 's/+/ /g;s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

# ==========================================
# POST handler
# ==========================================
handle_post() {
    local CL=$CONTENT_LENGTH
    local POST_DATA=""
    [ "$CL" -gt 0 ] 2>/dev/null && POST_DATA=$(dd bs=1 count=$CL 2>/dev/null)

    local action=$(echo "$POST_DATA" | grep -o 'action=[^&]*' | sed 's/action=//')

    case "$action" in
        load_url)
            local url=$(echo "$POST_DATA" | grep -o 'url=[^&]*' | sed 's/url=//')
            url=$(url_decode "$url")
            if [ -z "$url" ]; then
                printf 'Content-Type: application/json\n\n{"status":"error","message":"URL не указан"}'
                return
            fi
            if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$url" 2>/dev/null; then
                if [ -s "$PLAYLIST_FILE" ]; then
                    local ch=$(get_channel_count)
                    mkdir -p "$IPTV_DIR"
                    printf 'PLAYLIST_TYPE=url\nPLAYLIST_URL=%s\nPLAYLIST_SOURCE=\n' "$url" > "$CONFIG_FILE"
                    load_schedule
                    local now=$(date '+%d.%m.%Y %H:%M')
                    printf 'PLAYLIST_INTERVAL=%s\nEPG_INTERVAL=%s\nPLAYLIST_LAST_UPDATE=%s\nEPG_LAST_UPDATE=%s\n' \
                        "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE" > "$SCHEDULE_FILE"
                    restart_httpd
                    printf 'Content-Type: application/json\n\n{"status":"ok","message":"Плейлист загружен! Каналов: %s","channels":%s}' "$ch" "$ch"
                else
                    rm -f "$PLAYLIST_FILE"
                    printf 'Content-Type: application/json\n\n{"status":"error","message":"Плейлист пуст или некорректен"}'
                fi
            else
                printf 'Content-Type: application/json\n\n{"status":"error","message":"Не удалось скачать плейлист"}'
            fi
            ;;
        load_file)
            local content=$(echo "$POST_DATA" | sed 's/.*content=//')
            content=$(url_decode "$content")
            if [ -z "$content" ] || [ ${#content} -lt 10 ]; then
                printf 'Content-Type: application/json\n\n{"status":"error","message":"Содержимое пустое"}'
                return
            fi
            printf '%s\n' "$content" > "$PLAYLIST_FILE"
            local ch=$(get_channel_count)
            printf 'PLAYLIST_TYPE=file\nPLAYLIST_URL=\nPLAYLIST_SOURCE=manual\n' > "$CONFIG_FILE"
            load_schedule
            local now=$(date '+%d.%m.%Y %H:%M')
            printf 'PLAYLIST_INTERVAL=%s\nEPG_INTERVAL=%s\nPLAYLIST_LAST_UPDATE=%s\nEPG_LAST_UPDATE=%s\n' \
                "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE" > "$SCHEDULE_FILE"
            restart_httpd
            printf 'Content-Type: application/json\n\n{"status":"ok","message":"Плейлист загружен! Каналов: %s","channels":%s}' "$ch" "$ch"
            ;;
        setup_provider)
            local name=$(echo "$POST_DATA" | grep -o 'name=[^&]*' | sed 's/name=//'); name=$(url_decode "$name")
            local server=$(echo "$POST_DATA" | grep -o 'server=[^&]*' | sed 's/server=//'); server=$(url_decode "$server")
            local login=$(echo "$POST_DATA" | grep -o 'login=[^&]*' | sed 's/login=//'); login=$(url_decode "$login")
            local password=$(echo "$POST_DATA" | grep -o 'password=[^&]*' | sed 's/password=//'); password=$(url_decode "$password")
            if [ -z "$name" ] || [ -z "$login" ] || [ -z "$password" ]; then
                printf 'Content-Type: application/json\n\n{"status":"error","message":"Заполните все поля"}'
                return
            fi
            [ -z "$server" ] && server="http://$name"
            local purl="$server/get.php?username=$login&password=$password&type=m3u_plus&output=ts"
            if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$purl" 2>/dev/null; then
                if [ -s "$PLAYLIST_FILE" ]; then
                    local ch=$(get_channel_count)
                    printf 'PLAYLIST_TYPE=provider\nPLAYLIST_URL=%s\nPLAYLIST_SOURCE=%s\n' "$purl" "$name" > "$CONFIG_FILE"
                    printf 'PROVIDER_NAME=%s\nPROVIDER_LOGIN=%s\nPROVIDER_PASS=%s\nPROVIDER_SERVER=%s\n' \
                        "$name" "$login" "$password" "$server" > "$PROVIDER_CONFIG"
                    load_schedule
                    local now=$(date '+%d.%m.%Y %H:%M')
                    printf 'PLAYLIST_INTERVAL=%s\nEPG_INTERVAL=%s\nPLAYLIST_LAST_UPDATE=%s\nEPG_LAST_UPDATE=%s\n' \
                        "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE" > "$SCHEDULE_FILE"
                    restart_httpd
                    printf 'Content-Type: application/json\n\n{"status":"ok","message":"Плейлист провайдера загружен! Каналов: %s","channels":%s}' "$ch" "$ch"
                else
                    rm -f "$PLAYLIST_FILE"
                    printf 'Content-Type: application/json\n\n{"status":"error","message":"Не удалось получить плейлист"}'
                fi
            else
                printf 'Content-Type: application/json\n\n{"status":"error","message":"Ошибка подключения к провайдеру"}'
            fi
            ;;
        update_playlist)
            load_config
            case "$PLAYLIST_TYPE" in
                url)
                    if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null; then
                        local ch=$(get_channel_count)
                        load_schedule; local now=$(date '+%d.%m.%Y %H:%M')
                        printf 'PLAYLIST_INTERVAL=%s\nEPG_INTERVAL=%s\nPLAYLIST_LAST_UPDATE=%s\nEPG_LAST_UPDATE=%s\n' \
                            "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE" > "$SCHEDULE_FILE"
                        restart_httpd
                        printf 'Content-Type: application/json\n\n{"status":"ok","message":"Плейлист обновлён! Каналов: %s","channels":%s}' "$ch" "$ch"
                    else
                        printf 'Content-Type: application/json\n\n{"status":"error","message":"Ошибка при обновлении"}'
                    fi;;
                provider)
                    [ -f "$PROVIDER_CONFIG" ] && {
                        . "$PROVIDER_CONFIG"
                        local purl="http://$PROVIDER_SERVER/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"
                        if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$purl" 2>/dev/null; then
                            local ch=$(get_channel_count)
                            load_schedule; local now=$(date '+%d.%m.%Y %H:%M')
                            printf 'PLAYLIST_INTERVAL=%s\nEPG_INTERVAL=%s\nPLAYLIST_LAST_UPDATE=%s\nEPG_LAST_UPDATE=%s\n' \
                                "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE" > "$SCHEDULE_FILE"
                            restart_httpd
                            printf 'Content-Type: application/json\n\n{"status":"ok","message":"Плейлист обновлён! Каналов: %s","channels":%s}' "$ch" "$ch"
                        else
                            printf 'Content-Type: application/json\n\n{"status":"error","message":"Ошибка при обновлении"}'
                        fi
                    };;
                *) printf 'Content-Type: application/json\n\n{"status":"error","message":"Невозможно обновить"}' ;;
            esac
            ;;
        setup_epg)
            local epg_url=$(echo "$POST_DATA" | grep -o 'epg_url=[^&]*' | sed 's/epg_url=//')
            epg_url=$(url_decode "$epg_url")
            if [ -z "$epg_url" ]; then
                printf 'Content-Type: application/json\n\n{"status":"error","message":"EPG URL не указан"}'
                return
            fi
            if wget -q --timeout=30 -O "$EPG_FILE" "$epg_url" 2>/dev/null; then
                if [ -s "$EPG_FILE" ]; then
                    local sz=$(get_file_size "$EPG_FILE")
                    printf 'EPG_URL=%s\n' "$epg_url" > "$EPG_CONFIG"
                    load_schedule; local now=$(date '+%d.%m.%Y %H:%M')
                    printf 'PLAYLIST_INTERVAL=%s\nEPG_INTERVAL=%s\nPLAYLIST_LAST_UPDATE=%s\nEPG_LAST_UPDATE=%s\n' \
                        "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now" > "$SCHEDULE_FILE"
                    restart_httpd
                    printf 'Content-Type: application/json\n\n{"status":"ok","message":"EPG загружен! Размер: %s","size":"%s"}' "$sz" "$sz"
                else
                    rm -f "$EPG_FILE"
                    printf 'Content-Type: application/json\n\n{"status":"error","message":"EPG файл пуст"}'
                fi
            else
                printf 'Content-Type: application/json\n\n{"status":"error","message":"Не удалось скачать EPG"}'
            fi
            ;;
        update_epg)
            load_epg_config
            if [ -n "$EPG_URL" ]; then
                if wget -q --timeout=30 -O "$EPG_FILE" "$EPG_URL" 2>/dev/null; then
                    if [ -s "$EPG_FILE" ]; then
                        local sz=$(get_file_size "$EPG_FILE")
                        load_schedule; local now=$(date '+%d.%m.%Y %H:%M')
                        printf 'PLAYLIST_INTERVAL=%s\nEPG_INTERVAL=%s\nPLAYLIST_LAST_UPDATE=%s\nEPG_LAST_UPDATE=%s\n' \
                            "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now" > "$SCHEDULE_FILE"
                        restart_httpd
                        printf 'Content-Type: application/json\n\n{"status":"ok","message":"EPG обновлён! Размер: %s","size":"%s"}' "$sz" "$sz"
                    else
                        printf 'Content-Type: application/json\n\n{"status":"error","message":"EPG файл пуст"}'
                    fi
                else
                    printf 'Content-Type: application/json\n\n{"status":"error","message":"Ошибка при обновлении EPG"}'
                fi
            else
                printf 'Content-Type: application/json\n\n{"status":"error","message":"EPG не настроен"}'
            fi
            ;;
        delete_epg)
            rm -f "$EPG_FILE" "$EPG_CONFIG"
            printf 'Content-Type: application/json\n\n{"status":"ok","message":"EPG удалён"}'
            ;;
        set_schedule)
            local pl_int=$(echo "$POST_DATA" | grep -o 'playlist_interval=[^&]*' | sed 's/playlist_interval=//')
            local epg_int=$(echo "$POST_DATA" | grep -o 'epg_interval=[^&]*' | sed 's/epg_interval=//')
            [ -z "$pl_int" ] && pl_int=0
            [ -z "$epg_int" ] && epg_int=0
            load_schedule
            printf 'PLAYLIST_INTERVAL=%s\nEPG_INTERVAL=%s\nPLAYLIST_LAST_UPDATE=%s\nEPG_LAST_UPDATE=%s\n' \
                "$pl_int" "$epg_int" "$PLAYLIST_LAST_UPDATE" "$EPG_LAST_UPDATE" > "$SCHEDULE_FILE"
            if [ "$pl_int" -gt 0 ] || [ "$epg_int" -gt 0 ]; then
                start_scheduler
                printf 'Content-Type: application/json\n\n{"status":"ok","message":"Расписание настроено, планировщик запущен"}'
            else
                stop_scheduler
                printf 'Content-Type: application/json\n\n{"status":"ok","message":"Расписание отключено"}'
            fi
            ;;
        delete)
            rm -f "$PLAYLIST_FILE" "$CONFIG_FILE" "$PROVIDER_CONFIG"
            stop_httpd
            printf 'Content-Type: application/json\n\n{"status":"ok","message":"Плейлист удалён"}'
            ;;
        autostart)
            if [ -f /etc/init.d/iptv-manager ]; then
                /etc/init.d/iptv-manager disable 2>/dev/null; rm -f /etc/init.d/iptv-manager
                printf 'Content-Type: application/json\n\n{"status":"ok","message":"Автозапуск отключён","enabled":false}'
            else
                cat > /etc/init.d/iptv-manager <<'INITEOF'
#!/bin/sh /etc/rc.common
START=99
start() {
    mkdir -p /www/iptv/cgi-bin
    [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u
    [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml
    [ -f /etc/iptv/iptv-admin.cgi ] && cp /etc/iptv/iptv-admin.cgi /www/iptv/cgi-bin/index.cgi && chmod +x /www/iptv/cgi-bin/index.cgi
    busybox httpd -p 8082 -h /www/iptv -c '/cgi-bin/*.cgi' &
    if [ -f /etc/iptv/schedule.conf ]; then
        . /etc/iptv/schedule.conf
        [ "$PLAYLIST_INTERVAL" -gt 0 ] || [ "$EPG_INTERVAL" -gt 0 ] && /bin/sh /tmp/iptv-scheduler.sh &
    fi
}
stop() {
    kill $(cat /var/run/iptv-httpd.pid 2>/dev/null) 2>/dev/null
    kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null
    rm -f /var/run/iptv-httpd.pid /var/run/iptv-scheduler.pid
}
INITEOF
                chmod +x /etc/init.d/iptv-manager; /etc/init.d/iptv-manager enable 2>/dev/null
                printf 'Content-Type: application/json\n\n{"status":"ok","message":"Автозапуск включён","enabled":true}'
            fi
            ;;
        *)
            printf 'Content-Type: application/json\n\n{"status":"error","message":"Неизвестное действие"}'
            ;;
    esac
}

# ==========================================
# GET — HTML страница
# ==========================================
load_config; load_epg_config; load_schedule

CH=$(get_channel_count)
PL_SIZE=$(get_file_size "$PLAYLIST_FILE")
EPG_SIZE=$(get_file_size "$EPG_FILE")
AUTOSTART="false"; [ -f /etc/init.d/iptv-manager ] && AUTOSTART="true"
HTTPD="false"; httpd_running && HTTPD="true"
SCHED="false"; scheduler_running && SCHED="true"

cat <<HEADER
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>IPTV Manager</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f172a;color:#e2e8f0;min-height:100vh}
.container{max-width:960px;margin:0 auto;padding:20px}
.header{text-align:center;padding:30px 0 20px;border-bottom:1px solid #1e293b;margin-bottom:24px}
.header h1{font-size:28px;background:linear-gradient(135deg,#3b82f6,#8b5cf6);-webkit-background-clip:text;-webkit-text-fill-color:transparent;margin-bottom:8px}
.header p{color:#64748b;font-size:14px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px;margin-bottom:24px}
.stat{background:#1e293b;border-radius:12px;padding:16px;text-align:center;border:1px solid #334155}
.stat-value{font-size:22px;font-weight:700;color:#3b82f6;margin-bottom:4px}
.stat-label{font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px}
.tabs{display:flex;gap:4px;margin-bottom:20px;background:#1e293b;border-radius:12px;padding:4px;overflow-x:auto}
.tab{flex:1;padding:10px 14px;border:none;background:transparent;color:#94a3b8;border-radius:8px;cursor:pointer;font-size:13px;font-weight:500;transition:all .2s;white-space:nowrap}
.tab:hover{color:#e2e8f0}.tab.active{background:#3b82f6;color:#fff}
.panel{display:none;background:#1e293b;border-radius:16px;padding:24px;border:1px solid #334155;margin-bottom:16px}
.panel.active{display:block}
.panel h2{font-size:18px;margin-bottom:16px;color:#f1f5f9}
.form-group{margin-bottom:14px}
.form-group label{display:block;font-size:13px;color:#94a3b8;margin-bottom:6px;font-weight:500}
.form-group input,.form-group select,.form-group textarea{width:100%;padding:10px 14px;background:#0f172a;border:1px solid #334155;border-radius:8px;color:#e2e8f0;font-size:14px;transition:border-color .2s}
.form-group input:focus,.form-group textarea:focus{outline:none;border-color:#3b82f6;box-shadow:0 0 0 3px rgba(59,130,246,.1)}
.form-group textarea{min-height:80px;font-family:monospace;font-size:13px;resize:vertical}
.btn{padding:10px 20px;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;transition:all .2s;display:inline-flex;align-items:center;gap:6px}
.btn-primary{background:#3b82f6;color:#fff}.btn-primary:hover{background:#2563eb}
.btn-danger{background:#ef4444;color:#fff}.btn-danger:hover{background:#dc2626}
.btn-success{background:#22c55e;color:#fff}.btn-success:hover{background:#16a34a}
.btn-secondary{background:#334155;color:#e2e8f0}.btn-secondary:hover{background:#475569}
.btn-sm{padding:8px 14px;font-size:13px}
.btn-group{display:flex;gap:10px;margin-top:16px;flex-wrap:wrap}
.alert{padding:14px;border-radius:8px;margin-bottom:14px;font-size:14px;position:fixed;top:20px;right:20px;z-index:9999;min-width:280px;box-shadow:0 10px 40px rgba(0,0,0,.3)}
.alert-success{background:#064e3b;border:1px solid #10b981;color:#6ee7b7}
.alert-error{background:#7f1d1d;border:1px solid #ef4444;color:#fca5a5}
.alert-info{background:#1e3a5f;border:1px solid #3b82f6;color:#93c5fd}
.url-box{background:#0f172a;border:1px solid #334155;border-radius:8px;padding:12px;margin:12px 0;display:flex;align-items:center;gap:10px}
.url-box code{flex:1;font-size:13px;color:#3b82f6;word-break:break-all}
.url-box button{padding:6px 12px;background:#334155;border:none;border-radius:6px;color:#e2e8f0;cursor:pointer;font-size:12px;white-space:nowrap}
.url-box button:hover{background:#475569}
.schedule-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.schedule-card{background:#0f172a;border-radius:12px;padding:16px;border:1px solid #334155}
.schedule-card h3{font-size:14px;color:#f1f5f9;margin-bottom:12px}
.schedule-card select{width:100%;padding:10px;background:#1e293b;border:1px solid #334155;border-radius:8px;color:#e2e8f0;font-size:14px}
.schedule-card select:focus{outline:none;border-color:#3b82f6}
.schedule-info{margin-top:12px;font-size:12px;color:#64748b}
.schedule-info span{color:#94a3b8}
.channels-list{max-height:400px;overflow-y:auto;margin-top:12px}
.channel-item{display:flex;align-items:center;gap:10px;padding:10px;border-radius:8px;border-bottom:1px solid #334155}
.channel-item:hover{background:#334155}
.channel-item:last-child{border-bottom:none}
.ch-logo{width:32px;height:32px;border-radius:6px;background:#0f172a;display:flex;align-items:center;justify-content:center;font-size:14px;overflow:hidden;flex-shrink:0}
.ch-logo img{width:100%;height:100%;object-fit:cover}
.ch-name{font-weight:500;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ch-group{font-size:11px;color:#64748b;margin-top:2px}
.settings-row{display:flex;justify-content:space-between;align-items:center;padding:14px 0;border-bottom:1px solid #334155}
.settings-row:last-child{border-bottom:none}
.settings-info h3{font-size:14px;color:#f1f5f9;margin-bottom:4px}
.settings-info p{font-size:12px;color:#64748b}
.toggle{position:relative;width:44px;height:24px}
.toggle input{opacity:0;width:0;height:0}
.toggle-slider{position:absolute;cursor:pointer;inset:0;background:#334155;border-radius:24px;transition:.2s}
.toggle-slider:before{content:"";position:absolute;height:18px;width:18px;left:3px;bottom:3px;background:#e2e8f0;border-radius:50%;transition:.2s}
.toggle input:checked+.toggle-slider{background:#3b82f6}
.toggle input:checked+.toggle-slider:before{transform:translateX(20px)}
.badge{display:inline-block;padding:2px 8px;border-radius:20px;font-size:11px;font-weight:600}
.badge-green{background:#064e3b;color:#6ee7b7}
.badge-red{background:#7f1d1d;color:#fca5a5}
.badge-blue{background:#1e3a5f;color:#93c5fd}
.empty{text-align:center;padding:30px;color:#64748b}
.empty p{font-size:14px}
.footer{text-align:center;padding:24px 0;color:#475569;font-size:12px}
@media(max-width:640px){.stats{grid-template-columns:repeat(2,1fr)}.schedule-grid{grid-template-columns:1fr}.btn-group{flex-direction:column}.url-box{flex-direction:column}}
</style>
</head>
<body>
<div class="container">
<div class="header">
<h1>📺 IPTV Manager</h1>
<p>Управление IPTV, EPG и расписанием на OpenWrt</p>
</div>

<div class="stats">
<div class="stat">
<div class="stat-value">$CH</div>
<div class="stat-label">Каналов</div>
</div>
<div class="stat">
<div class="stat-value">$PL_SIZE</div>
<div class="stat-label">Плейлист</div>
</div>
<div class="stat">
<div class="stat-value">$EPG_SIZE</div>
<div class="stat-label">EPG</div>
</div>
<div class="stat">
<div class="stat-value" style="color:$([ "$HTTPD" = "true" ] && echo '#22c55e' || echo '#ef4444')">●</div>
<div class="stat-label">Сервер</div>
</div>
<div class="stat">
<div class="stat-value" style="color:$([ "$SCHED" = "true" ] && echo '#22c55e' || echo '#64748b')">●</div>
<div class="stat-label">Планировщик</div>
</div>
</div>

<div class="url-box">
<code id="pl-url">http://$LAN_IP:$IPTV_PORT/playlist.m3u</code>
<button onclick="copyText('pl-url')">Копировать</button>
</div>
<div class="url-box">
<code id="epg-url">http://$LAN_IP:$IPTV_PORT/epg.xml</code>
<button onclick="copyText('epg-url')">Копировать</button>
</div>

<div class="tabs">
<button class="tab active" onclick="switchTab('source')">📡 Плейлист</button>
<button class="tab" onclick="switchTab('epg')">📅 EPG</button>
<button class="tab" onclick="switchTab('schedule')">⏰ Расписание</button>
<button class="tab" onclick="switchTab('channels')">📋 Каналы</button>
<button class="tab" onclick="switchTab('settings')">⚙️</button>
</div>

<!-- ПЛЕЙЛИСТ -->
<div class="panel active" id="panel-source">
<h2>Источник плейлиста</h2>
<div class="form-group">
<label>Загрузить по ссылке</label>
<input type="url" id="url-input" placeholder="http://example.com/playlist.m3u" value="$([ "$PLAYLIST_TYPE" = "url" ] && echo "$PLAYLIST_URL")">
</div>
<button class="btn btn-primary btn-sm" onclick="loadFromUrl()">Загрузить по ссылке</button>

<hr style="border:none;border-top:1px solid #334155;margin:20px 0">

<div class="form-group">
<label>Вставить M3U содержимое</label>
<textarea id="m3u-text" placeholder="#EXTM3U&#10;#EXTINF:-1,Channel 1&#10;http://stream.example.com/ch1.ts"></textarea>
</div>
<button class="btn btn-primary btn-sm" onclick="loadFromText()">Загрузить из текста</button>

<hr style="border:none;border-top:1px solid #334155;margin:20px 0">

<div class="form-group">
<label>IPTV Провайдер</label>
<input type="text" id="provider-name" placeholder="Название провайдера" value="$([ "$PLAYLIST_TYPE" = "provider" ] && [ -f "$PROVIDER_CONFIG" ] && . "$PROVIDER_CONFIG" && echo "$PROVIDER_NAME")">
</div>
<div class="form-group">
<label>Сервер (домен или http://ip)</label>
<input type="text" id="provider-server" placeholder="example.com">
</div>
<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
<div class="form-group">
<label>Логин</label>
<input type="text" id="provider-login" placeholder="Ваш логин">
</div>
<div class="form-group">
<label>Пароль</label>
<input type="password" id="provider-password" placeholder="Ваш пароль">
</div>
</div>
<button class="btn btn-primary btn-sm" onclick="loadFromProvider()">Подключить провайдера</button>

<hr style="border:none;border-top:1px solid #334155;margin:20px 0">

<div class="btn-group">
<button class="btn btn-success btn-sm" onclick="updatePlaylist()">🔄 Обновить плейлист</button>
</div>
</div>

<!-- EPG -->
<div class="panel" id="panel-epg">
<h2>Телепрограмма (EPG)</h2>
<div class="form-group">
<label>EPG URL (XMLTV формат)</label>
<input type="url" id="epg-url-input" placeholder="http://epg.example.com/epg.xml" value="$EPG_URL">
</div>
<div class="btn-group">
<button class="btn btn-primary btn-sm" onclick="setupEpg()">Загрузить EPG</button>
<button class="btn btn-success btn-sm" onclick="updateEpg()">🔄 Обновить EPG</button>
<button class="btn btn-danger btn-sm" onclick="deleteEpg()">🗑 Удалить EPG</button>
</div>
<div class="schedule-info" style="margin-top:16px">
<p>EPG файл: <span>$EPG_FILE</span></p>
<p>Размер: <span>$EPG_SIZE</span></p>
<p>Последнее обновление: <span>${EPG_LAST_UPDATE:-—}</span></p>
</div>
</div>

<!-- РАСПИСАНИЕ -->
<div class="panel" id="panel-schedule">
<h2>Расписание обновлений</h2>
<div class="schedule-grid">
<div class="schedule-card">
<h3>📡 Плейлист</h3>
<select id="pl-interval">
<option value="0" $([ "$PLAYLIST_INTERVAL" = "0" ] && echo "selected")>Выключено</option>
<option value="1" $([ "$PLAYLIST_INTERVAL" = "1" ] && echo "selected")>Каждый час</option>
<option value="6" $([ "$PLAYLIST_INTERVAL" = "6" ] && echo "selected")>Каждые 6 часов</option>
<option value="12" $([ "$PLAYLIST_INTERVAL" = "12" ] && echo "selected")>Каждые 12 часов</option>
<option value="24" $([ "$PLAYLIST_INTERVAL" = "24" ] && echo "selected")>Раз в сутки</option>
</select>
<div class="schedule-info">
<p>Текущий: <span>$(interval_label "$PLAYLIST_INTERVAL")</span></p>
<p>Обновлён: <span>${PLAYLIST_LAST_UPDATE:-—}</span></p>
</div>
</div>
<div class="schedule-card">
<h3>📅 EPG</h3>
<select id="epg-interval">
<option value="0" $([ "$EPG_INTERVAL" = "0" ] && echo "selected")>Выключено</option>
<option value="1" $([ "$EPG_INTERVAL" = "1" ] && echo "selected")>Каждый час</option>
<option value="6" $([ "$EPG_INTERVAL" = "6" ] && echo "selected")>Каждые 6 часов</option>
<option value="12" $([ "$EPG_INTERVAL" = "12" ] && echo "selected")>Каждые 12 часов</option>
<option value="24" $([ "$EPG_INTERVAL" = "24" ] && echo "selected")>Раз в сутки</option>
</select>
<div class="schedule-info">
<p>Текущий: <span>$(interval_label "$EPG_INTERVAL")</span></p>
<p>Обновлён: <span>${EPG_LAST_UPDATE:-—}</span></p>
</div>
</div>
</div>
<div class="btn-group">
<button class="btn btn-primary btn-sm" onclick="saveSchedule()">💾 Сохранить расписание</button>
</div>
</div>

<!-- КАНАЛЫ -->
<div class="panel" id="panel-channels">
<h2>Список каналов ($CH)</h2>
<div id="channels-container" class="channels-list">
HEADER

if [ "$CH" -gt 0 ] 2>/dev/null; then
    grep "^#EXTINF" "$PLAYLIST_FILE" | head -100 | while IFS= read -r line; do
        name=$(echo "$line" | sed 's/.*,\(.*\)/\1/')
        logo=$(echo "$line" | grep -o 'tvg-logo="[^"]*"' | sed 's/tvg-logo="//;s/"//')
        group=$(echo "$line" | grep -o 'group-title="[^"]*"' | sed 's/group-title="//;s/"//')
        [ -z "$name" ] && name="Unknown"
        [ -z "$group" ] && group="General"
        echo "<div class=\"channel-item\">"
        echo "<div class=\"ch-logo\">"
        if [ -n "$logo" ]; then
            echo "<img src=\"$logo\" onerror=\"this.parentElement.innerHTML='📺'\">"
        else
            echo "📺"
        fi
        echo "</div>"
        echo "<div><div class=\"ch-name\">$name</div><div class=\"ch-group\">$group</div></div></div>"
    done
    [ "$CH" -gt 100 ] 2>/dev/null && echo "<div class=\"empty\"><p>Показано 100 из $CH каналов</p></div>"
else
    echo "<div class=\"empty\"><p>Плейлист не загружен</p></div>"
fi

cat <<SETTINGS
</div>
</div>

<!-- НАСТРОЙКИ -->
<div class="panel" id="panel-settings">
<h2>Настройки</h2>

<div class="settings-row">
<div class="settings-info">
<h3>Автозапуск</h3>
<p>Запускать сервер и планировщик при старте роутера</p>
</div>
<label class="toggle">
<input type="checkbox" id="autostart-toggle" $([ "$AUTOSTART" = "true" ] && echo "checked") onchange="toggleAutostart()">
<span class="toggle-slider"></span>
</label>
</div>

<div class="settings-row">
<div class="settings-info">
<h3>Сервер</h3>
<p>IP: $LAN_IP | Порт: $IPTV_PORT</p>
</div>
<span class="badge $([ "$HTTPD" = "true" ] && echo 'badge-green' || echo 'badge-red')">$([ "$HTTPD" = "true" ] && echo 'Запущен' || echo 'Остановлен')</span>
</div>

<div class="settings-row">
<div class="settings-info">
<h3>Планировщик</h3>
<p>Автоматические обновления</p>
</div>
<span class="badge $([ "$SCHED" = "true" ] && echo 'badge-green' || echo 'badge-red')">$([ "$SCHED" = "true" ] && echo 'Работает' || echo 'Остановлен')</span>
</div>

<div class="settings-row">
<div class="settings-info">
<h3>Путь к плейлисту</h3>
<p>$PLAYLIST_FILE</p>
</div>
</div>

<div class="settings-row">
<div class="settings-info">
<h3>Путь к EPG</h3>
<p>$EPG_FILE</p>
</div>
</div>

<div class="btn-group">
<button class="btn btn-danger btn-sm" onclick="deletePlaylist()">🗑 Удалить плейлист</button>
</div>
</div>

<div class="footer">IPTV Manager v1.1 — OpenWrt</div>
</div>

<script>
function switchTab(tab){
document.querySelectorAll('.tab').forEach(function(t){t.classList.remove('active')});
document.querySelectorAll('.panel').forEach(function(p){p.classList.remove('active')});
document.getElementById('tab-'+tab).classList.add('active');
document.getElementById('panel-'+tab).classList.add('active');
}
function copyText(id){
var el=document.getElementById(id);
var range=document.createRange();range.selectNodeContents(el);
var sel=window.getSelection();sel.removeAllRanges();sel.addRange(range);
document.execCommand('copy');sel.removeAllRanges();
var btn=el.nextElementSibling;btn.textContent='✓';
setTimeout(function(){btn.textContent='Копировать'},2000);
}
function notify(msg,type){
var n=document.createElement('div');
n.className='alert alert-'+type;
n.textContent=msg;document.body.appendChild(n);
setTimeout(function(){n.remove()},4000);
}
function post(data,cb){
var x=new XMLHttpRequest();
x.open('POST',window.location.href,true);
x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
x.onload=function(){
try{var r=JSON.parse(x.responseText);if(cb)cb(r);
if(r.status==='ok'){notify(r.message,'success');setTimeout(function(){location.reload()},1500)}
else notify(r.message,'error');
}catch(e){notify('Ошибка сервера','error')}};
x.onerror=function(){notify('Ошибка сети','error')};
x.send(data);
}
function loadFromUrl(){
var u=document.getElementById('url-input').value.trim();
if(!u){notify('Введите URL','error');return}
notify('Загрузка плейлиста...','info');
post('action=load_url&url='+encodeURIComponent(u));
}
function loadFromText(){
var c=document.getElementById('m3u-text').value.trim();
if(!c||c.length<10){notify('Вставьте M3U плейлист','error');return}
notify('Загрузка...','info');
post('action=load_file&content='+encodeURIComponent(c));
}
function loadFromProvider(){
var n=document.getElementById('provider-name').value.trim();
var s=document.getElementById('provider-server').value.trim();
var l=document.getElementById('provider-login').value.trim();
var p=document.getElementById('provider-password').value.trim();
if(!n||!l||!p){notify('Заполните все поля','error');return}
notify('Подключение...','info');
post('action=setup_provider&name='+encodeURIComponent(n)+'&server='+encodeURIComponent(s)+'&login='+encodeURIComponent(l)+'&password='+encodeURIComponent(p));
}
function updatePlaylist(){
notify('Обновление плейлиста...','info');
post('action=update_playlist');
}
function setupEpg(){
var u=document.getElementById('epg-url-input').value.trim();
if(!u){notify('Введите EPG URL','error');return}
notify('Загрузка EPG...','info');
post('action=setup_epg&epg_url='+encodeURIComponent(u));
}
function updateEpg(){
notify('Обновление EPG...','info');
post('action=update_epg');
}
function deleteEpg(){
if(!confirm('Удалить EPG?'))return;
post('action=delete_epg');
}
function saveSchedule(){
var pi=document.getElementById('pl-interval').value;
var ei=document.getElementById('epg-interval').value;
notify('Сохранение расписания...','info');
post('action=set_schedule&playlist_interval='+pi+'&epg_interval='+ei);
}
function deletePlaylist(){
if(!confirm('Удалить плейлист и все настройки?'))return;
post('action=delete');
}
function toggleAutostart(){
post('action=autostart',function(r){notify(r.message,'success')});
}
</script>
</body>
</html>
SETTINGS
