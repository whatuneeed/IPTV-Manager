'use strict';
'require view';
'require uci';
'require dom';
'require ui';

return view.extend({
    load: function() {
        return Promise.all([uci.load('iptv')]);
    },

    render: function() {
        var lan_ip = uci.get('network', 'lan', 'ipaddr') || '192.168.1.1';
        var port = '8082';
        var serverUrl = 'http://' + lan_ip + ':' + port + '/cgi-bin/admin.cgi';

        var statusEl = E('span', { 'style': 'color:#666;font-size:13px' }, _('Статус: проверка...'));

        var startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                startBtn.disabled = true;
                startBtn.textContent = _('Запуск...');
                statusEl.textContent = _('Запуск сервера...');
                statusEl.style.color = '#1a73e8';
                fetch(serverUrl)
                    .then(function(r) {
                        if (r.ok) {
                            statusEl.textContent = _('● Запущен');
                            statusEl.style.color = '#22c55e';
                            startBtn.textContent = _('✓ Работает');
                        } else {
                            statusEl.textContent = _('✗ Ошибка');
                            statusEl.style.color = '#ef4444';
                        }
                    })
                    .catch(function() {
                        statusEl.textContent = _('✗ Не удалось запустить');
                        statusEl.style.color = '#ef4444';
                    })
                    .finally(function() { startBtn.disabled = false; });
            }
        }, _('Запустить сервер'));

        var stopBtn = E('button', {
            'class': 'cbi-button cbi-button-negative',
            'click': function(ev) {
                stopBtn.disabled = true;
                stopBtn.textContent = _('Остановка...');
                var xhr = new XMLHttpRequest();
                xhr.open('POST', serverUrl);
                xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
                xhr.onload = function() {
                    statusEl.textContent = _('○ Остановлен');
                    statusEl.style.color = '#ef4444';
                    stopBtn.textContent = _('✓ Остановлен');
                    stopBtn.disabled = false;
                };
                xhr.onerror = function() {
                    statusEl.textContent = _('✗ Ошибка остановки');
                    statusEl.style.color = '#ef4444';
                    stopBtn.disabled = false;
                };
                xhr.send('action=stop_server');
            }
        }, _('Остановить сервер'));

        var btnRow = E('div', {
            'class': 'cbi-section',
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        var frame = E('iframe', {
            'src': serverUrl,
            'style': 'width:100%;height:calc(100vh - 240px);border:none;display:block;margin-top:10px',
            'frameborder': '0'
        });

        // Initial status check
        setTimeout(function() {
            fetch(serverUrl)
                .then(function(r) {
                    if (r.ok) {
                        statusEl.textContent = _('● Запущен');
                        statusEl.style.color = '#22c55e';
                    } else {
                        statusEl.textContent = _('○ Остановлен');
                        statusEl.style.color = '#666';
                    }
                })
                .catch(function() {
                    statusEl.textContent = _('○ Остановлен');
                    statusEl.style.color = '#666';
                });
        }, 500);

        return E([
            E('h2', {}, _('IPTV')),
            E('p', {}, _('Управление каналами и просмотр ТВ')),
            E('div', { 'style': 'height:10px' }),
            btnRow,
            frame
        ]);
    }
});
