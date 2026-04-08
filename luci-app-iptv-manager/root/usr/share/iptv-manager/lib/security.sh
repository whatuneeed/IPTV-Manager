#!/bin/sh
# ==========================================
# IPTV Manager — Security module
# Rate limiting, IP whitelist, авторизация
# ==========================================

# --- Rate limiter ---
_rate_limit() {
    local ip="${REMOTE_ADDR:-unknown}"
    local now
    now=$(date +%s)
    local block_file="/tmp/iptv-blocked-$ip"

    # Проверяем блокировку
    if [ -f "$block_file" ] && [ "$(cat "$block_file")" -gt "$now" ] 2>/dev/null; then
        return 1
    fi

    [ -f "$RATE_FILE" ] || echo "" > "$RATE_FILE"

    local recent
    recent=$(awk -v n="$now" 'BEGIN{c=0}{if($1>n-60)c++}END{print c}' "$RATE_FILE")

    echo "$now" >> "$RATE_FILE"

    # Atomic write
    local tmp_rf="/tmp/rf_tmp.$$"
    awk -v n="$now" '{if($1>n-60)print}' "$RATE_FILE" > "$tmp_rf" && mv "$tmp_rf" "$RATE_FILE"

    if _is_number "$recent" && [ "$recent" -ge "$RATE_LIMIT" ] 2>/dev/null; then
        echo "$((now + BLOCK_DURATION))" > "$block_file"
        log_warn "Rate limit exceeded for $ip ($recent requests/min)"
        return 1
    fi

    return 0
}

# --- IP whitelist ---
_ip_whitelist() {
    [ -s "$WHITELIST_FILE" ] || return 0
    local ip="${REMOTE_ADDR%:*}"
    grep -q "^${ip}$" "$WHITELIST_FILE" 2>/dev/null || return 1
}

# --- Security config ---
security_set_password() {
    local user="$1"
    local pass="$2"
    local cur_token
    cur_token=$(grep API_TOKEN "$SECURITY_FILE" 2>/dev/null | sed 's/.*="//;s/"//' || true)

    if [ -z "$user" ]; then
        printf 'ADMIN_USER=""\nADMIN_PASS=""\nAPI_TOKEN="%s"\n' "$cur_token" > "$SECURITY_FILE"
        log_info "Password authentication disabled"
    else
        printf 'ADMIN_USER="%s"\nADMIN_PASS="%s"\nAPI_TOKEN="%s"\n' "$user" "$pass" "$cur_token" > "$SECURITY_FILE"
        log_info "Password authentication enabled for user: $user"
    fi
}

security_set_token() {
    local token="$1"
    local cur_user cur_pass
    cur_user=$(grep ADMIN_USER "$SECURITY_FILE" 2>/dev/null | sed 's/.*="//;s/"//' || true)
    cur_pass=$(grep ADMIN_PASS "$SECURITY_FILE" 2>/dev/null | sed 's/.*="//;s/"//' || true)
    printf 'ADMIN_USER="%s"\nADMIN_PASS="%s"\nAPI_TOKEN="%s"\n' "$cur_user" "$cur_pass" "$token" > "$SECURITY_FILE"
    log_info "API token ${token:+enabled}${token:-disabled}"
}

security_set_whitelist() {
    local ips="$1"  # один IP на строку
    if [ -n "$ips" ]; then
        echo "$ips" | tr ' ' '\n' | grep -v '^$' > "$WHITELIST_FILE"
        log_info "IP whitelist updated"
    else
        > "$WHITELIST_FILE"
        log_info "IP whitelist cleared (all allowed)"
    fi
}
