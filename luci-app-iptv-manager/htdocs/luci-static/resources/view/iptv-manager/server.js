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

    _isRunning: function() {
        return callExec({
            command: '/bin/sh',
            params: ['-c', 'wget -q -O /dev/null --timeout=2 http://127.0.0.1:8082/ 2>/dev/null']
        }).then(function(res) {
            return res.code === 0;
        }).catch(function() {
            return false;
        });
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
                }).then(function() {
                    return new Promise(function(r) { setTimeout(r, 3000); });
                }).then(function() {
                    return self._isRunning();
                }).then(function(ok) {
                    _setStatus(ok);
                }).catch(function() {
                    _setStatus(false);
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
                }).then(function() {
                    return new Promise(function(r) { setTimeout(r, 1500); });
                }).then(function() {
                    return self._isRunning();
                }).then(function(ok) {
                    _setStatus(ok);
                }).catch(function() {
                    _setStatus(false);
                });
            }
        }, 'Остановить');

        function _setStatus(ok) {
            if (ok) {
                statusEl.textContent = '● Запущен';
                statusEl.style.color = '#22c55e';
                startBtn.textContent = '✓ Работает';
                startBtn.disabled = false;
                stopBtn.disabled = false;
            } else {
                statusEl.textContent = '○ Остановлен';
                statusEl.style.color = '#666';
                startBtn.textContent = 'Запустить';
                startBtn.disabled = false;
                stopBtn.disabled = true;
            }
        }

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [startBtn, stopBtn, statusEl]);

        self._isRunning().then(function(ok) {
            _setStatus(ok);
        }).catch(function() {
            _setStatus(false);
        });

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    }
});
