'use strict';
'require view';
'require uci';
'require fs';

return view.extend({
    load: function() {
        return L.resolveDefault(uci.load('iptv'), {});
    },

    _isRunning: function(port) {
        return fs.exec('/bin/sh', ['-c', 'pgrep uhttpd | tr "\n" " "']).then(function(res) {
            var pids = ((res.stdout || '') + ' ').trim().split(/\s+/).filter(Boolean);
            if (pids.length < 2) return false;
            var checks = pids.map(function(pid) {
                return fs.exec('/bin/sh', ['-c', 'cat /proc/' + pid + '/cmdline 2>/dev/null | tr "\\0" " "']).catch(function() { return {stdout: ''}; });
            });
            return Promise.all(checks).then(function(results) {
                return results.some(function(r) { return r.stdout && r.stdout.indexOf(':' + port) > -1; });
            });
        }).catch(function() { return false; });
    },

    render: function() {
        var port = '8082';
        var that = this;
        var statusEl = E('span', { 'style': 'color:#666;font-size:14px;font-weight:600' }, 'Проверка...');

        var startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                startBtn.disabled = true;
                startBtn.textContent = 'Запуск...';
                statusEl.style.color = '#1a73e8';
                statusEl.textContent = 'Запуск...';

                fs.exec('/bin/sh', ['-c',
                    'kill $(pgrep -f "uhttpd.*:' + port + '") 2>/dev/null; ' +
                    'sleep 1; ' +
                    'cp /etc/iptv/playlist.m3u /www/iptv/playlist.m3u 2>/dev/null; ' +
                    'uhttpd -p 0.0.0.0:' + port + ' -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh"'
                ]).then(null, function() {
                    // uhttpd doesn't exit - it runs in foreground with & in shell
                    // fs.exec waits for process, which means it never returns
                    // So we always get here or catch timeout
                });

                setTimeout(function() {
                    that._isRunning(port).then(function(ok) {
                        statusEl.textContent = ok ? '● Запущен' : '○ Остановлен';
                        statusEl.style.color = ok ? '#22c55e' : '#666';
                        startBtn.textContent = ok ? '✓ Работает' : 'Запустить';
                        startBtn.disabled = false;
                        stopBtn.disabled = !ok;
                        stopBtn.textContent = 'Остановить';
                    });
                }, 3000);
            }
        }, 'Запустить');

        var stopBtn = E('button', {
            'class': 'cbi-button cbi-button-negative',
            'click': function(ev) {
                stopBtn.disabled = true;
                stopBtn.textContent = 'Остановка...';
                statusEl.style.color = '#ef4444';
                statusEl.textContent = 'Остановка...';

                fs.exec_direct('/bin/sh', ['-c',
                    'kill $(pgrep -f "uhttpd.*:' + port + '") 2>/dev/null; ' +
                    'sleep 1'
                ]).then(function() {
                    statusEl.textContent = '○ Остановлен';
                    statusEl.style.color = '#666';
                    startBtn.textContent = 'Запустить';
                    startBtn.disabled = false;
                    stopBtn.disabled = true;
                    stopBtn.textContent = 'Остановить';
                }).catch(function() {
                    checkStatus(1000);
                });
            }
        }, 'Остановить');

        function checkStatus(delay) {
            var d = delay || 0;
            return new Promise(function(resolve) { setTimeout(resolve, d); })
                .then(function() { return that._isRunning(port); })
                .then(function(ok) {
                    statusEl.textContent = ok ? '● Запущен' : '○ Остановлен';
                    statusEl.style.color = ok ? '#22c55e' : '#666';
                    startBtn.textContent = ok ? '✓ Работает' : 'Запустить';
                    startBtn.disabled = false;
                    stopBtn.disabled = !ok;
                    stopBtn.textContent = 'Остановить';
                });
        }

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        checkStatus(500);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    }
});