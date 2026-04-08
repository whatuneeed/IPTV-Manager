#!/bin/sh
# ==========================================
# IPTV Manager — Logger module
# ==========================================

log_info()  { logger -t "iptv-manager" "[INFO] $1" 2>/dev/null || true; }
log_error() { logger -t "iptv-manager" "[ERROR] $1" 2>/dev/null || true; }
log_warn()  { logger -t "iptv-manager" "[WARN] $1" 2>/dev/null || true; }

# Log wrapper for commands: log_run "description" command args...
log_run() {
    local desc="$1"
    shift
    log_info "Running: $desc"
    if "$@" >>/tmp/iptv-manager.log 2>&1; then
        log_info "OK: $desc"
        return 0
    else
        log_error "FAIL: $desc (exit code: $?)"
        return 1
    fi
}
