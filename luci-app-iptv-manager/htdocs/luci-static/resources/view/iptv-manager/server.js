'use strict';
'require view';
'require uci';
'require ui';

return view.extend({
    load: function() {
        return L.resolveDefault(uci.load('iptv'), {});
    },

    render: function() {
        var lan_ip = uci.get('network', 'lan', 'ipaddr') || '192.168.1.1';
        var port = '8082';
        var adminUrl = 'http://' + lan_ip + ':' + port + '/cgi-bin/admin.cgi';

        var statusEl = E('span', { 'style': 'color:#666;font-size:14px;font-weight:600' }, 'Проверка...');
        var infoEl = E('div', { 'style': 'color:#888;font-size:12px;margin-top:4px' });

        var startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                startBtn.disabled = true;
                startBtn.textContent = 'Запуск...';
                // Open admin page in new tab — the server is already running as CGI
                window.open(adminUrl, '_blank');
                // Then check status
                setTimeout(function() {
                    startBtn.disabled = false;
                    startBtn.textContent = '✓ Открыто';
                    statusEl.textContent = '● Запущен';
                    statusEl.style.color = '#22c55e';
                }, 2000);
            }
        }, 'Открыть админку');

        var stopBtn = E('button', {
            'class': 'cbi-button cbi-button-negative',
            'click': function(ev) {
                stopBtn.disabled = true;
                stopBtn.textContent = 'Остановка...';
                statusEl.style.color = '#ef4444';
                statusEl.textContent = 'Остановка...';
                infoEl.textContent = '';

                var xhr = new XMLHttpRequest();
                xhr.open('POST', adminUrl, true);
                xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
                xhr.timeout = 10000;
                var done = false;
                var onDone = function() {
                    if (done) return;
                    done = true;
                    statusEl.textContent = '○ Остановлен';
                    startBtn.textContent = 'Открыть админку';
                    startBtn.disabled = false;
                    stopBtn.disabled = false;
                    stopBtn.textContent = 'Остановить';
                };
                xhr.onload = onDone;
                xhr.onerror = onDone;
                xhr.ontimeout = onDone;
                xhr.send('action=stop_server');
            }
        }, 'Остановить');

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        // Initial status check
        setTimeout(function() {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', adminUrl, true);
            xhr.timeout = 3000;
            xhr.onload = function() {
                statusEl.textContent = '● Запущен';
                statusEl.style.color = '#22c55e';
                stopBtn.disabled = false;
                startBtn.textContent = 'Открыть админку';
                startBtn.disabled = false;
            };
            xhr.onerror = xhr.ontimeout = function() {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
                stopBtn.disabled = true;
                startBtn.disabled = false;
                startBtn.textContent = 'Открыть админку';
                infoEl.textContent = 'Сервер не запущен. Откройте админку — он запустится автоматически.';
            };
            xhr.send();
        }, 500);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow, infoEl])
        ]);
    }
});
