#!/bin/sh
# ==========================================
# IPTV Manager — EPG module
# Загрузка и обработка телепрограммы
# ==========================================

# Загрузить EPG → /tmp/iptv-epg.xml.gz
epg_download() {
    local url="$1"

    if ! _validate_url "$url"; then
        log_error "Invalid EPG URL: $url"
        return 1
    fi

    local tmp="$EPG_TD"
    log_info "Downloading EPG from $url"

    if wget -q --timeout=30 --header="User-Agent: VLC/3.0" --no-check-certificate -O "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; then
        local magic
        magic=$(hexdump -n 2 -e '2/1 "%02x"' "$tmp" 2>/dev/null)

        if [ "$magic" = "1f8b" ]; then
            cp "$tmp" "$EPG_GZ"
        else
            gzip -c "$tmp" > "$EPG_GZ" 2>/dev/null
        fi

        rm -f "$tmp"
        local sz
        sz=$(file_size "$EPG_GZ")
        log_info "EPG downloaded: $sz"
        telegram_epg_updated "$sz" 2>/dev/null || true

        # Сохраняем URL
        printf 'EPG_URL="%s"\n' "$url" > "$EPG_CONFIG"

        # Обновляем расписание
        local now
        now=$(get_ts)
        load_sched
        save_sched "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$now"

        return 0
    else
        log_error "EPG download failed: $url"
        rm -f "$tmp"
        return 1
    fi
}

# Обновить EPG из сохранённого конфига
epg_refresh() {
    load_epg
    if [ -z "$EPG_URL" ]; then
        log_error "EPG URL not configured"
        return 1
    fi
    epg_download "$EPG_URL"
}

# Получить текущие передачи из EPG (JSON для админки)
epg_get_now() {
    local limit="${1:-50}"

    if [ ! -f "$EPG_GZ" ]; then
        printf '{"status":"ok","rows":[]}'
        return 0
    fi

    local now_ts
    now_ts=$(date '+%Y%m%d%H%M%S' 2>/dev/null || true)

    local rows
    rows=$(gunzip -c "$EPG_GZ" 2>/dev/null | awk -v now="$now_ts" '
    BEGIN{printf "[";f=1;c=0}
    /<programme / {
        s = $0; st = ""; ch = ""
        if (match(s, /start="[0-9]+/)) st = substr(s, RSTART + 7, RLENGTH - 7)
        if (match(s, /channel="[^"]+"/)) ch = substr(s, RSTART + 9, RLENGTH - 9)
    }
    /<title/ {
        t = $0
        if (match(t, /<title[^>]*>[^<]*<\/title>/)) {
            t = substr(t, RSTART, RLENGTH)
            gsub(/<[^>]*>/, "", t)
            ti = t
        }
    }
    /<\/programme>/ {
        if (ti != "" && ch != "" && st != "") {
            if(!f)printf ","
            f=0
            gsub(/"/, "\\\"", ti)
            gsub(/"/, "\\\"", ch)
            printf "{\"t\":\"%s:%s\",\"c\":\"%s\",\"p\":\"%s\"}", substr(st,9,2), substr(st,11,2), ch, ti
            c++
            if(c>=50)exit
        }
        ti = ""
    }
    END{printf "]"}
    ' 2>/dev/null || true)

    printf '{"status":"ok","rows":%s}' "$rows"
}

# Удалить EPG
epg_remove() {
    rm -f "$EPG_GZ" "$EPG_CONFIG"
    log_info "EPG removed"
}
