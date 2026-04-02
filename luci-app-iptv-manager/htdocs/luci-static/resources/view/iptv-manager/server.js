'use strict';
'require view';
'require uci';

return view.extend({
    load: function() {
        return L.resolveDefault(uci.load('iptv'), {});
    },

    render: function() {
        var statusEl = E('span', { 'style': 'color:#666;font-size:14px;font-weight:600' }, 'Проверка...');
        var that = this;

        var startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                startBtn.disabled = true;
                startBtn.textContent = 'Запуск...';
                statusEl.style.color = '#1a73e8';
                statusEl.textContent = 'Запуск...';

                L.ubus.call('file', 'exec', {
                    command: '/bin/sh',
                    params: ['-c',
                        'cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u 2>/dev/null; ' +
                        '/etc/init.d/iptv-manager enable; ' +
                        '/etc/init.d/iptv-manager start'
                    ]
                }).then(function() {
                    setTimeout(function() { that.checkStatus(statusEl, startBtn, stopBtn); }, 3000);
                }).catch(function() {
                    setTimeout(function() { that.checkStatus(statusEl, startBtn, stopBtn); }, 3000);
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

                L.ubus.call('file', 'exec', {
                    command: '/bin/sh',
                    params: ['-c', '/etc/init.d/iptv-manager stop']
                }).then(function() {
                    setTimeout(function() { that.checkStatus(statusEl, startBtn, stopBtn); }, 2000);
                }).catch(function() {
                    setTimeout(function() { that.checkStatus(statusEl, startBtn, stopBtn); }, 2000);
                });
            }
        }, 'Остановить');

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        this.checkStatus(statusEl, startBtn, stopBtn);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    },

    checkStatus: function(statusEl, startBtn, stopBtn) {
        L.ubus.call('file', 'exec', {
            command: '/bin/sh',
            params: ['-c', 'pgrep uhttpd']
        }).then(function(res) {
            var out = (res.stdout || '').trim();
            if (out.length > 0) {
                statusEl.textContent = '● Запущен';
                statusEl.style.color = '#22c55e';
                if (startBtn) startBtn.textContent = '✓ Работает';
                if (stopBtn) stopBtn.disabled = false;
                if (startBtn) startBtn.disabled = false;
                if (stopBtn) stopBtn.textContent = 'Остановить';
            } else {
                throw new Error();
            }
        }).catch(function() {
            statusEl.textContent = '○ Остановлен';
            statusEl.style.color = '#666';
            if (startBtn) startBtn.textContent = 'Запустить';
            if (startBtn) startBtn.disabled = false;
            if (stopBtn) stopBtn.disabled = true;
            if (stopBtn) stopBtn.textContent = 'Остановить';
        });
    }
});
