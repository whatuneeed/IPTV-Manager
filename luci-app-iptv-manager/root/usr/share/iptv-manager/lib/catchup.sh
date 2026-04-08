#!/bin/sh
# ==========================================
# IPTV Manager — Catchup / Timeshift module
# Парсинг catchup-атрибутов из M3U и генерация архивных ссылок
# ==========================================

# --- Парсинг catchup-атрибутов из M3U ---
# Извлекает catchup-данные для всех каналов в JSON
# Формат вывода: [{"channel":"name","url":"stream","catchup":"type","catchup_source":"url","catchup_days":3},...]
catchup_parse_m3u() {
    local playlist="${1:-$PLAYLIST_FILE}"
    [ -f "$playlist" ] || { echo "[]"; return; }

    awk '
    /#EXTINF:/ {
        name = ""; catchup = ""; catchup_source = ""; catchup_days = "3"
        # Извлекаем имя канала
        ii = index($0, ",")
        if (ii > 0) { name = substr($0, ii+1); sub(/^[ \t]+/, "", name) }
        if (name == "") name = "Неизвестный"

        # catchup тип
        p = index($0, "catchup=\"")
        if (p > 0) {
            s = substr($0, p+9)
            e = index(s, "\"")
            catchup = substr(s, 1, e-1)
        }

        # catchup-source
        p = index($0, "catchup-source=\"")
        if (p > 0) {
            s = substr($0, p+16)
            e = index(s, "\"")
            catchup_source = substr(s, 1, e-1)
        }

        # catchup-days
        p = index($0, "catchup-days=\"")
        if (p > 0) {
            s = substr($0, p+14)
            e = index(s, "\"")
            catchup_days = substr(s, 1, e-1)
        }
        next
    }
    /^http/ {
        gsub(/"/, "\\\"", $0)
        gsub(/"/, "\\\"", name)
        gsub(/"/, "\\\"", catchup_source)
        if (catchup != "") {
            printf "{\"channel\":\"%s\",\"url\":\"%s\",\"catchup\":\"%s\",\"catchup_source\":\"%s\",\"catchup_days\":%s}\n", \
                name, $0, catchup, catchup_source, catchup_days
        }
    }
    ' "$playlist" 2>/dev/null
}

# --- Утилита: timestamp → date components (BusyBox-compatible) ---
_ts_to_date() {
    local ts="$1"
    # BusyBox date doesn't support -d, use awk for conversion
    awk -v ts="$ts" 'BEGIN{
        # Unix epoch to YMDHMS
        # This is approximate but works on BusyBox
        days = int(ts / 86400)
        rem = ts - days * 86400
        h = int(rem / 3600); rem = rem - h * 3600
        m = int(rem / 60); s = rem - m * 60
        # Approximate year from days since 1970
        y = 1970 + int(days / 365.25)
        # Approximate month/day (rough)
        doy = days - int((y - 1970) * 365.25)
        if(doy < 0) { y--; doy = days - int((y - 1970) * 365.25) }
        mdays[1]=31; mdays[2]=28; mdays[3]=31; mdays[4]=30; mdays[5]=31; mdays[6]=30
        mdays[7]=31; mdays[8]=31; mdays[9]=30; mdays[10]=31; mdays[11]=30; mdays[12]=31
        if(y%4==0) mdays[2]=29
        mo = 1
        while(mo <= 12 && doy >= mdays[mo]) { doy -= mdays[mo]; mo++ }
        printf "%04d %02d %02d %02d %02d %02d", y, mo, doy+1, h, m, s
    }'
}

# --- Генерация архивной ссылки ---
# Usage: catchup_generate_url "catchup_source" "channel_url" "start_ts" "end_ts" "catchup_type" "catchup_id"
catchup_generate_url() {
    local source="$1"
    local channel_url="$2"
    local start_ts="$3"
    local end_ts="$4"
    local catchup_type="$5"
    local catchup_id="${6:-}"

    [ -z "$source" ] && [ -z "$catchup_type" ] && return 1

    local duration=$((end_ts - start_ts))

    # Form date components using BusyBox-compatible method
    local date_parts
    date_parts=$(_ts_to_date "$start_ts")
    local start_Y start_m start_d start_H start_M start_S
    start_Y=$(echo "$date_parts" | awk '{print $1}')
    start_m=$(echo "$date_parts" | awk '{print $2}')
    start_d=$(echo "$date_parts" | awk '{print $3}')
    start_H=$(echo "$date_parts" | awk '{print $4}')
    start_M=$(echo "$date_parts" | awk '{print $5}')
    start_S=$(echo "$date_parts" | awk '{print $6}')

    local result="$source"

    # Для shift/append режима — строим URL из channel_url
    if [ -z "$result" ]; then
        case "$catchup_type" in
            shift|append)
                if echo "$channel_url" | grep -q '?'; then
                    result="${channel_url}&utc=${start_ts}&lutc=${end_ts}"
                else
                    result="${channel_url}?utc=${start_ts}&lutc=${end_ts}"
                fi
                ;;
            *) return 1 ;;
        esac
    fi

    # Заменяем плейсхолдеры
    result=$(echo "$result" | sed \
        -e "s|{utc}|${start_ts}|g" \
        -e "s|\${start}|${start_ts}|g" \
        -e "s|{utcend}|${end_ts}|g" \
        -e "s|\${end}|${end_ts}|g" \
        -e "s|{lutc}|$(date +%s)|g" \
        -e "s|\${now}|$(date +%s)|g" \
        -e "s|\${timestamp}|$(date +%s)|g" \
        -e "s|{duration}|${duration}|g" \
        -e "s|{catchup-id}|${catchup_id}|g" \
        -e "s|{Y}|${start_Y}|g" \
        -e "s|{m}|${start_m}|g" \
        -e "s|{d}|${start_d}|g" \
        -e "s|{H}|${start_H}|g" \
        -e "s|{M}|${start_M}|g" \
        -e "s|{S}|${start_S}|g"
    )

    # Обработка {duration:X}
    local div
    div=$(echo "$result" | grep -o '{duration:[0-9]*}' | head -1 | grep -o '[0-9]*')
    if [ -n "$div" ] && [ "$div" -gt 0 ] 2>/dev/null; then
        local val=$((duration / div))
        result=$(echo "$result" | sed "s|{duration:[0-9]*}|${val}|g")
    fi

    echo "$result"
}

# --- CGI endpoint для catchup ---
# Вызывается из admin.cgi как action=get_catchup_url
# POST: channel_idx, start_ts, end_ts, catchup_id (опционально)
catchup_get_url() {
    local post_data="$1"

    local idx start_ts end_ts catchup_id
    idx=$(echo "$post_data" | sed -n 's/.*channel_idx=\([^&]*\).*/\1/p')
    start_ts=$(echo "$post_data" | sed -n 's/.*start_ts=\([^&]*\).*/\1/p')
    end_ts=$(echo "$post_data" | sed -n 's/.*end_ts=\([^&]*\).*/\1/p')
    catchup_id=$(echo "$post_data" | sed -n 's/.*catchup_id=\([^&]*\).*/\1/p')

    # Валидация
    case "$idx" in ''|*[!0-9]*) printf '{"status":"error","message":"Неверный индекс канала"}'; return 1 ;; esac
    case "$start_ts" in ''|*[!0-9]*) printf '{"status":"error","message":"Неверное время начала"}'; return 1 ;; esac
    case "$end_ts" in ''|*[!0-9]*) printf '{"status":"error","message":"Неверное время окончания"}'; return 1 ;; esac

    # Находим канал по индексу
    local channel_data
    channel_data=$(catchup_parse_m3u | sed -n "$((idx + 1))p")
    [ -z "$channel_data" ] && { printf '{"status":"error","message":"Канал не найден"}'; return 1; }

    local channel_url catchup_type catchup_source catchup_days
    channel_url=$(echo "$channel_data" | grep -o '"url":"[^"]*"' | head -1 | sed 's/"url":"//;s/"//')
    catchup_type=$(echo "$channel_data" | grep -o '"catchup":"[^"]*"' | head -1 | sed 's/"catchup":"//;s/"//')
    catchup_source=$(echo "$channel_data" | grep -o '"catchup_source":"[^"]*"' | head -1 | sed 's/"catchup_source":"//;s/"//')
    catchup_days=$(echo "$channel_data" | grep -o '"catchup_days":[0-9]*' | head -1 | sed 's/"catchup_days"://')

    [ -z "$catchup_type" ] && { printf '{"status":"error","message":"Канал не поддерживает архив"}'; return 1; }

    # Проверяем окно архива
    local now_ts
    now_ts=$(date +%s)
    local max_age=$((catchup_days * 86400))
    if [ "$((now_ts - start_ts))" -gt "$max_age" ] 2>/dev/null; then
        printf '{"status":"error","message":"Архив недоступен для этой даты (макс. %s дней)"}' "$catchup_days"
        return 1
    fi

    # Генерируем URL
    local archive_url
    archive_url=$(catchup_generate_url "$catchup_source" "$channel_url" "$start_ts" "$end_ts" "$catchup_type" "$catchup_id")

    if [ -n "$archive_url" ]; then
        printf '{"status":"ok","url":"%s","type":"%s"}' "$archive_url" "$catchup_type"
    else
        printf '{"status":"error","message":"Не удалось сгенерировать URL"}'
    fi
}

# --- Добавляем catchup-атрибуты в channels.json ---
# Расширяет стандартный channels.json полями catchup
catchup_enrich_channels_json() {
    local input="${1:-$PLAYLIST_FILE}"
    local output="${2:-/www/iptv/channels.json}"

    [ -f "$input" ] || { echo "[]" > "$output"; return; }

    awk '
    BEGIN { printf "["; f=1; i=0 }
    /#EXTINF:/ {
        nm=""; g=""; l=""; t=""; cp=""; cps=""; cpd="3"
        ii=index($0,","); if(ii>0){nm=substr($0,ii+1);sub(/^[ \t]+/,"",nm)}
        if(nm=="")nm="Неизвестный"
        p=index($0,"group-title=\""); if(p>0){s=substr($0,p+13);e=index(s,"\"");g=substr(s,1,e-1)}
        if(g=="")g="Общее"
        p=index($0,"tvg-logo=\""); if(p>0){s=substr($0,p+10);e=index(s,"\"");l=substr(s,1,e-1)}
        p=index($0,"tvg-id=\""); if(p>0){s=substr($0,p+8);e=index(s,"\"");t=substr(s,1,e-1)}

        # catchup атрибуты
        p=index($0,"catchup=\""); if(p>0){s=substr($0,p+9);e=index(s,"\"");cp=substr(s,1,e-1)}
        p=index($0,"catchup-source=\""); if(p>0){s=substr($0,p+16);e=index(s,"\"");cps=substr(s,1,e-1)}
        p=index($0,"catchup-days=\""); if(p>0){s=substr($0,p+14);e=index(s,"\"");cpd=substr(s,1,e-1)}
        next
    }
    /^http/ {
        if(!f) printf ","
        f=0
        gsub(/"/,"\\\"",$0); gsub(/"/,"\\\"",nm); gsub(/"/,"\\\"",g)
        gsub(/"/,"\\\"",l); gsub(/"/,"\\\"",t); gsub(/"/,"\\\"",cps)
        printf "{\"n\":\"%s\",\"g\":\"%s\",\"l\":\"%s\",\"i\":\"%s\",\"u\":\"%s\",\"idx\":%d,\"catchup\":\"%s\",\"catchup_source\":\"%s\",\"catchup_days\":%s}", \
            nm,g,l,t,$0,i,cp,cps,cpd
        i++
    }
    END { printf "]" }
    ' "$input" > "$output" 2>/dev/null || echo "[]" > "$output"
}

# --- API endpoint: список каналов с catchup поддержкой ---
catchup_list_channels() {
    local json
    json=$(catchup_parse_m3u)

    printf '{"status":"ok","channels":['
    local first=1
    echo "$json" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$first" -eq 1 ]; then
            first=0
        else
            printf ','
        fi
        printf '%s' "$line"
    done
    printf ']}'
}
