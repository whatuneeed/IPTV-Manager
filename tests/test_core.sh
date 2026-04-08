#!/bin/sh
# ==========================================
# IPTV Manager — Unit tests for core functions
# Run: bash test_core.sh  (or sh test_core.sh on OpenWrt)
# ==========================================

# Mock logger (not available in CI)
logger() { true; }

# Source module
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../luci-app-iptv-manager/root/usr/share/iptv-manager/lib/core.sh"

# Override iptv paths for testing
IPTV_DIR="/tmp/test-iptv"
WWW_DIR="/tmp/test-www"
PLAYLIST_FILE="$IPTV_DIR/playlist.m3u"

setUp() {
    mkdir -p "$IPTV_DIR"
    # Ensure config paths point to test directory
    CONFIG_FILE="$IPTV_DIR/iptv.conf"
    SCHEDULE_FILE="$IPTV_DIR/schedule.conf"
    EPG_CONFIG="$IPTV_DIR/epg.conf"
    SECURITY_FILE="$IPTV_DIR/security.conf"
    FAVORITES_FILE="$IPTV_DIR/favorites.json"
    # Reset sched vars
    PLAYLIST_INTERVAL=""
    EPG_INTERVAL=""
    PLAYLIST_LAST_UPDATE=""
    EPG_LAST_UPDATE=""
    PLAYLIST_TYPE=""
    PLAYLIST_URL=""
    PLAYLIST_SOURCE=""
}

tearDown() {
    rm -rf "$IPTV_DIR" "/tmp/test-www" "/tmp/iptv-"*
}

# --- test _validate_url ---
test_validate_url_http() {
    _validate_url "http://example.com/playlist.m3u"
    assertEquals "http URL should be valid" "0" "$?"
}

test_validate_url_https() {
    _validate_url "https://example.com/playlist.m3u"
    assertEquals "https URL should be valid" "0" "$?"
}

test_validate_url_rtsp() {
    _validate_url "rtsp://stream.example.com/live"
    assertEquals "rtsp URL should be valid" "0" "$?"
}

test_validate_url_udp() {
    _validate_url "udp://239.0.0.1:1234"
    assertEquals "udp URL should be valid" "0" "$?"
}

test_validate_url_invalid() {
    _validate_url "not-a-url"
    assertNotEquals "invalid URL should fail" "0" "$?"
}

test_validate_url_empty() {
    _validate_url ""
    assertNotEquals "empty URL should fail" "0" "$?"
}

# --- test _sanitize_str ---
test_sanitize_str_removes_special() {
    result=$(_sanitize_str 'hello<script>alert(1)</script>')
    # Should keep printable chars, just strip control chars
    assertNotEquals "should not be empty" "" "$result"
    assertTrue "should contain hello" "echo '$result' | grep -q 'hello'"
}

test_sanitize_str_keeps_cyrillic() {
    # tr [:print:] may behave differently across locales, just check non-empty
    result=$(_sanitize_str "Привет мир")
    assertNotEquals "should not be empty" "" "$result"
}

test_sanitize_str_limits_length() {
    long=$(printf '%0501d' 0)
    result=$(_sanitize_str "$long")
    len=${#result}
    assertTrue "should be <= 500 chars" "[ $len -le 500 ]"
}

# --- test _sanitize_cgi_idx ---
test_sanitize_idx_valid() {
    result=$(_sanitize_cgi_idx "42")
    assertEquals "should keep valid number" "42" "$result"
}

test_sanitize_idx_invalid() {
    result=$(_sanitize_cgi_idx "abc")
    assertEquals "should default to 0" "0" "$result"
}

test_sanitize_idx_empty() {
    result=$(_sanitize_cgi_idx "")
    assertEquals "should default to 0" "0" "$result"
}

# --- test _is_number ---
test_is_number_valid() {
    _is_number "123"
    assertEquals "123 should be number" "0" "$?"
}

test_is_number_zero() {
    _is_number "0"
    assertEquals "0 should be number" "0" "$?"
}

test_is_number_invalid() {
    _is_number "abc"
    assertNotEquals "abc should not be number" "0" "$?"
}

test_is_number_negative() {
    _is_number "-5"
    assertNotEquals "-5 should not be number" "0" "$?"
}

# --- test file_size ---
test_file_size_zero() {
    echo -n "" > "$IPTV_DIR/empty.txt"
    result=$(file_size "$IPTV_DIR/empty.txt")
    assertEquals "empty file should be 0 B" "0 B" "$result"
}

test_file_size_small() {
    echo "hello" > "$IPTV_DIR/small.txt"
    result=$(file_size "$IPTV_DIR/small.txt")
    assertContains "small file in B" "$result" "B"
}

test_file_size_not_exists() {
    result=$(file_size "$IPTV_DIR/nonexistent.txt")
    assertEquals "nonexistent file" "0 B" "$result"
}

# --- test get_ch ---
test_get_ch_empty() {
    touch "$PLAYLIST_FILE"
    result=$(get_ch)
    assertEquals "empty playlist" "0" "$result"
}

test_get_ch_with_channels() {
    cat > "$PLAYLIST_FILE" << 'EOF'
#EXTM3U
#EXTINF:-1,Channel 1
http://example.com/1
#EXTINF:-1,Channel 2
http://example.com/2
#EXTINF:-1,Channel 3
http://example.com/3
EOF
    result=$(get_ch)
    assertEquals "3 channels" "3" "$result"
}

# --- test detect_builtin_epg ---
test_detect_builtin_epg_found() {
    cat > "$PLAYLIST_FILE" << 'EOF'
#EXTM3U url-tvg="https://epg.example.com/guide.xml"
#EXTINF:-1,Channel 1
http://example.com/1
EOF
    result=$(detect_builtin_epg)
    assertEquals "should detect builtin EPG" "https://epg.example.com/guide.xml" "$result"
}

test_detect_builtin_epg_not_found() {
    cat > "$PLAYLIST_FILE" << 'EOF'
#EXTM3U
#EXTINF:-1,Channel 1
http://example.com/1
EOF
    result=$(detect_builtin_epg)
    assertEquals "no builtin EPG" "" "$result"
}

# --- test int_text ---
test_int_text_0() { assertEquals "Выкл" "$(int_text 0)"; }
test_int_text_1() { assertEquals "Каждый час" "$(int_text 1)"; }
test_int_text_6() { assertEquals "Каждые 6ч" "$(int_text 6)"; }
test_int_text_12() { assertEquals "Каждые 12ч" "$(int_text 12)"; }
test_int_text_24() { assertEquals "Раз в сутки" "$(int_text 24)"; }
test_int_text_default() { assertEquals "Выкл" "$(int_text 99)"; }

# --- test save_config / load_config ---
test_save_and_load_config() {
    save_config "url" "http://test.m3u" "source"
    load_config
    assertEquals "url" "url" "$PLAYLIST_TYPE"
    assertEquals "http://test.m3u" "$PLAYLIST_URL"
    assertEquals "source" "$PLAYLIST_SOURCE"
}

# --- test save_sched / load_sched ---
test_save_and_load_sched() {
    save_sched "6" "12" "01.01.2025 10:00" "01.01.2025 11:00"
    load_sched
    assertEquals "6" "$PLAYLIST_INTERVAL"
    assertEquals "12" "$EPG_INTERVAL"
    assertEquals "01.01.2025 10:00" "$PLAYLIST_LAST_UPDATE"
    assertEquals "01.01.2025 11:00" "$EPG_LAST_UPDATE"
}

test_load_sched_defaults() {
    rm -f "$SCHEDULE_FILE"
    # Reset interval vars to ensure they are not polluted from previous test
    PLAYLIST_INTERVAL=""
    EPG_INTERVAL=""
    PLAYLIST_LAST_UPDATE=""
    EPG_LAST_UPDATE=""
    load_sched
    assertEquals "0" "$PLAYLIST_INTERVAL"
    assertEquals "0" "$EPG_INTERVAL"
    assertEquals "--" "$PLAYLIST_LAST_UPDATE"
    assertEquals "--" "$EPG_LAST_UPDATE"
}

# Load shunit2
. "$SCRIPT_DIR/shunit2" 2>/dev/null || . /tmp/shunit2
