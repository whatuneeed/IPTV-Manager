#!/bin/sh
# ==========================================
# IPTV Manager v3.21 — Installer
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

# Cleanup function — removes ALL temporary files
cleanup() {
    rm -rf "$TMP_DIR"
    rm -f /tmp/iptv-*.tmp /tmp/iptv-*.tar.gz /tmp/iptv-*.*
}

# Download file from GitHub
dl() {
    local src="$1"
    local dst="$2"
    mkdir -p "$(dirname "$dst")" 2>/dev/null
    if wget -q --timeout=15 --no-check-certificate -O "$dst" "${RAW}/${src}" 2>/dev/null && [ -s "$dst" ]; then
        return 0
    fi
    return 1
}

# ============================
# Check prerequisites
# ============================
echo_step "Проверка системы"

command -v wget >/dev/null 2>&1 || { echo_error "wget не найден"; exit 1; }
command -v uhttpd >/dev/null 2>&1 || echo_info "⚠ uhttpd не найден — будет установлен через opkg"

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"

echo_success "Система: OpenWrt ($LAN_IP)"

# ============================
# Download files
# ============================
echo_step "Загрузка файлов"
mkdir -p "$TMP_DIR"

FILES="
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

TOTAL=0
OK=0
FAIL=0

echo "$FILES" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    src=$(echo "$line" | cut -d: -f1)
    dst=$(echo "$line" | cut -d: -f2)
    TOTAL=$((TOTAL + 1))
    if dl "$src" "$TMP_DIR/$dst"; then
        OK=$((OK + 1))
    else
        FAIL=$((FAIL + 1))
        echo_error "FAIL: $src"
    fi
done

# Re-count (subshell issue — recheck)
OK=0; FAIL=0; TOTAL=0
for line in $FILES; do
    [ -z "$line" ] && continue
    src=$(echo "$line" | cut -d: -f1)
    dst=$(echo "$line" | cut -d: -f2)
    TOTAL=$((TOTAL + 1))
    if [ -f "$TMP_DIR/$dst" ] && [ -s "$TMP_DIR/$dst" ]; then
        OK=$((OK + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

echo_success "Загружено: $OK/$TOTAL файлов (ошибок: $FAIL)"

if [ "$OK" -lt 10 ]; then
    echo_error "Слишком мало файлов загружено. Проверьте интернет-соединение."
    cleanup
    exit 1
fi

# ============================
# Install files
# ============================
echo_step "Установка"

# Copy to system paths
cp "$TMP_DIR/usr/share/iptv-manager/IPTV-Manager.sh" /usr/share/iptv-manager/IPTV-Manager.sh 2>/dev/null && {
    mkdir -p /usr/share/iptv-manager/lib
    for f in core.sh logger.sh playlist.sh epg.sh server.sh scheduler.sh security.sh cgi.sh telegram.sh catchup.sh; do
        cp "$TMP_DIR/usr/share/iptv-manager/lib/$f" /usr/share/iptv-manager/lib/$f 2>/dev/null
        chmod 644 /usr/share/iptv-manager/lib/$f
    done
    chmod 755 /usr/share/iptv-manager/IPTV-Manager.sh
    echo_success "Модули: /usr/share/iptv-manager/"
}

# Create config directory
mkdir -p /etc/iptv

# Install init script
[ -f "$TMP_DIR/etc/init.d/iptv-manager" ] && {
    cp "$TMP_DIR/etc/init.d/iptv-manager" /etc/init.d/iptv-manager
    chmod 755 /etc/init.d/iptv-manager
    echo_success "Init-скрипт: /etc/init.d/iptv-manager"
}

# Install uci-defaults
[ -f "$TMP_DIR/etc/uci-defaults/99-luci-iptv-manager" ] && {
    cp "$TMP_DIR/etc/uci-defaults/99-luci-iptv-manager" /etc/uci-defaults/99-luci-iptv-manager
    chmod 755 /etc/uci-defaults/99-luci-iptv-manager
    echo_success "UCI defaults: /etc/uci-defaults/99-luci-iptv-manager"
}

# Install uhttpd config
[ -f "$TMP_DIR/etc/config/iptv_uhttpd" ] && {
    cp "$TMP_DIR/etc/config/iptv_uhttpd" /etc/config/iptv_uhttpd
    echo_success "uhttpd config: /etc/config/iptv_uhttpd"
}

# Install LuCI menu
[ -f "$TMP_DIR/usr/share/luci/menu.d/luci-app-iptv-manager.json" ] && {
    mkdir -p /usr/share/luci/menu.d
    cp "$TMP_DIR/usr/share/luci/menu.d/luci-app-iptv-manager.json" /usr/share/luci/menu.d/luci-app-iptv-manager.json
    echo_success "LuCI menu: /usr/share/luci/menu.d/"
}

# Install LuCI ACL
[ -f "$TMP_DIR/usr/share/rpcd/acl.d/luci-app-iptv-manager.json" ] && {
    mkdir -p /usr/share/rpcd/acl.d
    cp "$TMP_DIR/usr/share/rpcd/acl.d/luci-app-iptv-manager.json" /usr/share/rpcd/acl.d/luci-app-iptv-manager.json
    chmod 644 /usr/share/rpcd/acl.d/luci-app-iptv-manager.json
    echo_success "LuCI ACL: /usr/share/rpcd/acl.d/"
}

# Install LuCI views
mkdir -p /www/luci-static/resources/view/iptv-manager
for f in admin.html srv.cgi srv.html iptv.js player.js server.js; do
    [ -f "$TMP_DIR/www/luci-static/resources/view/iptv-manager/$f" ] && {
        cp "$TMP_DIR/www/luci-static/resources/view/iptv-manager/$f" /www/luci-static/resources/view/iptv-manager/$f
    }
done
chmod 755 /www/luci-static/resources/view/iptv-manager/srv.cgi 2>/dev/null
echo_success "LuCI views: /www/luci-static/resources/view/iptv-manager/"

# Copy player.html to /etc/iptv/
[ -f "$TMP_DIR/etc/iptv/player.html" ] && {
    cp "$TMP_DIR/etc/iptv/player.html" /etc/iptv/player.html 2>/dev/null
}

# Create CLI symlink
ln -sf /usr/share/iptv-manager/IPTV-Manager.sh /usr/bin/iptv 2>/dev/null
echo_success "CLI: /usr/bin/iptv"

# ============================
# Post-install
# ============================
echo_step "Настройка"

# Enable init script
/etc/init.d/iptv-manager enable 2>/dev/null && echo_success "Автозапуск включён"

# Run uci-defaults
[ -f /etc/uci-defaults/99-luci-iptv-manager ] && {
    /etc/uci-defaults/99-luci-iptv-manager 2>/dev/null
    echo_success "UCI defaults выполнены"
}

# Restart rpcd
/etc/init.d/rpcd restart 2>/dev/null && echo_success "rpcd перезапущен"

# ============================
# CLEANUP — remove ALL temporary files
# ============================
echo_step "Очистка"
cleanup
rm -f /tmp/iptv-*.tmp /tmp/iptv-*.tar.gz /tmp/iptv-install-*
echo_success "Временные файлы удалены"

# ============================
# Start server
# ============================
echo_step "Запуск сервера"
/etc/init.d/iptv-manager start 2>/dev/null
sleep 3

# Verify
if wget -q --timeout=3 -O /dev/null "http://127.0.0.1:8082/" 2>/dev/null; then
    echo_success "Сервер запущен на http://$LAN_IP:8082"
else
    echo_info "Сервер не запустился сразу. Подождите 10 сек и попробуйте:"
    echo_info "  /etc/init.d/iptv-manager start"
fi

# ============================
# Done
# ============================
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
