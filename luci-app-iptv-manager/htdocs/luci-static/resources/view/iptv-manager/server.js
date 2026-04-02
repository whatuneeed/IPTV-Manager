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

    _checkStatus: function(sel) {
        return callExec({
            command: '/etc/iptv/IPTV-Manager.sh',
            params: ['status']
        }).then(function(res) {
            var out = (res.stdout || '').trim();
            if (out.indexOf('running') > -1) {
                sel._statusEl.textContent = '● Запущен';
                sel._statusEl.style.color = '#22c55e';
                sel._startBtn.textContent = '✓ Работает';
                sel._startBtn.disabled = false;
                sel._stopBtn.disabled = false;
            } else {
                sel._statusEl.textContent = '○ Остановлен';
                sel._statusEl.style.color = '#666';
                sel._startBtn.textContent = 'Запустить';
                sel._startBtn.disabled = false;
                sel._stopBtn.disabled = true;
            }
        }).catch(function() {
            sel._statusEl.textContent = '○ Остановлен';
            sel._statusEl.style.color = '#666';
            sel._startBtn.textContent = 'Запустить';
            sel._startBtn.disabled = false;
            sel._stopBtn.disabled = true;
        });
    },

    render: function(data) {
        var sel = {};
        sel._statusEl = E('span', { 'style': 'color:#666;font-size:14px;font-weight:600' }, 'Проверка...');

        sel._startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                sel._startBtn.disabled = true;
                sel._startBtn.textContent = 'Запуск...';
                sel._statusEl.style.color = '#1a73e8';
                sel._statusEl.textContent = 'Запуск...';

                callExec({
                    command: '/etc/iptv/IPTV-Manager.sh',
                    params: ['start']
                }).then(function() {
                    return new Promise(function(r) { setTimeout(r, 3000); });
                }).then(function() {
                    return sel._checkStatus(sel);
                }).catch(function() {
                    sel._checkStatus(sel);
                });
            }
        }, 'Запустить');

        sel._stopBtn = E('button', {
            'class': 'cbi-button cbi-button-negative',
            'click': function(ev) {
                sel._stopBtn.disabled = true;
                sel._stopBtn.textContent = 'Остановка...';
                sel._statusEl.style.color = '#ef4444';
                sel._statusEl.textContent = 'Остановка...';

                callExec({
                    command: '/etc/iptv/IPTV-Manager.sh',
                    params: ['stop']
                }).then(function() {
                    return new Promise(function(r) { setTimeout(r, 1500); });
                }).then(function() {
                    return sel._checkStatus(sel);
                }).catch(function() {
                    sel._checkStatus(sel);
                });
            }
        }, 'Остановить');

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [sel._startBtn, sel._stopBtn, sel._statusEl]);

        setTimeout(function() { sel._checkStatus(sel); }, 500);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    }
});
