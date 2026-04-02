'use strict';
'require view';
'require uci';
'require ui';
'require poll';
'require fs';

return view.extend({
    load: function() {
        return L.resolveDefault(uci.load('iptv'), {});
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

                // Use ubus file.exec to run the start command
                L.ubus.call('file', 'exec', {
                    command: '/bin/sh',
                    params: ['-c', '/etc/init.d/iptv-manager start >/dev/null 2>&1 &']
                }).then(function(res) {
                    // Wait then check
                    setTimeout(function() {
                        checkStatus();
                    }, 3000);
                }).catch(function(err) {
                    // Fallback: use uhttpd directly
                    L.ubus.call('file', 'exec', {
                        command: 'uhttpd',
                        params: ['-f', '-p', '0.0.0.0:' + port, '-h', '/www/iptv', '-x', '/www/iptv/cgi-bin', '-i', '.cgi=/bin/sh']
                    }).then(function(res) {
                        setTimeout(checkStatus, 3000);
                    }).catch(function(err2) {
                        statusEl.textContent = '✗ Ошибка';
                        statusEl.style.color = '#ef4444';
                        startBtn.textContent = 'Запустить';
                        startBtn.disabled = false;
                    });
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

                // Kill uhttpd on port 8082 via ubus
                L.ubus.call('file', 'exec', {
                    command: '/bin/sh',
                    params: ['-c', "kill $(pgrep -f 'uhttpd.*:" + port + "') 2>/dev/null; rm -f /var/run/iptv-httpd.pid"]
                }).then(function(res) {
                    checkStatus();
                }).catch(function() {
                    statusEl.textContent = '✗ Ошибка';
                    statusEl.style.color = '#ef4444';
                    stopBtn.textContent = 'Остановить';
                    stopBtn.disabled = false;
                });
            }
        }, 'Остановить');

        function checkStatus() {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', adminUrl, true);
            xhr.timeout = 3000;
            xhr.onload = function() {
                statusEl.textContent = '● Запущен';
                statusEl.style.color = '#22c55e';
                startBtn.textContent = '✓ Работает';
                startBtn.disabled = false;
                stopBtn.disabled = false;
                stopBtn.textContent = 'Остановить';
            };
            xhr.onerror = xhr.ontimeout = function() {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
                startBtn.textContent = 'Запустить';
                startBtn.disabled = false;
                stopBtn.disabled = true;
                stopBtn.textContent = 'Остановить';
            };
            xhr.send();
        }

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        // Initial status
        setTimeout(checkStatus, 500);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    }
});
