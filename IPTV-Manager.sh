#!/bin/sh
# ==========================================
# IPTV Manager for OpenWrt v1.1
# ==========================================
# Скрипт для настройки IPTV с веб-админкой,
# EPG телепрограммой и расписанием обновлений
# ==========================================

IPTV_MANAGER_VERSION="1.1"
GREEN="\033[1;32m"; RED="\033[1;31m"; CYAN="\033[1;36m"; YELLOW="\033[1;33m"; MAGENTA="\033[1;35m"; BLUE="\033[0;34m"; NC="\033[0m"
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
PAUSE() { echo -ne "${YELLOW}Нажмите Enter для продолжения...${NC}"; read dummy </dev/tty; }

get_timestamp() { date '+%d.%m.%Y %H:%M' 2>/dev/null || echo "—"; }

save_config() {
    mkdir -p "$IPTV_DIR"
    cat > "$CONFIG_FILE" <<EOF
PLAYLIST_TYPE=$1
PLAYLIST_URL=$2
PLAYLIST_SOURCE=$3
EOF
}

load_config() {
    [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
}

load_epg_config() {
    [ -f "$EPG_CONFIG" ] && . "$EPG_CONFIG"
}

load_schedule() {
    if [ -f "$SCHEDULE_FILE" ]; then
        . "$SCHEDULE_FILE"
    else
        PLAYLIST_INTERVAL="0"
        EPG_INTERVAL="0"
        PLAYLIST_LAST_UPDATE=""
        EPG_LAST_UPDATE=""
    fi
}

save_schedule() {
    cat > "$SCHEDULE_FILE" <<EOF
PLAYLIST_INTERVAL=$1
EPG_INTERVAL=$2
PLAYLIST_LAST_UPDATE=$3
EPG_LAST_UPDATE=$4
EOF
}

get_playlist_info() {
    load_config
    case "$PLAYLIST_TYPE" in
        url) echo_info "Тип: Ссылка"; echo_info "URL: $PLAYLIST_URL" ;;
        file) echo_info "Тип: Файл"; echo_info "Файл: $PLAYLIST_SOURCE" ;;
        provider)
            [ -f "$PROVIDER_CONFIG" ] && {
                . "$PROVIDER_CONFIG"
                echo_info "Тип: Провайдер: $PROVIDER_NAME"
            } ;;
        *) echo_info "Плейлист не настроен" ;;
    esac
}

get_epg_info() {
    load_epg_config
    if [ -n "$EPG_URL" ]; then
        echo_info "EPG: $EPG_URL"
        if [ -f "$EPG_FILE" ]; then
            local size=$(wc -c < "$EPG_FILE" 2>/dev/null)
            if [ "$size" -gt 1048576 ]; then echo_info "Размер: $((size / 1048576)) MB"
            elif [ "$size" -gt 1024 ]; then echo_info "Размер: $((size / 1024)) KB"
            else echo_info "Размер: ${size} B"; fi
        fi
    else
        echo_info "EPG не настроен"
    fi
}

get_channel_count() {
    [ -f "$PLAYLIST_FILE" ] && grep -c "^#EXTINF" "$PLAYLIST_FILE" 2>/dev/null || echo "0"
}

interval_to_text() {
    case "$1" in
        0) echo "Выключено" ;;
        1) echo "Каждый час" ;;
        6) echo "Каждые 6 часов" ;;
        12) echo "Каждые 12 часов" ;;
        24) echo "Раз в сутки" ;;
        *) echo "Выключено" ;;
    esac
}

# ==========================================
# Обновление плейлиста
# ==========================================
update_playlist() {
    load_config
    local now=$(get_timestamp)

    case "$PLAYLIST_TYPE" in
        url)
            if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null; then
                local channels=$(get_channel_count)
                echo_success "Плейлист обновлён! Каналов: $channels"
                save_schedule "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                return 0
            fi
            ;;
        provider)
            if [ -f "$PROVIDER_CONFIG" ]; then
                . "$PROVIDER_CONFIG"
                local purl="http://$PROVIDER_NAME/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"
                if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$purl" 2>/dev/null; then
                    local channels=$(get_channel_count)
                    echo_success "Плейлист обновлён! Каналов: $channels"
                    save_schedule "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                    return 0
                fi
            fi
            ;;
        file)
            if [ -f "$PLAYLIST_SOURCE" ]; then
                cp "$PLAYLIST_SOURCE" "$PLAYLIST_FILE"
                local channels=$(get_channel_count)
                echo_success "Плейлист обновлён из файла! Каналов: $channels"
                save_schedule "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                return 0
            fi
            ;;
    esac
    echo_error "Ошибка при обновлении плейлиста!"
    return 1
}

# ==========================================
# Обновление EPG
# ==========================================
update_epg() {
    load_epg_config
    local now=$(get_timestamp)

    if [ -z "$EPG_URL" ]; then
        echo_error "EPG URL не настроен!"
        return 1
    fi

    echo_info "Скачиваем EPG..."
    if wget -q --timeout=30 -O "$EPG_FILE" "$EPG_URL" 2>/dev/null; then
        if [ -s "$EPG_FILE" ]; then
            local size=$(wc -c < "$EPG_FILE" 2>/dev/null)
            echo_success "EPG обновлён! Размер: $((size / 1024)) KB"
            save_schedule "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
            return 0
        else
            echo_error "EPG файл пуст!"
            rm -f "$EPG_FILE"
            return 1
        fi
    else
        echo_error "Не удалось скачать EPG!"
        return 1
    fi
}

# ==========================================
# Фоновый планировщик
# ==========================================
start_scheduler() {
    stop_scheduler
    load_schedule

    cat > /tmp/iptv-scheduler.sh <<'SCHEDEOF'
#!/bin/sh
IPTV_DIR="/etc/iptv"
PLAYLIST_FILE="$IPTV_DIR/playlist.m3u"
EPG_FILE="$IPTV_DIR/epg.xml"
CONFIG_FILE="$IPTV_DIR/iptv.conf"
EPG_CONFIG="$IPTV_DIR/epg.conf"
SCHEDULE_FILE="$IPTV_DIR/schedule.conf"
PID_FILE="/var/run/iptv-scheduler.pid"
echo $$ > "$PID_FILE"

get_ts() { date '+%d.%m.%Y %H:%M' 2>/dev/null || echo ""; }

while true; do
    sleep 60

    [ ! -f "$SCHEDULE_FILE" ] && continue
    . "$SCHEDULE_FILE"

    now_epoch=$(date +%s 2>/dev/null || echo 0)

    # Проверка плейлиста
    if [ "$PLAYLIST_INTERVAL" -gt 0 ] 2>/dev/null; then
        if [ -n "$PLAYLIST_LAST_UPDATE" ]; then
            last_epoch=$(date -d "$PLAYLIST_LAST_UPDATE" +%s 2>/dev/null || echo 0)
        else
            last_epoch=0
        fi
        diff_h=$(( (now_epoch - last_epoch) / 3600 ))
        if [ "$diff_h" -ge "$PLAYLIST_INTERVAL" ]; then
            . "$CONFIG_FILE" 2>/dev/null
            case "$PLAYLIST_TYPE" in
                url) wget -q --timeout=15 -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null ;;
                provider)
                    if [ -f "$IPTV_DIR/provider.conf" ]; then
                        . "$IPTV_DIR/provider.conf"
                        purl="http://$PROVIDER_NAME/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"
                        wget -q --timeout=15 -O "$PLAYLIST_FILE" "$purl" 2>/dev/null
                    fi ;;
                file) [ -f "$PLAYLIST_SOURCE" ] && cp "$PLAYLIST_SOURCE" "$PLAYLIST_FILE" ;;
            esac
            new_ts=$(get_ts)
            echo "PLAYLIST_TYPE=$PLAYLIST_TYPE" > "$SCHEDULE_FILE.tmp"
            echo "PLAYLIST_INTERVAL=$PLAYLIST_INTERVAL" >> "$SCHEDULE_FILE.tmp"
            echo "EPG_INTERVAL=$EPG_INTERVAL" >> "$SCHEDULE_FILE.tmp"
            echo "PLAYLIST_LAST_UPDATE=$new_ts" >> "$SCHEDULE_FILE.tmp"
            echo "EPG_LAST_UPDATE=$EPG_LAST_UPDATE" >> "$SCHEDULE_FILE.tmp"
            mv "$SCHEDULE_FILE.tmp" "$SCHEDULE_FILE"
            # Обновляем копию для HTTP
            mkdir -p /www/iptv
            [ -f "$PLAYLIST_FILE" ] && cp "$PLAYLIST_FILE" /www/iptv/playlist.m3u
        fi
    fi

    # Проверка EPG
    if [ "$EPG_INTERVAL" -gt 0 ] 2>/dev/null; then
        if [ -n "$EPG_LAST_UPDATE" ]; then
            last_epoch=$(date -d "$EPG_LAST_UPDATE" +%s 2>/dev/null || echo 0)
        else
            last_epoch=0
        fi
        diff_h=$(( (now_epoch - last_epoch) / 3600 ))
        if [ "$diff_h" -ge "$EPG_INTERVAL" ]; then
            . "$EPG_CONFIG" 2>/dev/null
            if [ -n "$EPG_URL" ]; then
                wget -q --timeout=30 -O "$EPG_FILE" "$EPG_URL" 2>/dev/null
                if [ -s "$EPG_FILE" ]; then
                    new_ts=$(get_ts)
                    echo "PLAYLIST_TYPE=$PLAYLIST_TYPE" > "$SCHEDULE_FILE.tmp"
                    echo "PLAYLIST_INTERVAL=$PLAYLIST_INTERVAL" >> "$SCHEDULE_FILE.tmp"
                    echo "EPG_INTERVAL=$EPG_INTERVAL" >> "$SCHEDULE_FILE.tmp"
                    echo "PLAYLIST_LAST_UPDATE=$PLAYLIST_LAST_UPDATE" >> "$SCHEDULE_FILE.tmp"
                    echo "EPG_LAST_UPDATE=$new_ts" >> "$SCHEDULE_FILE.tmp"
                    mv "$SCHEDULE_FILE.tmp" "$SCHEDULE_FILE"
                fi
            fi
        fi
    fi
done
SCHEDEOF
    chmod +x /tmp/iptv-scheduler.sh
    /bin/sh /tmp/iptv-scheduler.sh &
    echo_success "Планировщик запущен"
}

stop_scheduler() {
    if [ -f "$SCHEDULER_PID" ]; then
        kill $(cat "$SCHEDULER_PID") 2>/dev/null
        rm -f "$SCHEDULER_PID" /tmp/iptv-scheduler.sh
        echo_success "Планировщик остановлен"
    fi
}

# ==========================================
# HTTP сервер (uhttpd)
# ==========================================
start_http_server() {
    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then
        echo_success "HTTP-сервер уже запущен на http://$LAN_IP:$IPTV_PORT"
        return
    fi

    if [ ! -f "$PLAYLIST_FILE" ]; then
        echo_error "Плейлист не найден! Сначала загрузите плейлист."
        PAUSE
        return 1
    fi

    mkdir -p /www/iptv/cgi-bin
    cp "$PLAYLIST_FILE" /www/iptv/playlist.m3u
    [ -f "$EPG_FILE" ] && cp "$EPG_FILE" /www/iptv/epg.xml
    [ -f "$IPTV_DIR/iptv-admin.cgi" ] && cp "$IPTV_DIR/iptv-admin.cgi" /www/iptv/cgi-bin/index.cgi && chmod +x /www/iptv/cgi-bin/index.cgi

    cat > /www/iptv/index.html <<HTMLEOF
<!DOCTYPE html>
<html>
<head><title>IPTV Manager</title>
<style>body{font-family:monospace;background:#0f172a;color:#e2e8f0;padding:30px;text-align:center}
a{color:#3b82f6;text-decoration:none}h1{margin-bottom:20px}</style></head>
<body>
<h1>IPTV Manager</h1>
<p><a href="/cgi-bin/index.cgi">Open Web Admin</a></p>
<p>Playlist: <a href="/playlist.m3u">/playlist.m3u</a></p>
<p>EPG: <a href="/epg.xml">/epg.xml</a></p>
</body></html>
HTMLEOF

    # Останавливаем uhttpd на этом порту если есть
    kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null
    sleep 1

    uhttpd -f -p "0.0.0.0:$IPTV_PORT" -h /www/iptv -c /bin/sh &
    echo $! > "$HTTPD_PID"

    echo_success "HTTP-сервер запущен!"
    echo_info "Админка: http://$LAN_IP:$IPTV_PORT/cgi-bin/index.cgi"
    echo_info "Плейлист: http://$LAN_IP:$IPTV_PORT/playlist.m3u"
    echo_info "EPG: http://$LAN_IP:$IPTV_PORT/epg.xml"
}

stop_http_server() {
    if [ -f "$HTTPD_PID" ]; then
        kill $(cat "$HTTPD_PID") 2>/dev/null
        # Также убиваем по процессу на всякий случай
        kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null
        rm -f "$HTTPD_PID"
        echo_success "HTTP-сервер остановлен"
    else
        kill $(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null) 2>/dev/null
        echo_info "HTTP-сервер остановлен (по процессу)"
    fi
}

# ==========================================
# Загрузка плейлиста по ссылке
# ==========================================
load_playlist_from_url() {
    echo_color "Загрузка плейлиста по ссылке"
    echo ""
    echo_info "Введите ссылку на M3U/M3U8 плейлист:"
    echo ""
    echo -ne "${YELLOW}URL плейлиста: ${NC}"
    read PLAYLIST_URL </dev/tty

    [ -z "$PLAYLIST_URL" ] && { echo_error "URL не может быть пустым!"; PAUSE; return 1; }

    echo_info "Скачиваем плейлист..."
    if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$PLAYLIST_URL" 2>/dev/null; then
        if [ -s "$PLAYLIST_FILE" ]; then
            local channels=$(get_channel_count)
            echo_success "Плейлист загружен! Каналов: $channels"
            save_config "url" "$PLAYLIST_URL" ""
            local now=$(get_timestamp)
            save_schedule "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
            start_http_server
        else
            echo_error "Плейлист пуст или некорректен!"
            rm -f "$PLAYLIST_FILE"; PAUSE; return 1
        fi
    else
        echo_error "Не удалось скачать плейлист!"; PAUSE; return 1
    fi
}

# ==========================================
# Загрузка плейлиста из файла
# ==========================================
load_playlist_from_file() {
    echo_color "Загрузка плейлиста из файла"
    echo ""
    echo_info "Скопируйте файл на роутер: scp playlist.m3u root@$LAN_IP:/tmp/"
    echo ""
    echo -ne "${YELLOW}Путь к файлу: ${NC}"
    read FILE_PATH </dev/tty

    [ -z "$FILE_PATH" ] && { echo_error "Путь не может быть пустым!"; PAUSE; return 1; }
    [ ! -f "$FILE_PATH" ] && { echo_error "Файл не найден: $FILE_PATH"; PAUSE; return 1; }

    cp "$FILE_PATH" "$PLAYLIST_FILE"
    local channels=$(get_channel_count)
    echo_success "Плейлист загружен! Каналов: $channels"
    save_config "file" "" "$FILE_PATH"
    local now=$(get_timestamp)
    save_schedule "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
    start_http_server
}

# ==========================================
# Настройка провайдера
# ==========================================
setup_provider() {
    echo_color "Настройка IPTV провайдера"
    echo ""
    echo -ne "${YELLOW}Название провайдера: ${NC}"
    read PROVIDER_NAME </dev/tty
    echo -ne "${YELLOW}Логин: ${NC}"
    read PROVIDER_LOGIN </dev/tty
    echo -ne "${YELLOW}Пароль: ${NC}"
    stty -echo; read PROVIDER_PASS </dev/tty; stty echo; echo ""

    [ -z "$PROVIDER_NAME" ] || [ -z "$PROVIDER_LOGIN" ] || [ -z "$PROVIDER_PASS" ] && {
        echo_error "Все поля обязательны!"; PAUSE; return 1; }

    cat > "$PROVIDER_CONFIG" <<EOF
PROVIDER_NAME=$PROVIDER_NAME
PROVIDER_LOGIN=$PROVIDER_LOGIN
PROVIDER_PASS=$PROVIDER_PASS
EOF

    local purl="http://$PROVIDER_NAME/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"
    echo_info "Получаем плейлист от провайдера..."
    if wget -q --timeout=15 -O "$PLAYLIST_FILE" "$purl" 2>/dev/null; then
        if [ -s "$PLAYLIST_FILE" ]; then
            local channels=$(get_channel_count)
            echo_success "Плейлист загружен! Провайдер: $PROVIDER_NAME, Каналов: $channels"
            save_config "provider" "$purl" "$PROVIDER_NAME"
            local now=$(get_timestamp)
            save_schedule "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
            start_http_server
        else
            echo_error "Не удалось получить плейлист!"; PAUSE; return 1
        fi
    else
        echo_error "Ошибка подключения к провайдеру!"; PAUSE; return 1
    fi
}

# ==========================================
# Настройка EPG
# ==========================================
setup_epg() {
    echo_color "Настройка EPG телепрограммы"
    echo ""
    load_epg_config
    [ -n "$EPG_URL" ] && echo_info "Текущий EPG URL: $EPG_URL"
    echo ""
    echo_info "Введите ссылку на EPG (XMLTV формат):"
    echo_info "Пример: http://epg.example.com/epg.xml.gz"
    echo ""
    echo -ne "${YELLOW}EPG URL: ${NC}"
    read EPG_URL </dev/tty

    [ -z "$EPG_URL" ] && { echo_error "URL не может быть пустым!"; PAUSE; return 1; }

    echo_info "Скачиваем EPG..."
    if wget -q --timeout=30 -O "$EPG_FILE" "$EPG_URL" 2>/dev/null; then
        if [ -s "$EPG_FILE" ]; then
            local size=$(wc -c < "$EPG_FILE" 2>/dev/null)
            echo_success "EPG загружен! Размер: $((size / 1024)) KB"
            cat > "$EPG_CONFIG" <<EOF
EPG_URL=$EPG_URL
EOF
            local now=$(get_timestamp)
            save_schedule "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"
            start_http_server
        else
            echo_error "EPG файл пуст!"; rm -f "$EPG_FILE"; PAUSE; return 1
        fi
    else
        echo_error "Не удалось скачать EPG!"; PAUSE; return 1
    fi
}

remove_epg() {
    rm -f "$EPG_FILE" "$EPG_CONFIG"
    echo_success "EPG удалён"
}

# ==========================================
# Настройка расписания
# ==========================================
setup_schedule() {
    load_schedule
    echo_color "Настройка расписания обновлений"
    echo ""
    echo_info "Плейлист: $(interval_to_text $PLAYLIST_INTERVAL) | EPG: $(interval_to_text $EPG_INTERVAL)"
    echo ""
    echo_info "Интервал обновления плейлиста:"
    echo -e "  ${CYAN}0) Выключено  1) Каждый час  2) Каждые 6ч  3) Каждые 12ч  4) Раз в сутки${NC}"
    echo -ne "${YELLOW}Выберите (0-4): ${NC}"
    read pl_interval </dev/tty

    case "$pl_interval" in
        0|1|6|12|24) PLAYLIST_INTERVAL=$pl_interval ;;
        2) PLAYLIST_INTERVAL=6 ;;
        3) PLAYLIST_INTERVAL=12 ;;
        4) PLAYLIST_INTERVAL=24 ;;
        *) PLAYLIST_INTERVAL=0 ;;
    esac

    echo ""
    echo_info "Интервал обновления EPG:"
    echo -e "  ${CYAN}0) Выключено  1) Каждый час  2) Каждые 6ч  3) Каждые 12ч  4) Раз в сутки${NC}"
    echo -ne "${YELLOW}Выберите (0-4): ${NC}"
    read epg_interval </dev/tty

    case "$epg_interval" in
        0|1|6|12|24) EPG_INTERVAL=$epg_interval ;;
        2) EPG_INTERVAL=6 ;;
        3) EPG_INTERVAL=12 ;;
        4) EPG_INTERVAL=24 ;;
        *) EPG_INTERVAL=0 ;;
    esac

    save_schedule "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$EPG_LAST_UPDATE"

    if [ "$PLAYLIST_INTERVAL" -gt 0 ] || [ "$EPG_INTERVAL" -gt 0 ]; then
        start_scheduler
        echo_success "Расписание настроено! Планировщик запущен."
    else
        stop_scheduler
        echo_success "Расписание отключено."
    fi
}

# ==========================================
# Удаление плейлиста
# ==========================================
remove_playlist() {
    echo_color "Удаление плейлиста"
    rm -f "$PLAYLIST_FILE" "$CONFIG_FILE" "$PROVIDER_CONFIG"
    stop_http_server
    echo_success "Плейлист удалён!"
}

# ==========================================
# Автозапуск
# ==========================================
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
    [ -f /etc/iptv/iptv-admin.cgi ] && cp /etc/iptv/iptv-admin.cgi /www/iptv/cgi-bin/index.cgi && chmod +x /www/iptv/cgi-bin/index.cgi
    busybox httpd -p 8082 -h /www/iptv -c '/cgi-bin/*.cgi' &
    if [ -f /etc/iptv/schedule.conf ]; then
        . /etc/iptv/schedule.conf
        if [ "$PLAYLIST_INTERVAL" -gt 0 ] || [ "$EPG_INTERVAL" -gt 0 ]; then
            /bin/sh /tmp/iptv-scheduler.sh &
        fi
    fi
}
stop() {
    kill $(cat /var/run/iptv-httpd.pid 2>/dev/null) 2>/dev/null
    kill $(cat /var/run/iptv-scheduler.pid 2>/dev/null) 2>/dev/null
    rm -f /var/run/iptv-httpd.pid /var/run/iptv-scheduler.pid
}
INITEOF
        chmod +x /etc/init.d/iptv-manager
        /etc/init.d/iptv-manager enable 2>/dev/null
        echo_success "Автозапуск включён"
    fi
}

# ==========================================
# Главное меню
# ==========================================
show_menu() {
    clear
    load_schedule
    echo -e "${MAGENTA}╔══════════════════════════════════════════╗"
    echo -e "║     IPTV Manager v$IPTV_MANAGER_VERSION                  ║"
    echo -e "╠══════════════════════════════════════════╣"
    echo -e "║${NC} Управление IPTV на OpenWrt             ${MAGENTA}║"
    echo -e "╠══════════════════════════════════════════╣"
    echo -e "║${NC} IP: ${CYAN}$LAN_IP                              ${MAGENTA}║"
    echo -e "║${NC} Порт: ${CYAN}$IPTV_PORT                              ${MAGENTA}║"
    echo -e "╚══════════════════════════════════════════╝${NC}"
    echo ""

    get_playlist_info
    echo ""
    get_epg_info
    echo ""

    echo_info "Расписание:"
    echo_info "  Плейлист: $(interval_to_text $PLAYLIST_INTERVAL)"
    echo_info "  EPG: $(interval_to_text $EPG_INTERVAL)"
    [ -n "$PLAYLIST_LAST_UPDATE" ] && echo_info "  Последнее обновление плейлиста: $PLAYLIST_LAST_UPDATE"
    [ -n "$EPG_LAST_UPDATE" ] && echo_info "  Последнее обновление EPG: $EPG_LAST_UPDATE"
    echo ""

    if [ -f "$HTTPD_PID" ] && kill -0 $(cat "$HTTPD_PID") 2>/dev/null; then
        echo_success "HTTP-сервер: запущен"
        echo_info "Админка: http://$LAN_IP:$IPTV_PORT/cgi-bin/index.cgi"
    else
        echo_error "HTTP-сервер: остановлен"
    fi
    echo ""

    echo -e "${CYAN}═══ Плейлист ═══${NC}"
    echo -e "${CYAN}1) ${GREEN}Загрузить по ссылке${NC}"
    echo -e "${CYAN}2) ${GREEN}Загрузить из файла${NC}"
    echo -e "${CYAN}3) ${GREEN}Настроить провайдера (логин/пароль)${NC}"
    echo -e "${CYAN}4) ${GREEN}Обновить плейлист${NC}"
    echo ""
    echo -e "${CYAN}═══ EPG ═══${NC}"
    echo -e "${CYAN}5) ${GREEN}Настроить EPG${NC}"
    echo -e "${CYAN}6) ${GREEN}Обновить EPG${NC}"
    echo -e "${CYAN}7) ${GREEN}Удалить EPG${NC}"
    echo ""
    echo -e "${CYAN}═══ Расписание ═══${NC}"
    echo -e "${CYAN}8) ${GREEN}Настроить расписание обновлений${NC}"
    echo ""
    echo -e "${CYAN}═══ Сервер ═══${NC}"
    echo -e "${CYAN}9) ${GREEN}Запустить HTTP-сервер${NC}"
    echo -e "${CYAN}10) ${GREEN}Остановить HTTP-сервер${NC}"
    echo -e "${CYAN}11) ${GREEN}Вкл/Выкл автозапуск${NC}"
    echo -e "${CYAN}12) ${GREEN}Удалить плейлист${NC}"
    echo ""
    echo -e "${CYAN}Enter) ${GREEN}Выход${NC}"
    echo ""
    echo -ne "${YELLOW}Выберите пункт: ${NC}"
    read choice </dev/tty

    case "$choice" in
        1) load_playlist_from_url ;;
        2) load_playlist_from_file ;;
        3) setup_provider ;;
        4) update_playlist ;;
        5) setup_epg ;;
        6) update_epg ;;
        7) remove_epg ;;
        8) setup_schedule ;;
        9) start_http_server ;;
        10) stop_http_server ;;
        11) setup_autostart ;;
        12) remove_playlist ;;
        *) echo_info "Выход"; exit 0 ;;
    esac

    PAUSE
}

while true; do
    show_menu
done
