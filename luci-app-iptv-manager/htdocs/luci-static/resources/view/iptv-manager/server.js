'use strict';
'require view';
'require uci';
'require fs';

return view.extend({
    load: function() {
        return L.resolveDefault(uci.load('iptv'), {});
    },

    render: function() {
        var lan_ip = uci.get('network', 'lan', 'ipaddr') || '192.168.1.1';
        var port = '8082';
        var baseUrl = 'http://' + lan_ip + ':' + port;

        var statusEl = E('span', { 'style': 'color:#666;font-size:14px;font-weight:600' }, 'Проверка...');

        var startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                startBtn.disabled = true;
                startBtn.textContent = 'Запуск...';
                statusEl.style.color = '#1a73e8';
                statusEl.textContent = 'Запуск...';

                // Write a start script first
                var script = '#!/bin/sh\n' +
                    'kill $(pgrep -f "uhttpd.*:' + port + '") 2>/dev/null\n' +
                    'rm -f /var/run/iptv-httpd.pid\n' +
                    'sleep 1\n' +
                    'nohup uhttpd -p 0.0.0.0:' + port + ' -h /www/iptv -x /www/iptv/cgi-bin -i ".cgi=/bin/sh" >/dev/null 2>&1 &\n' +
                    'PID=$!\n' +
                    'sleep 2\n' +
                    'echo $PID > /var/run/iptv-httpd.pid\n';

                fs.write('/etc/iptv/start-server.sh', script).then(function() {
                    fs.exec_direct('/etc/iptv/start-server.sh');
                }).then(function() {
                    return checkStatus(3000);
                }).catch(function() {
                    checkStatus(3000);
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

                var script = '#!/bin/sh\n' +
                    'kill $(pgrep -f "uhttpd.*:' + port + '") 2>/dev/null\n' +
                    'rm -f /var/run/iptv-httpd.pid\n' +
                    'kill $(cat /etc/iptv/monitor.pid 2>/dev/null) 2>/dev/null\n' +
                    'rm -f /etc/iptv/monitor.pid\n';

                fs.write('/etc/iptv/stop-server.sh', script).then(function() {
                    return fs.exec_direct('/etc/iptv/stop-server.sh');
                }).then(function() {
                    return checkStatus(1000);
                }).catch(function() {
                    checkStatus(1000);
                });
            }
        }, 'Остановить');

        function checkStatus(delay) {
            var d = delay || 0;
            return new Promise(function(resolve) {
                setTimeout(resolve, d);
            }).then(function() {
                return fs.stat('/var/run/iptv-httpd.pid');
            }).then(function(st) {
                if (st && st.size > 0) {
                    statusEl.textContent = '● Запущен';
                    statusEl.style.color = '#22c55e';
                    startBtn.textContent = '✓ Работает';
                    startBtn.disabled = false;
                    stopBtn.disabled = false;
                    stopBtn.textContent = 'Остановить';
                } else {
                    throw new Error('no pid');
                }
            }).catch(function() {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
                startBtn.textContent = 'Запустить';
                startBtn.disabled = false;
                stopBtn.disabled = false;
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