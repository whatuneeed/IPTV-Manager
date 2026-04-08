#!/bin/sh
# ==========================================
# IPTV Manager — Unit tests for telegram.sh
# ==========================================

logger() { true; }
uci() { echo "OpenWrt"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../luci-app-iptv-manager/root/usr/share/iptv-manager/lib/core.sh"
. "$SCRIPT_DIR/../luci-app-iptv-manager/root/usr/share/iptv-manager/lib/logger.sh"
. "$SCRIPT_DIR/../luci-app-iptv-manager/root/usr/share/iptv-manager/lib/telegram.sh"

IPTV_DIR="/tmp/test-iptv-tg"

setUp() {
    mkdir -p "$IPTV_DIR"
    TELEGRAM_CONF="$IPTV_DIR/telegram.conf"
    TELEGRAM_ENABLED="0"
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""
}

tearDown() {
    rm -rf "$IPTV_DIR"
}

# --- test _telegram_load_config not configured ---
test_telegram_load_config_disabled() {
    TELEGRAM_ENABLED="0"
    _telegram_load_config
    assertNotEquals "0" "$?"
}

# --- test _telegram_load_config missing token ---
test_telegram_load_config_no_token() {
    TELEGRAM_ENABLED="1"
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID="-100123"
    _telegram_load_config
    assertNotEquals "0" "$?"
}

# --- test _telegram_load_config missing chat_id ---
test_telegram_load_config_no_chat() {
    TELEGRAM_ENABLED="1"
    TELEGRAM_BOT_TOKEN="123:ABC"
    TELEGRAM_CHAT_ID=""
    _telegram_load_config
    assertNotEquals "0" "$?"
}

# --- test telegram_send disabled ---
test_telegram_send_disabled() {
    TELEGRAM_ENABLED="0"
    result=$(telegram_send "test")
    assertEquals "0" "$?"  # should silently skip
}

# --- test telegram_send missing config ---
test_telegram_send_missing_config() {
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""
    TELEGRAM_ENABLED="1"
    result=$(telegram_send "test" 2>/dev/null)
    assertEquals "0" "$?"  # should silently skip
}

# --- test pre-built notifications (just check they don't crash) ---
test_telegram_server_down_no_crash() {
    TELEGRAM_ENABLED="0"
    telegram_server_down
    assertEquals "0" "$?"
}

test_telegram_server_up_no_crash() {
    TELEGRAM_ENABLED="0"
    telegram_server_up
    assertEquals "0" "$?"
}

test_telegram_playlist_updated_no_crash() {
    TELEGRAM_ENABLED="0"
    telegram_playlist_updated "150"
    assertEquals "0" "$?"
}

test_telegram_epg_updated_no_crash() {
    TELEGRAM_ENABLED="0"
    telegram_epg_updated "5MB"
    assertEquals "0" "$?"
}

test_telegram_playlist_error_no_crash() {
    TELEGRAM_ENABLED="0"
    telegram_playlist_error "Download failed"
    assertEquals "0" "$?"
}

test_telegram_epg_error_no_crash() {
    TELEGRAM_ENABLED="0"
    telegram_epg_error "Timeout"
    assertEquals "0" "$?"
}

test_telegram_update_available_no_crash() {
    TELEGRAM_ENABLED="0"
    telegram_update_available "3.20" "3.21"
    assertEquals "0" "$?"
}

test_telegram_system_alert_no_crash() {
    TELEGRAM_ENABLED="0"
    telegram_system_alert "Test" "Message"
    assertEquals "0" "$?"
}

# Load shunit2
. "$SCRIPT_DIR/shunit2"
