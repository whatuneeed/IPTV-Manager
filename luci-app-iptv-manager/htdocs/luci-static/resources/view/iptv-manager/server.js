'use strict';
'require view';
'require uci';
'require rpc';

var callExec = rpc.declare({
    object: 'file',
    method: 'exec',
    params: ['command', 'params'],
    expect: {}
});

return view.extend({
    load: function() {
        return L.resolveDefault(uci.load('iptv'), {});
    },

    _isRunning: function() {
        return callExec({
            command: '/bin/sh',
            params: ['-c', 'wget -q -O /dev/null --timeout=2 http://127.0.0.1:8082/ 2>/dev/null']
        }).then(function(res) {
            return res.code === 0;
        }).catch(function() {
            return false;
        });
    },

    render: function(data) {
        var statusEl = E('span', { 'style': 'color:#666;font-size:14px;font-weight:600' }, 'Проверка...');
        var self = this;

        var startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                startBtn.disabled = true;
                startBtn.textContent = 'Запуск...';
                statusEl.style.color = '#1a73e8';
                statusEl.textContent = 'Запуск...';

                var cmd = [
                    'cat > /etc/init.d/iptv-manager <<INITSCRIPT',
                    '#!/bin/sh /etc/rc.common',
                    'START=99',
                    'USE_PROCD=1',
                    'start_service() {',
                    '    mkdir -p /www/iptv/cgi-bin',
                    '    cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u 2>/dev/null',
                    '    [ -f /etc/iptv/epg.xml ] && cp /etc/iptv/epg.xml /www/iptv/epg.xml 2>/dev/null',
                    '    procd_open_instance',
                    '    procd_set_param command uhttpd -f -p 0.0.0.0:8082 -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh"',
                    '    procd_set_param pidfile /var/run/iptv-httpd.pid',
                    '    procd_set_param stdout 1',
                    '    procd_set_param stderr 1',
                    '    procd_close_instance',
                    '}',
                    'stop() { kill $(pgrep -f "uhttpd.*8082" 2>/dev/null) 2>/dev/null; rm -f /var/run/iptv-httpd.pid; }',
                    'INITSCRIPT',
                    'chmod 755 /etc/init.d/iptv-manager',
                    '/etc/init.d/iptv-manager enable',
                    '/etc/init.d/iptv-manager restart'
                ].join(' && ');

                callExec({
                    command: '/bin/sh',
                    params: ['-c', cmd]
                }).then(function() {
                    return new Promise(function(r) { setTimeout(r, 3000); });
                }).then(function() {
                    return self._isRunning();
                }).then(function(ok) {
                    _setStatus(ok);
                }).catch(function() {
                    _setStatus(false);
                });
            }
        }, 'Запустить');

        var stopBtn = E('button', {
            'class': 'cbi-button cbi-button-negative',
            'click': function(ev) {
                stopBtn.disabled = true;
                stopBtn.textContent = 'Остановка...';
                statusEl.style.color = '#ef4444';
                statusEl.textContent = 'Остановка...';

                callExec({
                    command: '/bin/sh',
                    params: ['-c', '/etc/init.d/iptv-manager stop']
                }).then(function() {
                    return new Promise(function(r) { setTimeout(r, 1500); });
                }).then(function() {
                    return self._isRunning();
                }).then(function(ok) {
                    _setStatus(ok);
                }).catch(function() {
                    _setStatus(false);
                });
            }
        }, 'Остановить');

        function _setStatus(ok) {
            if (ok) {
                statusEl.textContent = '● Запущен';
                statusEl.style.color = '#22c55e';
                startBtn.textContent = '✓ Работает';
                startBtn.disabled = false;
                stopBtn.disabled = false;
            } else {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
                startBtn.textContent = 'Запустить';
                startBtn.disabled = false;
                stopBtn.disabled = true;
            }
        }

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        self._isRunning().then(function(ok) {
            _setStatus(ok);
        }).catch(function() {
            _setStatus(false);
        });

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    }
});
