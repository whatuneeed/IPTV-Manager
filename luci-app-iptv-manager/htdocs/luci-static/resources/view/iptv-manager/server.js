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
                statusEl.style.color = '#1a73e8';
                statusEl.textContent = 'Запуск...';
                infoEl.textContent = '';
                
                var xhr = new XMLHttpRequest();
                xhr.open('GET', adminUrl, true);
                xhr.timeout = 5000;
                xhr.onload = function() {
                    statusEl.textContent = '● Уже запущен';
                    statusEl.style.color = '#22c55e';
                    startBtn.textContent = '✓ Работает';
                    startBtn.disabled = false;
                    infoEl.textContent = 'Сервер работает';
                };
                xhr.onerror = xhr.ontimeout = function() {
                    checkStatusAfter(4000);
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
                    startBtn.textContent = 'Запустить';
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

        function checkStatusAfter(delay) {
            setTimeout(function() {
                var initScript = '/etc/init.d/iptv-manager start 2>/dev/null; /etc/rc.local 2>/dev/null';
                
                L.ubus(null, 'file', 'exec', {
                    command: '/bin/sh',
                    params: ['-c', initScript]
                }).then(function(res) {
                    setTimeout(function() {
                        checkRunning();
                    }, 2000);
                }).catch(function(e) {
                    statusEl.textContent = '✗ Нет доступа к запуску';
                    statusEl.style.color = '#ef4444';
                    infoEl.innerHTML = 'Выполните в терминале: <code>sh /etc/iptv/IPTV-Manager.sh</code>';
                    startBtn.textContent = 'Запустить';
                    startBtn.disabled = false;
                });
            }, delay);
        }

        function checkRunning() {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', adminUrl, true);
            xhr.timeout = 3000;
            xhr.onload = function() {
                statusEl.textContent = '● Запущен';
                statusEl.style.color = '#22c55e';
                startBtn.textContent = '✓ Работает';
                startBtn.disabled = false;
            };
            xhr.onerror = xhr.ontimeout = function() {
                statusEl.textContent = '✗ Не удалось запустить';
                statusEl.style.color = '#ef4444';
                infoEl.innerHTML = 'Сервер не ответил. Выполните: <code>sh /etc/iptv/IPTV-Manager.sh</code>';
                startBtn.textContent = 'Запустить';
                startBtn.disabled = false;
            };
            xhr.send();
        }

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        setTimeout(function() {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', adminUrl, true);
            xhr.timeout = 3000;
            xhr.onload = function() {
                statusEl.textContent = '● Запущен';
                statusEl.style.color = '#22c55e';
                stopBtn.disabled = false;
                startBtn.textContent = '✓ Работает';
            };
            xhr.onerror = xhr.ontimeout = function() {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
                stopBtn.disabled = true;
                startBtn.disabled = false;
                startBtn.textContent = 'Запустить';
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
