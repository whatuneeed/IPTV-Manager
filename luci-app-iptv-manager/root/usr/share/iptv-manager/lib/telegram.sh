#!/bin/sh
# ==========================================
# IPTV Manager — Telegram notifications
# ==========================================

# Config file: /etc/iptv/telegram.conf
# Format:
#   TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
#   TELEGRAM_CHAT_ID="-1001234567890"
#   TELEGRAM_ENABLED="1"

TELEGRAM_CONF="${IPTV_DIR:-/etc/iptv}/telegram.conf"

# Load telegram config
_telegram_load_config() {
    [ -f "$TELEGRAM_CONF" ] && . "$TELEGRAM_CONF"
    [ -z "$TELEGRAM_ENABLED" ] && TELEGRAM_ENABLED="0"
    [ "$TELEGRAM_ENABLED" != "1" ] && return 1
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 1
    [ -z "$TELEGRAM_CHAT_ID" ] && return 1
    return 0
}

# Send message to Telegram
# Usage: telegram_send "Message text" ["Markdown"|"HTML"]
telegram_send() {
    local text="$1"
    local parse_mode="${2:-Markdown}"

    _telegram_load_config || return 0  # silently skip if not configured

    # URL-encode text
    local encoded
    encoded=$(printf '%s' "$text" | sed 's/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;s/\$/%24/g;s/\&/%26/g;s/'"'"'/%27/g;s/(/%28/g;s/)/%29/g;s/*/%2A/g;s/+/%2B/g;s/,/%2C/g;s/-/%2D/g;s/\./%2E/g;s/\//%2F/g;s/:/%3A/g;s/;/%3B/g;s/>/%3E/g;s/?/%3F/g;s/@/%40/g;s/\[/%5B/g;s/\\/%5C/g;s/\]/%5D/g;s/_/%5F/g;s/`/%60/g;s/{/%7B/g;s/|/%7C/g;s/}/%7D/g;s/\~/%7E/g')

    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    local data="chat_id=${TELEGRAM_CHAT_ID}&text=${encoded}&parse_mode=${parse_mode}&disable_web_page_preview=true"

    wget -q --timeout=10 --no-check-certificate --post-data="$data" -O /dev/null "$url" 2>/dev/null
    local rc=$?

    if [ "$rc" -eq 0 ]; then
        log_info "Telegram notification sent"
    else
        log_warn "Failed to send Telegram notification (exit: $rc)"
    fi
    return $rc
}

# Pre-built notifications

telegram_server_down() {
    local hostname
    hostname=$(uci get system.@system[0].hostname 2>/dev/null || echo "OpenWrt")
    local lan_ip
    lan_ip=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1 || echo "192.168.1.1")
    telegram_send "🔴 *IPTV Manager — Сервер упал*

📡 Хост: \`${hostname}\`
🌐 IP: \`${lan_ip}\`
⏰ Время: \`$(date '+%d.%m.%Y %H:%M')\`

⚠️ Watchdog пытается перезапустить сервер..."
}

telegram_server_up() {
    local hostname
    hostname=$(uci get system.@system[0].hostname 2>/dev/null || echo "OpenWrt")
    telegram_send "🟢 *IPTV Manager — Сервер запущен*

📡 Хост: \`${hostname}\`
⏰ Время: \`$(date '+%d.%m.%Y %H:%M')\`"
}

telegram_playlist_updated() {
    local channels="$1"
    telegram_send "📡 *Плейлист обновлён*

📺 Каналов: \`${channels}\`
⏰ Время: \`$(date '+%d.%m.%Y %H:%M')\`"
}

telegram_epg_updated() {
    local size="$1"
    telegram_send "📺 *EPG обновлён*

💾 Размер: \`${size}\`
⏰ Время: \`$(date '+%d.%m.%Y %H:%M')\`"
}

telegram_playlist_error() {
    local error="${1:-Неизвестная ошибка}"
    telegram_send "❌ *Ошибка обновления плейлиста*

⚠️ Ошибка: \`${error}\`
⏰ Время: \`$(date '+%d.%m.%Y %H:%M')\`"
}

telegram_epg_error() {
    local error="${1:-Неизвестная ошибка}"
    telegram_send "❌ *Ошибка обновления EPG*

⚠️ Ошибка: \`${error}\`
⏰ Время: \`$(date '+%d.%m.%Y %H:%M')\`"
}

telegram_update_available() {
    local current="$1"
    local latest="$2"
    telegram_send "🔄 *Доступно обновление*

📦 Текущая версия: \`${current}\`
✨ Новая версия: \`${latest}\`

Запустите обновление через меню или админку."
}

telegram_system_alert() {
    local title="$1"
    local message="$2"
    telegram_send "🚨 *${title}*

${message}"
}

# Setup wizard — configure Telegram from SSH menu
telegram_setup() {
    echo_color "Настройка Telegram-уведомлений"
    echo ""
    echo -e "${CYAN}1) Включить Telegram${NC}"
    echo -e "${CYAN}2) Отключить${NC}"
    echo -e "${CYAN}3) Тестовое сообщение${NC}"
    echo -e "${CYAN}9) Назад${NC}"
    echo ""
    echo -ne "${YELLOW}> ${NC}"
    read c </dev/tty
    case "$c" in
        1)
            echo -ne "${YELLOW}Bot Token (от @BotFather): ${NC}"
            read token </dev/tty
            if [ -n "$token" ]; then
                echo -ne "${YELLOW}Chat ID: ${NC}"
                read chat_id </dev/tty
                if [ -n "$chat_id" ]; then
                    printf 'TELEGRAM_BOT_TOKEN="%s"\nTELEGRAM_CHAT_ID="%s"\nTELEGRAM_ENABLED="1"\n' "$token" "$chat_id" > "$TELEGRAM_CONF"
                    echo_success "Telegram настроен"
                    # Send test
                    telegram_send "✅ *IPTV Manager подключён*

Бот успешно настроен. Вы будете получать уведомления о:
• Падении/запуске сервера
• Обновлении плейлиста/EPG
• Доступных обновлениях"
                    echo_success "Тестовое сообщение отправлено"
                else
                    echo_error "Chat ID пуст"
                fi
            else
                echo_error "Bot Token пуст"
            fi
            ;;
        2)
            printf 'TELEGRAM_BOT_TOKEN=""\nTELEGRAM_CHAT_ID=""\nTELEGRAM_ENABLED="0"\n' > "$TELEGRAM_CONF"
            echo_success "Telegram отключён"
            ;;
        3)
            telegram_send "🧪 *Тестовое сообщение от IPTV Manager*"
            if [ $? -eq 0 ]; then
                echo_success "Сообщение отправлено"
            else
                echo_error "Ошибка отправки. Проверьте настройки."
            fi
            ;;
        9|*) return ;;
    esac
    PAUSE
}
