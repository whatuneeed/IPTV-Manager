#!/bin/sh
# ==========================================
# IPTV Manager — Playlist module
# Загрузка, валидация, объединение плейлистов
# ==========================================

# Загрузить плейлист по URL
playlist_download() {
    local url="$1"
    local output="${2:-$PLAYLIST_FILE}"

    if ! _validate_url "$url"; then
        log_error "Invalid playlist URL: $url"
        return 1
    fi

    log_info "Downloading playlist from $url"
    if wget $(wget_opt) -O "$output" "$url" 2>/dev/null && [ -s "$output" ]; then
        local ch
        ch=$(get_ch)
        log_info "Playlist downloaded: $ch channels"
        telegram_playlist_updated "$ch" 2>/dev/null || true
        echo "$ch"
        return 0
    else
        log_error "Playlist download failed: $url"
        telegram_playlist_error "Download failed: $url" 2>/dev/null || true
        return 1
    fi
}

# Проверить доступность URL плейлиста
playlist_validate_url() {
    local url="$1"

    if ! _validate_url "$url"; then
        printf '{"valid":false,"error":"Invalid URL format"}'
        return 1
    fi

    if wget -q --spider --timeout=10 --no-check-certificate "$url" 2>/dev/null; then
        local ch
        ch=$(wget -q --timeout=10 --no-check-certificate -O - "$url" 2>/dev/null | grep -c "^#EXTINF" || true)
        printf '{"valid":true,"channels":"%s"}' "$ch"
        return 0
    else
        printf '{"valid":false,"error":"URL unavailable"}'
        return 1
    fi
}

# Обновить плейлист из сохранённого конфига
playlist_refresh() {
    load_config
    case "$PLAYLIST_TYPE" in
        url)
            if ! _validate_url "$PLAYLIST_URL"; then
                log_error "Invalid saved playlist URL"
                return 1
            fi
            if playlist_download "$PLAYLIST_URL"; then
                local now
                now=$(get_ts)
                load_sched
                save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                return 0
            fi
            return 1
            ;;
        provider)
            if [ -f "$PROVIDER_CONFIG" ]; then
                . "$PROVIDER_CONFIG"
                local pu
                pu="http://${PROVIDER_SERVER:-$PROVIDER_NAME}/get.php?username=$PROVIDER_LOGIN&password=$PROVIDER_PASS&type=m3u_plus&output=ts"
                if playlist_download "$pu"; then
                    local now
                    now=$(get_ts)
                    load_sched
                    save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$now" "$EPG_LAST_UPDATE"
                    return 0
                fi
            fi
            return 1
            ;;
        file)
            if [ -f "$PLAYLIST_SOURCE" ]; then
                cp "$PLAYLIST_SOURCE" "$PLAYLIST_FILE"
                log_info "Playlist refreshed from file: $PLAYLIST_SOURCE"
                return 0
            fi
            log_error "Source file not found: $PLAYLIST_SOURCE"
            return 1
            ;;
    esac
    return 1
}

# Объединить несколько плейлистов
playlist_merge() {
    local urls="$1"  # пробел-разделённые URL
    local output="${2:-$PLAYLIST_FILE}"

    echo "#EXTM3U" > "$output"
    local total=0

    for url in $urls; do
        url=$(echo "$url" | sed 's/%2F/\//g;s/%3A/:/g;s/%3D/=/g;s/%3F/?/g;s/%26/\&/g;s/%2B/+/g;s/%25/%/g')
        if _validate_url "$url"; then
            local tmp="/tmp/iptv-merge-tmp.m3u"
            if wget -q --timeout=15 --no-check-certificate -O "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; then
                grep "^#\|^http" "$tmp" >> "$output" 2>/dev/null || true
                total=$((total + 1))
                log_info "Merged playlist #$total from $url"
            else
                log_warn "Failed to merge playlist: $url"
            fi
            rm -f "$tmp"
        else
            log_warn "Skipping invalid URL: $url"
        fi
    done

    local ch
    ch=$(grep -c "^#EXTINF" "$output" 2>/dev/null || true)
    log_info "Merge complete: $ch channels from $total playlists"
    echo "$ch"
}

# Удалить плейлист
playlist_remove() {
    rm -f "$PLAYLIST_FILE" "$CONFIG_FILE" "$PROVIDER_CONFIG"
    log_info "Playlist removed"
}
