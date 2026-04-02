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

                fs.exec_direct('/bin/sh', ['-c',
                    'sh /etc/iptv/IPTV-Manager.sh start >/dev/null 2>&1 & ' +
                    'sleep 3'
                ]).then(function() {
                    return checkStatus(2000);
                }).catch(function(e) {
                    statusEl.textContent = '✗ Ошибка';
                    statusEl.style.color = '#ef4444';
                    startBtn.textContent = 'Запустить';
                    startBtn.disabled = false;
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

                fs.exec_direct('/bin/sh', ['-c',
                    'sh /etc/iptv/IPTV-Manager.sh stop >/dev/null 2>&1 & ' +
                    'sleep 1'
                ]).then(function() {
                    return checkStatus(1000);
                }).catch(function() {
                    statusEl.textContent = '✗ Ошибка';
                    statusEl.style.color = '#ef4444';
                    stopBtn.textContent = 'Остановить';
                    stopBtn.disabled = false;
                });
            }
        }, 'Остановить');

        function checkStatus(delay) {
            var d = delay || 0;
            return new Promise(function(resolve) {
                setTimeout(resolve, d);
            }).then(function() {
                return fs.access('/var/run/iptv-httpd.pid');
            }).then(function() {
                statusEl.textContent = '● Запущен';
                statusEl.style.color = '#22c55e';
                startBtn.textContent = '✓ Работает';
                startBtn.disabled = false;
                stopBtn.disabled = false;
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
