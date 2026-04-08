#!/bin/sh
# ==========================================
# IPTV Manager — Unit tests for catchup.sh
# ==========================================

logger() { true; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../luci-app-iptv-manager/root/usr/share/iptv-manager/lib/core.sh"
. "$SCRIPT_DIR/../luci-app-iptv-manager/root/usr/share/iptv-manager/lib/logger.sh"
. "$SCRIPT_DIR/../luci-app-iptv-manager/root/usr/share/iptv-manager/lib/catchup.sh"

IPTV_DIR="/tmp/test-iptv-catchup"
PLAYLIST_FILE="$IPTV_DIR/playlist.m3u"

setUp() {
    mkdir -p "$IPTV_DIR"
}

tearDown() {
    rm -rf "$IPTV_DIR"
}

# --- test catchup_parse_m3u empty ---
test_catchup_parse_empty() {
    touch "$PLAYLIST_FILE"
    result=$(catchup_parse_m3u "$PLAYLIST_FILE")
    assertEquals "" "$result"
}

# --- test catchup_parse_m3u with catchup ---
test_catchup_parse_with_catchup() {
    cat > "$PLAYLIST_FILE" << 'EOF'
#EXTM3U
#EXTINF:-1 tvg-id="ch1" catchup="default" catchup-source="http://srv.tv/arch?id={catchup-id}&start={utc}" catchup-days="3",Channel 1
http://stream.example.com/ch1.ts
#EXTINF:-1 tvg-id="ch2",Channel 2
http://stream.example.com/ch2.ts
EOF
    result=$(catchup_parse_m3u "$PLAYLIST_FILE")
    assertContains "should contain channel 1" "$result" "Channel 1"
    assertContains "should contain catchup type" "$result" "default"
    assertContains "should contain catchup_source" "$result" "http://srv.tv/arch"
}

# --- test catchup_parse_m3u without catchup ---
test_catchup_parse_without_catchup() {
    cat > "$PLAYLIST_FILE" << 'EOF'
#EXTM3U
#EXTINF:-1,Simple Channel
http://example.com/simple.ts
EOF
    result=$(catchup_parse_m3u "$PLAYLIST_FILE")
    # Should not output channels without catchup attribute
    assertEquals "" "$result"
}

# --- test catchup_generate_url shift mode ---
test_catchup_generate_url_shift() {
    result=$(catchup_generate_url "" "http://srv/live/ch.ts" "1700000000" "1700003600" "shift" "")
    assertContains "should contain utc param" "$result" "utc=1700000000"
    assertContains "should contain lutc param" "$result" "lutc="
}

# --- test catchup_generate_url append mode ---
test_catchup_generate_url_append() {
    result=$(catchup_generate_url "" "http://srv/live/ch.ts?token=abc" "1700000000" "1700003600" "append" "")
    assertContains "should append params" "$result" "&utc=1700000000"
}

# --- test catchup_generate_url default mode ---
test_catchup_generate_url_default() {
    result=$(catchup_generate_url "http://api.tv/arch?start={utc}&end={utcend}&dur={duration}" "" "1700000000" "1700003600" "default" "")
    assertContains "should replace {utc}" "$result" "start=1700000000"
    assertContains "should replace {utcend}" "$result" "end=1700003600"
    assertContains "should replace {duration}" "$result" "dur=3600"
}

# --- test catchup_generate_url with catchup-id ---
test_catchup_generate_url_catchup_id() {
    result=$(catchup_generate_url "http://api.tv/arch?id={catchup-id}" "" "1700000000" "1700003600" "default" "prog_12345")
    assertContains "should replace catchup-id" "$result" "id=prog_12345"
}

# --- test catchup_generate_url with date placeholders ---
test_catchup_generate_url_date_placeholders() {
    result=$(catchup_generate_url "http://tv/arch/{Y}/{m}/{d}/{H}" "" "1700000000" "1700003600" "default" "")
    assertContains "should contain year" "$result" "/2023/"
}

# --- test catchup_generate_url duration division ---
test_catchup_generate_url_duration_div() {
    result=$(catchup_generate_url "http://tv/arch?dur={duration:60}" "" "1700000000" "1700003600" "default" "")
    assertContains "should be 60 (3600/60)" "$result" "dur=60"
}

# --- test catchup_generate_url no type no source ---
test_catchup_generate_url_nothing() {
    result=$(catchup_generate_url "" "" "1700000000" "1700003600" "" "")
    assertFalse "should fail" "[ $? -eq 0 ]"
}

# --- test catchup_enrich_channels_json ---
test_catchup_enrich_channels_json() {
    cat > "$PLAYLIST_FILE" << 'EOF'
#EXTM3U
#EXTINF:-1 tvg-id="ch1" tvg-name="News" tvg-logo="http://logo.png" group-title="News" catchup="shift" catchup-days="3",News Channel
http://stream.example.com/news.ts
EOF
    local outfile="$IPTV_DIR/channels.json"
    catchup_enrich_channels_json "$PLAYLIST_FILE" "$outfile"
    assertTrue "file should exist" "[ -f '$outfile' ]"
    assertContains "should contain channel name" "$(cat "$outfile")" "News"
    assertContains "should contain catchup" "$(cat "$outfile")" "shift"
    assertContains "should contain catchup_days" "$(cat "$outfile")" "3"
}

test_catchup_enrich_channels_json_empty() {
    local outfile="$IPTV_DIR/channels.json"
    touch "$IPTV_DIR/empty.m3u"
    catchup_enrich_channels_json "$IPTV_DIR/empty.m3u" "$outfile"
    assertTrue "file should exist" "[ -f '$outfile' ]"
    assertEquals "[]" "$(cat "$outfile")"
}

# Load shunit2
. "$SCRIPT_DIR/shunit2"
