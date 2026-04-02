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

    _checkStatus: function() {
        return callExec({
            command: '/bin/sh',
            params: ['-c', 'pgrep uhttpd']
        }).then(function(res) {
            var out = ((res && res.stdout) || '').trim();
            return out.length > 0;
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

                callExec({
                    command: '/bin/sh',
                    params: ['-c', 'cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u 2>/dev/null && /etc/init.d/iptv-manager enable && /etc/init.d/iptv-manager start']
                }).then(function() {
                    return new Promise(function(resolve) { setTimeout(resolve, 3000); });
                }).then(function() {
                    return self._checkStatus();
                }).then(function(ok) {
                    if (ok) {
                        statusEl.textContent = '● Запущен';
                        statusEl.style.color = '#22c55e';
                        startBtn.textContent = '✓ Работает';
                        stopBtn.disabled = false;
                    } else {
                        statusEl.textContent = '✗ Не запустился';
                        statusEl.style.color = '#ef4444';
                    }
                    startBtn.disabled = false;
                }).catch(function() {
                    statusEl.textContent = '✗ Ошибка';
                    statusEl.style.color = '#ef4444';
                    startBtn.disabled = false;
                    startBtn.textContent = 'Запустить';
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
                    return new Promise(function(resolve) { setTimeout(resolve, 2000); });
                }).then(function() {
                    return self._checkStatus();
                }).then(function(ok) {
                    if (!ok) {
                        statusEl.textContent = '○ Остановлен';
                        statusEl.style.color = '#666';
                        startBtn.textContent = 'Запустить';
                    } else {
                        statusEl.textContent = '● Запущен';
                        statusEl.style.color = '#22c55e';
                        startBtn.textContent = '✓ Работает';
                    }
                    startBtn.disabled = false;
                    stopBtn.disabled = !ok;
                    stopBtn.textContent = 'Остановить';
                }).catch(function() {
                    statusEl.textContent = '○ Остановлен';
                    statusEl.style.color = '#666';
                    startBtn.textContent = 'Запустить';
                    startBtn.disabled = false;
                    stopBtn.disabled = true;
                    stopBtn.textContent = 'Остановить';
                });
            }
        }, 'Остановить');

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        self._checkStatus().then(function(ok) {
            if (ok) {
                statusEl.textContent = '● Запущен';
                statusEl.style.color = '#22c55e';
                startBtn.textContent = '✓ Работает';
            } else {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
                stopBtn.disabled = true;
            }
        });

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    }
});
