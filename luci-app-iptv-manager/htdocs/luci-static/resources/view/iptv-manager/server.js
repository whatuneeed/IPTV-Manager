'use strict';
'require view';
'require uci';
'require rpc';

var callExec = rpc.declare({
    object: 'file',
    method: 'exec',
    params: ['command', 'params'],
    expect: {}
});

return view.extend({
    load: function() {
        return L.resolveDefault(uci.load('iptv'), {});
    },

    render: function(data) {
        var statusEl = E('span', { 'style': 'color:#666;font-size:14px;font-weight:600' }, 'Проверка...');

        var startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                startBtn.disabled = true;
                startBtn.textContent = 'Запуск...';
                callExec({
                    command: '/etc/init.d/iptv-manager',
                    params: ['start']
                }).then(function() {
                    return new Promise(function(r) { setTimeout(r, 2000); });
                }).then(function() {
                    return checkNow();
                }).catch(function() {
                    checkNow();
                });
            }
        }, 'Запустить');

        var stopBtn = E('button', {
            'class': 'cbi-button cbi-button-negative',
            'click': function(ev) {
                stopBtn.disabled = true;
                stopBtn.textContent = 'Остановка...';
                callExec({
                    command: '/etc/init.d/iptv-manager',
                    params: ['stop']
                }).then(function() {
                    return new Promise(function(r) { setTimeout(r, 2000); });
                }).then(function() {
                    return checkNow();
                }).catch(function() {
                    checkNow();
                });
            }
        }, 'Остановить');

        function checkNow() {
            return callExec({
                command: '/bin/sh',
                params: ['-c', 'pgrep -f 8082']
            }).then(function(res) {
                var out = ((res && res.stdout) || '').trim();
                if (out.length > 0) {
                    statusEl.textContent = '● Запущен';
                    statusEl.style.color = '#22c55e';
                    startBtn.textContent = '✓ Работает';
                    stopBtn.disabled = false;
                } else {
                    statusEl.textContent = '○ Остановлен';
                    statusEl.style.color = '#666';
                    startBtn.textContent = 'Запустить';
                    stopBtn.disabled = true;
                }
            }).catch(function() {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
                startBtn.textContent = 'Запустить';
                stopBtn.disabled = true;
            }).finally(function() {
                startBtn.disabled = false;
            });
        }

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        setTimeout(function() { checkNow(); }, 500);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    }
});
