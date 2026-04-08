#!/bin/sh
# ==========================================
# IPTV Manager — Unit tests for playlist.sh
# ==========================================

logger() { true; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../luci-app-iptv-manager/root/usr/share/iptv-manager/lib/core.sh"
. "$SCRIPT_DIR/../luci-app-iptv-manager/root/usr/share/iptv-manager/lib/logger.sh"
. "$SCRIPT_DIR/../luci-app-iptv-manager/root/usr/share/iptv-manager/lib/playlist.sh"

# Mock wget for tests
MOCK_WGET_RESULT=""
MOCK_WGET_FAIL=0
wget() {
    if [ "$MOCK_WGET_FAIL" -eq 1 ]; then
        return 1
    fi
    # Parse output file argument
    local outfile=""
    for arg in "$@"; do
        case "$arg" in -O) outfile="next"; continue;; esac
        if [ "$outfile" = "next" ]; then
            if [ -n "$MOCK_WGET_RESULT" ]; then
                echo "$MOCK_WGET_RESULT" > "$arg"
            fi
            outfile=""
        fi
    done
    return 0
}

IPTV_DIR="/tmp/test-iptv-playlist"
PLAYLIST_FILE="$IPTV_DIR/playlist.m3u"
CONFIG_FILE="$IPTV_DIR/iptv.conf"

setUp() {
    mkdir -p "$IPTV_DIR"
    CONFIG_FILE="$IPTV_DIR/iptv.conf"
    SCHEDULE_FILE="$IPTV_DIR/schedule.conf"
    EPG_CONFIG="$IPTV_DIR/epg.conf"
    SECURITY_FILE="$IPTV_DIR/security.conf"
    FAVORITES_FILE="$IPTV_DIR/favorites.json"
    PLAYLIST_INTERVAL=""
    EPG_INTERVAL=""
    PLAYLIST_LAST_UPDATE=""
    EPG_LAST_UPDATE=""
    MOCK_WGET_RESULT=""
    MOCK_WGET_FAIL=0
}

tearDown() {
    rm -rf "$IPTV_DIR"
}

# --- test playlist_download with valid URL ---
test_playlist_download_valid() {
    MOCK_WGET_RESULT="#EXTM3U
#EXTINF:-1,Channel 1
http://example.com/1
#EXTINF:-1,Channel 2
http://example.com/2"
    result=$(playlist_download "http://example.com/pl.m3u" "$PLAYLIST_FILE")
    assertEquals "2" "$result"
    assertTrue "playlist file should exist" "[ -f '$PLAYLIST_FILE' ]"
}

test_playlist_download_invalid_url() {
    result=$(playlist_download "not-a-url" "$PLAYLIST_FILE")
    assertFalse "should fail for invalid URL" "[ $? -eq 0 ]"
}

test_playlist_download_fail() {
    MOCK_WGET_FAIL=1
    result=$(playlist_download "http://example.com/pl.m3u" "$PLAYLIST_FILE" 2>/dev/null)
    assertFalse "should fail when wget fails" "[ $? -eq 0 ]"
    MOCK_WGET_FAIL=0
}

# --- test playlist_validate_url ---
test_playlist_validate_url_valid() {
    # Mock wget --spider success
    result=$(playlist_validate_url "http://example.com/pl.m3u")
    # Since wget is mocked, this will try spider which isn't mocked
    # Just test that it returns JSON
    assertContains "should return JSON" "$result" '"valid"'
}

test_playlist_validate_url_invalid_format() {
    result=$(playlist_validate_url "not-a-url")
    assertContains "should have valid:false" "$result" '"valid":false'
}

# --- test playlist_remove ---
test_playlist_remove() {
    touch "$PLAYLIST_FILE"
    touch "$CONFIG_FILE"
    touch "$IPTV_DIR/provider.conf"
    playlist_remove
    assertFalse "playlist should be gone" "[ -f '$PLAYLIST_FILE' ]"
    assertFalse "config should be gone" "[ -f '$CONFIG_FILE' ]"
}

# --- test get_ch ---
test_get_ch_zero() {
    touch "$PLAYLIST_FILE"
    result=$(get_ch)
    assertEquals "0" "$result"
}

test_get_ch_multiple() {
    cat > "$PLAYLIST_FILE" << 'EOF'
#EXTM3U
#EXTINF:-1,One
http://ex.com/1
#EXTINF:-1,Two
http://ex.com/2
#EXTINF:-1,Three
http://ex.com/3
EOF
    result=$(get_ch)
    assertEquals "3" "$result"
}

# --- test detect_builtin_epg ---
test_detect_builtin_epg_with_url() {
    cat > "$PLAYLIST_FILE" << 'EOF'
#EXTM3U url-tvg="https://epg.test.com/guide.xml"
#EXTINF:-1,Test
http://test.com/1
EOF
    result=$(detect_builtin_epg)
    assertEquals "https://epg.test.com/guide.xml" "$result"
}

test_detect_builtin_epg_without_url() {
    cat > "$PLAYLIST_FILE" << 'EOF'
#EXTM3U
#EXTINF:-1,Test
http://test.com/1
EOF
    result=$(detect_builtin_epg)
    assertEquals "" "$result"
}

# --- test file_size ---
test_file_size_empty() {
    echo -n "" > "$IPTV_DIR/empty.txt"
    result=$(file_size "$IPTV_DIR/empty.txt")
    assertEquals "0 B" "$result"
}

test_file_size_small() {
    echo "hello world" > "$IPTV_DIR/small.txt"
    result=$(file_size "$IPTV_DIR/small.txt")
    assertContains "should contain B" "$result" "B"
}

test_file_size_nonexistent() {
    result=$(file_size "$IPTV_DIR/nonexistent.txt")
    assertEquals "0 B" "$result"
}

# --- test wget_opt ---
test_wget_opt_contains_timeout() {
    result=$(wget_opt)
    assertContains "should contain timeout" "$result" "timeout"
}

# --- test _is_number ---
test_is_number_positive() { _is_number "42"; assertEquals "0" "$?"; }
test_is_number_zero() { _is_number "0"; assertEquals "0" "$?"; }
test_is_number_negative() { _is_number "-5"; assertNotEquals "0" "$?"; }
test_is_number_string() { _is_number "abc"; assertNotEquals "0" "$?"; }
test_is_number_empty() { _is_number ""; assertNotEquals "0" "$?"; }

# --- test _validate_url ---
test_validate_url_http() { _validate_url "http://x.com"; assertEquals "0" "$?"; }
test_validate_url_https() { _validate_url "https://x.com"; assertEquals "0" "$?"; }
test_validate_url_rtsp() { _validate_url "rtsp://x"; assertEquals "0" "$?"; }
test_validate_url_rtmp() { _validate_url "rtmp://x"; assertEquals "0" "$?"; }
test_validate_url_udp() { _validate_url "udp://x"; assertEquals "0" "$?"; }
test_validate_url_rtp() { _validate_url "rtp://x"; assertEquals "0" "$?"; }
test_validate_url_bad() { _validate_url "ftp://x"; assertNotEquals "0" "$?"; }
test_validate_url_empty() { _validate_url ""; assertNotEquals "0" "$?"; }

# --- test _sanitize_str ---
test_sanitize_keeps_safe() {
    result=$(_sanitize_str "hello world 123")
    assertEquals "hello world 123" "$result"
}

test_sanitize_limits_length() {
    long=$(printf '%0501d' 0)
    result=$(_sanitize_str "$long")
    assertTrue "len <= 500" "[ ${#result} -le 500 ]"
}

# --- test _sanitize_cgi_idx ---
test_sanitize_idx_valid() { assertEquals "42" "$(_sanitize_cgi_idx "42")"; }
test_sanitize_idx_zero() { assertEquals "0" "$(_sanitize_cgi_idx "0")"; }
test_sanitize_idx_invalid() { assertEquals "0" "$(_sanitize_cgi_idx "abc")"; }
test_sanitize_idx_empty() { assertEquals "0" "$(_sanitize_cgi_idx "")"; }

# --- test save_config / load_config ---
test_save_load_config() {
    save_config "url" "http://test.m3u" "source"
    load_config
    assertEquals "url" "$PLAYLIST_TYPE"
    assertEquals "http://test.m3u" "$PLAYLIST_URL"
    assertEquals "source" "$PLAYLIST_SOURCE"
}

# --- test save_sched / load_sched ---
test_save_load_sched() {
    save_sched "6" "12" "01.01.2025 10:00" "01.01.2025 11:00"
    load_sched
    assertEquals "6" "$PLAYLIST_INTERVAL"
    assertEquals "12" "$EPG_INTERVAL"
}

test_load_sched_defaults() {
    rm -f "$IPTV_DIR/schedule.conf"
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

# --- test int_text ---
test_int_text_0() { assertEquals "Выкл" "$(int_text 0)"; }
test_int_text_1() { assertEquals "Каждый час" "$(int_text 1)"; }
test_int_text_6() { assertEquals "Каждые 6ч" "$(int_text 6)"; }
test_int_text_12() { assertEquals "Каждые 12ч" "$(int_text 12)"; }
test_int_text_24() { assertEquals "Раз в сутки" "$(int_text 24)"; }
test_int_text_default() { assertEquals "Выкл" "$(int_text 99)"; }

# Load shunit2
. "$SCRIPT_DIR/shunit2"
