#!/bin/sh
# ==========================================
# IPTV Manager — Scheduler module
# Автоматическое обновление плейлиста и EPG
# ==========================================

# Convert "DD.MM.YYYY HH:MM" to epoch (BusyBox-compatible, no date -d)
_date_to_epoch() {
    local input="$1"
    # Parse DD.MM.YYYY HH:MM
    local day month year hour min
    day=$(echo "$input" | cut -d. -f1)
    month=$(echo "$input" | cut -d. -f2)
    year=$(echo "$input" | cut -d. -f3 | cut -d' ' -f1)
    hour=$(echo "$input" | cut -d' ' -f2 | cut -d: -f1)
    min=$(echo "$input" | cut -d: -f2)
    # Validate
    case "$year" in ''|*[!0-9]*) echo "0"; return;; esac
    case "$month" in ''|*[!0-9]*) echo "0"; return;; esac
    # Approximate epoch (good enough for interval comparison)
    awk -v y="$year" -v m="$month" -v d="${day:-1}" -v h="${hour:-0}" -v mi="${min:-0}" 'BEGIN{
        # Days from 1970 to year
        days = 0
        for(i=1970; i<y; i++) days += (i%4==0) ? 366 : 365
        # Days in months
        split("31,28,31,30,31,30,31,31,30,31,30,31", md, ",")
        if(y%4==0) md[2]=29
        for(i=1; i<m; i++) days += md[i]
        days += d - 1
        printf "%d", days*86400 + h*3600 + mi*60
    }'
}

# Запустить планировщик
scheduler_start() {
    scheduler_stop

    cat > /tmp/iptv-scheduler.sh << 'SCEOF'
#!/bin/sh
D=/etc/iptv
echo $$ > /var/run/iptv-scheduler.pid

# BusyBox-compatible date to epoch
_date_to_epoch() {
    local input="$1"
    local day month year hour min
    day=$(echo "$input" | cut -d. -f1)
    month=$(echo "$input" | cut -d. -f2)
    year=$(echo "$input" | cut -d. -f3 | cut -d' ' -f1)
    hour=$(echo "$input" | cut -d' ' -f2 | cut -d: -f1)
    min=$(echo "$input" | cut -d: -f2)
    case "$year" in ''|*[!0-9]*) echo "0"; return;; esac
    case "$month" in ''|*[!0-9]*) echo "0"; return;; esac
    awk -v y="$year" -v m="$month" -v d="${day:-1}" -v h="${hour:-0}" -v mi="${min:-0}" 'BEGIN{
        days = 0
        for(i=1970; i<y; i++) days += (i%4==0) ? 366 : 365
        split("31,28,31,30,31,30,31,31,30,31,30,31", md, ",")
        if(y%4==0) md[2]=29
        for(i=1; i<m; i++) days += md[i]
        days += d - 1
        printf "%d", days*86400 + h*3600 + mi*60
    }'
}

while true; do
    sleep 60
    [ ! -f "$D/schedule.conf" ] && continue
    . "$D/schedule.conf"

    N=$(date +%s 2>/dev/null || echo 0)

    # Обновление плейлиста
    if [ "${PLAYLIST_INTERVAL:-0}" -gt 0 ] 2>/dev/null; then
        L=$(_date_to_epoch "${PLAYLIST_LAST_UPDATE:-0}")
        if [ "$(( (N-L)/3600 ))" -ge "$PLAYLIST_INTERVAL" ] 2>/dev/null; then
            . "$D/iptv.conf" 2>/dev/null
            case "$PLAYLIST_TYPE" in
                url) wget -q --timeout=15 --no-check-certificate -O "$D/playlist.m3u" "$PLAYLIST_URL" 2>/dev/null ;;
                file) [ -f "$PLAYLIST_SOURCE" ] && cp "$PLAYLIST_SOURCE" "$D/playlist.m3u" ;;
            esac
            NT=$(date '+%d.%m.%Y %H:%M')
            printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' \
                "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$NT" "$EPG_LAST_UPDATE" > "$D/schedule.conf"
            [ -f "$D/playlist.m3u" ] && cp "$D/playlist.m3u" /www/iptv/playlist.m3u 2>/dev/null || true
        fi
    fi

    # Обновление EPG
    if [ "${EPG_INTERVAL:-0}" -gt 0 ] 2>/dev/null; then
        L=$(_date_to_epoch "${EPG_LAST_UPDATE:-0}")
        if [ "$(( (N-L)/3600 ))" -ge "$EPG_INTERVAL" ] 2>/dev/null; then
            . "$D/epg.conf" 2>/dev/null
            if [ -n "$EPG_URL" ]; then
                wget -q --timeout=30 --no-check-certificate -O "$D/epg-dl.tmp" "$EPG_URL" 2>/dev/null && [ -s "$D/epg-dl.tmp" ] && {
                    M=$(hexdump -n 2 -e '2/1 "%02x"' "$D/epg-dl.tmp" 2>/dev/null)
                    if [ "$M" = "1f8b" ]; then
                        cp "$D/epg-dl.tmp" /tmp/iptv-epg.xml.gz
                    else
                        gzip -c "$D/epg-dl.tmp" > /tmp/iptv-epg.xml.gz 2>/dev/null
                    fi
                    NT=$(date '+%d.%m.%Y %H:%M')
                    printf 'PLAYLIST_INTERVAL="%s"\nEPG_INTERVAL="%s"\nPLAYLIST_LAST_UPDATE="%s"\nEPG_LAST_UPDATE="%s"\n' \
                        "$PLAYLIST_INTERVAL" "$EPG_INTERVAL" "$PLAYLIST_LAST_UPDATE" "$NT" > "$D/schedule.conf"
                    rm -f "$D/epg-dl.tmp"
                }
            fi
        fi
    fi
done
SCEOF
    chmod +x /tmp/iptv-scheduler.sh
    /bin/sh /tmp/iptv-scheduler.sh &
    log_info "Scheduler started"
    echo_success "Планировщик запущен"
}

# Остановить планировщик
scheduler_stop() {
    kill "$(cat /var/run/iptv-scheduler.pid 2>/dev/null)" 2>/dev/null || true
    rm -f /var/run/iptv-scheduler.pid /tmp/iptv-scheduler.sh
    log_info "Scheduler stopped"
}
