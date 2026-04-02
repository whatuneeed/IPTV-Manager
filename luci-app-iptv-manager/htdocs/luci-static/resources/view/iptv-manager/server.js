'use strict';
'require view';
'require uci';
'require ui';

return view.extend({
    load: function() {
        return Promise.all([uci.load('iptv')]);
    },

    render: function() {
        var lan_ip = uci.get('network', 'lan', 'ipaddr') || '192.168.1.1';
        var port = '8082';
        var baseUrl = 'http://' + lan_ip + ':' + port;
        var adminUrl = baseUrl + '/cgi-bin/admin.cgi';

        var statusEl = E('span', { 'style': 'color:#666;font-size:14px;font-weight:600' }, 'Проверка...');

        var startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                startBtn.disabled = true;
                startBtn.textContent = 'Запуск...';
                statusEl.style.color = '#1a73e8';
                statusEl.textContent = 'Запуск...';

                // Server is CGI — if it responds, it's running.
                // If not, tell user to start via terminal script.
                var xhr = new XMLHttpRequest();
                xhr.open('GET', adminUrl, true);
                xhr.timeout = 5000;
                xhr.onload = function() {
                    statusEl.textContent = '● Запущен';
                    statusEl.style.color = '#22c55e';
                    startBtn.textContent = '✓ Работает';
                    startBtn.disabled = false;
                };
                xhr.onerror = function() {
                    // Not running — instruct user
                    statusEl.textContent = '✗ Не запущен';
                    statusEl.style.color = '#ef4444';
                    ui.addNotification(null, E('p', {}, 
                        'Сервер не запущен. Выполните в терминале роутера: ' +
                        E('code', {}, 'sh /etc/iptv/IPTV-Manager.sh') +
                        ' → пункт 4) Сервер → 1) Запустить'), 'info');
                    startBtn.textContent = 'Запустить';
                    startBtn.disabled = false;
                    startBtn.onclick = function() {
                        window.open(adminUrl, '_blank');
                    };
                };
                xhr.ontimeout = function() {
                    statusEl.textContent = '✗_timeout';
                    statusEl.style.color = '#ef4444';
                    startBtn.textContent = 'Запустить';
                    startBtn.disabled = false;
                };
                xhr.send();
            }
        }, 'Запустить сервер');

        var stopBtn = E('button', {
            'class': 'cbi-button cbi-button-negative',
            'click': function(ev) {
                stopBtn.disabled = true;
                stopBtn.textContent = 'Остановка...';
                statusEl.style.color = '#ef4444';
                statusEl.textContent = 'Остановка...';

                var xhr = new XMLHttpRequest();
                xhr.open('POST', adminUrl, true);
                xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
                xhr.timeout = 10000;
                // Both success AND error = success (server kills itself)
                var done = false;
                xhr.onload = function() {
                    if (done) return;
                    done = true;
                    finishStop();
                };
                xhr.onerror = function() {
                    if (done) return;
                    done = true;
                    finishStop();
                };
                xhr.ontimeout = function() {
                    if (done) return;
                    done = true;
                    finishStop();
                };
                xhr.send('action=stop_server');

                function finishStop() {
                    statusEl.textContent = '○ Остановлен';
                    startBtn.textContent = 'Запустить сервер';
                    startBtn.disabled = false;
                    stopBtn.disabled = false;
                    stopBtn.textContent = 'Остановить сервер';
                    startBtn.onclick = null;
                    // Rebind start
                    startBtn.onclick = arguments.callee.caller.caller.caller;
                }
            }
        }, 'Остановить сервер');

        var btnRow = E('div', {
            'class': 'cbi-section',
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center;justify-content:space-between'
        }, [
            E('div', { 'style': 'display:flex;gap:10px;align-items:center' }, [startBtn, stopBtn]),
            statusEl
        ]);

        var adminLink = E('a', {
            'style': 'color:#1a73e8;font-size:13px;text-decoration:none',
            'href': adminUrl, 'target': '_blank'
        }, 'Открыть админку →');

        var playerLink = E('a', {
            'style': 'color:#1a73e8;font-size:13px;text-decoration:none',
            'href': baseUrl + '/player.html', 'target': '_blank'
        }, 'Открыть плеер →');

        var m3uInfo = E('div', { 'style': 'font-size:12px;color:#888' },
            'Плейлист: ' + E('code', {}, baseUrl + '/playlist.m3u')
        );

        var epgInfo = E('div', { 'style': 'font-size:12px;color:#888' },
            'EPG: ' + E('code', {}, baseUrl + '/epg.xml')
        );

        var linksRow = E('div', {
            'style': 'display:flex;gap:15px;flex-wrap:wrap;margin-top:10px;border-top:1px solid #ddd;padding-top:10px'
        }, [adminLink, playerLink, m3uInfo, epgInfo]);

        // Initial status check
        setTimeout(function() {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', adminUrl, true);
            xhr.timeout = 3000;
            xhr.onload = function() {
                statusEl.textContent = '● Запущен';
                statusEl.style.color = '#22c55e';
                startBtn.textContent = '✓ Работает';
            };
            xhr.onerror = xhr.ontimeout = function() {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
            };
            xhr.send();
        }, 500);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            btnRow,
            linksRow
        ]);
    }
});
