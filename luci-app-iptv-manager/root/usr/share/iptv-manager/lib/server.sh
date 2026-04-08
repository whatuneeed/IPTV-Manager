#!/bin/sh
# ==========================================
# IPTV Manager — Server module
# HTTP-сервер, CGI, watchdog
# ==========================================

# Запустить HTTP-сервер
server_start() {
    mkdir -p "$WWW_DIR" "$CGI_DIR" /www/cgi-bin || { log_error "Failed to create directories"; return 1; }

    rm -f "$WWW_DIR/admin.cgi" "$WWW_DIR/channels.json" "$WWW_DIR/player.html" /www/cgi-bin/srv.cgi

    # Копируем статические файлы
    if [ -f "$IPTV_DIR/server.html" ]; then
        cp "$IPTV_DIR/server.html" "$WWW_DIR/server.html" 2>/dev/null || true
    fi
    # Копируем admin.html (отдельный файл, не генерируется)
    if [ -f "$IPTV_DIR/admin.html" ]; then
        cp "$IPTV_DIR/admin.html" "$WWW_DIR/admin.html" 2>/dev/null || true
    fi

    if [ -f "$PLAYLIST_FILE" ]; then
        cp "$PLAYLIST_FILE" "$WWW_DIR/playlist.m3u" || { log_error "Failed to copy playlist"; return 1; }
    else
        echo "#EXTM3U" > "$WWW_DIR/playlist.m3u"
    fi

    # Генерируем CGI
    generate_cgi
    generate_player
    generate_srv_cgi

    # Убиваем старый
    kill -9 "$(pgrep -f "uhttpd.*$IPTV_PORT")" 2>/dev/null || true
    sleep 2

    # Записываем время старта
    date +%s > "$STARTUP_TIME"

    # Запускаем
    ( trap "" HUP INT QUIT; uhttpd -p "0.0.0.0:$IPTV_PORT" -h "$WWW_DIR" -x "$CGI_DIR" -i ".cgi=/bin/sh" </dev/null >/dev/null 2>&1 ) &
    echo $! > "$HTTPD_PID"

    # Проверяем
    local tries=0
    while [ "$tries" -lt "$SERVER_START_TRIES" ]; do
        tries=$((tries + 1))
        sleep 1
        if wget -q --timeout=1 -O /dev/null "http://127.0.0.1:$IPTV_PORT/" 2>/dev/null; then
            break
        fi
    done

    if wget -q --timeout=2 -O /dev/null "http://127.0.0.1:$IPTV_PORT/" 2>/dev/null; then
        local pid
        pid=$(pgrep -f "uhttpd.*$IPTV_PORT" | head -1)
        echo "$pid" > "$HTTPD_PID"
        log_info "Server started on port $IPTV_PORT (PID: $pid, $tries attempts)"
        telegram_server_up 2>/dev/null || true
        echo_success "Сервер запущен! ($tries попыток)"

        # Запускаем watchdog
        setup_watchdog
        return 0
    else
        log_error "Server failed to start on port $IPTV_PORT"
        telegram_server_down 2>/dev/null || true
        echo_error "Ошибка: uhttpd не запустился. Проверьте: logread | grep uhttpd"
        return 1
    fi
}

# Остановить HTTP-сервер
server_stop() {
    kill "$(cat "$HTTPD_PID" 2>/dev/null)" 2>/dev/null || true
    kill "$(pgrep -f "uhttpd.*:$IPTV_PORT" 2>/dev/null)" 2>/dev/null || true
    rm -f "$HTTPD_PID"
    log_info "Server stopped"
    echo_success "Сервер остановлен"
}

# Проверить статус сервера
server_status() {
    if [ -f "$HTTPD_PID" ] && kill -0 "$(cat "$HTTPD_PID" 2>/dev/null)" 2>/dev/null; then
        echo "running"
    elif wget -q -O /dev/null --timeout=2 "http://127.0.0.1:$IPTV_PORT/" 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# Настроить watchdog
setup_watchdog() {
    mkdir -p /usr/bin
    local wd_port="$IPTV_PORT"
    cat > /usr/bin/iptv-watchdog.sh << WDOGEOF
#!/bin/sh
WD_PORT="$wd_port"
trap "" HUP INT QUIT
while true; do
    sleep 20
    if [ -f /www/iptv/cgi-bin/admin.cgi ]; then
        if ! wget -q --timeout=3 -O /dev/null "http://127.0.0.1:\$WD_PORT/cgi-bin/admin.cgi" 2>/dev/null; then
            kill -9 "\$(pgrep -f "uhttpd.*\$WD_PORT")" 2>/dev/null || true
            sleep 1
            mkdir -p /www/iptv /www/iptv/cgi-bin
            [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u 2>/dev/null || true
            [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml 2>/dev/null || true
            ( trap "" HUP INT QUIT; uhttpd -p "0.0.0.0:\$WD_PORT" -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" </dev/null >/dev/null 2>&1 ) &
            sleep 3
        fi
    fi
done
WDOGEOF
    chmod +x /usr/bin/iptv-watchdog.sh

    # Добавляем в rc.local
    if ! grep -q "iptv-watchdog" /etc/rc.local 2>/dev/null; then
        sed -i '/exit 0/d' /etc/rc.local 2>/dev/null || true
        echo '# IPTV Manager watchdog' >> /etc/rc.local
        echo '/usr/bin/iptv-watchdog.sh >/dev/null 2>&1 &' >> /etc/rc.local
        echo 'exit 0' >> /etc/rc.local
    fi

    # Запускаем
    kill "$(pgrep -f "iptv-watchdog")" 2>/dev/null || true
    sleep 1
    /usr/bin/iptv-watchdog.sh >/dev/null 2>&1 &

    if [ -n "$(pgrep -f 'iptv-watchdog')" ]; then
        log_info "Watchdog started"
    else
        log_warn "Watchdog failed to start"
    fi
}

# Удалить watchdog
remove_watchdog() {
    kill "$(pgrep -f "iptv-watchdog")" 2>/dev/null || true
    sed -i '/iptv-watchdog/d' /etc/rc.local 2>/dev/null || true
    sed -i '/IPTV Manager watchdog/d' /etc/rc.local 2>/dev/null || true
    rm -f /usr/bin/iptv-watchdog.sh
}
