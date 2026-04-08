#!/bin/sh
# ==========================================
# IPTV Manager v3.21 — Installer / Updater / Uninstaller
# Usage: wget -q -O - https://raw.githubusercontent.com/whatuneeed/IPTV-Manager/main/install.sh | sh
# ==========================================

GREEN="\033[1;32m"; RED="\033[1;31m"; CYAN="\033[1;36m"; YELLOW="\033[1;33m"; NC="\033[0m"

echo_info() { echo -e "${CYAN}$1${NC}"; }
echo_success() { echo -e "${GREEN}✓ $1${NC}"; }
echo_error() { echo -e "${RED}✗ $1${NC}"; }
echo_step() { echo -e "\n${YELLOW}── $1 ──────────────────────────────${NC}"; }

REPO="whatuneeed/IPTV-Manager"
BRANCH="main"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
TMP_DIR="/tmp/iptv-install-$$"
IPTV_DIR="/etc/iptv"
BACKUP_DIR="/tmp/iptv-backup-$$"

cleanup() {
    rm -rf "$TMP_DIR" "$BACKUP_DIR"
    rm -f /tmp/iptv-*.tmp /tmp/iptv-*.tar.gz /tmp/iptv-*.*
}

dl() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")" 2>/dev/null
    wget -q --timeout=15 --no-check-certificate -O "$dst" "${RAW}/${src}" 2>/dev/null && [ -s "$dst" ]
}

# ============================
# Check if installed
# ============================
is_installed() {
    [ -f /usr/share/iptv-manager/IPTV-Manager.sh ] && [ -f /etc/init.d/iptv-manager ]
}

get_status() {
    if is_installed; then
        local ch=0
        [ -f "$IPTV_DIR/playlist.m3u" ] && ch=$(grep -c "^#EXTINF" "$IPTV_DIR/playlist.m3u" 2>/dev/null || echo 0)
        local srv="❌ Остановлен"
        pgrep -f "uhttpd.*8082" >/dev/null 2>&1 && srv="✅ Запущен"
        echo "$ch|$srv"
    else
        echo "0|not_installed"
    fi
}

# ============================
# Download all files
# ============================
download_files() {
    echo_step "Загрузка файлов"
    mkdir -p "$TMP_DIR"

    local FILES="
luci-app-iptv-manager/root/usr/share/iptv-manager/IPTV-Manager.sh:usr/share/iptv-manager/IPTV-Manager.sh
luci-app-iptv-manager/root/usr/share/iptv-manager/lib/core.sh:usr/share/iptv-manager/lib/core.sh
luci-app-iptv-manager/root/usr/share/iptv-manager/lib/logger.sh:usr/share/iptv-manager/lib/logger.sh
luci-app-iptv-manager/root/usr/share/iptv-manager/lib/playlist.sh:usr/share/iptv-manager/lib/playlist.sh
luci-app-iptv-manager/root/usr/share/iptv-manager/lib/epg.sh:usr/share/iptv-manager/lib/epg.sh
luci-app-iptv-manager/root/usr/share/iptv-manager/lib/server.sh:usr/share/iptv-manager/lib/server.sh
luci-app-iptv-manager/root/usr/share/iptv-manager/lib/scheduler.sh:usr/share/iptv-manager/lib/scheduler.sh
luci-app-iptv-manager/root/usr/share/iptv-manager/lib/security.sh:usr/share/iptv-manager/lib/security.sh
luci-app-iptv-manager/root/usr/share/iptv-manager/lib/cgi.sh:usr/share/iptv-manager/lib/cgi.sh
luci-app-iptv-manager/root/usr/share/iptv-manager/lib/telegram.sh:usr/share/iptv-manager/lib/telegram.sh
luci-app-iptv-manager/root/usr/share/iptv-manager/lib/catchup.sh:usr/share/iptv-manager/lib/catchup.sh
luci-app-iptv-manager/root/etc/init.d/iptv-manager:etc/init.d/iptv-manager
luci-app-iptv-manager/root/etc/uci-defaults/99-luci-iptv-manager:etc/uci-defaults/99-luci-iptv-manager
luci-app-iptv-manager/root/etc/config/iptv_uhttpd:etc/config/iptv_uhttpd
luci-app-iptv-manager/root/usr/share/luci/menu.d/luci-app-iptv-manager.json:usr/share/luci/menu.d/luci-app-iptv-manager.json
luci-app-iptv-manager/root/usr/share/rpcd/acl.d/luci-app-iptv-manager.json:usr/share/rpcd/acl.d/luci-app-iptv-manager.json
luci-app-iptv-manager/htdocs/luci-static/resources/view/iptv-manager/admin.html:www/luci-static/resources/view/iptv-manager/admin.html
luci-app-iptv-manager/htdocs/luci-static/resources/view/iptv-manager/srv.cgi:www/luci-static/resources/view/iptv-manager/srv.cgi
luci-app-iptv-manager/htdocs/luci-static/resources/view/iptv-manager/srv.html:www/luci-static/resources/view/iptv-manager/srv.html
luci-app-iptv-manager/htdocs/luci-static/resources/view/iptv-manager/iptv.js:www/luci-static/resources/view/iptv-manager/iptv.js
luci-app-iptv-manager/htdocs/luci-static/resources/view/iptv-manager/player.js:www/luci-static/resources/view/iptv-manager/player.js
luci-app-iptv-manager/htdocs/luci-static/resources/view/iptv-manager/server.js:www/luci-static/resources/view/iptv-manager/server.js
player.html:etc/iptv/player.html
"
    local ok=0 fail=0
    echo "$FILES" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        local src=$(echo "$line" | cut -d: -f1)
        local dst=$(echo "$line" | cut -d: -f2)
        if dl "$src" "$TMP_DIR/$dst"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            echo_error "FAIL: $src"
        fi
    done

    # Re-count files
    ok=0; fail=0
    for line in $FILES; do
        [ -z "$line" ] && continue
        local dst=$(echo "$line" | cut -d: -f2)
        if [ -f "$TMP_DIR/$dst" ] && [ -s "$TMP_DIR/$dst" ]; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done

    echo_success "Загружено: $ok файлов (ошибок: $fail)"
    [ "$ok" -lt 10 ] && return 1
    return 0
}

# ============================
# Install files
# ============================
install_files() {
    echo_step "Установка"

    # Modules
    cp "$TMP_DIR/usr/share/iptv-manager/IPTV-Manager.sh" /usr/share/iptv-manager/IPTV-Manager.sh 2>/dev/null && {
        mkdir -p /usr/share/iptv-manager/lib
        for f in core.sh logger.sh playlist.sh epg.sh server.sh scheduler.sh security.sh cgi.sh telegram.sh catchup.sh; do
            cp "$TMP_DIR/usr/share/iptv-manager/lib/$f" /usr/share/iptv-manager/lib/$f 2>/dev/null
            chmod 644 /usr/share/iptv-manager/lib/$f
        done
        chmod 755 /usr/share/iptv-manager/IPTV-Manager.sh
        echo_success "Модули: /usr/share/iptv-manager/"
    }

    # Config dir
    mkdir -p "$IPTV_DIR"

    # Init script
    [ -f "$TMP_DIR/etc/init.d/iptv-manager" ] && {
        cp "$TMP_DIR/etc/init.d/iptv-manager" /etc/init.d/iptv-manager
        chmod 755 /etc/init.d/iptv-manager
        echo_success "Init-скрипт"
    }

    # UCI defaults
    [ -f "$TMP_DIR/etc/uci-defaults/99-luci-iptv-manager" ] && {
        cp "$TMP_DIR/etc/uci-defaults/99-luci-iptv-manager" /etc/uci-defaults/99-luci-iptv-manager
        chmod 755 /etc/uci-defaults/99-luci-iptv-manager
    }

    # uhttpd config
    [ -f "$TMP_DIR/etc/config/iptv_uhttpd" ] && {
        cp "$TMP_DIR/etc/config/iptv_uhttpd" /etc/config/iptv_uhttpd
    }

    # LuCI menu
    [ -f "$TMP_DIR/usr/share/luci/menu.d/luci-app-iptv-manager.json" ] && {
        mkdir -p /usr/share/luci/menu.d
        cp "$TMP_DIR/usr/share/luci/menu.d/luci-app-iptv-manager.json" /usr/share/luci/menu.d/luci-app-iptv-manager.json
    }

    # LuCI ACL
    [ -f "$TMP_DIR/usr/share/rpcd/acl.d/luci-app-iptv-manager.json" ] && {
        mkdir -p /usr/share/rpcd/acl.d
        cp "$TMP_DIR/usr/share/rpcd/acl.d/luci-app-iptv-manager.json" /usr/share/rpcd/acl.d/luci-app-iptv-manager.json
        chmod 644 /usr/share/rpcd/acl.d/luci-app-iptv-manager.json
    }

    # LuCI views
    mkdir -p /www/luci-static/resources/view/iptv-manager
    for f in admin.html srv.cgi srv.html iptv.js player.js server.js; do
        [ -f "$TMP_DIR/www/luci-static/resources/view/iptv-manager/$f" ] && {
            cp "$TMP_DIR/www/luci-static/resources/view/iptv-manager/$f" /www/luci-static/resources/view/iptv-manager/$f
        }
    done
    chmod 755 /www/luci-static/resources/view/iptv-manager/srv.cgi 2>/dev/null
    echo_success "LuCI views"

    # player.html
    [ -f "$TMP_DIR/etc/iptv/player.html" ] && cp "$TMP_DIR/etc/iptv/player.html" "$IPTV_DIR/player.html" 2>/dev/null

    # CLI symlink
    ln -sf /usr/share/iptv-manager/IPTV-Manager.sh /usr/bin/iptv 2>/dev/null
    echo_success "CLI: /usr/bin/iptv"
}

# ============================
# Backup configs
# ============================
backup_configs() {
    mkdir -p "$BACKUP_DIR"
    for f in iptv.conf epg.conf schedule.conf security.conf favorites.json provider.conf playlist.m3u; do
        [ -f "$IPTV_DIR/$f" ] && cp "$IPTV_DIR/$f" "$BACKUP_DIR/$f"
    done
    echo_success "Конфиги сохранены"
}

restore_configs() {
    if [ -d "$BACKUP_DIR" ]; then
        for f in "$BACKUP_DIR"/*; do
            [ -f "$f" ] && cp "$f" "$IPTV_DIR/"
        done
        echo_success "Конфиги восстановлены"
    fi
}

# ============================
# Generate CGI and start server
# ============================
generate_and_start() {
    echo_step "Запуск сервера"

    # Create empty playlist if missing
    [ -f "$IPTV_DIR/playlist.m3u" ] || echo "#EXTM3U" > "$IPTV_DIR/playlist.m3u"

    # Generate CGI
    mkdir -p /www/iptv /www/iptv/cgi-bin
    cp "$IPTV_DIR/playlist.m3u" /www/iptv/playlist.m3u 2>/dev/null
    . /usr/share/iptv-manager/IPTV-Manager.sh --server 2>/dev/null || true
    echo_success "CGI сгенерированы"

    # Enable init
    /etc/init.d/iptv-manager enable 2>/dev/null

    # Run uci-defaults
    [ -f /etc/uci-defaults/99-luci-iptv-manager ] && /etc/uci-defaults/99-luci-iptv-manager 2>/dev/null

    # Restart rpcd
    /etc/init.d/rpcd restart 2>/dev/null

    # Start server
    /etc/init.d/iptv-manager start 2>/dev/null
    sleep 3

    local LAN_IP
    LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
    [ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"

    if wget -q --timeout=3 -O /dev/null "http://127.0.0.1:8082/" 2>/dev/null; then
        echo_success "Сервер запущен: http://$LAN_IP:8082"
    else
        echo_info "Сервер не запустился сразу. Через 10 сек:"
        echo_info "  /etc/init.d/iptv-manager start"
    fi
}

# ============================
# FULL UNINSTALL
# ============================
full_uninstall() {
    echo_step "Полное удаление IPTV Manager"
    echo -ne "${YELLOW}Удалить IPTV Manager полностью? (y/N): ${NC}"
    read ans
    case "$ans" in y|Y) ;; *) echo_info "Отмена"; return ;; esac

    echo_info "Остановка сервисов..."
    /etc/init.d/iptv-manager stop 2>/dev/null
    kill "$(pgrep -f 'uhttpd.*8082')" 2>/dev/null || true
    kill "$(pgrep -f 'iptv-scheduler')" 2>/dev/null || true
    kill "$(pgrep -f 'iptv-watchdog')" 2>/dev/null || true
    sleep 1

    echo_info "Удаление файлов..."
    rm -rf /usr/share/iptv-manager
    rm -rf "$IPTV_DIR"
    rm -rf /www/iptv
    rm -rf /www/luci-static/resources/view/iptv-manager
    rm -f /usr/share/luci/menu.d/luci-app-iptv-manager.json
    rm -f /usr/share/rpcd/acl.d/luci-app-iptv-manager.json
    rm -f /www/cgi-bin/srv.cgi /www/cgi-bin/srv.html
    rm -f /etc/init.d/iptv-manager
    rm -f /etc/uci-defaults/99-luci-iptv-manager
    rm -f /etc/config/iptv_uhttpd
    rm -f /var/run/iptv-httpd.pid /var/run/iptv-scheduler.pid
    rm -f /tmp/iptv-*.tmp /tmp/iptv-*.tar.gz /tmp/iptv-*.*
    rm -f /tmp/epg-dl.tmp /tmp/rf_tmp /tmp/iptv-blocked-*
    rm -f /usr/bin/iptv-watchdog.sh /usr/bin/iptv
    rm -f /usr/lib/lua/luci/controller/iptv-manager* 2>/dev/null
    rm -f /usr/lib/lua/luci/model/cbi/iptv-manager* 2>/dev/null
    rm -f /usr/lib/lua/luci/view/iptv-manager* 2>/dev/null

    /etc/init.d/rpcd restart 2>/dev/null

    echo_success "IPTV Manager полностью удалён"
}

# ============================
# MAIN
# ============================

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"

# ============================
# Interactive vs Automatic mode
# ============================
# If stdin is a pipe (wget | sh), run automatically.
# If stdin is a terminal, show menu.
if [ -t 0 ]; then
    # Interactive mode — terminal
    INTERACTIVE=1
    read_choice() {
        echo -ne "${YELLOW}> ${NC}"
        read choice </dev/tty
    }
else
    # Automatic mode — pipe from wget
    INTERACTIVE=0
    read_choice() {
        if is_installed; then
            # Already installed — auto-update
            choice="1"
        else
            # Fresh install
            choice="1"
        fi
    }
fi

echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "     ${GREEN}IPTV Manager v3.21${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"

if is_installed; then
    STATUS=$(get_status)
    CH=$(echo "$STATUS" | cut -d'|' -f1)
    SRV=$(echo "$STATUS" | cut -d'|' -f2)
    echo ""
    echo -e "  📺 Каналов: ${CYAN}$CH${NC}"
    echo -e "  🖥 Сервер: $SRV"
    echo -e "  🌐 http://$LAN_IP:8082"
    echo ""
    echo -e "  ${CYAN}1) Обновить${NC} (сохранит настройки и плейлист)"
    echo -e "  ${CYAN}2) Полностью удалить${NC}"
    echo ""
    echo -e "  ${CYAN}0) Выход${NC}"
    echo ""
    read_choice
    case "$choice" in
        1)
            echo_info "Обновление IPTV Manager..."
            backup_configs
            download_files || { cleanup; exit 1; }
            install_files
            restore_configs
            cleanup
            generate_and_start
            echo ""
            echo_success "Обновление завершено!"
            ;;
        2)
            full_uninstall
            cleanup
            ;;
        *) echo_info "Отмена"; cleanup; exit 0 ;;
    esac
else
    echo ""
    echo -e "  ${CYAN}1) Установить${NC}"
    echo ""
    echo -e "  ${CYAN}0) Выход${NC}"
    echo ""
    read_choice
    case "$choice" in
        1)
            echo_info "Установка IPTV Manager..."
            download_files || { cleanup; exit 1; }
            install_files
            cleanup
            generate_and_start
            echo ""
            echo -e "${GREEN}══════════════════════════════════════════${NC}"
            echo -e "  ${GREEN}IPTV Manager v3.21 установлен!${NC}"
            echo -e "${GREEN}══════════════════════════════════════════${NC}"
            echo ""
            echo -e "  🌐 Админка: ${CYAN}http://$LAN_IP:8082/cgi-bin/admin.cgi${NC}"
            echo -e "  📺 Плеер: ${CYAN}http://$LAN_IP:8082/player.html${NC}"
            echo -e "  📡 LuCI: ${CYAN}Services → IPTV Manager${NC}"
            echo ""
            echo -e "  CLI: ${CYAN}iptv${NC}"
            echo ""
            ;;
        *) echo_info "Отмена"; cleanup; exit 0 ;;
    esac
fi
