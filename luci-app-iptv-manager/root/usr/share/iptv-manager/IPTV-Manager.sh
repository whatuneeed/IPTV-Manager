#!/bin/sh
# ==========================================
# IPTV Manager для OpenWrt v3.21 — Entry Point
# Загружает модули из lib/ и передаёт управление
# ==========================================

# Определяем базовую директорию
IPTV_MANAGER_DIR="$(cd "$(dirname "$0")" && pwd)"

# Загружаем модули
for _mod in "$IPTV_MANAGER_DIR/lib/core.sh" \
            "$IPTV_MANAGER_DIR/lib/logger.sh" \
            "$IPTV_MANAGER_DIR/lib/playlist.sh" \
            "$IPTV_MANAGER_DIR/lib/epg.sh" \
            "$IPTV_MANAGER_DIR/lib/server.sh" \
            "$IPTV_MANAGER_DIR/lib/scheduler.sh" \
            "$IPTV_MANAGER_DIR/lib/security.sh" \
            "$IPTV_MANAGER_DIR/lib/cgi.sh" \
            "$IPTV_MANAGER_DIR/lib/telegram.sh" \
            "$IPTV_MANAGER_DIR/lib/catchup.sh"; do
    if [ -f "$_mod" ]; then
        . "$_mod"
    else
        echo "ERROR: Module not found: $_mod" >&2
        exit 1
    fi
done
unset _mod

# Strip BOM and CRLF при запуске
SELF="$0"
if [ -f "$SELF" ]; then sed -i '1s/^\xef\xbb\xbf//;s/\r$//' "$SELF" 2>/dev/null; fi

# Auto-update on startup
_auto_update() {
    local latest
    latest=$(wget -q --timeout=10 --no-check-certificate -O - "$RAW_URL/IPTV-Manager.sh" 2>/dev/null \
        | head -10 | grep -o 'IPTV_MANAGER_VERSION="[^"]*"' | sed 's/IPTV_MANAGER_VERSION="//;s/"//')
    if [ -n "$latest" ] && [ "$latest" != "$IPTV_MANAGER_VERSION" ]; then
        echo -e "${CYAN}Доступна версия v$latest (у вас v$IPTV_MANAGER_VERSION). Обновляю...${NC}"
        log_info "Auto-update: v$IPTV_MANAGER_VERSION -> v$latest"
        local tmp="/tmp/IPTV-Manager-new.sh"
        if wget -q --timeout=15 --no-check-certificate -O "$tmp" "$RAW_URL/IPTV-Manager.sh" 2>/dev/null && [ -s "$tmp" ]; then
            cp "$tmp" "$IPTV_DIR/IPTV-Manager.sh"
            chmod +x "$IPTV_DIR/IPTV-Manager.sh"
            rm -f "$tmp"
            log_info "Auto-update complete"
            exec sh "$IPTV_DIR/IPTV-Manager.sh"
        else
            log_error "Auto-update failed: could not download new version"
        fi
    fi
}
_auto_update

# Инициализация
core_init

# ==========================================
# Обработка команд start/stop/status/restart
# ==========================================
case "$1" in
    start)
        echo "=== Запуск IPTV-сервера ==="
        server_start
        exit $?
        ;;
    stop)
        echo "=== Остановка IPTV-сервера ==="
        server_stop
        exit 0
        ;;
    status)
        server_status
        exit 0
        ;;
    restart)
        server_stop
        sleep 1
        server_start
        exit $?
        ;;
    --server)
        # Для procd init — только генерация CGI, без запуска сервера
        generate_cgi
        generate_player
        generate_srv_cgi
        exit 0
        ;;
esac

# ==========================================
# Загружаем остальные функции (меню, CGI-генерация, и т.д.)
# из оригинального скрипта — пока что оставляем inline
# TODO: вынести в lib/menu.sh и lib/cgi.sh
# ==========================================

# Здесь вставляется полный код генерации CGI, меню и т.д.
# (из оригинального IPTV-Manager.sh, строки с generate_server_html до конца)
# Для экономии места — это тот же код, только использует функции из модулей

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
var sb=qs('#startBtn');sb.disabled=false;sb.textContent=working?'\u2713 Работает':'Запустить';
var ob=qs('#stopBtn');ob.disabled=!working;
}
function chk(){var x=new XMLHttpRequest();x.open('GET',API+'?action=server_status',true);x.timeout=5000;x.onload=function(){try{var r=JSON.parse(x.responseText);setStatus(r.status==='ok'&&r.output.indexOf('running')>-1)}catch(e){setStatus(false)}};x.onerror=x.ontimeout=function(){setStatus(false)};x.send()}
qs('#startBtn').onclick=function(){this.disabled=true;this.textContent='Запуск...';qs('#status').textContent='Запуск...';qs('#status').style.color='var(--primary)';var x=new XMLHttpRequest();x.open('GET',API+'?action=server_start',true);x.timeout=15000;x.onload=function(){setTimeout(chk,10000)};x.onerror=x.ontimeout=function(){setTimeout(chk,10000)};x.send()};
qs('#stopBtn').onclick=function(){this.disabled=true;this.textContent='Остановка...';qs('#status').textContent='Остановка...';qs('#status').style.color='var(--danger)';var x=new XMLHttpRequest();x.open('GET',API+'?action=server_stop',true);x.timeout=15000;x.onload=function(){setTimeout(chk,5000)};x.onerror=x.ontimeout=function(){setTimeout(chk,5000)};x.send()};
chk();
</script>
</body>
</html>
SERVEREOF
}

# ==========================================
# Генерация srv.cgi для LuCI
# ==========================================
generate_srv_cgi() {
    mkdir -p /www/cgi-bin || { log_error "Failed to create /www/cgi-bin"; return 1; }
    cat > /www/cgi-bin/srv.cgi << 'SRVEOF'
#!/bin/sh
PID=/var/run/iptv-httpd.pid
HDR() { printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'; }
JSON() { printf 'Content-Type: application/json\r\n\r\n'; }
ACT=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')
case "$ACTION$ACT" in
    *start*)
        JSON
        kill "$(pgrep -f "uhttpd.*8082")" 2>/dev/null || true
        sleep 1
        mkdir -p /www/iptv /www/iptv/cgi-bin
        [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u 2>/dev/null || true
        [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml 2>/dev/null || true
        uhttpd -p 0.0.0.0:8082 -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" </dev/null >/dev/null 2>&1 &
        printf '{"ok":true}'
        ;;
    *stop*)
        JSON
        kill "$(pgrep -f "uhttpd.*8082")" 2>/dev/null || true
        rm -f "$PID" 2>/dev/null || true
        printf '{"ok":true}'
        ;;
    *status*)
        JSON
        if [ -f "$PID" ] && kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null; then
            printf '{"ok":true,"running":true}'
        elif wget -q -O /dev/null --timeout=2 http://127.0.0.1:8082/ 2>/dev/null; then
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
    if [ -f /www/luci-static/resources/view/iptv-manager/srv.html ]; then
        cp /www/luci-static/resources/view/iptv-manager/srv.html /www/cgi-bin/srv.html || true
    fi
}

# ==========================================
# Генерация CGI — использует модуль cgi.sh
# ==========================================
generate_cgi() {
    cgi_generate_admin
    cgi_generate_epg
}

generate_player() {
    # Копируем player.html если есть
    if [ -f "$IPTV_MANAGER_DIR/../player.html" ]; then
        cp "$IPTV_MANAGER_DIR/../player.html" /www/iptv/player.html 2>/dev/null || true
    elif [ -f "/etc/iptv/player.html" ]; then
        cp /etc/iptv/player.html /www/iptv/player.html 2>/dev/null || true
    fi
    # Копируем admin.html
    if [ -f "$IPTV_MANAGER_DIR/../luci-app-iptv-manager/htdocs/luci-static/resources/view/iptv-manager/admin.html" ]; then
        cp "$IPTV_MANAGER_DIR/../luci-app-iptv-manager/htdocs/luci-static/resources/view/iptv-manager/admin.html" /www/iptv/admin.html 2>/dev/null || true
    fi
}

# ==========================================
# Главное меню (SSH)
# ==========================================
print_header() {
    clear
    load_sched
    [ -z "$PLAYLIST_INTERVAL" ] && PLAYLIST_INTERVAL="0"
    [ -z "$EPG_INTERVAL" ] && EPG_INTERVAL="0"
    [ -z "$PLAYLIST_LAST_UPDATE" ] && PLAYLIST_LAST_UPDATE="—"
    [ -z "$EPG_LAST_UPDATE" ] && EPG_LAST_UPDATE="--"

    local ch; ch=$(get_ch)
    local srv_status="❌ Остановлен"
    local srv_uptime="—"

    if [ -f "$HTTPD_PID" ] && kill -0 "$(cat "$HTTPD_PID" 2>/dev/null)" 2>/dev/null; then
        srv_status="✅ Запущен"
        if [ -f "$STARTUP_TIME" ]; then
            local _sn; _sn=$(cat "$STARTUP_TIME" 2>/dev/null)
            if [ -n "$_sn" ]; then
                local _now; _now=$(date +%s)
                local _diff=$((_now - _sn))
                if [ "$_diff" -gt 0 ] 2>/dev/null; then
                    local _id=$((_diff / 86400)); local _ih=$(((_diff % 86400) / 3600)); local _im=$(((_diff % 3600) / 60))
                    srv_uptime=""; [ "$_id" -gt 0 ] && srv_uptime="${_id}д "
                    srv_uptime="${srv_uptime}${_ih}ч ${_im}м"
                fi
            fi
        fi
    fi

    load_config; load_epg
    local display_epg="❌"; [ -n "$EPG_URL" ] && display_epg="✅"
    local display_ram="0K"; [ -d /etc/iptv ] && display_ram=$(du -sh /etc/iptv 2>/dev/null | cut -f1)
    local display_disk="0K"; [ -d /www/iptv ] && display_disk=$(du -sh /www/iptv 2>/dev/null | cut -f1)

    local hd_count=0; [ -f "$PLAYLIST_FILE" ] && hd_count=$(grep -ci "hd\|1080\|4k\|2160\|uhd" "$PLAYLIST_FILE" 2>/dev/null || true)
    [ -z "$hd_count" ] && hd_count=0
    local sd_count=$((ch - hd_count)); [ "$sd_count" -lt 0 ] 2>/dev/null && sd_count=0
    local groups=""; [ -f "$PLAYLIST_FILE" ] && groups=$(grep -o 'group-title="[^"]*"' "$PLAYLIST_FILE" 2>/dev/null | sed 's/group-title="//;s/"//' | sort -u | grep . || true)
    local grp_count=0; [ -n "$groups" ] && grp_count=$(echo "$groups" | wc -l | tr -d ' ')

    echo ""
    echo -e "══════════════════════════════════════════"
    echo -e "     IPTV Manager v${CYAN}$IPTV_MANAGER_VERSION${NC}                   "
    echo -e "══════════════════════════════════════════"
    echo -e "🌐 ${CYAN}$LAN_IP${NC}:${CYAN}$IPTV_PORT${NC}"
    echo -e "📺 ${GREEN}${ch}${NC} каналов 🎬 HD:${CYAN}${hd_count}${NC}  SD:${CYAN}${sd_count}${NC} 📂 ${CYAN}${grp_count}${NC} групп"
    echo -e "📡 EPG: ${CYAN}${display_epg}${NC}  💾 ${CYAN}${display_ram}${NC}  🗄 ${CYAN}${display_disk}${NC}"
    echo -e "🖥 Сервер: ${GREEN}${srv_status}${NC}  ⏱ ${CYAN}${srv_uptime}${NC}"
    echo -e "══════════════════════════════════════════"
}

show_menu() {
    print_header
    load_config
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
    echo -e "  ${CYAN}8)${NC} ${GREEN}📱  Telegram${NC}"
    echo -e "  ${CYAN}9)${NC} ${GREEN}🗑️   Удалить${NC}"
    echo ""
    echo -e "${CYAN} 0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1) menu_playlist ;; 2) menu_epg ;; 3) menu_server ;;
        4) menu_schedule ;; 5) menu_security ;; 6) menu_backup ;;
        7) menu_update ;; 8) telegram_setup ;; 9) menu_uninstall ;; 0) exit 0 ;; *) echo_info "Отмена" ;;
    esac
    PAUSE
}

# Упрощённые меню-функции (полные — в оригинальном скрипте)
menu_playlist() {
    print_header; load_config
    echo -e "${YELLOW}── 📡 Плейлист ──────────────────────────${NC}"
    echo -e "  Каналов: ${GREEN}$(get_ch)${NC}"
    echo ""
    echo -e "${CYAN} 1) Загрузить по ссылке${NC}"
    echo -e "${CYAN} 2) Обновить${NC}"
    echo -e "${CYAN} 3) Удалить${NC}"
    echo -e "${CYAN} 9) Назад${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"; read c </dev/tty
    case "$c" in
        1) echo -ne "${YELLOW}URL: ${NC}"; read url </dev/tty
           if [ -n "$url" ]; then
               playlist_download "$url" && save_config "url" "$url" "" && server_start
           fi ;;
        2) playlist_refresh && server_start ;;
        3) playlist_remove; server_stop ;;
    esac
}

menu_epg() {
    print_header; load_epg
    echo -e "${YELLOW}── 📺 EPG ─────────────────────────${NC}"
    echo -e "  URL: ${CYAN}${EPG_URL:--}${NC}"
    echo ""
    echo -e "${CYAN} 1) Настроить${NC}"
    echo -e "${CYAN} 2) Обновить${NC}"
    echo -e "${CYAN} 3) Удалить${NC}"
    echo -e "${CYAN} 9) Назад${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"; read c </dev/tty
    case "$c" in
        1) echo -ne "${YELLOW}EPG URL: ${NC}"; read url </dev/tty
           [ -n "$url" ] && epg_download "$url" ;;
        2) epg_refresh ;;
        3) epg_remove ;;
    esac
}

menu_server() {
    print_header
    echo -e "${YELLOW}── 🔧 Сервер ────────────────────────${NC}"
    echo -e "  Статус: ${CYAN}$(server_status)${NC}"
    echo ""
    echo -e "${CYAN} 1) Запустить/Остановить${NC}"
    echo -e "${CYAN} 2) Перезапустить${NC}"
    echo -e "${CYAN} 9) Назад${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"; read c </dev/tty
    case "$c" in
        1) if [ "$(server_status)" = "running" ]; then server_stop; else server_start; fi ;;
        2) server_stop; sleep 1; server_start ;;
    esac
}

menu_schedule() {
    print_header; load_sched
    echo -e "${YELLOW}── ⏰ Расписание ───────────────────────${NC}"
    echo -e "  Плейлист: ${CYAN}$(int_text $PLAYLIST_INTERVAL)${NC}  EPG: ${CYAN}$(int_text $EPG_INTERVAL)${NC}"
    echo ""
    echo -e "${CYAN} 1) Каждый час${NC}"
    echo -e "${CYAN} 2) Каждые 6ч${NC}"
    echo -e "${CYAN} 3) Каждые 12ч${NC}"
    echo -e "${CYAN} 4) Раз в сутки${NC}"
    echo -e "${CYAN} 5) Выкл${NC}"
    echo -e "${CYAN} 9) Назад${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"; read c </dev/tty
    case "$c" in
        1) PLAYLIST_INTERVAL=1;; 2) PLAYLIST_INTERVAL=6;; 3) PLAYLIST_INTERVAL=12;;
        4) PLAYLIST_INTERVAL=24;; *) PLAYLIST_INTERVAL=0;;
    esac
    load_sched
    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$EPG_LAST_UPDATE"
    if [ "$PLAYLIST_INTERVAL" -gt 0 ] 2>/dev/null || [ "$EPG_INTERVAL" -gt 0 ] 2>/dev/null; then
        scheduler_start
    else
        scheduler_stop
    fi
}

menu_security() {
    print_header; . "$SECURITY_FILE" 2>/dev/null
    echo -e "${YELLOW}── 🔒 Безопасность ──────────────────────${NC}"
    echo -e "  Пароль: ${CYAN}${ADMIN_USER:--}${NC}"
    echo -e "  API токен: ${CYAN}${API_TOKEN:--}${NC}"
    echo ""
    echo -e "${CYAN} 1) Пароль${NC}"
    echo -e "${CYAN} 2) API токен${NC}"
    echo -e "${CYAN} 9) Назад${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"; read c </dev/tty
    case "$c" in
        1) echo -ne "${YELLOW}Логин: ${NC}"; read u </dev/tty
           echo -ne "${YELLOW}Пароль: ${NC}"; stty -echo; read p </dev/tty; stty echo; echo ""
           security_set_password "$u" "$p" ;;
        2) echo -ne "${YELLOW}Токен: ${NC}"; read t </dev/tty
           security_set_token "$t" ;;
    esac
}

menu_backup() {
    print_header
    echo -e "${YELLOW}── 💾 Бэкап ────────────────────────${NC}"
    echo -e "${CYAN} 1) Создать${NC}"
    echo -e "${CYAN} 2) Восстановить${NC}"
    echo -e "${CYAN} 9) Назад${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"; read c </dev/tty
    case "$c" in
        1) BF="/tmp/iptv-backup-$(date +%Y%m%d%H%M%S).tar.gz"
           tar czf "$BF" -C /etc iptv 2>/dev/null && echo_success "Бэкап: $BF" ;;
        2) echo -ne "${YELLOW}Путь к архиву: ${NC}"; read f </dev/tty
           [ -f "$f" ] && tar xzf "$f" -C / 2>/dev/null && echo_success "Восстановлено" ;;
    esac
}

menu_update() {
    print_header
    echo -e "${YELLOW}── 🔄 Обновление ────────────────────────${NC}"
    echo -e "  Версия: ${CYAN}$IPTV_MANAGER_VERSION${NC}"
    echo ""
    local latest
    latest=$(wget -q --timeout=10 --no-check-certificate -O - "$RAW_URL/IPTV-Manager.sh" 2>/dev/null | head -10 | grep -o 'IPTV_MANAGER_VERSION="[^"]*"' | sed 's/IPTV_MANAGER_VERSION="//;s/"//')
    echo -e "  Доступна: ${CYAN}${latest:--}${NC}"
    echo ""
    echo -e "${CYAN} 1) Обновить${NC}"
    echo -e "${CYAN} 2) Сброс к заводским${NC}"
    echo -e "${CYAN} 9) Назад${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"; read c </dev/tty
    case "$c" in
        1) _auto_update ;;
        2) echo -ne "${YELLOW}Сбросить? (y/N): ${NC}"; read ans </dev/tty
           case "$ans" in y|Y) rm -rf "$IPTV_DIR"/*; server_stop; exec sh "$0";;esac ;;
    esac
}

menu_uninstall() {
    print_header
    echo -e "${YELLOW}── ❌ Полное удаление ───────────────────${NC}"
    echo -e "  Будет удалено:"
    echo -e "  • Модули: /usr/share/iptv-manager/"
    echo -e "  • Конфиги: /etc/iptv/"
    echo -e "  • Runtime: /www/iptv/"
    echo -e "  • LuCI views: /www/luci-static/resources/view/iptv-manager/"
    echo -e "  • LuCI menu/ACL"
    echo -e "  • Init скрипт, watchdog, symlink"
    echo ""
    echo -ne "${YELLOW}Удалить IPTV Manager полностью? (y/N): ${NC}"; read ans </dev/tty
    case "$ans" in
        y|Y)
            echo_info "Останавливаем сервисы..."
            server_stop 2>/dev/null
            scheduler_stop 2>/dev/null
            remove_watchdog 2>/dev/null

            # Удаляем модули
            rm -rf /usr/share/iptv-manager

            # Удаляем конфиги и runtime
            rm -rf "$IPTV_DIR" /www/iptv

            # Удаляем LuCI файлы
            rm -rf /www/luci-static/resources/view/iptv-manager
            rm -f /usr/share/luci/menu.d/luci-app-iptv-manager.json
            rm -f /usr/share/rpcd/acl.d/luci-app-iptv-manager.json

            # Удаляем CGI файлы
            rm -f /www/cgi-bin/srv.cgi /www/cgi-bin/srv.html

            # Удаляем init и конфиги
            rm -f /etc/init.d/iptv-manager
            rm -f /etc/uci-defaults/99-luci-iptv-manager
            rm -f /etc/config/iptv_uhttpd

            # Удаляем временные файлы
            rm -f /var/run/iptv-httpd.pid /var/run/iptv-scheduler.pid
            rm -f /tmp/iptv-*.tmp /tmp/iptv-*.tar.gz /tmp/iptv-*.m3u /tmp/iptv-*.*
            rm -f /tmp/epg-dl.tmp /tmp/rf_tmp /tmp/iptv-blocked-*

            # Удаляем symlink и watchdog
            rm -f /usr/bin/iptv-watchdog.sh /usr/bin/iptv

            # Перезапускаем rpcd
            /etc/init.d/rpcd restart 2>/dev/null || true

            echo_success "IPTV Manager полностью удалён"
            echo_info "Для выхода введите Enter"
            ;;
        *) echo_info "Отмена"; return ;;
    esac
}

# ==========================================
# Express setup (первый запуск)
# ==========================================
express_setup() {
    echo_color "🚀 Экспресс-настройка IPTV Manager"
    echo ""
    echo -e "${YELLOW}[1/4] Загружаю плейлист 'TV'...${NC}"
    local default_pl="https://raw.githubusercontent.com/smolnp/IPTVru/refs/heads/gh-pages/IPTVru.m3u"
    if playlist_download "$default_pl"; then
        printf 'PLAYLIST_TYPE="url"\nPLAYLIST_URL="%s"\nPLAYLIST_SOURCE=""\nPLAYLIST_NAME="TV"\n' "$default_pl" > "$CONFIG_FILE"
        echo_success "✓ Плейлист 'TV' загружен ($(get_ch) каналов)"
    else
        echo_error "✗ Не удалось скачать плейлист"
    fi

    echo -e "${YELLOW}[2/4] EPG: пропущено${NC}"

    echo -e "${YELLOW}[3/4] Расписание: каждые 6ч...${NC}"
    save_sched "6" "0" "$(get_ts)" "$(get_ts)"
    scheduler_start

    echo -e "${YELLOW}[4/4] Запускаю сервер...${NC}"
    server_start

    echo ""
    echo_color "✅ Готово! http://$LAN_IP:$IPTV_PORT/cgi-bin/admin.cgi"
}

# ==========================================
# Проверка: нужна ли настройка?
# ==========================================
_needs_setup() {
    load_config
    local has_pl=false
    [ -n "$PLAYLIST_TYPE" ] && [ -n "$PLAYLIST_URL" ] && has_pl=true
    local srv_running=false
    [ -f "$HTTPD_PID" ] && kill -0 "$(cat "$HTTPD_PID" 2>/dev/null)" 2>/dev/null && srv_running=true
    if [ "$has_pl" = "false" ] && [ "$srv_running" = "false" ]; then
        return 0  # needs setup
    fi
    return 1
}

# ==========================================
# Главный цикл
# ==========================================
if _needs_setup; then
    echo ""
    echo -e "${YELLOW}💡 IPTV Manager не настроен. Нажмите 1 для быстрой настройки.${NC}"
    echo ""
    echo -e "${CYAN} 1) Запустить настройку${NC}"
    echo -e "${CYAN} 0) Выход${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in 1) express_setup;; *) exit 0;; esac
fi

while true; do show_menu; done
