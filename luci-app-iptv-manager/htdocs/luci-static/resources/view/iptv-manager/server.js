'use strict';
'require view';
'require uci';
'require ui';

return view.extend({
    load: function() {
        return Promise.all([
            uci.load('iptv'),
            L.resolveDefault(uci.get('system', '@system[0]', 'hostname'), 'OpenWrt')
        ]);
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

                // Try to check if running
                var xhr = new XMLHttpRequest();
                xhr.open('GET', adminUrl, true);
                xhr.timeout = 5000;
                xhr.onload = function() {
                    // Already running — nothing to do
                    statusEl.textContent = '● Уже запущен';
                    statusEl.style.color = '#22c55e';
                    startBtn.textContent = '✓ Работает';
                    startBtn.disabled = false;
                    infoEl.textContent = 'Сервер работает. Админка: ' + adminUrl;
                };
                xhr.onerror = xhr.ontimeout = function() {
                    // Not running — start via init script
                    statusEl.textContent = 'Запуск через init-скрипт...';
                    // Try ubus to execute command
                    var cmd = '/etc/init.d/iptv-manager start';
                    L.ubus(null, 'file', 'exec', {
                        command: '/bin/sh',
                        params: ['-c', cmd]
                    }).then(function() {
                        checkStatusAfter(3000);
                    }).catch(function() {
                        // Fallback: try ubus via call with session
                        L.ubus(null, 'uci', 'get', { config: 'system', section: '@system[0]' }).then(function() {
                            // Ubus works, try exec
                            return L.ubus.call('file', 'exec', {
                                command: '/bin/sh',
                                params: ['-c', cmd]
                            });
                        }).then(function() {
                            checkStatusAfter(3000);
                        }).catch(function(e) {
                            statusEl.textContent = '✗ Ошибка';
                            statusEl.style.color = '#ef4444';
                            infoEl.innerHTML = '<span style="color:#ef4444">Не удалось запустить автоматически. Выполните:</span><br><code>sh /etc/iptv/IPTV-Manager.sh</code>';
                            startBtn.disabled = false;
                            startBtn.textContent = 'Запустить';
                        });
                    });
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
                    statusEl.style.color = '#ef4444';
                    startBtn.textContent = 'Запустить';
                    startBtn.disabled = false;
                    stopBtn.disabled = false;
                    stopBtn.textContent = 'Остановить';
                    infoEl.textContent = '';
                };
                xhr.onload = onDone;
                xhr.onerror = onDone;
                xhr.ontimeout = onDone;
                xhr.send('action=stop_server');
            }
        }, 'Остановить');

        function checkStatusAfter(delay) {
            setTimeout(function() {
                var xhr2 = new XMLHttpRequest();
                xhr2.open('GET', adminUrl, true);
                xhr2.timeout = 3000;
                xhr2.onload = function() {
                    statusEl.textContent = '● Запущен';
                    statusEl.style.color = '#22c55e';
                    startBtn.textContent = '✓ Работает';
                    startBtn.disabled = false;
                    infoEl.textContent = 'Сервер запущен: ' + adminUrl;
                };
                xhr2.onerror = xhr2.ontimeout = function() {
                    statusEl.textContent = '✗ Не удалось запустить';
                    statusEl.style.color = '#ef4444';
                    infoEl.innerHTML = '<span style="color:#ef4444">Сервер не ответил. Попробуйте: sh /etc/iptv/IPTV-Manager.sh</span>';
                    startBtn.textContent = 'Запустить';
                    startBtn.disabled = false;
                };
                xhr2.send();
            }, delay);
        }

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
                startBtn.textContent = '✓ Работает';
                infoEl.textContent = 'Сервер работает: ' + adminUrl;
            };
            xhr.onerror = xhr.ontimeout = function() {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
                stopBtn.disabled = true;
                startBtn.disabled = false;
                startBtn.textContent = 'Запустить';
                infoEl.textContent = '';
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
