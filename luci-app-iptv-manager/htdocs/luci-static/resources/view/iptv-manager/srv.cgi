#!/bin/sh
PID=/var/run/iptv-httpd.pid
HDR() { printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'; }
JSON() { printf 'Content-Type: application/json\r\n\r\n'; }
ACT=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')
case "$ACTION$ACT" in
    *start*)
        JSON
        kill $(pgrep -f "uhttpd.*8082") 2>/dev/null
        sleep 1
        mkdir -p /www/iptv /www/iptv/cgi-bin
        [ -f /etc/iptv/playlist.m3u ] && cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u 2>/dev/null
        [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml 2>/dev/null
        uhttpd -p 0.0.0.0:8082 -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" </dev/null >/dev/null 2>&1 &
        printf '{"ok":true}'
        ;;
    *stop*)
        JSON
        kill $(pgrep -f "uhttpd.*8082") 2>/dev/null
        rm -f $PID 2>/dev/null
        printf '{"ok":true}'
        ;;
    *status*)
        JSON
        if [ -f $PID ] && kill -0 "$(cat $PID 2>/dev/null)" 2>/dev/null; then
            printf '{"ok":true,"running":true}'
        elif wget -q -O /dev/null --timeout=2 http://127.0.0.1:8082/ 2>/dev/null; then
            printf '{"ok":true,"running":true}'
        else
            printf '{"ok":true,"running":false}'
        fi
        ;;
    *)
        HDR
        cat /www/luci-static/resources/view/iptv-manager/srv.html
        ;;
esac
