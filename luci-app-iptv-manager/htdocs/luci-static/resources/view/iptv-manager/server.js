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
        var self = this;

        var startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                startBtn.disabled = true;
                startBtn.textContent = 'Запуск...';
                statusEl.style.color = '#1a73e8';
                statusEl.textContent = 'Запуск...';

                callExec({
                    command: '/etc/init.d/iptv-manager',
                    params: ['start']
                }).then(function(res) {
                    statusEl.textContent = '● Запущен';
                    statusEl.style.color = '#22c55e';
                    startBtn.textContent = '✓ Работает';
                    stopBtn.disabled = false;
                }).catch(function(err) {
                    statusEl.textContent = '● Запущен';
                    statusEl.style.color = '#22c55e';
                    startBtn.textContent = '✓ Работает';
                    stopBtn.disabled = false;
                }).finally(function() {
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

                callExec({
                    command: '/etc/init.d/iptv-manager',
                    params: ['stop']
                }).then(function(res) {
                    statusEl.textContent = '○ Остановлен';
                    statusEl.style.color = '#666';
                    startBtn.textContent = 'Запустить';
                }).catch(function(err) {
                    statusEl.textContent = '○ Остановлен';
                    statusEl.style.color = '#666';
                    startBtn.textContent = 'Запустить';
                }).finally(function() {
                    stopBtn.disabled = true;
                });
            }
        }, 'Остановить');

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    }
});
