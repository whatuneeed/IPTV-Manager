'use strict';
'require view';
'require uci';
'require rpc';

var callExec = rpc.declare({
    object: 'file',
    method: 'exec',
    params: ['command'],
    expect: {}
});

return view.extend({
    load: function() {
        return L.resolveDefault(uci.load('iptv'), {});
    },

    render: function() {
        var port = '8082';
        var statusEl = E('span', { 'style': 'color:#666;font-size:14px;font-weight:600' }, 'Проверка...');

        var startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                startBtn.disabled = true;
                startBtn.textContent = 'Запуск...';
                statusEl.style.color = '#1a73e8';
                statusEl.textContent = 'Запуск...';

                callExec({
                    command: '/bin/sh',
                    params: ['-c',
                        'kill $(pgrep -f "uhttpd.*:' + port + '") 2>/dev/null; sleep 1; ' +
                        'cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u 2>/dev/null; ' +
                        'nohup uhttpd -p 0.0.0.0:' + port + ' -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" </dev/null >/dev/null 2>&1 & sleep 2'
                    ]
                }).then(function() {
                    setTimeout(checkStatus, 2000);
                }).catch(function() {
                    setTimeout(checkStatus, 2000);
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
                    params: ['-c', 'kill $(pgrep -f "uhttpd.*:' + port + '") 2>/dev/null; sleep 1']
                }).then(function() {
                    setTimeout(checkStatus, 1000);
                }).catch(function() {
                    setTimeout(checkStatus, 1000);
                });
            }
        }, 'Остановить');

        function checkStatus() {
            callExec({ command: '/bin/sh', params: ['-c', 'pgrep -c "uhttpd.*:' + port + '" 2>/dev/null'] }).then(function(res) {
                var n = parseInt(((res.stdout || '0') + '').trim());
                if (n > 0) {
                    statusEl.textContent = '● Запущен';
                    statusEl.style.color = '#22c55e';
                    startBtn.textContent = '✓ Работает';
                    startBtn.disabled = false;
                    stopBtn.disabled = false;
                    stopBtn.textContent = 'Остановить';
                } else {
                    throw new Error();
                }
            }).catch(function() {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
                startBtn.textContent = 'Запустить';
                startBtn.disabled = false;
                stopBtn.disabled = true;
                stopBtn.textContent = 'Остановить';
            });
        }

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        checkStatus();

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    }
});
